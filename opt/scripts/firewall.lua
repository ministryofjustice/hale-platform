-- ============================================================================
-- FIREWALL STUB MODULE
-- ============================================================================
-- Simple implementation for testing. Increments score:{ip} on each
-- request and 404 response, no banning logic.
--
-- USAGE:
--   In nginx.conf, set:
--     access_by_lua_block { require("firewall").req() }
--     log_by_lua_block { require("firewall").res() }
--     content_by_lua_block { require("firewall").stats() }
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
-- CONFIGURATION
-- ============================================================================
-- These variables are declared with "local" so they're private to this file.
-- os.getenv() reads environment variables; "or" provides a default if nil.
-- tonumber() converts strings to numbers (env vars are always strings).
-- ============================================================================

-- Redis server hostname (K8s service name or IP)
local REDIS_HOST = os.getenv("REDIS_HOST") or "redis"

-- Redis server port (standard Redis port is 6379)
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379

-- Redis password (nil if not set, which means no auth required)
local REDIS_AUTH = os.getenv("REDIS_AUTH")

-- Timeout in milliseconds for Redis operations (200ms keeps requests fast)
local REDIS_TIMEOUT = 200

-- Max connections to keep in the pool PER nginx worker process.
-- With 18 K8s pods, default of 25 means max ~450 connections to Redis.
-- Tuned for cross-AZ latency (~1ms). Increase if you see pool exhaustion errors.
local REDIS_POOL_SIZE = tonumber(os.getenv("REDIS_POOL_SIZE")) or 25

-- How long (ms) to keep idle connections in the pool before closing them.
-- 10 seconds is a good balance between reuse and not hogging connections.
local REDIS_KEEPALIVE_MS = tonumber(os.getenv("REDIS_KEEPALIVE_MS")) or 10000

-- How long (seconds) before a score:{ip} key expires in Redis.
-- After 1 hour of no requests, the IP's score resets to 0.
local SCORE_TTL = tonumber(os.getenv("FIREWALL_SCORE_TTL")) or 3600

-- Score threshold above which requests are blocked with 403 Forbidden.
-- Set to 0 to disable blocking (scoring only).
local BLOCK_THRESHOLD = tonumber(os.getenv("FIREWALL_BLOCK_THRESHOLD")) or 2000


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
        "[firewall] startup FIREWALL_BLOCK_THRESHOLD=", BLOCK_THRESHOLD,
        " FIREWALL_SCORE_TTL=", SCORE_TTL
    )
end


