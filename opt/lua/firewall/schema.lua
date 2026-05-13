-- ============================================================================
-- SCHEMA MODULE
-- ============================================================================
-- Pure schema for the `firewall:rules` and `firewall:config` Redis keys:
-- parse + validate functions, the canonical key whitelists, and the
-- VALID_MODES set. No ngx.* dependencies so this can be unit tested with
-- plain busted.
--
-- USAGE:
--   local schema = require "firewall.schema"
--   local cfg,   warns = schema.parse_config(cjson.decode(raw_json))
--   local rules, warns = schema.parse_rules(cjson.decode(raw_json))
--
-- Both functions return (result, warnings_table).
-- warnings_table is always a table (may be empty). Caller is responsible
-- for logging the strings (e.g. via ngx.log(ngx.WARN, ...)).
-- ============================================================================
--
-- ============================================================================
-- REDIS KEY SCHEMAS
-- ============================================================================
-- These schemas define the data stored in Redis. The WP CLI seed commands
-- and any admin UI controller must write data that conforms to this shape.
-- Invalid fields are coerced or defaulted with a WARN log — they are never
-- silently accepted as-is.
--
-- ----------------------------------------------------------------------------
-- KEY: firewall:config  (JSON object)
-- ----------------------------------------------------------------------------
--
--   {
--     "emission_interval": <number>,   -- Optional. Milliseconds per token
--                                      --   (i.e. the inverse of the sustained
--                                      --   request rate). Must be > 0.
--                                      --   Default: 100  (10 req/s sustained)
--
--     "burst": <number>,               -- Optional. Burst capacity in ms.
--                                      --   Allows short bursts above the
--                                      --   sustained rate. Must be >= 0.
--                                      --   Default: 150000 (150 s of burst)
--
--     "penalty_ttl": <integer>,        -- Optional. TTL in ms applied to
--                                      --   penalty state. Must be >= 0.
--                                      --   Default: 600000 (600 s)
--
--     "audit_enabled": <boolean>,      -- Optional. When true, the GCRA script
--                                      --   writes rule breakdowns to the audit
--                                      --   stream on each blocked request.
--                                      --   Default: false
--
--     "audit_maxlen": <integer>,       -- Optional. MAXLEN trim on the audit
--                                      --   stream (approximate). Must be > 0.
--                                      --   Default: 10000
--
--     "mode": <string>                 -- Optional. One of:
--                                      --     "enforce" — block requests that exceed limits (429)
--                                      --     "monitor" — log/audit "would-block" events but allow the request
--                                      --     "off"     — skip GCRA entirely (still cheaper than disabling Lua)
--                                      --   Default: "monitor"  (safe rollout)
--                                      --   Note: changes propagate within RC_CACHE_TTL (60s),
--                                      --   or instantly via /firewall/flush-cache.
--   }
--
-- ----------------------------------------------------------------------------
-- KEY: firewall:rules  (JSON array of rule objects, phase-tagged)
-- ----------------------------------------------------------------------------
--
-- Each rule belongs to exactly one phase ("req" or "res"). All matching
-- rules within a phase contribute their cost to the per-IP GCRA bucket;
-- there is no separate action enum — the bucket is the only mechanism.
--
--   [
--     {
--       "name":  <string>,         -- REQUIRED. Stable identifier. Used as
--                                  --   the audit trigger ("rule:<phase>-score:<name>:<cost>").
--                                  --   1..64 chars, [a-z0-9-] only,
--                                  --   unique within the array.
--
--       "phase": <string>,         -- REQUIRED. "req" | "res".
--                                  --   "req" rules are evaluated in
--                                  --   access_by_lua against the request.
--                                  --   "res" rules are evaluated in
--                                  --   log_by_lua against the response.
--
--       "cost":  <integer>,        -- REQUIRED. Tokens contributed to the
--                                  --   GCRA bucket on a match. 0..99999.
--                                  --     0           = audit only (no scoring)
--                                  --     small       = accumulates over time
--                                  --     >= capacity = guaranteed block on match
--
--       "match": { ... }           -- REQUIRED. Predicate object. Keys allowed
--                                  --   depend on the rule's phase (see below).
--                                  --   Predicates within a single rule are
--                                  --   AND'd. At least one predicate required.
--     }
--   ]
--
-- Request-phase match predicates (phase = "req"):
--   "uri_pattern":   <string>      -- PCRE against the request path only
--                                  --   (no query string). Case-insensitive.
--   "ua_pattern":    <string>      -- PCRE against the User-Agent header.
--                                  --   Case-insensitive.
--   "query_pattern": <string>      -- PCRE against the raw query string
--                                  --   (ngx.var.args). Only matches when
--                                  --   a query string is present. Case-insensitive.
--   "method":        <string>      -- Exact HTTP method match (e.g. "POST").
--                                  --   Case-sensitive.
--   "has_query":     <boolean>     -- true = match only requests with a query
--                                  --   string; false = only those without.
--
-- Response-phase match predicates (phase = "res"):
--   "status":        <integer>     -- Exact HTTP status match. 100..599.
--
-- Example:
--   SET firewall:rules '[
--     {"name":"req-wp-install-probe", "phase":"req", "cost":9999,
--        "match":{"uri_pattern":"^/wp-admin/install\\.php$"}},
--     {"name":"req-php-post",         "phase":"req", "cost":10,
--        "match":{"uri_pattern":"\\.php$","method":"POST"}},
--     {"name":"req-sqlmap-ua",        "phase":"req", "cost":50,
--        "match":{"ua_pattern":"sqlmap"}},
--     {"name":"res-404",              "phase":"res", "cost":50,
--        "match":{"status":404}},
--     {"name":"res-499",              "phase":"res", "cost":25,
--        "match":{"status":499}}
--   ]'
--
-- Validation behaviour:
--   - parse_rules is fail-soft: invalid entries are dropped with a WARN log;
--     the firewall keeps running on whatever survives.
--   - validate_rules_strict (admin write path) promotes every WARN to an
--     ERROR so the operator must fix bad input before it lands in Redis.
-- ============================================================================

