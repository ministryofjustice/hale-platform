-- ============================================================================
-- FIREWALL MODULE - GCRA Rate Limiting
-- ============================================================================
-- Uses GCRA (Generic Cell Rate Algorithm) for rate limiting instead of
-- simple score accumulation. This solves the TTL refresh bug where slow
-- attackers could accumulate infinite score.
--
-- USAGE:
--   In nginx.conf, set:
--     access_by_lua_block { require("firewall").req() }
--     log_by_lua_block { require("firewall").res() }
--     content_by_lua_block { require("firewall").stats() }
--
-- REDIS KEYS:
--   firewall:rules   - JSON array of scoring rules
--   firewall:config  - JSON object {emission_interval, burst}
--   gcra:{ip}        - GCRA TAT (theoretical arrival time) per IP
--
-- LUA QUICK REFERENCE FOR THIS FILE:
--   - Comments start with -- (double dash)
--   - "local" restricts scope to this file (like "private" in other languages)
--   - Tables {} are Lua's only data structure (used as arrays AND objects)
--   - Strings concatenate with .. (two dots), e.g., "hello" .. "world"
--   - nil is Lua's null/undefined
--   - "and" / "or" are logical operators (not && / ||)
--   - Functions can return multiple values: local ok, err = some_func()
--   - #table gives the length of an array-style table
--
-- OPENRESTY CONCEPTS:
--   - This runs inside nginx via OpenResty (nginx + LuaJIT)
--   - "ngx" is a global object provided by OpenResty for nginx interaction
--   - ngx.var.* accesses nginx variables (request headers, IP, etc.)
--   - ngx.log() writes to nginx error log
--   - ngx.say() writes to HTTP response body
--   - resty.redis is OpenResty's non-blocking Redis client
-- ============================================================================


-- ============================================================================
-- MODULE TABLE
-- ============================================================================
-- In Lua, modules are just tables. We create an empty table "_M" and attach
-- functions to it. At the end of the file, we "return _M" to export it.
-- When nginx.conf does require("firewall"), it gets this table back.
-- ============================================================================
local _M = {}


-- ============================================================================
-- LOAD SUBMODULES
-- ============================================================================
-- require() loads a Lua module. Unlike Node.js require(), Lua caches modules
-- so this is cheap after first call.
--
-- firewall.redis: Redis connection pooling with fail-open pattern
-- firewall.cost: Pure functions for calculating request cost from rules
-- firewall.gcra: GCRA rate limiting algorithm with Redis Lua script
-- cjson.safe: JSON encoder/decoder (returns nil on error instead of throwing)
-- ============================================================================
local redis_pool   = require "firewall.redis"
local cost_module  = require "firewall.cost"
local gcra_module  = require "firewall.gcra"
local config_module = require "firewall.config"
local cjson = require "cjson.safe"


-- ============================================================================
-- CONFIGURATION
-- ============================================================================
-- These variables are declared with "local" so they're private to this file.
-- os.getenv() reads environment variables; "or" provides a default if nil.
-- Redis config is in firewall/redis.lua module.
-- ============================================================================

-- Kill switch: set to "false" to disable all firewall scoring and blocking.
-- When disabled, req() and res() return immediately with zero overhead.
local FIREWALL_ENABLED = os.getenv("FIREWALL_ENABLED") ~= "false"

-- Per-worker cache for rules + config loaded from Redis.
-- Holds decoded Lua tables (fast — no JSON decode per request).
-- Invalidated when the shared version counter changes, which flush_cache()
-- increments. This propagates config changes to ALL workers, not just the
-- one that handled the /flush-cache request.
local _rc_cache = { rules = nil, config = nil, version = -1, expires = 0 }
local RC_CACHE_TTL = 60  -- seconds

-- Shared dict for cross-worker cache version signal (declared in nginx.conf)
local rc_shared = ngx.shared.firewall_rc_cache

-- Cost penalty for 404 responses. Attackers often probe for vulnerable URLs.
local PENALTY_404 = 50


