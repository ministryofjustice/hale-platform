-- justice.gov.uk CSP policy unit tests (csp/justice.lua)
-- Run: make test-firewall (or busted spec/csp_justice_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local justice = require "csp.justice"

local WWW = "www.justice.gov.uk"
local DEV = "dev.websitebuilder.service.justice.gov.uk"
local CDN = "https://cdn.websitebuilder.service.justice.gov.uk"
local DEV_CDN = "https://cdn.dev.websitebuilder.service.justice.gov.uk"
local GTM = "https://www.googletagmanager.com/"
local LOGGED_IN_COOKIE = "wordpress_logged_in_abc123=hash"

-- Policy for a site-relative path; defaults to the production host.
local function policy(path, cookie, host)
    return justice.policy(path, cookie, host or WWW)
end

-- Extract one "<name>-src ..." clause from a policy string.
local function directive(policy_string, name)
    for clause in policy_string:gmatch("[^;]+") do
        clause = clause:gsub("^%s+", "")
        if clause:sub(1, #name + 5) == name .. "-src " or clause == name .. "-src" then
            return clause
        end
    end
    return nil
end

describe("justice sites", function()
    it("is enforced", function()
        assert.equals("enforce", justice.mode)
    end)

    it("lists all five environments", function()
        local paths = {}
        for _, site in ipairs(justice.sites) do paths[site.host] = site.path end
        assert.equals("", paths["www.justice.gov.uk"])
        for _, host in ipairs({
            "hale.docker",
            "dev.websitebuilder.service.justice.gov.uk",
            "demo.websitebuilder.service.justice.gov.uk",
            "staging.websitebuilder.service.justice.gov.uk",
        }) do
            assert.equals("/justice", paths[host], host)
        end
        assert.equals(5, #justice.sites)
    end)
end)

describe("justice img-src", function()
    it("allows self and the CDN on public pages, without data:", function()
        assert.equals("img-src 'self' " .. CDN, directive(policy("/", nil), "img"))
    end)

    it("additionally allows data: on admin pages", function()
        assert.equals("img-src 'self' " .. CDN .. " data:", directive(policy("/wp-admin/options.php", nil), "img"))
    end)

    it("uses the default img-src on theme dist pages", function()
        local expected = "img-src 'self' " .. CDN
        assert.equals(expected, directive(policy("/wp-content/themes/justice/dist/img/logo.png", nil), "img"))
    end)

    it("uses the environment's own CDN", function()
        assert.equals("img-src 'self' " .. DEV_CDN, directive(policy("/", nil, DEV), "img"))
        assert.equals("img-src 'self' " .. DEV_CDN .. " data:", directive(policy("/wp-admin/", nil, DEV), "img"))
    end)

    it("omits the CDN where the environment has none (local)", function()
        assert.equals("img-src 'self'", directive(policy("/", nil, "hale.docker"), "img"))
        assert.equals("img-src 'self' data:", directive(policy("/wp-admin/", nil, "hale.docker"), "img"))
        assert.is_nil(policy("/", nil, "hale.docker"):find("  ", 1, true))
    end)

    it("falls back to the production CDN for an unknown or missing host", function()
        assert.equals("img-src 'self' " .. CDN, directive(policy("/", nil, "unknown.example"), "img"))
        assert.equals("img-src 'self' " .. CDN, directive(justice.policy("/", nil), "img"))
    end)
end)

describe("justice style-src", function()
    it("allows unsafe-inline on logged-out public pages (matches the policy live on www; no hashes)", function()
        local style = directive(policy("/", nil), "style")
        assert.equals("style-src 'self' 'unsafe-inline'", style)
        assert.is_nil(style:find("sha256", 1, true))
        assert.is_nil(style:find("'unsafe-eval'", 1, true))
    end)

    it("is the same for unrelated cookies", function()
        assert.equals("style-src 'self' 'unsafe-inline'", directive(policy("/", "foo=bar; comment_author=x"), "style"))
    end)

    it("allows unsafe-inline when logged in", function()
        assert.equals("style-src 'self' 'unsafe-inline'", directive(policy("/", LOGGED_IN_COOKIE), "style"))
        assert.equals("style-src 'self' 'unsafe-inline'", directive(policy("/", "WordPress_Logged_In_ABC=1"), "style"))
    end)

    it("adds unsafe-eval on admin pages", function()
        assert.equals("style-src 'self' 'unsafe-inline' 'unsafe-eval'", directive(policy("/wp-admin/", nil), "style"))
    end)

    it("allows unsafe-inline for theme dist assets", function()
        assert.equals("style-src 'self' 'unsafe-inline'",
            directive(policy("/wp-content/themes/justice/dist/css/app.css", nil), "style"))
    end)
end)

describe("justice script-src", function()
    it("allows self, GTM and unsafe-inline on logged-out public pages (no hashes)", function()
        local script = directive(policy("/", nil), "script")
        assert.equals("script-src 'self' " .. GTM .. " 'unsafe-inline'", script)
        assert.is_nil(script:find("sha256", 1, true))
        assert.is_nil(script:find("'unsafe-eval'", 1, true))
    end)

    it("normalises whitespace (no legacy leading-space or double-space artefacts)", function()
        for _, path in ipairs({ "/", "/wp-admin/", "/wp-content/themes/justice/dist/js/app.js" }) do
            assert.is_nil(policy(path, nil):find("  ", 1, true), "double space in policy for " .. path)
        end
    end)

    it("allows unsafe-inline when logged in", function()
        assert.equals("script-src 'self' " .. GTM .. " 'unsafe-inline'", directive(policy("/", LOGGED_IN_COOKIE), "script"))
    end)

    it("adds unsafe-eval on admin pages", function()
        assert.equals("script-src 'self' 'unsafe-inline' 'unsafe-eval'", directive(policy("/wp-admin/upload.php", nil), "script"))
    end)

    it("falls through to the default script-src for theme dist assets", function()
        -- Deliberate asymmetry with style-src, carried over from the legacy maps.
        assert.equals("script-src 'self' " .. GTM .. " 'unsafe-inline'",
            directive(policy("/wp-content/themes/justice/dist/js/app.min.js", nil), "script"))
    end)
end)

describe("justice worker-src and object-src", function()
    it("always ends with worker-src self blob and object-src none", function()
        for _, path in ipairs({ "/", "/wp-admin/", "/wp-content/themes/justice/dist/css/a.css" }) do
            assert.truthy(policy(path, nil):find("; worker%-src 'self' blob:; object%-src 'none'$"), "bad tail for " .. path)
        end
    end)
end)

describe("justice prefix anchoring", function()
    it("does not treat non-root wp-admin paths as admin", function()
        assert.is_nil(directive(policy("/blog/wp-admin/", nil), "img"):find("data:", 1, true))
        assert.is_nil(directive(policy("/xwp-admin/", nil), "img"):find("data:", 1, true))
    end)

    it("requires the trailing slash on /wp-admin", function()
        assert.is_nil(directive(policy("/wp-admin", nil), "img"):find("data:", 1, true))
    end)

    it("treats /wp-login.php as an ordinary public page (nginx denies it anyway)", function()
        assert.equals(policy("/", nil), policy("/wp-login.php", nil))
    end)

    it("treats a nil path as a public page", function()
        assert.equals(policy("/", nil), policy(nil, nil))
    end)
end)

describe("justice full policy strings", function()
    it("builds the public logged-out policy", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline'; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline'; " ..
            "img-src 'self' " .. CDN .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            policy("/", nil))
    end)

    it("builds the admin logged-in policy", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline' 'unsafe-eval'; " ..
            "script-src 'self' 'unsafe-inline' 'unsafe-eval'; " ..
            "img-src 'self' " .. CDN .. " data:; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            policy("/wp-admin/index.php", LOGGED_IN_COOKIE))
    end)

    it("builds the theme dist logged-out policy", function()
        assert.equals(
            "style-src 'self' 'unsafe-inline'; " ..
            "script-src 'self' " .. GTM .. " 'unsafe-inline'; " ..
            "img-src 'self' " .. CDN .. "; " ..
            "worker-src 'self' blob:; " ..
            "object-src 'none'",
            policy("/wp-content/themes/justice/dist/js/app.min.js", nil))
    end)

    it("orders directives style, script, img, worker, object", function()
        assert.truthy(policy("/", nil):find(
            "^style%-src .*; script%-src .*; img%-src .*; worker%-src .*; object%-src 'none'$"))
    end)
end)
