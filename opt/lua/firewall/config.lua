-- ============================================================================
-- CONFIG PARSING MODULE
-- ============================================================================
-- Pure functions for parsing and validating firewall config and rules loaded
-- from Redis. No ngx.* dependencies so this can be unit tested with busted.
--
-- USAGE:
--   local config_mod = require "firewall.config"
--   local cfg, warns = config_mod.parse_config(cjson.decode(raw_json))
--   local rules, warns = config_mod.parse_rules(cjson.decode(raw_json))
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
--     "emission_interval": <number>,   -- REQUIRED. Milliseconds per token
--                                      --   (i.e. the inverse of the sustained
--                                      --   request rate). Must be > 0.
--                                      --   Default: 1000  (1 req/s sustained)
--
--     "burst": <number>,               -- REQUIRED. Burst capacity in ms.
--                                      --   Allows short bursts above the
--                                      --   sustained rate. Must be >= 0.
--                                      --   Default: 100000 (100 s of burst)
--
--     "audit_enabled": <boolean>,      -- Optional. When true, the GCRA script
--                                      --   writes rule breakdowns to the audit
--                                      --   stream on each blocked request.
--                                      --   Default: false
--
--     "audit_stream": <string>,        -- Optional. Redis stream key name for
--                                      --   audit events.
--                                      --   Default: "firewall:audit"
--
--     "audit_maxlen": <integer>        -- Optional. MAXLEN trim on the audit
--                                      --   stream (approximate). Must be > 0.
--                                      --   Default: 10000
--   }
--
-- Example (minimal):
--   SET firewall:config '{"emission_interval":500,"burst":50000}'
--
-- Example (with audit):
--   SET firewall:config '{"emission_interval":500,"burst":50000,
--                          "audit_enabled":true,"audit_maxlen":5000}'
--
-- ----------------------------------------------------------------------------
-- KEY: firewall:rules  (JSON array of rule objects)
-- ----------------------------------------------------------------------------
--
--   [
--     {
--       "id": <string>,          -- REQUIRED. Unique rule identifier. Used as
--                                --   the breakdown key ("rule:<id>") in audit
--                                --   events. Must be a non-empty string.
--
--       "cost": <number>,        -- REQUIRED. Tokens consumed when this rule
--                                --   matches. Must be > 0.
--
--       "enabled": <boolean>,    -- Optional. Set to false to disable without
--                                --   removing. Default: true (any non-false
--                                --   value is treated as enabled).
--
--       "conditions": {          -- Optional. If omitted the rule matches every
--                                --   request.
--
--         "uri_pattern": <string>,  -- Optional. PCRE regex matched against the
--                                   --   request path only (ngx.var.uri).
--                                   --   Does NOT include the query string —
--                                   --   use has_query for query detection.
--                                   --   Case-insensitive.
--
--         "query_pattern": <string>, -- Optional. PCRE regex matched against the
--                                   --   raw query string (ngx.var.args), e.g.
--                                   --   "^[a-z]{6}=[0-9]{6}$" to detect random
--                                   --   probe parameters. Only matches when a
--                                   --   query string is present. Case-insensitive.
--
--         "ua_pattern":  <string>,  -- Optional. PCRE regex matched against the
--                                   --   User-Agent header. Case-insensitive.
--
--         "method":      <string>,  -- Optional. Exact HTTP method match,
--                                   --   e.g. "POST". Case-sensitive.
--
--         "has_query":   <boolean>  -- Optional. true = only match requests
--                                   --   with a query string; false = only
--                                   --   match requests without one.
--       }
--     },
--     ...
--   ]
--
-- Example:
--   SET firewall:rules '[
--     {"id":"base",       "cost":1},
--     {"id":"query-string","cost":4,  "conditions":{"has_query":true}},
--     {"id":"txt-ext",    "cost":20,  "conditions":{"uri_pattern":"\\.txt$"}},
--     {"id":"post",       "cost":2,   "conditions":{"method":"POST"}},
--     {"id":"bad-bot",    "cost":50,  "conditions":{"ua_pattern":"zgrab|masscan"}}
--   ]'
--
-- Validation rules (enforced by parse_rules):
--   - Rules with missing/non-string id are skipped with WARN.
--   - Rules with non-numeric or non-positive cost are skipped with WARN.
--   - Rules where conditions is not an object are skipped with WARN.
--   - Rules where uri_pattern, ua_pattern, query_pattern, or method is not a
--     string are skipped with WARN (prevents regex engine errors at request time).
--   - has_query is not type-checked (any falsy/truthy value is accepted).
-- ============================================================================

