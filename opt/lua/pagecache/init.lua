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
--   pagecache:v{version}:{host}:{request_uri}          content key
--   pagecache:fence:{host}:{request_uri}                purge fence (no version)
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
local BYPASS_URI = {
    "/wp%-admin", "/wp%-login", "/wp%-json", "/xmlrpc%.php",
    "wp%-cron", "/feed", "sitemap",
}

-- Request cookies that mean "personalised" — logged in, commenter, password.
local BYPASS_COOKIE = {
    "wordpress_logged_in", "wordpress_[a-f0-9]+", "comment_author",
    "wp%-postpass", "wordpress_no_cache",
}

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

local function build_key(red)
    local ver = red:get(VERSION_KEY)
    if ver == ngx.null or not ver then ver = "0" end
    return PREFIX .. "v" .. ver .. ":" .. ngx.var.host .. ":" .. ngx.var.request_uri
end

-- Fence key for this path. Unversioned and shared with the WP purge plugin,
-- which must build this exact same key from $host/$path.
local function build_fence_key()
    return PREFIX .. "fence:" .. ngx.var.host .. ":" .. ngx.var.request_uri
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
    if not request_cacheable() then set_status("bypass"); return end

    local red = redis_pool.connect()
    if not red then set_status("down"); return end       -- fail-open -> PHP

    local key  = build_key(red)
    local blob = red:get(key)
    if blob == ngx.null or not blob then
        -- Snapshot Redis's own clock (not local wall-clock - avoids drift
        -- across pods) so the deferred write can tell if a purge landed
        -- after this request started rendering.
        local time_ok, time_res = pcall(function() return red:time() end)
        local started = nil
        if time_ok and type(time_res) == "table" and time_res[1] then
            started = tostring(time_res[1]) .. "." .. tostring(time_res[2] or "0")
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

    -- Stored blob = "<content-type>\n<body>". Split on the first newline.
    local nl   = blob:find("\n", 1, true)
    local ct   = nl and blob:sub(1, nl - 1) or DEFAULT_CT
    local body = nl and blob:sub(nl + 1) or blob

    ngx.header["Content-Type"] = ct
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

    local ct = ngx.header["Content-Type"] or ""
    local cc = ngx.header["Cache-Control"] or ""
    if ngx.status ~= 200
        or not ct:find("text/html", 1, true)
        or ngx.header["Set-Cookie"]                       -- personalised response
        or ngx.header["Content-Encoding"]                 -- store uncompressed only
        or cc:find("no%-cache") or cc:find("no%-store") or cc:find("private")
    then
        ngx.ctx.pc_store = false
        return
    end
    ngx.ctx.pc_ct = ct
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
            return
        end
        buf[#buf + 1] = chunk
    end
end


-- Timer callback: the actual Redis write (cosockets are allowed in timers).
--
-- Fenced write: if `started` is set, the write only commits when no purge
-- fence for this path was stamped at or after `started`. A fence at/after
-- that time means a purge happened mid-render, so `body` may be stale -
-- the write is silently dropped rather than re-caching old content.
-- Check + write happen in one EVAL so there's no gap between them.
local function write_to_redis(premature, key, fence_key, started, ct, body)
    if premature then return end
    local red = redis_pool.connect()
    if not red then return end

    local value = ct .. "\n" .. body
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
    if not ngx.ctx.pc_store or not ngx.ctx.pc_buf then return end
    local body = table.concat(ngx.ctx.pc_buf)
    if body == "" then return end

    local ok, err = ngx.timer.at(0, write_to_redis,
        ngx.ctx.pc_key, ngx.ctx.pc_fence, ngx.ctx.pc_started,
        ngx.ctx.pc_ct or DEFAULT_CT, body)
    if not ok then
        ngx.log(ngx.ERR, "[pagecache] store timer failed: ", err)
    end
end

return _M
