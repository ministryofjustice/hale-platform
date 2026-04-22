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

describe("calculate", function()
    it("returns 0 for nil/empty rules", function()
        assert.equals(0, (cost.calculate("/test", "ua", "GET", false, nil, nil, mock_regex)))
        assert.equals(0, (cost.calculate("/test", "ua", "GET", false, nil, {}, mock_regex)))
    end)

    it("matches unconditional rule", function()
        local rules = {{ id = "base", conditions = {}, cost = 1 }}
        local total, _ = cost.calculate("/anything", "ua", "GET", false, nil, rules, mock_regex)
        assert.equals(1, total)
    end)

    it("matches uri_pattern", function()
        local rules = {{ id = "txt", conditions = { uri_pattern = "\\.txt$" }, cost = 20 }}
        assert.equals(20, (cost.calculate("/admin.txt", "ua", "GET", false, nil, rules, mock_regex)))
        assert.equals(0,  (cost.calculate("/admin.html", "ua", "GET", false, nil, rules, mock_regex)))
    end)

    it("matches ua_pattern", function()
        local rules = {{ id = "curl", conditions = { ua_pattern = "curl" }, cost = 25 }}
        assert.equals(25, (cost.calculate("/api", "curl/7.64", "GET", false, nil, rules, mock_regex)))
        assert.equals(0,  (cost.calculate("/api", "Mozilla",   "GET", false, nil, rules, mock_regex)))
    end)

    it("matches method exactly", function()
        local rules = {{ id = "post", conditions = { method = "POST" }, cost = 10 }}
        assert.equals(10, (cost.calculate("/api", "ua", "POST", false, nil, rules, mock_regex)))
        assert.equals(0,  (cost.calculate("/api", "ua", "GET",  false, nil, rules, mock_regex)))
    end)

    it("matches has_query condition", function()
        local rules = {{ id = "query", conditions = { has_query = true }, cost = 5 }}
        assert.equals(5, (cost.calculate("/search", "ua", "GET", true,  nil, rules, mock_regex)))
        assert.equals(0, (cost.calculate("/search", "ua", "GET", false, nil, rules, mock_regex)))
    end)

    it("matches query_pattern when query string present", function()
        -- Use simple substring pattern compatible with the Lua-based mock regex
        local rules = {{ id = "probe", conditions = { query_pattern = "probe=" }, cost = 30 }}
        assert.equals(30, (cost.calculate("/", "ua", "GET", true, "probe=948726", rules, mock_regex)))
    end)

    it("does not match query_pattern when query string is nil", function()
        local rules = {{ id = "probe", conditions = { query_pattern = "probe=" }, cost = 30 }}
        assert.equals(0, (cost.calculate("/", "ua", "GET", false, nil, rules, mock_regex)))
    end)

    it("does not match query_pattern when query string is empty", function()
        local rules = {{ id = "probe", conditions = { query_pattern = "probe=" }, cost = 30 }}
        assert.equals(0, (cost.calculate("/", "ua", "GET", false, "", rules, mock_regex)))
    end)

    it("query_pattern does not match when pattern is absent from query string", function()
        local rules = {{ id = "probe", conditions = { query_pattern = "probe=" }, cost = 30 }}
        -- WP asset query string does not contain "probe=" so rule should not fire
        assert.equals(0, (cost.calculate("/wp-includes/css/style.css", "ua", "GET", true, "ver=6.9.1", rules, mock_regex)))
    end)

    it("requires all conditions to match", function()
        local rules = {{
            id = "specific",
            conditions = { uri_pattern = "admin", ua_pattern = "curl", method = "POST" },
            cost = 200
        }}
        assert.equals(200, (cost.calculate("/admin", "curl/7", "POST", false, nil, rules, mock_regex)))
        assert.equals(0,   (cost.calculate("/index", "curl/7", "POST", false, nil, rules, mock_regex)))
        assert.equals(0,   (cost.calculate("/admin", "Mozilla", "POST", false, nil, rules, mock_regex)))
    end)

    it("skips disabled rules", function()
        local rules = {{ id = "off", enabled = false, conditions = {}, cost = 1000 }}
        assert.equals(0, (cost.calculate("/any", "any", "GET", false, nil, rules, mock_regex)))
    end)

    it("stacks multiple matching rules", function()
        local rules = {
            { id = "base", conditions = {}, cost = 1 },
            { id = "txt",  conditions = { uri_pattern = "\\.txt$" }, cost = 20 },
        }
        local total, breakdown = cost.calculate("/admin.txt", "ua", "GET", false, nil, rules, mock_regex)
        assert.equals(21, total)
        assert.equals(1,  breakdown["rule:base"])
        assert.equals(20, breakdown["rule:txt"])
    end)
end)

describe("calculate with realistic rules", function()
    local rules = {
        { id = "base",         conditions = {},                           cost = 1  },
        { id = "query-string", conditions = { has_query = true },        cost = 4  },
        { id = "txt-ext",      conditions = { uri_pattern = "\\.txt$" }, cost = 20 },
    }

    it("stacks base + query-string + txt-ext", function()
        local total, breakdown = cost.calculate("/admin.txt", "ua", "GET", true, "foo=1", rules, mock_regex)
        -- base(1) + query-string(4) + txt-ext(20) = 25
        assert.equals(25, total)
        assert.equals(1,  breakdown["rule:base"])
        assert.equals(4,  breakdown["rule:query-string"])
        assert.equals(20, breakdown["rule:txt-ext"])
    end)
end)