local _M = {}

-- GCRA defaults (kept in sync with gcra.lua DEFAULTS)
_M.DEFAULTS = {
    emission_interval = 1000,          -- ms per token
    burst             = 100000,        -- ms of burst capacity
    audit_enabled     = false,
    audit_stream      = "firewall:audit",
    audit_maxlen      = 10000,
}

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
            "firewall:config not found in Redis — using defaults. "
            .. "Run seed_config() to initialise.")
        return out, warnings
    end

    if type(raw) ~= "table" then
        table.insert(warnings,
            "firewall:config is not a JSON object (got " .. type(raw) .. ") — using defaults")
        return out, warnings
    end

    -- emission_interval: must be a positive number
    local ei = tonumber(raw.emission_interval)
    if ei == nil or ei <= 0 then
        table.insert(warnings,
            "config.emission_interval invalid ("
            .. tostring(raw.emission_interval)
            .. ") — using default " .. _M.DEFAULTS.emission_interval)
    else
        out.emission_interval = ei
    end

    -- burst: must be a non-negative number
    local burst = tonumber(raw.burst)
    if burst == nil or burst < 0 then
        table.insert(warnings,
            "config.burst invalid ("
            .. tostring(raw.burst)
            .. ") — using default " .. _M.DEFAULTS.burst)
    else
        out.burst = burst
    end

    -- audit_enabled: boolean, optional
    if raw.audit_enabled ~= nil then
        out.audit_enabled = not not raw.audit_enabled
    end

    -- audit_stream: string, optional
    if type(raw.audit_stream) == "string" and raw.audit_stream ~= "" then
        out.audit_stream = raw.audit_stream
    end

    -- audit_maxlen: positive integer, optional
    local maxlen = tonumber(raw.audit_maxlen)
    if maxlen ~= nil and maxlen > 0 then
        out.audit_maxlen = math.floor(maxlen)
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
function _M.parse_rules(raw)
    local warnings = {}

    if raw == nil then
        -- Absence of rules is handled by the ERR log in firewall.lua; no extra
        -- warning needed here so callers can distinguish "missing" from "malformed".
        return nil, warnings
    end

    if type(raw) ~= "table" then
        table.insert(warnings,
            "firewall:rules is not a JSON array (got " .. type(raw) .. ") — ignoring")
        return nil, warnings
    end

    local valid = {}
    for i, rule in ipairs(raw) do
        local label = "rules[" .. i .. "]"
        local skip = false

        if type(rule) ~= "table" then
            table.insert(warnings, label .. " is not an object — skipping")
            skip = true
        else
            label = label .. " id=" .. tostring(rule.id)

            -- id must be a non-empty string (used as breakdown key)
            if type(rule.id) ~= "string" or rule.id == "" then
                table.insert(warnings,
                    label .. " missing or non-string id — skipping")
                skip = true
            end

            -- cost must be a positive number
            if not skip and (type(rule.cost) ~= "number" or rule.cost <= 0) then
                table.insert(warnings,
                    label .. " has invalid cost (" .. tostring(rule.cost) .. ") — skipping")
                skip = true
            end

            -- conditions, if present, must be a table with string pattern values
            if not skip and rule.conditions ~= nil then
                if type(rule.conditions) ~= "table" then
                    table.insert(warnings,
                        label .. " conditions is not an object — skipping")
                    skip = true
                else
                    for _, pattern_field in ipairs({ "uri_pattern", "ua_pattern", "query_pattern" }) do
                        local v = rule.conditions[pattern_field]
                        if v ~= nil and type(v) ~= "string" then
                            table.insert(warnings,
                                label .. " conditions." .. pattern_field
                                .. " must be a string (got " .. type(v) .. ") — skipping")
                            skip = true
                            break
                        end
                    end
                    if not skip then
                        local m = rule.conditions.method
                        if m ~= nil and type(m) ~= "string" then
                            table.insert(warnings,
                                label .. " conditions.method must be a string (got " .. type(m) .. ") — skipping")
                            skip = true
                        end
                    end
                end
            end
        end

        if not skip then
            table.insert(valid, rule)
        end
    end

    return valid, warnings
end

return _M
