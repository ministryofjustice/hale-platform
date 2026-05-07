-- ============================================================================
-- Single source of truth for firewall constants and default config values.
--
-- Required by:
--   firewall.lua          — PENALTY_404, ALLOW_PREFIX, BLOCK_PREFIX, audit
--   firewall.gcra         — re-exports as gcra.DEFAULTS
--   firewall.config       — re-exports as config.DEFAULTS, used by parse_config
--
-- If you change a value here, check the WordPress admin UI
-- (hale-components/inc/firewall.php) for matching defaults.
-- ============================================================================

local _M = {}

-- GCRA bucket parameters and audit settings used by gcra.check() and as the
-- baseline applied by config.parse_config() to firewall:config.
_M.GCRA = {
    emission_interval = 100,            -- ms per token
    burst             = 150000,         -- ms of burst capacity
    penalty_ttl       = 600000,         -- ms; written to block key on GCRA block (0 = disabled)
    key_prefix        = "gcra:",
    allow_prefix      = "firewall:allow:",
    block_prefix      = "firewall:block:",
    audit_enabled     = false,
    audit_stream      = "firewall:audit",
    audit_maxlen      = 10000,
    mode              = "monitor",      -- "enforce" | "monitor" | "off"
}

-- Cost charged on 404 responses by firewall.res() (probing for vulnerable
-- URLs is expensive — make the attacker pay for it).
_M.PENALTY_404 = 50

-- Shared-dict block-cache key prefix used by firewall.req()/res().
_M.BLOCKED_CACHE_PREFIX = "blocked:"

return _M
