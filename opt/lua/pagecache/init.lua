-- ============================================================================
-- FULL-PAGE CACHE (OpenResty + Redis)
-- ============================================================================
-- Serves cached HTML straight from Redis (db1), skipping PHP entirely on a HIT.
-- Shared across ALL pods (unlike nginx's per-pod fastcgi_cache, which this
-- replaces). Invalidated per-URL by the WordPress purge mu-plugin on publish.
--
-- Wiring (in the `location ~ \.php$` block):
--   access_by_lua   -> pagecache.fetch()         serve HIT, or flag MISS to store
--   header_filter   -> pagecache.filter_headers()decide if the response is storeable
--   body_filter     -> pagecache.capture_body()  buffer the HTML (no cosocket here)
--   log_by_lua      -> pagecache.store()         persist to Redis via a 0-delay timer
--
-- Fail-open everywhere: any Redis problem just means PHP serves the request.
--
-- KEY SCHEME (must match the WP purge mu-plugin):
--   pagecache:v{version}:{host}:{path}                  content key
--   pagecache:fence:{host}:{path}                        purge fence (no version)
--   - value is the PC2 blob: allowlisted response headers + body (see
--     encode_blob()); Yoast's X-Robots-Tag etc. survive a HIT that way.
--   - {path} is $request_uri minus any query portion (see cache_path()).
--   - {host} isolates multisite sites; {version} bumps for an instant mass flush.
--   - scheme is deliberately omitted: TLS is terminated upstream, so the scheme
--     nginx sees can differ from what WordPress sees. Host + path is canonical.
--
-- PURGE/WRITE RACE: a request that MISSes can still be mid-render when an
-- editor publishes and the purge plugin deletes that path's cache entry.
-- The deferred Redis write (after the response is sent) would otherwise
-- re-cache that now-stale render straight into the just-purged key. The
-- fence key closes this: the purge stamps it with the current Redis time,
-- and the deferred write only commits if no fence was stamped at/after the
-- time this request started rendering (see write_to_redis/CAS_WRITE_SCRIPT).
-- ============================================================================

local redis_pool = require "pagecache.redis"

local _M = {}

local ENABLED     = os.getenv("PAGECACHE_ENABLED") == "true"
local TTL         = tonumber(os.getenv("PAGECACHE_TTL")) or 300
local MAX_BYTES   = tonumber(os.getenv("PAGECACHE_MAX_BYTES")) or (2 * 1024 * 1024)
local PREFIX      = "pagecache:"
local VERSION_KEY = "pagecache:version"
local DEFAULT_CT  = "text/html; charset=UTF-8"

-- Request URIs that must never be cached (admin, auth, API, cron, feeds...).
-- request_uri is the ORIGINAL url, before the internal rewrite to index.php.
-- Lua patterns (no '|' alternation), matched unanchored via uri:find(), so
-- subdirectory-multisite prefixes ("/site1/wp-signup.php") still match.
-- Feed/search/sitemap patterns are anchored enough that content slugs like
-- /feedback/ or /research/ stay cacheable.
-- /hale-wpms-2020/ is the wps-hide-login slug (platform-wide login path).
-- Its responses are redirects/login pages that the filter_headers() guards
-- (status 200 + Set-Cookie + no-cache) would refuse anyway; listing it here
-- makes the intent explicit and skips the Redis lookup entirely.
local BYPASS_URI = {
    "/wp%-admin", "/wp%-login", "/wp%-json", "/xmlrpc%.php",
    "wp%-cron", "wp%-signup", "wp%-activate",
    "/hale%-wpms%-2020",
    "/feed/", "/feed$", "/comments/feed",
    "sitemap[^/]*%.xml", "/search/", "/search$",
}

-- Request cookies that mean "personalised" — logged in, commenter, password.
local BYPASS_COOKIE = {
    "wordpress_logged_in", "wordpress_[a-f0-9]+", "comment_author",
    "wp%-postpass", "wordpress_no_cache",
}

-- Response headers (besides Content-Type) preserved into the cache blob and
-- replayed on a HIT. A HIT skips PHP entirely, so any header not listed here
-- is silently dropped from cached responses. Yoast SEO emits X-Robots-Tag
-- (e.g. "noindex, follow") on pages excluded from indexing — losing it would
-- let search engines index those pages. WP core emits Link (REST discovery,
-- shortlink).
local STORE_HEADERS = { "X-Robots-Tag", "Link" }