-- ============================================================================
-- STARTUP HOOK: Called from nginx init_worker_by_lua_block
-- ============================================================================
-- This runs once per nginx worker process when nginx starts (or reloads).
-- We log the resolved firewall settings so operators can verify env config.
--
-- In nginx.conf: init_worker_by_lua_block { require("firewall").init() }
-- ============================================================================
function _M.init()
    ngx.log(
        ngx.NOTICE,
        "[firewall] startup ENABLED=", tostring(FIREWALL_ENABLED),
        " REDIS_SSL=", tostring(redis_pool.config.ssl)
    )
end


-- Redis connection helpers are in firewall/redis.lua module.
-- Use redis_pool.connect() and redis_pool.release(red) for connections.


-- ============================================================================
-- HELPER: Load rules and GCRA config from Redis (with cross-worker cache)
-- ============================================================================
-- Per-worker Lua tables cache the decoded rules/config for RC_CACHE_TTL
-- seconds. A version counter in the shared dict (firewall_rc_cache) lets
-- flush_cache() invalidate all workers simultaneously — each worker detects
-- a version mismatch on its next request and re-reads from Redis.
-- Warnings from validation therefore fire at most once per refresh window
-- per worker, not on every request.
-- ============================================================================
local function load_rules_and_config(red)
    local now            = ngx.now()
    local shared_version = rc_shared:get("version") or 0

    if _rc_cache.expires > now and _rc_cache.version == shared_version then
        return _rc_cache.rules, _rc_cache.config
    end

    -- Fetch both keys from Redis
    local rules_json  = red:get("firewall:rules")
    local config_json = red:get("firewall:config")

    -- Decode JSON (cjson.safe returns nil on invalid JSON instead of throwing)
    local raw_rules  = (rules_json  and rules_json  ~= ngx.null) and cjson.decode(rules_json)  or nil
    local raw_config = (config_json and config_json ~= ngx.null) and cjson.decode(config_json) or nil

    -- Validate and coerce; collect human-readable warnings
    local rules,       rule_warns   = config_module.parse_rules(raw_rules)
    local gcra_config, config_warns = config_module.parse_config(raw_config)

    -- Log any warnings once per cache window (not per request)
    for _, w in ipairs(rule_warns) do
        ngx.log(ngx.WARN, "[firewall] ", w)
    end
    for _, w in ipairs(config_warns) do
        ngx.log(ngx.WARN, "[firewall] ", w)
    end

    _rc_cache = { rules = rules, config = gcra_config, version = shared_version, expires = now + RC_CACHE_TTL }
    return rules, gcra_config
end


-- ============================================================================
-- HELPER: Regex wrapper for cost module
-- ============================================================================
-- The cost module is pure Lua (no ngx dependencies) so it can be unit tested.
-- This wrapper provides ngx.re.match to the cost module for pattern matching.
--
-- ngx.re.match uses PCRE regex with JIT compilation - much faster than
-- Lua's built-in string.match for complex patterns.
--
-- Flags: "ijo" = case-insensitive, JIT-compile, compile-once (cached)
-- ============================================================================
local function ngx_regex_match(subject, pattern)
    local m, err = ngx.re.match(subject, pattern, "ijo")
    return m ~= nil
end


-- ============================================================================
-- REQUEST PHASE: Called on every incoming request
-- ============================================================================
-- This function is called from nginx.conf in the "access_by_lua" directive,
-- which runs before nginx processes the request.
--
-- We calculate the request's "cost" based on rules, then check if the IP
-- has exceeded its rate limit using GCRA (Generic Cell Rate Algorithm).
--
-- BLOCKING OPTIMIZATION:
--   1. Check nginx shared dict first - if IP is cached as blocked, 429 immediately
--   2. If not cached, do GCRA check in Redis
--   3. If blocked: write audit entry ONCE to Redis stream, cache locally
--   4. Subsequent requests from blocked IP hit local cache (0 Redis operations)
--
-- In nginx.conf: access_by_lua_block { require("firewall").req() }
-- ============================================================================