-- ============================================================================
-- HELPER: Create and connect a Redis client
-- ============================================================================
-- This is a "local function" - only callable within this file (not exported).
-- Returns a connected Redis client object, or nil if connection failed.
--
-- IMPORTANT: We "fail open" - if Redis is down, we return nil and the
-- calling code allows the request through. This prevents Redis outages
-- from taking down the whole site.
-- ============================================================================
local function connect_redis()
    -- require() loads a Lua module. "resty.redis" is OpenResty's Redis client.
    -- Unlike Node.js require(), Lua caches modules so this is cheap after first call.
    local redis = require "resty.redis"
    
    -- Create a new Redis client instance (this doesn't connect yet)
    local red = redis:new()
    
    -- Set timeout for all subsequent Redis operations on this client
    red:set_timeout(REDIS_TIMEOUT)
    
    -- Attempt to connect to Redis server.
    -- Lua functions often return (success_value, error_message).
    -- If connect fails, ok=nil and err contains the error string.
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        -- ngx.log writes to nginx error log. ngx.ERR is the severity level.
        -- Multiple arguments are concatenated automatically.
        ngx.log(ngx.ERR, "[firewall] redis connect failed (fail-open): ", err)
        return nil  -- Return nil to signal failure; caller should handle gracefully
    end
    
    -- If REDIS_AUTH is set and not empty string, authenticate with Redis.
    -- The "and" here is a guard: only evaluate right side if left is truthy.
    if REDIS_AUTH and REDIS_AUTH ~= "" then
        -- Note: we reuse variable names "ok" and "err" - this is common in Lua.
        -- The previous ok/err are just overwritten (no block scoping like JS let).
        local ok, err = red:auth(REDIS_AUTH)
        if not ok then
            ngx.log(ngx.ERR, "[firewall] redis auth failed (fail-open): ", err)
            return nil
        end
    end
    
    -- Return the connected client object
    return red
end


-- ============================================================================
-- HELPER: Return Redis connection to the pool
-- ============================================================================
-- Instead of closing the TCP connection, we return it to a connection pool.
-- The next request can reuse it, avoiding TCP handshake overhead.
--
-- Parameters:
--   red: The Redis client object (or nil if connection failed)
--
-- set_keepalive(timeout_ms, pool_size):
--   - timeout_ms: Close connection if idle longer than this
--   - pool_size: Max connections to keep in pool (per nginx worker)
-- ============================================================================
local function release_redis(red)
    -- Guard against nil (if connect_redis failed)
    if red then
        red:set_keepalive(REDIS_KEEPALIVE_MS, REDIS_POOL_SIZE)
    end
end


-- ============================================================================
-- REQUEST PHASE: Called on every incoming request
-- ============================================================================
-- This function is called from nginx.conf in the "access_by_lua" directive,
-- which runs before nginx processes the request. We increment a counter
-- for this IP address to track request frequency.
--
-- The function is attached to _M (our module table) so it's exported.
-- In nginx.conf: access_by_lua_block { require("firewall").req() }
-- ============================================================================
function _M.req()
    -- Get the client's IP address.
    -- ngx.var gives access to nginx variables.
    -- http_x_forwarded_for: IP from X-Forwarded-For header (set by load balancer)
    -- remote_addr: Direct connection IP (fallback if no proxy header)
    -- The "or" returns the first truthy value (like || in JavaScript).
    local ip = ngx.var.http_x_forwarded_for or ngx.var.remote_addr
    
    -- pcall = "protected call" - Lua's try/catch equivalent.
    -- It calls the function and catches any errors instead of crashing.
    -- Returns: (true, return_value) on success, (false, error_message) on error.
    -- We wrap Redis operations in pcall so a bug doesn't break the site.
    local ok, err = pcall(function()
        -- Get a Redis connection (may return nil if Redis is down)
        local red = connect_redis()
        if not red then return end  -- Fail-open: just exit the function, allow request
        
        -- Check current score and block if above threshold.
        -- We check BEFORE incrementing so blocked IPs get rejected immediately.
        if BLOCK_THRESHOLD > 0 then
            local score = red:get("score:" .. ip)
            -- score is nil if key doesn't exist, ngx.null if Redis returns null
            if score and score ~= ngx.null and tonumber(score) > BLOCK_THRESHOLD then
                release_redis(red)  -- Return connection before exiting
                ngx.log(ngx.WARN, "[firewall] blocked ip=", ip, " score=", score)
                ngx.exit(ngx.HTTP_FORBIDDEN)  -- 403 - stops request processing
            end
        end
        
        -- Pipeline batches multiple Redis commands into one network round-trip.
        -- This is faster than sending INCR, waiting, then sending EXPIRE.
        red:init_pipeline()
        
        -- INCR: Increment the counter. Creates key with value 1 if doesn't exist.
        -- The ".." operator concatenates strings: "score:" .. "1.2.3.4" = "score:1.2.3.4"
        red:incr("score:" .. ip)
        
        -- EXPIRE: Reset the TTL to 1 hour. Key auto-deletes after this time.
        red:expire("score:" .. ip, SCORE_TTL)
        
        -- Send the pipeline to Redis and get results.
        -- Returns a table (array) with one result per command: {new_score, 1}
        local results = red:commit_pipeline()
        
        -- Log the new score (results[1] is the INCR result).
        -- Lua arrays are 1-indexed, not 0-indexed!
        if results then
            ngx.log(ngx.INFO, "[firewall] req ip=", ip, " score=", results[1])
        end
        
        -- Return connection to pool for reuse
        release_redis(red)
    end)
    
    -- If pcall caught an error (ok=false), log it but don't block the request
    if not ok then
        ngx.log(ngx.ERR, "[firewall] req error (fail-open): ", err)
    end
end


-- ============================================================================
-- RESPONSE PHASE: Called after response is sent, for 404s only
-- ============================================================================
-- This runs in nginx's "log_by_lua" phase, after the response is sent.
-- We add extra score for 404 errors, since attackers often probe for
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
    -- ngx.status is the HTTP response status code (200, 404, 500, etc.)
    -- Early return if not a 404 - we only care about "not found" responses
    if ngx.status ~= 404 then
        return
    end
    
    -- Capture variables NOW, before the request context disappears.
    -- Once we're inside the timer callback, ngx.var.* won't be available
    -- because the original request will be gone.
    local ip = ngx.var.http_x_forwarded_for or ngx.var.remote_addr
    
    -- Schedule the Redis work to run in a timer context.
    -- ngx.timer.at(delay, callback) schedules a function to run after 'delay' seconds.
    -- Using 0 means "run immediately, but in a context where sockets work".
    --
    -- The callback receives one argument: 'premature' (boolean).
    -- premature=true means nginx is shutting down and we should abort quickly.
    local ok, err = ngx.timer.at(0, function(premature)
        -- If nginx is shutting down, don't bother with Redis operations
        if premature then
            return
        end
        
        -- Now we're in a timer context - sockets are allowed here!
        -- Wrap in pcall for safety (same pattern as req())
        local timer_ok, timer_err = pcall(function()
            local red = connect_redis()
            if not red then return end  -- Fail-open: Redis down, skip scoring
            
            -- Pipeline the INCR + EXPIRE for efficiency
            red:init_pipeline()
            red:incr("score:" .. ip)
            red:expire("score:" .. ip, SCORE_TTL)
            local results = red:commit_pipeline()
            
            if results then
                ngx.log(ngx.INFO, "[firewall] res 404 ip=", ip, " score=", results[1])
            end
            
            release_redis(red)
        end)
        
        if not timer_ok then
            ngx.log(ngx.ERR, "[firewall] res timer error: ", timer_err)
        end
    end)
    
    -- If we couldn't even schedule the timer, log it (rare, usually means
    -- too many pending timers - controlled by lua_max_pending_timers in nginx.conf)
    if not ok then
        ngx.log(ngx.ERR, "[firewall] res failed to create timer: ", err)
    end
