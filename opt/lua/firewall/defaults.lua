-- ============================================================================
-- Single source of truth for firewall constants and default config values.
--
-- Required by:
--   firewall.lua          — ALLOW_KEY_PREFIX, BLOCK_KEY_PREFIX,
--                           AUDIT_STREAM, BLOCKED_CACHE_PREFIX
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
_M.GCRA_KEY_PREFIX  = "firewall:gcra:"   -- per-IP TAT and breakdown hash
_M.ALLOW_KEY_PREFIX = "firewall:allow:"  -- per-IP allowlist key
_M.BLOCK_KEY_PREFIX = "firewall:block:"  -- per-IP blocklist key
_M.AUDIT_STREAM     = "firewall:audit"   -- audit Redis stream key

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