-- Local cache for blocked IPs (nginx shared dict)
local blocked_cache = ngx.shared.firewall_cache

function _M.req()
    -- Early return if firewall is disabled (kill switch)
    if not FIREWALL_ENABLED then return end
    
    -- Get the client's IP address.
    -- nginx's realip module rewrites remote_addr to the client IP from X-Forwarded-For.
    local ip = ngx.var.remote_addr
    
    -- =========================================================================
    -- FAST PATH: Check local cache for blocked IP (0 Redis operations)
    -- =========================================================================
    local cached_block = blocked_cache:get("blocked:" .. ip)
    if cached_block then
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
    
    -- Capture request details for cost calculation
    local uri = ngx.var.uri
    local ua = ngx.var.http_user_agent or ""
    local method = ngx.var.request_method
        local args = ngx.var.args
        local has_query = (args ~= nil and args ~= "")
    
    -- IMPORTANT: ngx.exit() works via a Lua error internally, so it must NOT
    -- be called inside pcall — pcall would catch and swallow it, allowing the
    -- request through. Instead we set a flag inside pcall and call ngx.exit()
    -- after the protected block.
    local blocked = false
    local ok, err = pcall(function()
        -- Get a Redis connection (may return nil if Redis is down)
        local red = redis_pool.connect()
        if not red then return end  -- Fail-open: just exit the function, allow request
        
        -- Load rules and GCRA config from Redis
        local rules, gcra_config = load_rules_and_config(red)
        
        -- No rules in Redis = misconfiguration. Fail open but warn loudly so
        -- operators know to seed firewall:rules (e.g. via firewall.seed_rules()).
        if not rules then
            ngx.log(ngx.ERR, "[firewall] no rules found in Redis (firewall:rules) "
                          .. "— all requests allowed. Run seed_rules() to initialise.")
            redis_pool.release(red)
            return
        end
        
        -- Calculate request cost based on URI, user-agent, method, etc.
        -- Returns total cost and a breakdown table for debugging
        local request_cost, breakdown = cost_module.calculate(
            uri, ua, method, has_query, args, rules, ngx_regex_match
        )
        
        -- Store cost in nginx variable for access log
        -- (avoids noisy per-request error log lines)
        ngx.var.firewall_cost = tostring(request_cost)
        
        -- Check GCRA rate limit (passes breakdown for audit tracking)
        -- Returns: allowed (boolean), info table {retry_after, tat, accumulated, reason}
        -- reason is one of: "allow" (allowlist hit), "block" (blocklist hit), "gcra"
            local allowed, info = gcra_module.check(red, ip, request_cost, gcra_config, breakdown)
        
        -- Allowlist short-circuit: clean bypass, no audit, no local cache.
        -- The GCRA script already skipped TAT update, so nothing else to do.
        if allowed and info.reason == "allow" then
            redis_pool.release(red)
            return
        end
        
        -- If rate limit exceeded, handle the block
        if not allowed then
            -- retry_after is in ms. 0 from a "block" reason means permanent ban.
            -- shared_dict :set(key, value, 0) means "no expiry" — exactly what we want.
            local cache_ttl
            if info.reason == "block" and info.retry_after == 0 then
                cache_ttl = 0  -- permanent
            else
                cache_ttl = math.ceil(info.retry_after / 1000)
            end
            
            -- Cache the block locally to avoid Redis hits for this IP
            blocked_cache:set("blocked:" .. ip, true, cache_ttl)
            
            -- Write audit entry ONCE (subsequent blocks hit local cache, skip this)
            if gcra_config and gcra_config.audit_enabled then
                local now = math.floor(ngx.now() * 1000)
                local audit_stream = gcra_config.audit_stream or "firewall:audit"
                local audit_maxlen = gcra_config.audit_maxlen or 10000
                
                -- Trigger string differs by reason: blocklist hits don't have a
                -- meaningful rule breakdown, GCRA blocks do.
                local trigger
                if info.reason == "block" then
                    trigger = "blocklist"
                else
                    local trigger_parts = {}
                    for rule, rule_cost in pairs(breakdown) do
                        table.insert(trigger_parts, rule .. ":" .. rule_cost)
                    end
                    trigger = table.concat(trigger_parts, ",")
                end
                
                -- Write to audit stream (accumulated comes from GCRA script)
                red:xadd(audit_stream, "MAXLEN", "~", audit_maxlen, "*",
                    "ip", ip,
                    "blocked_at", now,
                    "cost", request_cost,
                    "reason", info.reason,
                    "trigger", trigger,
                    "accumulated", info.accumulated or "")
            end
            
            ngx.log(ngx.WARN, "[firewall] blocked ip=", ip,
                    " reason=", info.reason,
                    " cost=", request_cost,
                    " retry_after=", info.retry_after)
            
            -- Return connection before signalling block
            redis_pool.release(red)
            
            blocked = true
        end
        
        -- Return connection to pool for reuse
        redis_pool.release(red)
    end)
    
    if not ok then
        -- Genuine Lua error - fail open
        ngx.log(ngx.ERR, "[firewall] req error (fail-open): ", err)
    elseif blocked then
        -- ngx.exit() here is outside pcall and cannot be swallowed
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end


