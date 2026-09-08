-- CDN origin map unit tests (csp/cdn.lua)
-- Run: make test-firewall (or busted spec/csp_cdn_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local cdn = require "csp.cdn"
local justice = require "csp.justice"

local PROD_CDN = "https://cdn.websitebuilder.service.justice.gov.uk"

describe("csp cdn", function()
    it("defaults to the production CDN", function()
        assert.equals(PROD_CDN, cdn.default)
        assert.equals(PROD_CDN, cdn.for_host("www.justice.gov.uk"))
        assert.equals(PROD_CDN, cdn.for_host("unknown.example"))
        assert.equals(PROD_CDN, cdn.for_host(nil))
    end)

    it("maps each non-production environment to its own CDN", function()
        for _, env in ipairs({ "dev", "demo", "staging" }) do
            assert.equals("https://cdn." .. env .. ".websitebuilder.service.justice.gov.uk",
                cdn.for_host(env .. ".websitebuilder.service.justice.gov.uk"), env)
        end
    end)

    it("has no CDN for local", function()
        assert.is_nil(cdn.for_host("hale.docker"))
        assert.is_false(cdn.hosts["hale.docker"])
    end)

    it("only lists hosts that are justice site hosts (catches typos)", function()
        local known = {}
        for _, site in ipairs(justice.sites) do known[site.host] = true end
        for host in pairs(cdn.hosts) do
            assert.truthy(known[host], host .. " is in csp/cdn.lua but not in justice.sites")
        end
    end)
end)