local _M = {}

local defaults = require "firewall.defaults"
local cidr     = require "firewall.cidr"

-- Default config values live in firewall.defaults. Re-exported here so
-- parse_config() and existing callers continue to use schema.DEFAULTS.
_M.DEFAULTS = defaults.GCRA

-- Valid values for the "mode" config field.
_M.VALID_MODES = { enforce = true, monitor = true, off = true }

-- Valid values for the rule "phase" field. Adding a new phase only requires
-- (a) extending this set, (b) adding a phase-specific predicate validator
-- in _PHASE_VALIDATORS below, and (c) wiring a hot-path call to
-- cache.get_rules("<phase>"). The cache layer itself is data-driven and
-- needs no change.
_M.VALID_PHASES = { req = true, res = true }

-- Name charset: lowercase, digits, hyphens. No spaces, dots, slashes, or
-- colons (colons would break the "rule:<phase>-score:<name>:<cost>" audit
-- trigger format).
local _NAME_PATTERN = "^[a-z0-9%-]+$"
local _NAME_MAX_LEN = 64

local _COST_MAX = 99999

-- ============================================================================
-- parse_config: validate and coerce a decoded firewall:config object
-- ============================================================================
-- @param raw table|nil: cjson-decoded value of Redis firewall:config key
-- @return table: validated config with defaults applied for missing/bad fields
-- @return table: list of warning strings (empty when input is clean)
-- ============================================================================
function _M.parse_config(raw)
    local warnings = {}
    local out = {}

    -- Copy defaults so out always has every key
    for k, v in pairs(_M.DEFAULTS) do out[k] = v end

    if raw == nil then
        table.insert(warnings,
            "firewall:config not found in Redis — using defaults.")
        return out, warnings
    end

    if type(raw) ~= "table" then
        table.insert(warnings,
            "firewall:config is not a JSON object (got " .. type(raw) .. ") — using defaults")
        return out, warnings
    end

    -- emission_interval: must be a positive number (optional — default if absent)
    if raw.emission_interval ~= nil then
        local ei = tonumber(raw.emission_interval)
        if ei == nil or ei <= 0 then
            table.insert(warnings,
                "config.emission_interval invalid ("
                .. tostring(raw.emission_interval)
                .. ") — using default " .. _M.DEFAULTS.emission_interval)
        else
            out.emission_interval = ei
        end
    end

    -- burst: must be a non-negative number (optional — default if absent)
    if raw.burst ~= nil then
        local burst = tonumber(raw.burst)
        if burst == nil or burst < 0 then
            table.insert(warnings,
                "config.burst invalid ("
                .. tostring(raw.burst)
                .. ") — using default " .. _M.DEFAULTS.burst)
        else
            out.burst = burst
        end
    end

    -- audit_enabled: boolean, optional
    if raw.audit_enabled ~= nil then
        if type(raw.audit_enabled) ~= "boolean" then
            table.insert(warnings,
                "config.audit_enabled must be a boolean (true or false), got "
                .. type(raw.audit_enabled))
        else
            out.audit_enabled = raw.audit_enabled
        end
    end

    -- audit_maxlen: positive integer, optional
    if raw.audit_maxlen ~= nil then
        local maxlen = tonumber(raw.audit_maxlen)
        if maxlen == nil or maxlen <= 0 then
            table.insert(warnings,
                "config.audit_maxlen must be a positive integer, got "
                .. tostring(raw.audit_maxlen))
        else
            out.audit_maxlen = math.floor(maxlen)
        end
    end

    -- mode: enforce | monitor | off, optional
    if raw.mode ~= nil then
        if type(raw.mode) == "string" and _M.VALID_MODES[raw.mode] then
            out.mode = raw.mode
        else
            table.insert(warnings,
                "config.mode invalid (" .. tostring(raw.mode)
                .. ") — must be enforce|monitor|off — using default " .. _M.DEFAULTS.mode)
        end
    end

    -- penalty_ttl: non-negative integer (ms), optional
    if raw.penalty_ttl ~= nil then
        local pt = tonumber(raw.penalty_ttl)
        if pt == nil or pt < 0 then
            table.insert(warnings,
                "config.penalty_ttl invalid ("
                .. tostring(raw.penalty_ttl)
                .. ") — using default " .. _M.DEFAULTS.penalty_ttl)
        else
            out.penalty_ttl = math.floor(pt)
        end
    end

    return out, warnings
