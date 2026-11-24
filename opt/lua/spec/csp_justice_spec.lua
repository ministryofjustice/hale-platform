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
local SNIPPET_HASH = "'sha256-Ac6EurLc5WNuBriCCA6Gi746Ieu1q/votBRNGQmBSUk='"  -- mojLoadLocalizedData()
local GTM_IMG = "https://www.googletagmanager.com"
local GA_IMG = "https://*.google-analytics.com"
local SPECULATION = "'inline-speculation-rules'"

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

describe("justice base policy (public pages, logged out)", function()
    it("allows self and unsafe-inline styles; self, GTM, known snippets and speculation rules for scripts", function()
        local p = build("/")
        assert.same({ "'self'", "'unsafe-inline'", CDN }, p:get("style-src"))
        assert.same({ "'self'", GTM, CDN, SNIPPET_HASH, SPECULATION }, p:get("script-src"))
        assert.same({ "'self'", CDN, GTM_IMG, GA_IMG }, p:get("img-src"))
        assert.same({ "'self'", "blob:" }, p:get("worker-src"))
        assert.same({ "'none'" }, p:get("object-src"))
    end)

    it("NEVER allows unsafe-inline scripts on public pages", function()
        for _, path in ipairs({ "/", "/courts/", "/wp-login.php", "/wp-content/themes/justice/dist/js/a.js" }) do
            for _, host in ipairs({ WWW, DEV, LOCAL }) do
                assert.is_false(has(build(path, host):get("script-src"), "'unsafe-inline'"), host .. path)
            end
        end
    end)

    it("does not allow eval or data: images", function()
        local rendered = build("/"):render()
        assert.is_nil(rendered:find("'unsafe-eval'", 1, true))
        assert.is_nil(rendered:find("data:", 1, true))
    end)

    it("treats /wp-login.php and a nil path as public pages", function()
        assert.equals(build("/"):render(), build("/wp-login.php"):render())
        assert.equals(build("/"):render(), build(nil):render())
    end)
end)

describe("justice logged-in overlay", function()
    it("swaps the script hashes for unsafe-inline, never both", function()
        local p = build("/", WWW, LOGGED_IN_COOKIE)
        assert.same({ "'self'", GTM, CDN, "'unsafe-inline'" }, p:get("script-src"))
        assert.is_false(has(p:get("script-src"), SNIPPET_HASH))
        assert.is_false(has(p:get("script-src"), SPECULATION))
    end)

    it("matches the login cookie case-insensitively and ignores other cookies", function()
        assert.is_true(has(build("/", WWW, "x=1; WordPress_Logged_In_ABC=1"):get("script-src"), "'unsafe-inline'"))
        assert.is_false(has(build("/", WWW, "foo=bar; comment_author=x"):get("script-src"), "'unsafe-inline'"))
    end)

    it("changes nothing else", function()
        local out, inn = build("/"), build("/", WWW, LOGGED_IN_COOKIE)
        for _, name in ipairs({ "style-src", "img-src", "worker-src", "object-src" }) do
            assert.same(out:get(name), inn:get(name), name)
        end
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

describe("justice analytics overlay", function()
    it("allows GTM and Google Analytics image pixels on every page", function()
        for _, path in ipairs({ "/", "/wp-admin/" }) do
            for _, host in ipairs({ WWW, DEV, LOCAL }) do
                local img = build(path, host):get("img-src")
                assert.is_true(has(img, GTM_IMG), host .. path)
                assert.is_true(has(img, GA_IMG), host .. path)
            end
        end
    end)

    it("does not add them anywhere but img-src", function()
        local rendered = build("/"):render()
        for _, name in ipairs({ "style-src", "worker-src", "object-src" }) do
            assert.is_false(has(build("/"):get(name), GA_IMG), name)
        end
        assert.equals(1, select(2, rendered:gsub("google%-analytics%.com", "")))
    end)
end)

describe("justice admin overlay", function()
    it("adds unsafe-inline and unsafe-eval to script-src, unsafe-eval to style-src, data: to img-src", function()
        local p = build("/wp-admin/options.php")
        assert.same({ "'self'", GTM, CDN, "'unsafe-inline'", "'unsafe-eval'" }, p:get("script-src"))
        assert.is_true(has(p:get("style-src"), "'unsafe-eval'"))
        assert.is_true(has(p:get("img-src"), "data:"))
    end)

    it("uses unsafe-inline scripts with or without the login cookie, never a hash", function()
        for _, cookie in ipairs({ "", LOGGED_IN_COOKIE }) do
            local p = build("/wp-admin/", WWW, cookie)
            assert.is_true(has(p:get("script-src"), "'unsafe-inline'"))
            assert.is_false(has(p:get("script-src"), SNIPPET_HASH))
        end
    end)

    it("keeps everything public pages have, except the script hashes", function()
        local public, admin = build("/"), build("/wp-admin/")
        for _, name in ipairs({ "style-src", "img-src", "worker-src", "object-src" }) do
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
    it("public page on www, logged out", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. CDN .. "; " ..
            "script-src 'self' " .. GTM .. " " .. CDN .. " " .. SNIPPET_HASH .. " " .. SPECULATION .. "; " ..
            "img-src 'self' " .. CDN .. " " .. GTM_IMG .. " " .. GA_IMG .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = WWW }))
    end)

    it("public page on www, logged in", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. CDN .. "; " ..
            "script-src 'self' " .. GTM .. " " .. CDN .. " 'unsafe-inline'; " ..
            "img-src 'self' " .. CDN .. " " .. GTM_IMG .. " " .. GA_IMG .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = WWW, cookie = LOGGED_IN_COOKIE }))
    end)

    it("public page on dev, logged out", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. DEV_CDN .. "; " ..
            "script-src 'self' " .. GTM .. " " .. DEV_CDN .. " " .. SNIPPET_HASH .. " " .. SPECULATION .. "; " ..
            "img-src 'self' " .. DEV_CDN .. " " .. GTM_IMG .. " " .. GA_IMG .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = DEV }))
    end)

    it("public page locally, logged out (no CDN)", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline'; " ..
            "script-src 'self' " .. GTM .. " " .. SNIPPET_HASH .. " " .. SPECULATION .. "; " ..
            "img-src 'self' " .. GTM_IMG .. " " .. GA_IMG .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/", host = LOCAL }))
    end)

    it("admin page on www", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' " .. CDN .. " 'unsafe-eval'; " ..
            "script-src 'self' " .. GTM .. " " .. CDN .. " 'unsafe-inline' 'unsafe-eval'; " ..
            "img-src 'self' " .. CDN .. " " .. GTM_IMG .. " " .. GA_IMG .. " data:; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            justice.policy({ path = "/wp-admin/index.php", host = WWW, cookie = LOGGED_IN_COOKIE }))
    end)
end)
