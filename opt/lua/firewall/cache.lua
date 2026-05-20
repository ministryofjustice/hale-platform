-- ============================================================================
-- Per-worker rules/config cache and block-decision cache.
--
-- Shared by firewall.lua (request hot path) and firewall.admin (admin
-- endpoints). Extracting these here avoids a circular dependency: both
-- modules can require("firewall.cache") independently; neither needs to
-- require the other.
--
-- This module is a singleton. Lua caches module results after the first
-- require(), so every caller in the same worker process shares the same
-- module state. _rc_cache is a module-level upvalue; load_rules_and_config()
-- reassigns it to a fresh table on each Redis refresh, and all accessor
-- functions (get_rules, is_allowed, is_blocked) re-dereference it on
-- every call, so they always see the current version.
-- ============================================================================

local _M = {}

local defaults = require "firewall.defaults"
local schema   = require "firewall.schema"
local cidr     = require "firewall.cidr"
local cjson    = require "cjson.safe"

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
}

-- Redis key holding the cluster-wide cache invalidation counter. Bumped by
-- any writer of firewall:rules / :config / :allowlist / :blocklist (PHP
-- admin, ops scripts) to signal "rules/config changed, drop your local
-- copy". Polled once per second per pod by the timer in firewall.init();
-- the value is mirrored into rc_shared:get("cache_version") for hot-path
-- comparison without per-request Redis I/O.
local CACHE_VERSION_KEY     = defaults.CACHE_VERSION_KEY
local PENALTIES_VERSION_KEY = defaults.PENALTIES_VERSION_KEY

-- Last penalties_version seen by this worker's poller. Initialised to -1 so
-- the very first poll (warm-up) does not trigger a spurious flush.
local _last_penalties_version = -1

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
--
-- Cluster-wide invalidation works via firewall:cache_version in Redis:
-- writers (PHP admin save, ops scripts) bump the
-- counter; the per-pod timer in firewall.init() polls it once a second
-- and mirrors the value into the rc_shared "cache_version" slot. Each
-- worker compares that slot to its own _rc_cache.version on every call;
-- a mismatch triggers a re-read from Redis.
--
-- Validation warnings are logged at most once per refresh.
function _M.load_rules_and_config(red)
    local shared_version = rc_shared:get("cache_version") or 0

    if _rc_cache.version == shared_version and _rc_cache.rules ~= nil then
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
    }
    ngx.log(ngx.NOTICE, "[firewall] event=rules_reload version=", shared_version,
            " rule_count=", rules and #rules or 0)
    return rules, gcra_config
end


-- Return the cache version currently mirrored into the per-pod shared dict.
-- Used by the stats endpoint so tests can observe when a reload has occurred.
function _M.get_cache_version()
    return rc_shared:get("cache_version") or 0
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


-- Mirror Redis-side version counters into the per-pod shared dict.
-- Called once per second by a background timer in firewall.init() (worker 0
-- only, so the cost is one Redis MGET per pod per second regardless of how
-- many nginx workers or how much traffic). Hot-path code reads only
-- rc_shared:get("cache_version") and pays no Redis I/O per request.
--
-- When penalties_version advances the per-pod blocked_cache shared dict is
-- flushed so all workers immediately stop serving stale auto-ban decisions.
-- ngx.shared dicts are cross-worker, so one flush from worker 0 covers all.
--
-- Returns the cache_version value written, or nil + err on failure. The
-- caller (timer) swallows errors: a failed poll leaves the previous value in
-- place and the next tick retries.
function _M.poll_versions(red)
    local results, err = red:mget(CACHE_VERSION_KEY, PENALTIES_VERSION_KEY)
    if not results then
        return nil, err
    end

    local cv = results[1]
    local pv = results[2]
    if cv == ngx.null or cv == nil then cv = 0 else cv = tonumber(cv) or 0 end
    if pv == ngx.null or pv == nil then pv = 0 else pv = tonumber(pv) or 0 end

    rc_shared:set("cache_version",     cv)
    rc_shared:set("penalties_version", pv)

    if _last_penalties_version ~= -1 and pv ~= _last_penalties_version then
        _M.blocked_cache:flush_all()
        ngx.log(ngx.NOTICE, "[firewall] event=penalties_flush version=", pv)
    end
    _last_penalties_version = pv

    return cv
end


-- Return the penalties version currently mirrored into the per-pod shared
-- dict. Used by the stats endpoint so tests can observe when a flush has
-- occurred.
function _M.get_penalties_version()
    return rc_shared:get("penalties_version") or 0
end


return _M