end

-- ============================================================================
-- parse_rules: validate a decoded firewall:rules array
-- ============================================================================
-- @param raw table|nil: cjson-decoded value of Redis firewall:rules key
-- @return table|nil: cleaned rules array, or nil if structurally unusable
-- @return table: list of warning strings (empty when input is clean)
-- ============================================================================

local _ALLOWED_RULE_KEYS = {
    name = true, phase = true, cost = true, match = true,
}

local _ALLOWED_REQ_MATCH_KEYS = {
    uri_pattern   = true,
    ua_pattern    = true,
    query_pattern = true,
    method        = true,
    has_query     = true,
}

local _ALLOWED_RES_MATCH_KEYS = {
    status = true,
}

-- Per-phase predicate validator. Each returns (ok, err_string).
-- Called only after the rule has passed top-level validation (name/phase/cost/match).
local function _validate_req_match(match)
    -- string-typed pattern fields
    for _, field in ipairs({ "uri_pattern", "ua_pattern", "query_pattern" }) do
        local v = match[field]
        if v ~= nil and type(v) ~= "string" then
            return false, "match." .. field .. " must be a string (got " .. type(v) .. ")"
        end
    end
    if match.method ~= nil and type(match.method) ~= "string" then
        return false, "match.method must be a string (got " .. type(match.method) .. ")"
    end
    if match.has_query ~= nil and type(match.has_query) ~= "boolean" then
        return false, "match.has_query must be a boolean (got " .. type(match.has_query) .. ")"
    end
    for k in pairs(match) do
        if not _ALLOWED_REQ_MATCH_KEYS[k] then
            return false, "match has unknown key \"" .. tostring(k) .. "\" for phase=req"
        end
    end
    return true
end

local function _validate_res_match(match)
    if match.status ~= nil then
        local s = tonumber(match.status)
        if s == nil or s ~= math.floor(s) or s < 100 or s > 599 then
            return false, "match.status must be an integer in 100..599 (got " .. tostring(match.status) .. ")"
        end
    end
    for k in pairs(match) do
        if not _ALLOWED_RES_MATCH_KEYS[k] then
            return false, "match has unknown key \"" .. tostring(k) .. "\" for phase=res"
        end
    end
    return true
end

local _PHASE_VALIDATORS = {
    req = _validate_req_match,
    res = _validate_res_match,
}

