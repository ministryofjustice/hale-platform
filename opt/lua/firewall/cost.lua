-- ============================================================================
-- COST CALCULATION MODULE
-- ============================================================================
-- Pure functions for calculating request costs. No ngx.* dependencies.
-- All scoring is driven by rules (no hardcoded patterns).
--
-- USAGE:
--   local cost = require "firewall.cost"
--   local total, breakdown = cost.calculate(uri, ua, method, has_query, query, rules, regex_fn)
-- ============================================================================

local _M = {}

--- Check if a rule's conditions match the request
local function match_conditions(cond, uri, ua, method, has_query, query, regex_fn)
    if not cond then return true end

    if cond.uri_pattern and not regex_fn(uri, cond.uri_pattern) then
        return false
    end
    if cond.ua_pattern and not regex_fn(ua, cond.ua_pattern) then
        return false
    end
    if cond.method and method ~= cond.method then
        return false
    end
    if cond.has_query ~= nil and cond.has_query ~= has_query then
        return false
    end
    if cond.query_pattern then
        -- query is the raw query string (ngx.var.args), may be nil/empty
        if not query or query == "" then return false end
        if not regex_fn(query, cond.query_pattern) then return false end
    end

    return true
end

--- Calculate cost from rules
-- @param uri string: Request URI path (no query string)
-- @param ua string: User-Agent header
-- @param method string: HTTP method
-- @param has_query boolean: True if request has query string
-- @param query string|nil: Raw query string (ngx.var.args), used for query_pattern matching
-- @param rules table: Array of rule objects
-- @param regex_fn function: fn(subject, pattern) -> truthy if matches
-- @return number: Total cost
-- @return table: Breakdown {["rule:id"]=cost, ...}
function _M.calculate(uri, ua, method, has_query, query, rules, regex_fn)
    if not rules or type(rules) ~= "table" then
        return 0, {}
    end

    local breakdown = {}
    local total = 0

    for _, rule in ipairs(rules) do
        if rule.enabled ~= false and rule.cost then
            if match_conditions(rule.conditions, uri, ua, method, has_query, query, regex_fn) then
                local key = "rule:" .. (rule.id or "unknown")
                breakdown[key] = rule.cost
                total = total + rule.cost
            end
        end
    end

    return total, breakdown
end

return _M
