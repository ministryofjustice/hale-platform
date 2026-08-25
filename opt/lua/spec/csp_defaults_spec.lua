-- Default (catch-all) CSP policy unit tests (csp/defaults.lua)
-- Run: make test-firewall (or busted spec/csp_defaults_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local defaults = require "csp.defaults"

local WWW = "www.justice.gov.uk"
local DEV = "dev.websitebuilder.service.justice.gov.uk"
local CDN = "https://cdn.websitebuilder.service.justice.gov.uk"
local DEV_CDN = "https://cdn.dev.websitebuilder.service.justice.gov.uk"

-- The old wordpress.conf $csp_report_only map default, with the wildcard
-- https://*.websitebuilder.service.justice.gov.uk replaced by one CDN origin.
local function expected(cdn_origin)
    local suffix = cdn_origin and (" " .. cdn_origin) or ""
    return "default-src 'self'; "
        .. "script-src 'self' 'unsafe-inline' 'unsafe-eval'" .. suffix .. "; "
        .. "style-src 'self' 'unsafe-inline'" .. suffix .. "; "
        .. "img-src 'self' data: https:; "
        .. "font-src 'self' data:" .. suffix .. "; "
        .. "frame-ancestors 'self'; object-src 'none';"
end

describe("csp defaults", function()
    it("is report-only", function()
        assert.equals("report-only", defaults.mode)
    end)

    it("is a catch-all (no sites)", function()
        assert.is_nil(defaults.sites)
    end)

    it("allows the production CDN in script, style and font-src", function()
        assert.equals(expected(CDN), defaults.policy("/", nil, WWW))
        assert.equals(expected(CDN), defaults.policy("/", nil, "unknown.example"))
    end)

    it("allows the environment's own CDN", function()
        assert.equals(expected(DEV_CDN), defaults.policy("/", nil, DEV))
    end)

    it("allows no CDN where the environment has none (local)", function()
        local policy = defaults.policy("/", nil, "hale.docker")
        assert.equals(expected(nil), policy)
        assert.is_nil(policy:find("  ", 1, true))
        assert.is_nil(policy:find("websitebuilder", 1, true))
    end)

    it("returns the same policy for every page and cookie", function()
        assert.equals(expected(CDN), defaults.policy("/wp-admin/options.php", nil, WWW))
        assert.equals(expected(CDN), defaults.policy("/anything", "wordpress_logged_in_1=abc", WWW))
    end)
end)
