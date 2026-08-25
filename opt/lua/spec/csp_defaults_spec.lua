-- Default (catch-all) CSP policy unit tests (csp/defaults.lua)
-- Run: make test-firewall (or busted spec/csp_defaults_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local defaults = require "csp.defaults"

local WWW = "www.justice.gov.uk"
local DEV = "dev.websitebuilder.service.justice.gov.uk"
local CDN = "https://cdn.websitebuilder.service.justice.gov.uk"
local DEV_CDN = "https://cdn.dev.websitebuilder.service.justice.gov.uk"

local function has(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

describe("csp defaults", function()
    it("is a report-only catch-all", function()
        assert.equals("report-only", defaults.mode)
        assert.is_nil(defaults.sites)
    end)

    it("declares the base policy", function()
        local p = defaults.build({ path = "/", host = "hale.docker" })
        assert.same({ "'self'" }, p:get("default-src"))
        assert.same({ "'self'", "'unsafe-inline'", "'unsafe-eval'" }, p:get("script-src"))
        assert.same({ "'self'", "'unsafe-inline'" }, p:get("style-src"))
        assert.same({ "'self'", "data:", "https:" }, p:get("img-src"))
        assert.same({ "'self'", "data:" }, p:get("font-src"))
        assert.same({ "'self'" }, p:get("frame-ancestors"))
        assert.same({ "'none'" }, p:get("object-src"))
    end)

    it("adds the environment's CDN to script, style, img and font-src", function()
        local p = defaults.build({ path = "/", host = DEV })
        for _, name in ipairs({ "script-src", "style-src", "img-src", "font-src" }) do
            assert.is_true(has(p:get(name), DEV_CDN), name)
        end
        assert.is_false(has(p:get("default-src"), DEV_CDN))
        assert.is_false(has(p:get("frame-ancestors"), DEV_CDN))
    end)

    it("uses the production CDN for www and unknown hosts", function()
        assert.is_true(has(defaults.build({ path = "/", host = WWW }):get("script-src"), CDN))
        assert.is_true(has(defaults.build({ path = "/", host = "example.com" }):get("script-src"), CDN))
    end)

    it("is the same for every page and cookie", function()
        local expected = defaults.policy({ path = "/", host = WWW })
        assert.equals(expected, defaults.policy({ path = "/wp-admin/options.php", host = WWW }))
        assert.equals(expected, defaults.policy({ path = "/x", host = WWW, cookie = "wordpress_logged_in_1=a" }))
    end)

    it("renders the header value for dev", function()
        assert.equals(
            "default-src 'self'; " ..
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' " .. DEV_CDN .. "; " ..
            "style-src 'self' 'unsafe-inline' " .. DEV_CDN .. "; " ..
            "img-src 'self' data: https: " .. DEV_CDN .. "; " ..
            "font-src 'self' data: " .. DEV_CDN .. "; " ..
            "frame-ancestors 'self'; " ..
            "object-src 'none'",
            defaults.policy({ path = "/", host = DEV }))
    end)
end)
