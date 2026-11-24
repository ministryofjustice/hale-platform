-- ============================================================================
-- FIREWALL REDIS CONNECTION POOL
-- ============================================================================
-- Thin wrapper around the shared redis_pool factory, bound to the firewall's
-- logical database. Connection settings (host, auth, TLS, pool sizing) come
-- from the shared env vars documented in redis_pool.lua.
--
-- Fail-open: if Redis is down, connect() returns nil and callers should allow
-- the request through.
--
-- USAGE:
--   local redis_pool = require "firewall.redis"
--   local red = redis_pool.connect()
--   if red then
--       -- do Redis operations
--       redis_pool.release(red)
--   end
--
-- FIREWALL_DB - logical db index. 0 = default (production). Override to 1 in
-- test environments to isolate test data from live data on the same Redis
-- instance.
-- ============================================================================

local redis_pool = require "redis_pool"

return redis_pool.new{
    db          = tonumber(os.getenv("FIREWALL_DB")) or 0,
    pool_prefix = "firewall",
    log_prefix  = "redis",
}
