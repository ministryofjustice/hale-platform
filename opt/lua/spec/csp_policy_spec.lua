-- CSP builder unit tests (csp/policy.lua)
-- Run: make test-firewall (or busted spec/csp_policy_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local policy = require "csp.policy"

local function base()
    return policy.new({
        { "style-src", "'self'", "'unsafe-inline'" },
        { "img-src",   "'self'" },
    })
end

describe("policy.new / render", function()
    it("renders directives in declaration order", function()
        assert.equals("style-src 'self' 'unsafe-inline'; img-src 'self'", base():render())
    end)

    it("exposes a directive's sources as a copy", function()
        local p = base()
        local sources = p:get("img-src")
        assert.same({ "'self'" }, sources)
        table.insert(sources, "data:")
        assert.same({ "'self'" }, p:get("img-src"))
        assert.is_nil(p:get("font-src"))
    end)
end)

describe("policy:add", function()
    it("appends sources to one directive", function()
        assert.same({ "'self'", "data:" }, base():add("img-src", "data:"):get("img-src"))
    end)

    it("appends the same sources to several directives", function()
        local p = base():add({ "style-src", "img-src" }, "https://cdn.example")
        assert.same({ "'self'", "'unsafe-inline'", "https://cdn.example" }, p:get("style-src"))
        assert.same({ "'self'", "https://cdn.example" }, p:get("img-src"))
    end)

    it("skips nil sources, wherever they appear", function()
        local p = base():add("img-src", nil):add("img-src", nil, "data:", nil, "blob:")
        assert.same({ "'self'", "data:", "blob:" }, p:get("img-src"))
        assert.is_nil(p:render():find("  ", 1, true))
    end)

    it("ignores duplicates so overlays are idempotent", function()
        local p = base():add("img-src", "'self'", "data:"):add("img-src", "data:")
        assert.same({ "'self'", "data:" }, p:get("img-src"))
    end)

    it("appends a directive the policy did not have", function()
        local p = base():add("font-src", "'self'", "data:")
        assert.equals("style-src 'self' 'unsafe-inline'; img-src 'self'; font-src 'self' data:", p:render())
    end)

    it("is chainable (returns the same policy)", function()
        local p = base()
        assert.equals(p, p:add("img-src", "data:"))
        assert.equals(p, p:add("style-src", "x"):add("img-src", "y"))
    end)
end)

describe("policy:clone", function()
    it("is independent of the original", function()
        local original = base()
        local copy = original:clone():add("img-src", "data:"):add("font-src", "'self'")
        assert.same({ "'self'" }, original:get("img-src"))
        assert.is_nil(original:get("font-src"))
        assert.same({ "'self'", "data:" }, copy:get("img-src"))
    end)
end)

describe("policy.is_admin", function()
    it("matches site-relative wp-admin paths only", function()
        assert.is_true(policy.is_admin("/wp-admin/"))
        assert.is_true(policy.is_admin("/wp-admin/options.php"))
        assert.is_false(policy.is_admin("/wp-admin"))
        assert.is_false(policy.is_admin("/blog/wp-admin/"))
        assert.is_false(policy.is_admin("/xwp-admin/"))
        assert.is_false(policy.is_admin("/"))
        assert.is_false(policy.is_admin(nil))
    end)
end)