-- Count entries in a table (works for non-sequential keys too).
local function _count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function _M.parse_rules(raw)
    local warnings = {}

    if raw == nil then
        -- Absence of rules is a normal startup state; firewall.lua logs an
        -- ERR separately so callers can distinguish "missing" from "malformed".
        return nil, warnings
    end

    if type(raw) ~= "table" then
        table.insert(warnings,
            "firewall:rules is not a JSON array (got " .. type(raw) .. ") — ignoring")
        return nil, warnings
    end

    local valid = {}
    local seen_names = {}

    for i, rule in ipairs(raw) do
        local label = "rules[" .. i .. "]"
        local skip = false

        if type(rule) ~= "table" then
            table.insert(warnings, label .. " is not an object — skipping")
            skip = true
        end

        -- name: required, charset/length-validated, unique
        if not skip then
            local name = rule.name
            if type(name) ~= "string" or name == "" then
                table.insert(warnings,
                    label .. " missing or non-string name — skipping")
                skip = true
            elseif #name > _NAME_MAX_LEN then
                table.insert(warnings,
                    label .. " name=" .. tostring(name) .. " exceeds "
                    .. _NAME_MAX_LEN .. " chars — skipping")
                skip = true
            elseif not name:match(_NAME_PATTERN) then
                table.insert(warnings,
                    label .. " name=" .. tostring(name)
                    .. " has invalid charset (allowed: [a-z0-9-]) — skipping")
                skip = true
            elseif seen_names[name] then
                table.insert(warnings,
                    label .. " name=" .. tostring(name) .. " is duplicated — skipping")
                skip = true
            end
            if not skip then label = label .. " name=" .. rule.name end
        end

        -- phase: required, must be in VALID_PHASES
        if not skip then
            if type(rule.phase) ~= "string" or not _M.VALID_PHASES[rule.phase] then
                table.insert(warnings,
                    label .. " has invalid phase (" .. tostring(rule.phase)
                    .. ") — must be one of req|res — skipping")
                skip = true
            end
        end

        -- cost: required, integer, 0..99999
        if not skip then
            local c = rule.cost
            if type(c) ~= "number" or c ~= math.floor(c) or c < 0 or c > _COST_MAX then
                table.insert(warnings,
                    label .. " has invalid cost (" .. tostring(c)
                    .. ") — must be integer in 0.." .. _COST_MAX .. " — skipping")
                skip = true
            end
        end

        -- match: required, table, at least one predicate, phase-validated
        if not skip then
            if type(rule.match) ~= "table" then
                table.insert(warnings,
                    label .. " missing or non-object match — skipping")
                skip = true
            elseif _count_keys(rule.match) == 0 then
                table.insert(warnings,
                    label .. " match must contain at least one predicate — skipping")
                skip = true
            else
                local validator = _PHASE_VALIDATORS[rule.phase]
                local ok, err = validator(rule.match)
                if not ok then
                    table.insert(warnings, label .. " " .. err .. " — skipping")
                    skip = true
                end
            end
        end

        -- Reject unknown top-level rule keys (catches typos like "cosst").
        if not skip then
            for k in pairs(rule) do
                if not _ALLOWED_RULE_KEYS[k] then
                    table.insert(warnings,
                        label .. " has unknown key \"" .. tostring(k) .. "\" — skipping")
                    skip = true
                    break
                end
            end
        end

        if not skip then
            seen_names[rule.name] = true
            table.insert(valid, rule)
        end
    end

    return valid, warnings
end

-- ============================================================================
-- ADMIN-SIDE STRICT VALIDATION
-- ============================================================================
-- parse_config / parse_rules are fail-soft: at request time we want bad
-- entries skipped with a warning so the firewall keeps running. On the
-- admin write path we want the opposite — surface every warning as an
-- error so the operator can fix the input before it lands in Redis. These
-- wrappers also catch top-level shape problems and unknown keys, which
-- are silently ignored by the lenient path.
-- ============================================================================

-- Promote a list of warnings to errors and return ok/errors/normalised.
local function _result(ok, errors, normalised)
    return { ok = ok, errors = errors or {}, normalised = normalised }
end

-- Detect whether a Lua table decoded from JSON looks like a JSON array.
-- cjson decodes [] -> empty table and {} -> empty table, so we treat an
-- empty table as "object" (callers reject empty config separately).
local function _is_json_array(t)
    if #t == 0 then return false end
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
    end
    return true
end

