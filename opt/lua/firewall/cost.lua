-- ============================================================================
-- COST CALCULATION MODULE
-- ============================================================================
-- Pure functions for accumulating GCRA token costs from a list of rules
-- against a single phase's signals (request or response). No ngx.*
-- dependencies — `regex_fn` is injected so this stays unit-testable.
--
-- USAGE (request phase):
--   local cost = require "firewall.cost"
--   local total, breakdown = cost.calculate(
--       { uri = uri, ua = ua, method = method, has_query = has_query, query = query },
--       cache.get_rules("req"),
--       ngx.re.find  -- or any fn(subject, pattern) -> truthy if matches
--   )
--
-- USAGE (response phase):
--   local total, breakdown = cost.calculate(
--       { status = ngx.status },
--       cache.get_rules("res"),
--       nil  -- response phase has no regex predicates today
--   )
--
-- The breakdown table is keyed by "rule:<phase>-score:<name>" to match the
-- audit trigger format documented in the README.
-- ============================================================================

local _M = {}

-- ----------------------------------------------------------------------------
-- Per-predicate helpers. Each returns true when the predicate is satisfied
-- (or absent — predicates only filter when present).
-- ----------------------------------------------------------------------------

local function _match_req(match, signals, regex_fn)
    if match.uri_pattern then
        if not regex_fn or not regex_fn(signals.uri or "", match.uri_pattern) then
            return false
        end
    end
    if match.ua_pattern then
        if not regex_fn or not regex_fn(signals.ua or "", match.ua_pattern) then
            return false
        end
    end
    if match.method and signals.method ~= match.method then
        return false
    end
    if match.has_query ~= nil and match.has_query ~= signals.has_query then
        return false
    end
    if match.query_pattern then
        local q = signals.query
        if not q or q == "" then return false end
        if not regex_fn or not regex_fn(q, match.query_pattern) then
            return false
        end
    end
    return true
end

local function _match_res(match, signals, _regex_fn)
    if match.status and signals.status ~= match.status then
        return false
    end
    return true
end

local _PHASE_MATCHERS = {
    req = _match_req,
    res = _match_res,
}

--- Calculate total cost from a list of rules.
-- Rules must already be filtered to a single phase by the caller (cache
-- layer hands out per-phase slices via cache.get_rules(phase)).
--
-- @param signals table: phase-specific request/response signals
-- @param rules table: array of normalised rule objects (all same phase)
-- @param regex_fn function|nil: fn(subject, pattern) -> truthy on match.
--                               Required for req-phase regex predicates.
-- @return number: total cost (sum of all matching rule costs)
-- @return table: breakdown { ["rule:<phase>-score:<name>"] = cost, ... }
function _M.calculate(signals, rules, regex_fn)
    if not rules or type(rules) ~= "table" then
        return 0, {}
    end

    local breakdown = {}
    local total = 0

    for _, rule in ipairs(rules) do
        local matcher = _PHASE_MATCHERS[rule.phase]
        if matcher then
            if rule.match and matcher(rule.match, signals, regex_fn) then
                local key = "rule:" .. rule.phase .. "-score:" .. rule.name
                breakdown[key] = rule.cost
                total = total + rule.cost
            end
        else
            -- Defensive: schema.parse_rules already rejects unknown phases, so
            -- reaching this branch means rules bypassed validation (e.g. a
            -- migration script writing directly to Redis). Log so the operator
            -- notices the silent zero-score rather than chasing missing audit
            -- entries. Guarded so unit tests without an ngx stub still work.
            if ngx and ngx.log then
                ngx.log(ngx.WARN,
                    "[firewall] cost.calculate skipped rule name=",
                    tostring(rule.name),
                    " with unknown phase=", tostring(rule.phase))
            end
        end
    end

    return total, breakdown
end

return _M
