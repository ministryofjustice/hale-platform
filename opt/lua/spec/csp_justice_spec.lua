-- justice.gov.uk CSP policy unit tests (csp/justice.lua)
-- Run: make test-firewall (or busted spec/csp_justice_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local justice = require "csp.justice"

local WWW = "www.justice.gov.uk"
local DEV = "dev.websitebuilder.service.justice.gov.uk"
local LOCAL = "hale.docker"
local CDN = "https://cdn.websitebuilder.service.justice.gov.uk"
local DEV_CDN = "https://cdn.dev.websitebuilder.service.justice.gov.uk"
local GTM = "https://www.googletagmanager.com/"
local LOGGED_IN_COOKIE = "wordpress_logged_in_abc123=hash"

-- Build for a site-relative path; defaults to the production host.
local function build(path, host, cookie)
    return justice.build({ path = path, host = host or WWW, cookie = cookie })
end

local function has(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

describe("justice sites", function()
    it("is enforced", function()
        assert.equals("enforce", justice.mode)
    end)

    it("lists all six environments", function()
        local paths = {}
        for _, site in ipairs(justice.sites) do paths[site.host] = site.path end
        assert.equals("", paths[WWW])
        for _, host in ipairs({
            LOCAL,
            DEV,
            "demo.websitebuilder.service.justice.gov.uk",
            "staging.websitebuilder.service.justice.gov.uk",
            "websitebuilder.service.justice.gov.uk",
        }) do
            assert.equals("/justice", paths[host], host)
        end
        assert.equals(6, #justice.sites)
    end)
end)

describe("justice base policy (public pages)", function()
    it("allows self and unsafe-inline styles, plus GTM for scripts", function()
        local p = build("/")
        assert.same({ "'self'", "'unsafe-inline'", CDN }, p:get("style-src"))
        assert.same({ "'self'", GTM, "'unsafe-inline'", CDN }, p:get("script-src"))
        assert.same({ "'self'", CDN }, p:get("img-src"))
        assert.same({ "'self'", "blob:" }, p:get("worker-src"))
        assert.same({ "'none'" }, p:get("object-src"))
    end)

    it("does not allow eval, data: images or hashes", function()
        local rendered = build("/"):render()
        assert.is_nil(rendered:find("'unsafe-eval'", 1, true))
        assert.is_nil(rendered:find("data:", 1, true))
        assert.is_nil(rendered:find("sha256", 1, true))
    end)

    it("is the same whether or not the user is logged in", function()
        assert.equals(build("/"):render(), build("/", WWW, LOGGED_IN_COOKIE):render())
    end)

    it("treats /wp-login.php and a nil path as public pages", function()
        assert.equals(build("/"):render(), build("/wp-login.php"):render())
        assert.equals(build("/"):render(), build(nil):render())
    end)
end)

describe("justice CDN overlay", function()
    it("adds the environment's CDN to style, script and img-src", function()
        local p = build("/", DEV)
        for _, name in ipairs({ "style-src", "script-src", "img-src" }) do
            assert.is_true(has(p:get(name), DEV_CDN), name)
            assert.is_false(has(p:get(name), CDN), name)
        end
    end)

    it("adds no CDN where the environment has none (local)", function()
        local rendered = build("/", LOCAL):render()
        assert.is_nil(rendered:find("cdn.", 1, true))
        assert.is_nil(rendered:find("  ", 1, true))
    end)

    it("never adds the CDN to worker or object-src", function()
        local p = build("/")
        assert.is_false(has(p:get("worker-src"), CDN))
        assert.is_false(has(p:get("object-src"), CDN))
    end)
end)

describe("justice admin overlay", function()
    it("adds unsafe-eval to style and script-src, and data: to img-src", function()
        local p = build("/wp-admin/options.php")
        assert.is_true(has(p:get("style-src"), "'unsafe-eval'"))
        assert.is_true(has(p:get("script-src"), "'unsafe-eval'"))
        assert.is_true(has(p:get("img-src"), "data:"))
    end)

    it("keeps everything public pages have", function()
        local public, admin = build("/"), build("/wp-admin/")
        for _, name in ipairs({ "style-src", "script-src", "img-src", "worker-src", "object-src" }) do
            for _, source in ipairs(public:get(name)) do
                assert.is_true(has(admin:get(name), source), name .. " lost " .. source)
            end
        end
    end)

    it("only fires for site-relative /wp-admin/ paths", function()
        for _, path in ipairs({ "/wp-admin", "/blog/wp-admin/", "/xwp-admin/", "/wp-content/themes/justice/dist/js/a.js" }) do
            assert.is_nil(build(path):render():find("'unsafe-eval'", 1, true), path)
        end
    end)
end)

describe("justice rendered header values", function()
    it("public page on www (matches the old wordpress.conf map exactly)", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. CDN .. "; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline' " .. CDN .. "; " ..
            "img-src 'self' " .. CDN .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = WWW }))
    end)

    it("public page on dev", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. DEV_CDN .. "; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline' " .. DEV_CDN .. "; " ..
            "img-src 'self' " .. DEV_CDN .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = DEV }))
    end)

    it("public page locally (no CDN)", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline'; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline'; " ..
            "img-src 'self'; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = LOCAL }))
    end)

    it("admin page on www", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. CDN .. " 'unsafe-eval'; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline' " .. CDN .. " 'unsafe-eval'; " ..
            "img-src 'self' " .. CDN .. " data:; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/wp-admin/index.php", host = WWW, cookie = LOGGED_IN_COOKIE }))
    end)
end)
