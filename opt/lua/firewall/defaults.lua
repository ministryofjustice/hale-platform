-- ============================================================================
-- Single source of truth for firewall constants and default config values.
--
-- Required by:
--   firewall.lua          — ALLOW_KEY_PREFIX, BLOCK_KEY_PREFIX,
--                           AUDIT_STREAM, BLOCKED_CACHE_PREFIX
--   firewall.cache        — CACHE_VERSION_KEY, PENALTIES_VERSION_KEY
--   firewall.admin        — BLOCK_KEY_PREFIX, BLOCKED_CACHE_PREFIX,
--                           PENALTIES_VERSION_KEY
--   firewall.gcra         — re-exports _M.GCRA as gcra.DEFAULTS; reads the
--                           prefix constants directly
--   firewall.schema       — re-exports _M.GCRA as schema.DEFAULTS, used by
--                           parse_config to fill missing fields
--
-- Fields in _M.GCRA are operator-tunable via firewall:config in Redis.
-- Top-level _M.* values are constants — same name in every deployment so
-- PHP and ops scripts can hardcode them.
--
-- If you change a tunable here, check the WordPress admin UI
-- (hale-components/inc/firewall.php) for matching defaults.
-- ============================================================================

local _M = {}

-- ----------------------------------------------------------------------------
-- Redis key constants (NOT operator-tunable). Same name in every deployment.
-- ----------------------------------------------------------------------------
_M.GCRA_KEY_PREFIX       = "firewall:gcra:"             -- per-IP TAT and breakdown hash
_M.ALLOW_KEY_PREFIX      = "firewall:allow:"            -- per-IP allowlist key (GCRA bypass)
_M.BLOCK_KEY_PREFIX      = "firewall:block:"            -- per-IP blocklist key (GCRA block)
_M.AUDIT_STREAM          = "firewall:audit"             -- audit Redis stream key
_M.ALLOWLIST_KEY         = "firewall:allowlist"         -- CIDR/IP range allowlist (early bypass)
_M.BLOCKLIST_KEY         = "firewall:blocklist"         -- CIDR/IP range blocklist (early 403)
_M.CACHE_VERSION_KEY     = "firewall:cache_version"     -- cluster-wide rules/config invalidation counter
_M.PENALTIES_VERSION_KEY = "firewall:penalties_version" -- cluster-wide blocked_cache invalidation counter

-- GCRA bucket parameters used by gcra.check() and as the baseline applied
-- by config.parse_config() to firewall:config. Every field here is an
-- operator tunable, exposed via the WordPress admin UI.
_M.GCRA = {
    emission_interval = 100,            -- ms per token
    burst             = 150000,         -- ms of burst capacity
    penalty_ttl       = 600000,         -- ms; written to block key on GCRA block (0 = disabled)
    audit_enabled     = false,
    audit_maxlen      = 10000,
    mode              = "monitor",      -- "enforce" | "monitor" | "off"
}

-- Shared-dict block-cache key prefix used by firewall.req()/res().
_M.BLOCKED_CACHE_PREFIX = "blocked:"

return _M
