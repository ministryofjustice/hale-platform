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
local cidr   = require "firewall.cidr"
local cjson  = require "cjson.safe"

-- Per-worker in-memory cache of decoded rules + config.
-- `rules_by_phase` is the lookup table the request and response hot paths
-- iterate over via get_rules(phase); each entry is a slice of `rules`.
-- `allowlist` and `blocklist` hold pre-parsed CIDR entries for is_allowed()
-- and is_blocked(); they are populated from the same Redis refresh cycle.
local _rc_cache    = {
    rules          = nil,
    rules_by_phase = { req = {}, res = {} },
    allowlist      = {},
    blocklist      = {},
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


-- Pre-parse a list of CIDR/IP strings into cidr.parse() entries once at
-- refresh time so is_allowed()/is_blocked() do no parsing on the hot path.
local function _parse_cidr_list(strings)
    local parsed = {}
    for _, s in ipairs(strings or {}) do
        local entry = cidr.parse(s)
        if entry then table.insert(parsed, entry) end
    end
    return parsed
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

    local rules_json      = red:get("firewall:rules")
    local config_json     = red:get("firewall:config")
    local allowlist_json  = red:get("firewall:allowlist")
    local blocklist_json  = red:get("firewall:blocklist")

    local raw_rules,     rules_json_err
    local raw_config,    config_json_err
    local raw_allowlist, allowlist_json_err
    local raw_blocklist, blocklist_json_err

    if rules_json     and rules_json     ~= ngx.null then
        raw_rules,     rules_json_err     = cjson.decode(rules_json)
    end
    if config_json    and config_json    ~= ngx.null then
        raw_config,    config_json_err    = cjson.decode(config_json)
    end
    if allowlist_json and allowlist_json ~= ngx.null then
        raw_allowlist, allowlist_json_err = cjson.decode(allowlist_json)
    end
    if blocklist_json and blocklist_json ~= ngx.null then
        raw_blocklist, blocklist_json_err = cjson.decode(blocklist_json)
    end

    if rules_json_err     then
        ngx.log(ngx.ERR, "[firewall] event=json_decode_error key=firewall:rules err=", rules_json_err)
    end
    if config_json_err    then
        ngx.log(ngx.ERR, "[firewall] event=json_decode_error key=firewall:config err=", config_json_err)
    end
    if allowlist_json_err then
        ngx.log(ngx.ERR, "[firewall] event=json_decode_error key=firewall:allowlist err=", allowlist_json_err)
    end
    if blocklist_json_err then
        ngx.log(ngx.ERR, "[firewall] event=json_decode_error key=firewall:blocklist err=", blocklist_json_err)
    end

    local rules,            rule_warns   = schema.parse_rules(raw_rules)
    local gcra_config,      config_warns = schema.parse_config(raw_config)
    local allowlist_strs,   allow_warns  = schema.parse_allowlist(raw_allowlist)
    local blocklist_strs,   block_warns  = schema.parse_blocklist(raw_blocklist)

    for _, w in ipairs(rule_warns)   do ngx.log(ngx.WARN, "[firewall] event=schema_warn kind=rules ", w) end
    for _, w in ipairs(config_warns) do ngx.log(ngx.WARN, "[firewall] event=schema_warn kind=config ", w) end
    for _, w in ipairs(allow_warns)  do ngx.log(ngx.WARN, "[firewall] event=schema_warn kind=allowlist ", w) end
    for _, w in ipairs(block_warns)  do ngx.log(ngx.WARN, "[firewall] event=schema_warn kind=blocklist ", w) end

    _rc_cache = {
        rules          = rules,
        rules_by_phase = _split_by_phase(rules),
        allowlist      = _parse_cidr_list(allowlist_strs),
        blocklist      = _parse_cidr_list(blocklist_strs),
        config         = gcra_config,
        version        = shared_version,
        expires        = now + RC_CACHE_TTL,
    }
    ngx.log(ngx.NOTICE, "[firewall] event=rules_reload version=", shared_version,
            " rule_count=", rules and #rules or 0)
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


-- Check whether ip falls within the cached CIDR allowlist.
-- Returns false on cold cache (empty list) — consistent with fail-open
-- behavior for rules and config on worker startup.
function _M.is_allowed(ip)
    return cidr.contains(_rc_cache.allowlist, ip)
end


-- Check whether ip falls within the cached CIDR blocklist.
function _M.is_blocked(ip)
    return cidr.contains(_rc_cache.blocklist, ip)
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
        ngx.log(ngx.ERR, "[firewall] event=cache_flush_error err=", err)
        rc_shared:set("version", 1)
    else
        ngx.log(ngx.NOTICE, "[firewall] event=cache_flush version=", ok)
    end
    _rc_cache.expires = 0
end


return _M