-- ============================================================================
-- RESPONSE PHASE: Called after response is sent, for 404s only
-- ============================================================================
-- This runs in nginx's "log_by_lua" phase, after the response is sent.
-- We add extra cost for 404 errors, since attackers often probe for
-- vulnerable URLs which return 404.
--
-- IMPORTANT: The log_by_lua phase does NOT allow socket operations (Redis,
-- HTTP calls, etc.) because the request is already finished. OpenResty
-- disables these APIs to prevent blocking during logging.
--
-- SOLUTION: We use ngx.timer.at(0, callback) to schedule the Redis work
-- in a separate "timer context" where sockets ARE allowed. The "0" means
-- "run as soon as possible" (not a delay). The callback runs asynchronously
-- after this function returns.
--
-- In nginx.conf: log_by_lua_block { require("firewall").res() }
-- ============================================================================
function _M.res()
    -- Early return if firewall is disabled
    if not FIREWALL_ENABLED then return end
    
    -- ngx.status is the HTTP response status code (200, 404, 500, etc.)
    -- Early return if not a 404 - we only care about "not found" responses
    if ngx.status ~= ngx.HTTP_NOT_FOUND then return end
    
    -- Capture variables NOW, before the request context disappears.
    -- Once we're inside the timer callback, ngx.var.* won't be available
    -- because the original request will be gone.
    local ip = ngx.var.remote_addr
    
    -- Skip if IP is already cached as blocked (no point adding penalty)
    if blocked_cache:get("blocked:" .. ip) then return end
    
    -- Schedule the Redis work to run in a timer context.
    -- ngx.timer.at(delay, callback) schedules a function to run after 'delay' seconds.
    -- Using 0 means "run immediately, but in a context where sockets work".
    --
    -- The callback receives one argument: 'premature' (boolean).
    -- premature=true means nginx is shutting down and we should abort quickly.
    local ok, err = ngx.timer.at(0, function(premature)
        -- If nginx is shutting down, don't bother with Redis operations
        if premature then return end
        
        -- Now we're in a timer context - sockets are allowed here!
        -- Wrap in pcall for safety (same pattern as req())
        local timer_ok, timer_err = pcall(function()
            -- Double-check cache (might have been blocked by another worker)
            if blocked_cache:get("blocked:" .. ip) then return end
            
            local red = redis_pool.connect()
            if not red then return end  -- Fail-open: Redis down, skip penalty
            
            -- Load GCRA config (we don't need rules for penalty)
            local _, gcra_config = load_rules_and_config(red)
            
            -- Add 404 penalty via GCRA - consumes PENALTY_404 tokens
            -- Pass a simple breakdown for audit
            local breakdown = { ["rule:404-penalty"] = PENALTY_404 }
            local allowed, info = gcra_module.check(red, ip, PENALTY_404, gcra_config, breakdown)
            
            -- If blocked by 404 penalty, cache locally
            if not allowed then
                local cache_ttl = math.ceil(info.retry_after / 1000)
                blocked_cache:set("blocked:" .. ip, true, cache_ttl)
                
                -- Write audit if enabled
                if gcra_config and gcra_config.audit_enabled then
                    local now = math.floor(ngx.now() * 1000)
                    local audit_stream = gcra_config.audit_stream or "firewall:audit"
                    local audit_maxlen = gcra_config.audit_maxlen or 10000
                    
                    red:xadd(audit_stream, "MAXLEN", "~", audit_maxlen, "*",
                        "ip", ip,
                        "blocked_at", now,
                        "cost", PENALTY_404,
                        "trigger", "rule:404-penalty:" .. PENALTY_404,
                        "accumulated", info.accumulated or "")
                end
                
                ngx.log(ngx.WARN, "[firewall] blocked by 404 penalty ip=", ip,
                        " retry_after=", info.retry_after)
            else
                ngx.log(ngx.INFO, "[firewall] 404 penalty ip=", ip,
                        " cost=", PENALTY_404)
            end
            
            redis_pool.release(red)
        end)
        
        if not timer_ok then
            ngx.log(ngx.ERR, "[firewall] res timer error: ", timer_err)
        end
    end)
    
    -- If we couldn't even schedule the timer, log it (rare, usually means
    -- too many pending timers - controlled by lua_max_pending_timers in nginx.conf)
    if not ok then
        ngx.log(ngx.ERR, "[firewall] timer schedule error: ", err)
    end
