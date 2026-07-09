-- ============================================================================
-- SHARED REDIS CONNECTION POOL FACTORY
-- ============================================================================
-- Builds a Redis connection-pool module for a given logical database. Used by
-- firewall/redis.lua (db0) and pagecache/redis.lua (db1) so the connection
-- logic lives in one place.
--
-- Fail-open: if Redis is down, connect() returns nil and callers must let the
-- request through. A Redis outage must never take the site down.
--
-- Each instance gets its OWN keepalive pool, named "<pool_prefix>_db<db>".
-- Without a distinct pool name per database, a reused socket could be handed
-- to a caller expecting a different SELECTed db (e.g. a db1 page-cache socket
-- reused by the firewall, which expects db0).
--
-- CONFIGURATION (env vars, shared by all instances):
--   REDIS_HOST          - Redis hostname (default: "redis")
--   REDIS_PORT          - Redis port (default: 6379)
--   REDIS_AUTH          - Redis password (default: none)
--   REDIS_SSL           - Use TLS (default: true, set "false" to disable)
--   REDIS_POOL_SIZE     - Max connections per worker (default: 25)
--   REDIS_KEEPALIVE_MS  - Idle connection timeout in ms (default: 10000)
--
-- The logical db index is NOT read here: each caller resolves its own env var
-- (FIREWALL_DB, PAGECACHE_DB, ...) and passes the value to new().
-- ============================================================================

local _M = {}

local REDIS_HOST = os.getenv("REDIS_HOST") or "redis"
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379
local REDIS_AUTH = os.getenv("REDIS_AUTH")
local REDIS_SSL  = os.getenv("REDIS_SSL") ~= "false"

-- Timeout in milliseconds for Redis operations (200ms keeps requests fast).
local REDIS_TIMEOUT = 200

-- Max connections kept in the pool PER nginx worker process.
-- With 18 K8s pods, default of 25 means max ~450 connections to Redis.
-- Tuned for cross-AZ latency (~1ms). Increase if you see pool exhaustion errors.
local REDIS_POOL_SIZE = tonumber(os.getenv("REDIS_POOL_SIZE")) or 25

-- How long (ms) idle connections stay in the pool before closing.
local REDIS_KEEPALIVE_MS = tonumber(os.getenv("REDIS_KEEPALIVE_MS")) or 10000


-- ============================================================================
-- new(opts): build a pool module bound to one logical database.
--
--   opts.db          - logical Redis db index (required)
--   opts.pool_prefix - keepalive pool name prefix, e.g. "firewall" (required)
--   opts.log_prefix  - tag used in error-log lines, e.g. "redis" (required)
--
-- Returns a table with connect(), release() and a config export.
-- ============================================================================
function _M.new(opts)
    local db          = assert(tonumber(opts.db), "redis_pool.new: opts.db required")
    local pool_prefix = assert(opts.pool_prefix, "redis_pool.new: opts.pool_prefix required")
    local log_prefix  = assert(opts.log_prefix, "redis_pool.new: opts.log_prefix required")

    -- Distinct pool per db: keeps SELECTed sockets from leaking between users
    -- of different logical databases.
    local pool_name = pool_prefix .. "_db" .. db

    local pool = {}

    -- ------------------------------------------------------------------------
    -- connect(): Create and connect a Redis client (fail-open -> nil on error).
    -- ------------------------------------------------------------------------
    function pool.connect()
        local redis = require "resty.redis"

        local red = redis:new()
        red:set_timeout(REDIS_TIMEOUT)

        -- For ElastiCache with encryption-in-transit, we need SSL.
        local ok, err
        if REDIS_SSL then
            ok, err = red:connect(REDIS_HOST, REDIS_PORT,
                { ssl = true, ssl_verify = true, pool = pool_name })
        else
            ok, err = red:connect(REDIS_HOST, REDIS_PORT, { pool = pool_name })
        end
        if not ok then
            ngx.log(ngx.ERR, "[", log_prefix, "] connect failed (fail-open): ", err)
            return nil
        end

        if REDIS_AUTH and REDIS_AUTH ~= "" then
            local auth_ok, auth_err = red:auth(REDIS_AUTH)
            if not auth_ok then
                ngx.log(ngx.ERR, "[", log_prefix, "] auth failed (fail-open): ", auth_err)
                red:close()
                return nil
            end
        end

        -- Select the logical database. Skipped for db0 (Redis default) to avoid
        -- an unnecessary round-trip; safe because the named pool guarantees any
        -- reused socket was SELECTed on this same db.
        if db ~= 0 then
            local sel_ok, sel_err = red:select(db)
            if not sel_ok then
                ngx.log(ngx.ERR, "[", log_prefix, "] select db failed (fail-open): ", sel_err)
                red:close()
                return nil
            end
        end

        return red
    end

    -- ------------------------------------------------------------------------
    -- release(): Return the connection to the named keepalive pool instead of
    -- closing it, so the next request skips the TCP/TLS handshake.
    -- ------------------------------------------------------------------------
    function pool.release(red)
        if red then
            red:set_keepalive(REDIS_KEEPALIVE_MS, REDIS_POOL_SIZE)
        end
    end

    -- Exported for logging/debugging.
    pool.config = {
        host         = REDIS_HOST,
        port         = REDIS_PORT,
        ssl          = REDIS_SSL,
        db           = db,
        pool         = pool_name,
        pool_size    = REDIS_POOL_SIZE,
        keepalive_ms = REDIS_KEEPALIVE_MS,
    }

    return pool
end

return _M
