-- ============================================================================
-- PAGE CACHE REDIS CONNECTION POOL
-- ============================================================================
-- Thin wrapper around the shared redis_pool factory, bound to the page
-- cache's own logical database (default db1) with its own keepalive pool, so
-- page-cache sockets can never be handed to the firewall (db0) or vice versa.
-- Connection settings (host, auth, TLS, pool sizing) come from the shared env
-- vars documented in redis_pool.lua.
--
-- Fail-open: if Redis is down, connect() returns nil and callers must let the
-- request fall through to PHP. A cache outage must never take the site down.
--
-- PAGECACHE_DB - logical db index for the page cache (default: 1). Separate
-- from the firewall's db so a page-cache FLUSHDB can never wipe the firewall
-- rules.
-- ============================================================================

local redis_pool = require "redis_pool"

return redis_pool.new{
    db          = tonumber(os.getenv("PAGECACHE_DB")) or 1,
    pool_prefix = "pagecache",
    log_prefix  = "pagecache",
}
