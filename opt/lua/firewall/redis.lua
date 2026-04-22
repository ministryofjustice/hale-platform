-- ============================================================================
-- REDIS CONNECTION POOL MODULE
-- ============================================================================
-- Manages Redis connections with connection pooling for OpenResty.
-- Uses "fail open" pattern - if Redis is down, returns nil and callers
-- should allow requests through to prevent Redis outages from breaking site.
--
-- USAGE:
--   local redis_pool = require "firewall.redis"
--   local red = redis_pool.connect()
--   if red then
--       -- do Redis operations
--       redis_pool.release(red)
--   end
--
-- CONFIGURATION (via environment variables):
--   REDIS_HOST         - Redis hostname (default: "redis")
--   REDIS_PORT         - Redis port (default: 6379)
--   REDIS_AUTH         - Redis password (default: none)
--   REDIS_SSL          - Use TLS (default: true, set "false" to disable)
--   REDIS_POOL_SIZE    - Max connections per worker (default: 25)
--   REDIS_KEEPALIVE_MS - Idle connection timeout (default: 10000)
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

-- Use TLS for Redis connection (default true for ElastiCache, set false for local dev)
local REDIS_SSL = os.getenv("REDIS_SSL") ~= "false"

-- Timeout in milliseconds for Redis operations (200ms keeps requests fast)
local REDIS_TIMEOUT = 200

-- Max connections to keep in the pool PER nginx worker process.
-- With 18 K8s pods, default of 25 means max ~450 connections to Redis.
-- Tuned for cross-AZ latency (~1ms). Increase if you see pool exhaustion errors.
local REDIS_POOL_SIZE = tonumber(os.getenv("REDIS_POOL_SIZE")) or 25

-- How long (ms) to keep idle connections in the pool before closing them.
-- 10 seconds is a good balance between reuse and not hogging connections.
local REDIS_KEEPALIVE_MS = tonumber(os.getenv("REDIS_KEEPALIVE_MS")) or 10000


-- ============================================================================
-- connect(): Create and connect a Redis client
-- ============================================================================
-- Returns a connected Redis client object, or nil if connection failed.
--
-- IMPORTANT: We "fail open" - if Redis is down, we return nil and the
-- calling code allows the request through. This prevents Redis outages
-- from taking down the whole site.
-- ============================================================================
function _M.connect()
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
    -- For ElastiCache with encryption-in-transit, we need SSL.
    local ok, err
    if REDIS_SSL then
        -- ssl_verify=false because ElastiCache certs may not be in CA bundle
        ok, err = red:connect(REDIS_HOST, REDIS_PORT, { ssl = true, ssl_verify = false })
    else
        ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    end
    if not ok then
        -- ngx.log writes to nginx error log. ngx.ERR is the severity level.
        -- Multiple arguments are concatenated automatically.
        ngx.log(ngx.ERR, "[redis] connect failed (fail-open): ", err)
        return nil  -- Return nil to signal failure; caller should handle gracefully
    end
    
    -- If REDIS_AUTH is set and not empty string, authenticate with Redis.
    -- The "and" here is a guard: only evaluate right side if left is truthy.
    if REDIS_AUTH and REDIS_AUTH ~= "" then
        -- Note: we reuse variable names "ok" and "err" - this is common in Lua.
        -- The previous ok/err are just overwritten (no block scoping like JS let).
        local ok, err = red:auth(REDIS_AUTH)
        if not ok then
            ngx.log(ngx.ERR, "[redis] auth failed (fail-open): ", err)
            return nil
        end
    end
    
    -- Return the connected client object
    return red
end


-- ============================================================================
-- release(): Return Redis connection to the pool
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
function _M.release(red)
    -- Guard against nil (if connect failed)
    if red then
        red:set_keepalive(REDIS_KEEPALIVE_MS, REDIS_POOL_SIZE)
    end
end


-- ============================================================================
-- Export configuration for logging/debugging
-- ============================================================================
_M.config = {
    host = REDIS_HOST,
    port = REDIS_PORT,
    ssl = REDIS_SSL,
    pool_size = REDIS_POOL_SIZE,
    keepalive_ms = REDIS_KEEPALIVE_MS,
}


return _M
