-- Default (catch-all) CSP policy unit tests (csp/defaults.lua)
-- Run: make test-firewall (or busted spec/csp_defaults_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local defaults = require "csp.defaults"

local EXPECTED = "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
    .. "style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; "
    .. "frame-ancestors 'self'; object-src 'none';"

describe("csp defaults", function()
    it("is report-only", function()
        assert.equals("report-only", defaults.mode)
    end)

    it("is a catch-all (no sites)", function()
        assert.is_nil(defaults.sites)
    end)

    it("applies the legacy default policy verbatim", function()
        assert.equals(EXPECTED, defaults.policy_string)
        assert.equals(EXPECTED, defaults.policy("/", nil))
    end)

    it("returns the same policy for every page and cookie", function()
        assert.equals(EXPECTED, defaults.policy("/wp-admin/options.php", nil))
        assert.equals(EXPECTED, defaults.policy("/anything", "wordpress_logged_in_1=abc"))
        assert.equals(EXPECTED, defaults.policy())
    end)
end)
