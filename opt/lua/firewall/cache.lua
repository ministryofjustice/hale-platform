-- ============================================================================
-- Per-worker rules/config cache and block-decision cache.
--
-- Shared by firewall.lua (request hot path) and firewall.admin (admin
-- endpoints). Extracting these here avoids a circular dependency: both
-- modules can require("firewall.cache") independently; neither needs to
-- require the other.
--
-- The _rc_cache table is a module-level singleton. Lua caches module results
-- after the first require(), so every caller in the same worker process sees
-- the same table — mutations (e.g. flush() zeroing expires) are immediately
-- visible everywhere.
-- ============================================================================

local _M = {}

local schema = require "firewall.schema"
local cjson         = require "cjson.safe"

-- Per-worker in-memory cache of decoded rules + config.
-- `rules_by_phase` is the lookup table the request and response hot paths
-- iterate over via get_rules(phase); each entry is a slice of `rules`.
local _rc_cache    = {
    rules          = nil,
    rules_by_phase = { req = {}, res = {} },
    config         = nil,
    version        = -1,
    expires        = 0,
}
local RC_CACHE_TTL = 60  -- seconds

-- Shared dicts declared in nginx.conf.
_M.blocked_cache = ngx.shared.firewall_cache
local rc_shared  = ngx.shared.firewall_rc_cache


-- Bucket a flat rules array into per-phase slices once at refresh time so
-- the hot path doesn't re-filter on every request.
local function _split_by_phase(rules)
    local by_phase = { req = {}, res = {} }
    if not rules then return by_phase end
    for _, rule in ipairs(rules) do
        local bucket = by_phase[rule.phase]
        if bucket then table.insert(bucket, rule) end
    end
    return by_phase
end


-- Load and validate firewall:rules + firewall:config from Redis.
-- Per-worker cache keyed off a shared version counter so flush() propagates
-- invalidation to all workers at once. Validation warnings are logged at
-- most once per refresh window.
function _M.load_rules_and_config(red)
    local now            = ngx.now()
    local shared_version = rc_shared:get("version") or 0

    if _rc_cache.expires > now and _rc_cache.version == shared_version then
        return _rc_cache.rules, _rc_cache.config
    end

    local rules_json  = red:get("firewall:rules")
    local config_json = red:get("firewall:config")

    local raw_rules  = (rules_json  and rules_json  ~= ngx.null) and cjson.decode(rules_json)  or nil
    local raw_config = (config_json and config_json ~= ngx.null) and cjson.decode(config_json) or nil

    local rules,       rule_warns   = schema.parse_rules(raw_rules)
    local gcra_config, config_warns = schema.parse_config(raw_config)

    for _, w in ipairs(rule_warns)   do ngx.log(ngx.WARN, "[firewall] ", w) end
    for _, w in ipairs(config_warns) do ngx.log(ngx.WARN, "[firewall] ", w) end

    _rc_cache = {
        rules          = rules,
        rules_by_phase = _split_by_phase(rules),
        config         = gcra_config,
        version        = shared_version,
        expires        = now + RC_CACHE_TTL,
    }
    return rules, gcra_config
end


-- Hot-path accessor: return the array of rules for a given phase
-- ("req"|"res"). Always returns a table (empty when the cache hasn't been
-- warmed yet or no rules of that phase are configured) so callers can
-- ipairs() unconditionally without nil-guards.
function _M.get_rules(phase)
    local bucket = _rc_cache.rules_by_phase and _rc_cache.rules_by_phase[phase]
    return bucket or {}
end


-- Flush all cached state cluster-wide:
--   • clears the block-decision shared dict (firewall_cache)
--   • bumps the shared version counter so every worker re-reads rules/config
--     from Redis on its next request (otherwise the 60 s TTL would delay
--     propagation of rule/config edits)
--   • zeroes this worker's in-memory cache TTL so it re-reads immediately
--
-- Sends no HTTP response — callers (flush_cache endpoint, tests) do that.
function _M.flush()
    _M.blocked_cache:flush_all()
    local ok, err = rc_shared:incr("version", 1, 0)
    if not ok then
        ngx.log(ngx.ERR, "[firewall] cache.flush: rc_shared:incr failed: ", err)
        rc_shared:set("version", 1)
    end
    _rc_cache.expires = 0
end


return _M