end


-- ============================================================================
-- STATS ENDPOINT: Debug endpoint to view firewall state
-- ============================================================================
-- Returns JSON with current rules, config, and active IP rate limits.
-- Useful for debugging but should be protected in production!
--
-- In nginx.conf, you'd set up a location block like:
--   location /stats {
--       content_by_lua_block { require("firewall").stats() }
--   }
-- ============================================================================
function _M.stats()
    -- Set Content-Type to JSON so browsers can parse it
    ngx.header.content_type = "application/json"
    
    local red = redis_pool.connect()
    if not red then
        -- ngx.say() writes to HTTP response body (adds newline automatically)
        ngx.say('{"error": "redis connection failed"}')
        return
    end
    
    -- Get rules and config
    local rules, config = load_rules_and_config(red)
    
    -- Get all GCRA keys to show active rate-limited IPs
    -- WARNING: KEYS * is slow on large datasets - fine for debugging only!
    local gcra_keys = red:keys("gcra:*")
    local tat_data = {}
    
    -- Build a table of IP -> TAT (theoretical arrival time)
    if gcra_keys and #gcra_keys > 0 then
        -- ipairs() iterates over array-style tables in order.
        -- The underscore "_" is a Lua convention for "I don't need this value"
        for _, key in ipairs(gcra_keys) do
            local tat = red:get(key)
            -- ngx.null is a special value that resty.redis returns for nil Redis values
            if tat and tat ~= ngx.null then
                -- key:sub(6) removes "gcra:" prefix (6 chars)
                local ip = key:sub(6)
                tat_data[ip] = tonumber(tat)
            end
        end
    end
    
    -- Build response object
    local stats = {
        enabled = FIREWALL_ENABLED,
        rules_count = rules and #rules or 0,
        config = config or gcra_module.DEFAULTS,
        active_ips = tat_data,
    }
    
    redis_pool.release(red)
    
    -- cjson.encode converts Lua table to JSON string
    ngx.say(cjson.encode(stats))
end