-- Blob format v2: "PC2\n", one "Name: value" line per stored header
-- (Content-Type always first), a blank line, then the body. Legacy blobs
-- ("<content-type>\n<body>") are still readable; new writes are always PC2.
-- An old worker reading a PC2 blob during a rolling deploy serves it wrongly
-- for up to TTL — accepted, same tradeoff as the fence format changeover.
local BLOB_MAGIC = "PC2\n"

local function encode_blob(ct, hdrs, body)
    local lines = { "PC2", "Content-Type: " .. ct }
    for _, h in ipairs(hdrs or {}) do
        lines[#lines + 1] = h[1] .. ": " .. h[2]
    end
    return table.concat(lines, "\n") .. "\n\n" .. body
end

-- Returns content-type, header list ({name, value} pairs) or nil, body.
local function decode_blob(blob)
    if blob:sub(1, 4) ~= BLOB_MAGIC then
        -- Legacy format: "<content-type>\n<body>".
        local nl = blob:find("\n", 1, true)
        local ct = nl and blob:sub(1, nl - 1) or DEFAULT_CT
        local body = nl and blob:sub(nl + 1) or blob
        return ct, nil, body
    end
    local sep = blob:find("\n\n", 5, true)
    if not sep then
        -- No header/body separator: never written by encode_blob, so the
        -- blob is corrupt. Serve the remainder as-is rather than erroring.
        return DEFAULT_CT, nil, blob:sub(5)
    end
    local ct, hdrs = DEFAULT_CT, {}
    for line in blob:sub(5, sep - 1):gmatch("[^\n]+") do
        local name, value = line:match("^([^:]+):%s*(.*)$")
        if name then
            if name:lower() == "content-type" then
                ct = value
            else
                hdrs[#hdrs + 1] = { name, value }
            end
        end
    end
    return ct, hdrs, blob:sub(sep + 2)
end

-- $pagecache_status is a map var (declared in the *.conf files), surfaced in the
-- access log so HIT/MISS/BYPASS is visible per request.
local function set_status(s)
    ngx.var.pagecache_status = s
end

-- Is this REQUEST eligible to read/write the page cache?
local function request_cacheable()
    if ngx.req.get_method() ~= "GET" then return false end
    if (ngx.var.args or "") ~= "" then return false end   -- query string -> dynamic

    local uri = ngx.var.request_uri or ""
    for _, pat in ipairs(BYPASS_URI) do
        if uri:find(pat) then return false end
    end

    local cookie = ngx.var.http_cookie
    if cookie then
        for _, pat in ipairs(BYPASS_COOKIE) do
            if cookie:find(pat) then return false end
        end
    end
    return true
end

-- Path used in cache keys: $request_uri with any query portion stripped.
-- Only reachable with an EMPTY query ("/path?" - request_cacheable rejects
-- non-empty $args), but "/path?" would otherwise key separately from
-- "/path" and the WP purge plugin (which keys on path alone) could never
-- delete it. $uri can't be used instead: it's already rewritten to
-- /index.php by the permalink handling.
local function cache_path()
    local uri = ngx.var.request_uri or "/"
    local q = uri:find("?", 1, true)
    if q then uri = uri:sub(1, q - 1) end
    return uri
end

-- The version is cached per worker for VERSION_TTL seconds: it halves the
-- Redis round-trips on every request, at the cost of a version bump (mass
-- flush) taking up to VERSION_TTL to be seen by this worker. Per-URL purges
-- are unaffected: they DEL the content key and stamp the unversioned fence,
-- neither of which involves the version.
local VERSION_TTL = 1
local ver_cache, ver_cached_at = nil, 0

local function get_version(red)
    local now = ngx.now()
    if ver_cache and (now - ver_cached_at) < VERSION_TTL then
        return ver_cache
    end
    local res = red:get(VERSION_KEY)
    if res == ngx.null then
        -- Key absent (never bumped) = version 0. The PHP purge plugin's
        -- (int) cast derives 0 from a missing key too. Cached like any
        -- other value so the common no-bump state still skips the GET.
        ver_cache, ver_cached_at = 0, now
        return 0
    end
    local ver = tonumber(res)
    if ver then
        -- Normalise to an integer: the PHP purge plugin does (int) on this
        -- same value, and the two sides must derive identical keys from it.
        ver_cache, ver_cached_at = math.floor(ver), now
        return ver_cache
    end
    -- GET errored (returned nil): keep the last-known version rather than
    -- falling back to v0, which would miss everything and write entries
    -- under a key no purge would ever touch.
    return ver_cache or 0
end

local function build_key(red)
    return PREFIX .. "v" .. get_version(red) .. ":" .. ngx.var.host .. ":" .. cache_path()
end

-- Fence key for this path. Unversioned and shared with the WP purge plugin,
-- which must build this exact same key from $host/$path.
local function build_fence_key()
    return PREFIX .. "fence:" .. ngx.var.host .. ":" .. cache_path()
end

-- Atomic check-and-write: refuse to cache a render if a purge fence for this
-- path was stamped at or after the time this request started rendering.
-- That means a purge happened mid-render, so the buffered body may be stale.
local CAS_WRITE_SCRIPT = [[
local fence = redis.call('GET', KEYS[2])
if fence and tonumber(fence) and tonumber(ARGV[3])
   and tonumber(fence) >= tonumber(ARGV[3]) then
    return 0
end
redis.call('SETEX', KEYS[1], ARGV[1], ARGV[2])
return 1
]]


-- ============================================================================
-- fetch(): access phase. Serve a HIT, or flag the request to be stored on MISS.
-- ============================================================================
function _M.fetch()
    if not ENABLED then set_status("off"); return end
    if not request_cacheable() then
        ngx.header["X-Page-Cache"] = "BYPASS"
        set_status("bypass")
        return
    end

    local red = redis_pool.connect()
    if not red then set_status("down"); return end       -- fail-open -> PHP

    local key  = build_key(red)
    local blob = red:get(key)
    if blob == ngx.null or not blob then
        -- Snapshot Redis's own clock (not local wall-clock - avoids drift
        -- across pods) so the deferred write can tell if a purge landed
        -- after this request started rendering. Integer microseconds:
        -- "sec.usec" string concatenation would mis-order within a second
        -- ({1234, 5} -> "1234.5" reads as half a second, not 5us). Must
        -- match the fence format in the hale-components purge module.
        local time_ok, time_res = pcall(function() return red:time() end)
        local started = nil
        if time_ok and type(time_res) == "table" and tonumber(time_res[1]) then
            started = tostring(
                tonumber(time_res[1]) * 1000000 + (tonumber(time_res[2]) or 0))
        end
        redis_pool.release(red)
        ngx.ctx.pc_key     = key                         -- remember for store phase
        ngx.ctx.pc_fence   = build_fence_key()
        ngx.ctx.pc_started = started
        ngx.ctx.pc_store   = true
        set_status("miss")
        return
    end
    redis_pool.release(red)

    local ct, hdrs, body = decode_blob(blob)

    ngx.header["Content-Type"] = ct
    for _, h in ipairs(hdrs or {}) do
        local cur = ngx.header[h[1]]
        if cur then
            -- Same name stored more than once -> multi-value header.
            if type(cur) ~= "table" then cur = { cur } end
            cur[#cur + 1] = h[2]
            ngx.header[h[1]] = cur
        else
            ngx.header[h[1]] = h[2]
        end
    end
    ngx.header["X-Page-Cache"] = "HIT"
    set_status("hit")
    ngx.print(body)
    ngx.exit(ngx.HTTP_OK)
end


-- ============================================================================
-- filter_headers(): header phase. Confirm the RESPONSE is safe to cache.
-- ============================================================================
function _M.filter_headers()
    if not ngx.ctx.pc_store then return end

    -- Either header can be a table if PHP emitted it more than once.
    local ct = ngx.header["Content-Type"] or ""
    local cc = ngx.header["Cache-Control"] or ""
    if type(ct) == "table" then ct = ct[1] or "" end
    if type(cc) == "table" then cc = table.concat(cc, ", ") end
    if ngx.status ~= 200
        or not ct:find("text/html", 1, true)
        or ngx.header["Set-Cookie"]                       -- personalised response
        or ngx.header["Content-Encoding"]                 -- store uncompressed only
        or cc:find("no%-cache") or cc:find("no%-store") or cc:find("private")
    then
        ngx.ctx.pc_store = false
        ngx.header["X-Page-Cache"] = "BYPASS"
        set_status("bypass")   -- would otherwise log "miss", implying storeable
        return
    end
    ngx.ctx.pc_ct = ct

    -- Snapshot the allowlisted headers now; they're gone by the log phase
    -- on some code paths and this is the last cheap place to read them.
    local hdrs = {}
    for _, name in ipairs(STORE_HEADERS) do
        local v = ngx.header[name]
        if type(v) == "table" then
            for _, one in ipairs(v) do hdrs[#hdrs + 1] = { name, one } end
        elseif v then
            hdrs[#hdrs + 1] = { name, v }
        end
    end
    ngx.ctx.pc_hdrs = hdrs

    ngx.header["X-Page-Cache"] = "MISS"
end


-- ============================================================================
-- capture_body(): body phase. Buffer the HTML. No cosocket (Redis) allowed here.
-- ============================================================================
function _M.capture_body()
    if not ngx.ctx.pc_store then return end

    local buf = ngx.ctx.pc_buf
    if not buf then buf = {}; ngx.ctx.pc_buf = buf; ngx.ctx.pc_len = 0 end

    local chunk = ngx.arg[1]
    if chunk and chunk ~= "" then
        ngx.ctx.pc_len = ngx.ctx.pc_len + #chunk
        if ngx.ctx.pc_len > MAX_BYTES then                -- too big: give up storing
            ngx.ctx.pc_store = false
            ngx.ctx.pc_buf = nil
            -- headers already sent (X-Page-Cache: MISS) - too late to say BYPASS
            set_status("bypass")   -- would otherwise log "miss", implying storeable
            return
        end
        buf[#buf + 1] = chunk
    end

    -- Only a body that reached eof is complete. Without this, a client
    -- abort mid-response would cache the truncated page for the full TTL.
    if ngx.arg[2] then
        ngx.ctx.pc_eof = true
    end
end


-- Timer callback: the actual Redis write (cosockets are allowed in timers).
--
-- Fenced write: if `started` is set, the write only commits when no purge
-- fence for this path was stamped at or after `started`. A fence at/after
-- that time means a purge happened mid-render, so `body` may be stale -
-- the write is silently dropped rather than re-caching old content.
-- Check + write happen in one EVAL so there's no gap between them.
local function write_to_redis(premature, key, fence_key, started, ct, hdrs, body)
    if premature then return end
    local red = redis_pool.connect()
    if not red then return end

    local value = encode_blob(ct, hdrs, body)
    if started and fence_key then
        -- SETEX guarantees a TTL on every key -> eligible for volatile-lru
        -- eviction, so the shared instance can never evict the firewall's
        -- persistent keys. (Done inside the script too - see CAS_WRITE_SCRIPT.)
        local ok, err = red:eval(CAS_WRITE_SCRIPT, 2, key, fence_key, TTL, value, started)
        if not ok then
            ngx.log(ngx.ERR, "[pagecache] fenced write failed: ", err)
        end
    else
        -- No snapshot time available (e.g. Redis TIME failed earlier) -
        -- fall back to an unfenced write rather than dropping the cache
        -- entirely. Rare; only happens on a partial Redis failure.
        red:setex(key, TTL, value)
    end
    redis_pool.release(red)
end


-- ============================================================================
-- store(): log phase. Schedule the Redis write once the response is sent.
-- ============================================================================
function _M.store()
    if not ngx.ctx.pc_store or not ngx.ctx.pc_buf or not ngx.ctx.pc_eof then return end
    local body = table.concat(ngx.ctx.pc_buf)
    if body == "" then return end

    local ok, err = ngx.timer.at(0, write_to_redis,
        ngx.ctx.pc_key, ngx.ctx.pc_fence, ngx.ctx.pc_started,
        ngx.ctx.pc_ct or DEFAULT_CT, ngx.ctx.pc_hdrs, body)
    if not ok then
        ngx.log(ngx.ERR, "[pagecache] store timer failed: ", err)
    end
end

-- Exposed for tests only; not part of the module interface.
_M._encode_blob = encode_blob
_M._decode_blob = decode_blob

return _M
