-- ============================================================================
-- PAGE CACHE REDIS CONNECTION POOL
-- ============================================================================
-- Dedicated Redis pool for the full-page cache. Mirrors firewall/redis.lua but
-- targets a SEPARATE logical database (default db1) and a SEPARATE connection
-- pool name, so page-cache sockets can never be handed to the firewall (which
-- uses db0 and the default pool) or vice versa.
--
-- Fail-open: if Redis is down, connect() returns nil and callers must let the
-- request fall through to PHP. A cache outage must never take the site down.
--
-- CONFIGURATION (env vars; connection settings shared with the firewall):
--   REDIS_HOST          - Redis hostname (default: "redis")
--   REDIS_PORT          - Redis port (default: 6379)
--   REDIS_AUTH          - Redis password (default: none)
--   REDIS_SSL           - Use TLS (default: true, set "false" to disable)
--   PAGECACHE_DB        - Logical db index for the page cache (default: 1)
--   REDIS_POOL_SIZE     - Max connections per worker (default: 25)
--   REDIS_KEEPALIVE_MS  - Idle connection timeout in ms (default: 10000)
-- ============================================================================

local _M = {}

local REDIS_HOST = os.getenv("REDIS_HOST") or "redis"
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT")) or 6379
local REDIS_AUTH = os.getenv("REDIS_AUTH")
local REDIS_SSL  = os.getenv("REDIS_SSL") ~= "false"

-- Page cache lives in its own logical DB so a page-cache FLUSHDB can never
-- wipe the firewall rules in db0.
local PAGECACHE_DB = tonumber(os.getenv("PAGECACHE_DB")) or 1

local REDIS_TIMEOUT      = 200
local REDIS_POOL_SIZE    = tonumber(os.getenv("REDIS_POOL_SIZE")) or 25
local REDIS_KEEPALIVE_MS = tonumber(os.getenv("REDIS_KEEPALIVE_MS")) or 10000

-- Distinct pool name keeps db1 sockets out of the firewall's default (db0)
-- pool. Without this, a reused socket could still be SELECTed on the wrong DB.
local POOL_NAME = "pagecache_db" .. PAGECACHE_DB


-- ============================================================================
-- connect(): Create and connect a Redis client (fail-open -> nil on error).
-- ============================================================================
function _M.connect()
    local redis = require "resty.redis"

    local red = redis:new()
    red:set_timeout(REDIS_TIMEOUT)

    local ok, err
    if REDIS_SSL then
        ok, err = red:connect(REDIS_HOST, REDIS_PORT,
            { ssl = true, ssl_verify = true, pool = POOL_NAME })
    else
        ok, err = red:connect(REDIS_HOST, REDIS_PORT, { pool = POOL_NAME })
    end
    if not ok then
        ngx.log(ngx.ERR, "[pagecache] connect failed (fail-open): ", err)
        return nil
    end

    if REDIS_AUTH and REDIS_AUTH ~= "" then
        local auth_ok, auth_err = red:auth(REDIS_AUTH)
        if not auth_ok then
            ngx.log(ngx.ERR, "[pagecache] auth failed (fail-open): ", auth_err)
            red:close()
            return nil
        end
    end

    -- Always SELECT: this pool must never operate on db0 (the firewall's DB).
    local sel_ok, sel_err = red:select(PAGECACHE_DB)
    if not sel_ok then
        ngx.log(ngx.ERR, "[pagecache] select db failed (fail-open): ", sel_err)
        red:close()
        return nil
    end

    return red
end


-- ============================================================================
-- release(): Return the connection to the (named) keepalive pool.
-- ============================================================================
function _M.release(red)
    if red then
        red:set_keepalive(REDIS_KEEPALIVE_MS, REDIS_POOL_SIZE)
    end
end


-- Exported for logging/debugging.
_M.config = {
    host = REDIS_HOST,
    port = REDIS_PORT,
    ssl  = REDIS_SSL,
    db   = PAGECACHE_DB,
    pool = POOL_NAME,
}

return _M