-- ============================================================================
-- FLUSH CACHE: Clear all locally-cached blocked IPs
-- ============================================================================
-- Used by the test suite to ensure a clean state at the start of each test.
-- In nginx.conf: location /flush-cache { content_by_lua_block { require("firewall").flush_cache() } }
-- ============================================================================
function _M.flush_cache()
    blocked_cache:flush_all()
    -- Increment the shared version counter so every worker detects a cache
    -- miss on its next request and re-reads rules/config from Redis.
    -- incr(key, step, init) atomically increments; init=0 seeds it if absent.
    local ok, err = rc_shared:incr("version", 1, 0)
    if not ok then
        ngx.log(ngx.ERR, "[firewall] flush_cache: rc_shared:incr failed: ", err)
        rc_shared:set("version", 1)
    end
    -- Also invalidate this worker's cache immediately (don't wait for next request)
    _rc_cache.expires = 0
    ngx.header.content_type = "application/json"
    ngx.say('{"ok":true}')
end


-- ============================================================================
-- SEED DEFAULT RULES: Populate Redis with default rules
-- ============================================================================
-- Call this once to initialize firewall:rules with sensible defaults.
-- Can be called from CLI or init_worker_by_lua_block.
--
-- Rules can later be modified via WordPress admin or wp firewall CLI.
-- ============================================================================
function _M.seed_rules()
    local red = redis_pool.connect()
    if not red then
        return nil, "redis connection failed"
    end
    
    -- Seed a minimal safe ruleset. Tune costs for your traffic profile.
    local seed = {
        { id = "base",         conditions = {},                   cost = 1  },
        { id = "query-string", conditions = { has_query = true }, cost = 4  }
    }
    local rules_json = cjson.encode(seed)
    local ok, err = red:set("firewall:rules", rules_json)
    
    redis_pool.release(red)
    
    return ok, err
end


-- ============================================================================
-- ALLOW / BLOCK LIST HELPERS
-- ============================================================================
-- Thin Redis wrappers used by external tooling (e.g. a future WP CLI command
-- like `wp firewall allow 1.2.3.4 --ttl=3600`). Each lives in its own Redis
-- key so native EXPIRE handles ban/grant lifetimes — see the GCRA Lua script
-- which checks these keys before running rate limiting.
--
-- Key naming is kept in sync with gcra.lua DEFAULTS.allow_prefix / block_prefix.
-- ============================================================================

local ALLOW_PREFIX = "firewall:allow:"
local BLOCK_PREFIX = "firewall:block:"

-- Set ip on the allowlist. ttl is seconds; nil/0 = permanent.
function _M.allow_ip(ip, ttl)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end
    
    local ok, err
    if ttl and ttl > 0 then
        ok, err = red:set(ALLOW_PREFIX .. ip, "1", "EX", ttl)
    else
        ok, err = red:set(ALLOW_PREFIX .. ip, "1")
    end
    
    redis_pool.release(red)
    -- Drop any cached block so the new allow takes effect immediately on this worker
    blocked_cache:delete("blocked:" .. ip)
    return ok, err
end

-- Remove ip from the allowlist.
function _M.unallow_ip(ip)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end
    
    local ok, err = red:del(ALLOW_PREFIX .. ip)
    redis_pool.release(red)
    return ok, err
end

-- Set ip on the blocklist. ttl is seconds; nil/0 = permanent.
function _M.block_ip(ip, ttl)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end
    
    local ok, err
    if ttl and ttl > 0 then
        ok, err = red:set(BLOCK_PREFIX .. ip, "1", "EX", ttl)
    else
        ok, err = red:set(BLOCK_PREFIX .. ip, "1")
    end
    
    redis_pool.release(red)
    -- Pre-warm the local cache so this worker blocks immediately
    if ok then
        blocked_cache:set("blocked:" .. ip, true, ttl or 0)
    end
    return ok, err
end

-- Remove ip from the blocklist.
function _M.unblock_ip(ip)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end
    
    local ok, err = red:del(BLOCK_PREFIX .. ip)
    redis_pool.release(red)
    -- Drop any cached block on this worker
    blocked_cache:delete("blocked:" .. ip)
    return ok, err
end


-- ============================================================================
-- EXPORT THE MODULE
-- ============================================================================
-- This is required! When nginx.conf does require("firewall"), Lua runs this
-- entire file and returns whatever "return" gives. We return our _M table
-- which contains the init(), req(), res(), stats(), and seed_rules() functions.
-- ============================================================================
return _M