-- Classify the top-level type of a raw JSON string without decoding it.
-- Returns "array", "object", or nil (unrecognised / empty body).
-- Pure string operation — no cjson or ngx dependency.
function _M.json_top_level_type(body)
    local first_char = body:match("^%s*(.)")
    if first_char == "[" then return "array" end
    if first_char == "{" then return "object" end
    return nil
end

function _M.validate_rules_strict(raw)
    if type(raw) ~= "table" then
        return _result(false, { "Rules must be a JSON array of rule objects." })
    end
    if next(raw) ~= nil and not _is_json_array(raw) then
        return _result(false, { "Rules must be a JSON array, not an object." })
    end

    local cleaned, warnings = _M.parse_rules(raw)
    if #warnings > 0 then
        return _result(false, warnings)
    end
    return _result(true, {}, cleaned or {})
end

-- ============================================================================
-- parse_allowlist / parse_blocklist
-- ============================================================================
-- Fail-soft validators for firewall:allowlist and firewall:blocklist.
-- Both keys hold a JSON array of IPv4 addresses or CIDR strings.
-- Invalid entries are skipped with a warning; valid entries are returned
-- as the original strings (callers convert to parsed form via cidr.parse).
--
-- @param  raw   table|nil  cjson-decoded Redis value
-- @param  label string     used in warning messages ("allowlist"|"blocklist")
-- @return table            array of valid CIDR/IP strings
-- @return table            list of warning strings
-- ============================================================================
local function _parse_ip_list(raw, label)
    local warnings = {}
    if raw == nil then
        return {}, warnings
    end
    if type(raw) ~= "table" then
        table.insert(warnings,
            label .. " must be a JSON array (got " .. type(raw) .. ")")
        return {}, warnings
    end
    local valid = {}
    for i, entry in ipairs(raw) do
        local lbl = label .. "[" .. i .. "]"
        if type(entry) ~= "string" or entry == "" then
            table.insert(warnings, lbl .. " must be a non-empty string — skipping")
        elseif not cidr.parse(entry) then
            table.insert(warnings,
                lbl .. " \"" .. tostring(entry)
                .. "\" is not a valid IPv4 address or CIDR — skipping")
        else
            table.insert(valid, entry)
        end
    end
    return valid, warnings
end

function _M.parse_allowlist(raw)
    return _parse_ip_list(raw, "allowlist")
end

function _M.parse_blocklist(raw)
    return _parse_ip_list(raw, "blocklist")
end

-- ============================================================================
-- ADMIN-SIDE STRICT VALIDATION
-- ============================================================================

function _M.validate_allowlist_strict(raw)
    if type(raw) ~= "table" then
        return _result(false, { "Allowlist must be a JSON array of IPv4 addresses or CIDRs." })
    end
    if next(raw) ~= nil and not _is_json_array(raw) then
        return _result(false, { "Allowlist must be a JSON array, not an object." })
    end
    local cleaned, warnings = _M.parse_allowlist(raw)
    if #warnings > 0 then
        return _result(false, warnings)
    end
    return _result(true, {}, cleaned)
end

function _M.validate_blocklist_strict(raw)
    if type(raw) ~= "table" then
        return _result(false, { "Blocklist must be a JSON array of IPv4 addresses or CIDRs." })
    end
    if next(raw) ~= nil and not _is_json_array(raw) then
        return _result(false, { "Blocklist must be a JSON array, not an object." })
    end
    local cleaned, warnings = _M.parse_blocklist(raw)
    if #warnings > 0 then
        return _result(false, warnings)
    end
    return _result(true, {}, cleaned)
end

function _M.validate_config_strict(raw)
    if type(raw) ~= "table" then
        return _result(false, { "Config must be a JSON object." })
    end
    if _is_json_array(raw) then
        return _result(false, { "Config must be a JSON object, not a JSON array." })
    end

    local allowed = {
        emission_interval = true, burst = true, penalty_ttl = true,
        audit_enabled = true, audit_maxlen = true,
        mode = true,
    }
    local errors = {}
    for k in pairs(raw) do
        if not allowed[k] then
            table.insert(errors, "Unknown config key \"" .. tostring(k) .. "\".")
        end
    end

    local cleaned, warnings = _M.parse_config(raw)
    for _, w in ipairs(warnings) do table.insert(errors, w) end
    if #errors > 0 then
        return _result(false, errors)
    end
    return _result(true, {}, cleaned)
end

return _M