end


-- ============================================================================
-- STATS ENDPOINT: Debug endpoint to view all Redis data
-- ============================================================================
-- Returns all keys and values from Redis as plain text.
-- Useful for debugging but should be protected in production!
--
-- In nginx.conf, you'd set up a location block like:
--   location /firewall-stats {
--       content_by_lua_block { require("firewall").stats() }
--   }
-- ============================================================================
function _M.stats()
    -- Set Content-Type to text/plain so browsers display inline instead of
    -- prompting a file download. Must be set before any ngx.say() calls.
    ngx.header.content_type = "text/plain"
    
    local red = connect_redis()
    if not red then
        -- ngx.say() writes to HTTP response body (adds newline automatically)
        ngx.say("redis error: connection failed")
        return
    end
    
    -- KEYS * returns all keys in Redis. 
    -- WARNING: This is slow on large datasets - fine for debugging only!
    local keys = red:keys("*")
    
    -- Check if keys is nil (error) or empty table.
    -- #keys is the length operator - returns number of elements in array.
    if not keys or #keys == 0 then
        ngx.say("(empty database)")
        release_redis(red)
        return
    end
    
    -- Loop through all keys and print their values.
    -- ipairs() iterates over array-style tables in order.
    -- The underscore "_" is a Lua convention for "I don't need this value"
    -- (ipairs returns index, value - we only need value).
    for _, key in ipairs(keys) do
        local val = red:get(key)
        
        -- ngx.null is a special value that resty.redis returns for nil Redis values.
        -- It's different from Lua's nil for technical reasons.
        if val and val ~= ngx.null then
            ngx.say(key, " = ", val)
        else
            ngx.say(key, " = (nil)")
        end
    end
    
    release_redis(red)
end


-- ============================================================================
-- EXPORT THE MODULE
-- ============================================================================
-- This is required! When nginx.conf does require("firewall"), Lua runs this
-- entire file and returns whatever "return" gives. We return our _M table
-- which contains the init(), req(), res(), and stats() functions.
-- ============================================================================
return _M
