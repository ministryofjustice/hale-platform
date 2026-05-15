-- Cost module unit tests
-- Run: docker build -f test.Dockerfile -t firewall-test . && docker run --rm firewall-test

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local cost = require "firewall.cost"

-- Simple regex mock
local function mock_regex(subject, pattern)
    if not subject or not pattern then return false end

    if pattern:find("|") then
        for part in pattern:gmatch("[^|]+") do
            local p = part:gsub("\\%.", "%%."):gsub("%-", "%%-")
            if subject:lower():find(p:lower()) then return true end
        end
        return false
    end

    local lua_pattern = pattern
        :gsub("\\%.", "%%.")
        :gsub("%-", "%%-")
        :gsub("%$$", "$")
    return subject:lower():find(lua_pattern:lower()) ~= nil
end

-- Build req-phase signal table for the new cost.calculate(signals, rules, regex_fn)
-- signature. Tests stay readable while paying the same predicate ground.
local function _req(uri, ua, method, has_query, query)
    return { uri = uri, ua = ua, method = method, has_query = has_query, query = query }
end

local function _req_rule(name, cost_, match)
    return { name = name, phase = "req", cost = cost_, match = match }
end

describe("calculate (req phase)", function()
    it("returns 0 for nil/empty rules", function()
        assert.equals(0, (cost.calculate(_req("/test", "ua", "GET", false), nil,  mock_regex)))
        assert.equals(0, (cost.calculate(_req("/test", "ua", "GET", false), {},   mock_regex)))
    end)

    it("matches uri_pattern", function()
        local rules = { _req_rule("txt", 20, { uri_pattern = "\\.txt$" }) }
        assert.equals(20, (cost.calculate(_req("/admin.txt",  "ua", "GET", false), rules, mock_regex)))
        assert.equals(0,  (cost.calculate(_req("/admin.html", "ua", "GET", false), rules, mock_regex)))
    end)

    it("matches ua_pattern", function()
        local rules = { _req_rule("curl", 25, { ua_pattern = "curl" }) }
        assert.equals(25, (cost.calculate(_req("/api", "curl/7.64", "GET", false), rules, mock_regex)))
        assert.equals(0,  (cost.calculate(_req("/api", "Mozilla",   "GET", false), rules, mock_regex)))
    end)

    it("matches method exactly", function()
        local rules = { _req_rule("post", 10, { method = "POST" }) }
        assert.equals(10, (cost.calculate(_req("/api", "ua", "POST", false), rules, mock_regex)))
        assert.equals(0,  (cost.calculate(_req("/api", "ua", "GET",  false), rules, mock_regex)))
    end)

    it("matches has_query predicate", function()
        local rules = { _req_rule("query", 5, { has_query = true }) }
        assert.equals(5, (cost.calculate(_req("/search", "ua", "GET", true),  rules, mock_regex)))
        assert.equals(0, (cost.calculate(_req("/search", "ua", "GET", false), rules, mock_regex)))
    end)

    it("matches query_pattern when query string present", function()
        local rules = { _req_rule("probe", 30, { query_pattern = "probe=" }) }
        assert.equals(30, (cost.calculate(_req("/", "ua", "GET", true, "probe=948726"), rules, mock_regex)))
    end)

    it("does not match query_pattern when query string is nil", function()
        local rules = { _req_rule("probe", 30, { query_pattern = "probe=" }) }
        assert.equals(0, (cost.calculate(_req("/", "ua", "GET", false, nil), rules, mock_regex)))
    end)

    it("does not match query_pattern when query string is empty", function()
        local rules = { _req_rule("probe", 30, { query_pattern = "probe=" }) }
        assert.equals(0, (cost.calculate(_req("/", "ua", "GET", false, ""), rules, mock_regex)))
    end)

    it("query_pattern does not match when pattern is absent from query string", function()
        local rules = { _req_rule("probe", 30, { query_pattern = "probe=" }) }
        assert.equals(0, (cost.calculate(_req("/wp-includes/css/style.css", "ua", "GET", true, "ver=6.9.1"), rules, mock_regex)))
    end)

    it("requires all predicates within a rule to match", function()
        local rules = { _req_rule("specific", 200, {
            uri_pattern = "admin", ua_pattern = "curl", method = "POST",
        }) }
        assert.equals(200, (cost.calculate(_req("/admin", "curl/7", "POST", false), rules, mock_regex)))
        assert.equals(0,   (cost.calculate(_req("/index", "curl/7", "POST", false), rules, mock_regex)))
        assert.equals(0,   (cost.calculate(_req("/admin", "Mozilla", "POST", false), rules, mock_regex)))
    end)

    it("includes cost=0 (audit-only) rules in the breakdown but adds nothing to total", function()
        local rules = { _req_rule("audit", 0, { uri_pattern = "\\.txt$" }) }
        local total, breakdown = cost.calculate(_req("/x.txt", "ua", "GET", false), rules, mock_regex)
        assert.equals(0, total)
        assert.equals(0, breakdown["rule:req-score:audit"])
    end)

    it("stacks multiple matching rules and keys breakdown by name", function()
        local rules = {
            _req_rule("base", 1, { uri_pattern = "." }),
            _req_rule("txt",  20, { uri_pattern = "\\.txt$" }),
        }
        local total, breakdown = cost.calculate(_req("/admin.txt", "ua", "GET", false), rules, mock_regex)
        assert.equals(21, total)
        assert.equals(1,  breakdown["rule:req-score:base"])
        assert.equals(20, breakdown["rule:req-score:txt"])
    end)
end)

describe("calculate with realistic req rules", function()
    local rules = {
        _req_rule("base",         1,  { uri_pattern = "." }),
        _req_rule("query-string", 4,  { has_query = true }),
        _req_rule("txt-ext",      20, { uri_pattern = "\\.txt$" }),
    }

    it("stacks base + query-string + txt-ext", function()
        local total, breakdown = cost.calculate(_req("/admin.txt", "ua", "GET", true, "foo=1"), rules, mock_regex)
        assert.equals(25, total)
        assert.equals(1,  breakdown["rule:req-score:base"])
        assert.equals(4,  breakdown["rule:req-score:query-string"])
        assert.equals(20, breakdown["rule:req-score:txt-ext"])
    end)
end)

describe("calculate (res phase)", function()
    local rules = {
        { name = "res-404", phase = "res", cost = 50, match = { status = 404 } },
        { name = "res-499", phase = "res", cost = 25, match = { status = 499 } },
    }

    it("matches a status rule and keys breakdown by name", function()
        local total, breakdown = cost.calculate({ status = 404 }, rules, nil)
        assert.equals(50, total)
        assert.equals(50, breakdown["rule:res-score:res-404"])
        assert.is_nil(breakdown["rule:res-score:res-499"])
    end)

    it("returns 0 when status does not match any rule", function()
        local total, breakdown = cost.calculate({ status = 200 }, rules, nil)
        assert.equals(0, total)
        assert.same({}, breakdown)
    end)

    it("returns 0 for nil/empty rules", function()
        assert.equals(0, (cost.calculate({ status = 404 }, nil, nil)))
        assert.equals(0, (cost.calculate({ status = 404 }, {},  nil)))
    end)
end)
