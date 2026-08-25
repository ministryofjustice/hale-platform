-- CSP engine unit tests (csp/csp.lua): policy selection, site matching, apply()
-- Run: make test-firewall (or busted spec/csp_spec.lua inside the test image)

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local csp = require "csp.csp"
local justice = require "csp.justice"
local defaults = require "csp.defaults"

local WWW = "www.justice.gov.uk"
local DEV = "dev.websitebuilder.service.justice.gov.uk"

local function req(host, uri, cookie)
    return { host = host, uri = uri, cookie = cookie }
end

-- A fake policy module that records what it was called with.
local function fake(name, sites, mode)
    local m = { mode = mode or "enforce", sites = sites, calls = {} }
    function m.policy(path, cookie, host)
        table.insert(m.calls, { path = path, cookie = cookie, host = host })
        return name .. " " .. tostring(path)
    end
    return m
end

describe("csp.build policy selection", function()
    local real_policies = csp.policies
    after_each(function() csp.policies = real_policies end)

    it("returns nil for nil request, or nil/empty host", function()
        assert.is_nil(csp.build(nil))
        assert.is_nil(csp.build(req(nil, "/", nil)))
        assert.is_nil(csp.build(req("", "/", nil)))
    end)

    it("returns nil when no policy matches", function()
        csp.policies = { fake("a", { { host = "a.example", path = "" } }) }
        assert.is_nil(csp.build(req("b.example", "/", nil)))
    end)

    it("uses the first matching policy, in order", function()
        local first  = fake("first",  { { host = "a.example", path = "" } })
        local second = fake("second", { { host = "a.example", path = "" } })
        csp.policies = { first, second }
        assert.equals("first /x", csp.build(req("a.example", "/x", nil)).policy)
        assert.equals(0, #second.calls)
    end)

    it("treats a policy without sites as a catch-all", function()
        local specific = fake("specific", { { host = "a.example", path = "/sub" } })
        local catchall = fake("catchall", nil, "report-only")
        csp.policies = { specific, catchall }
        assert.equals("specific /", csp.build(req("a.example", "/sub/", nil)).policy)
        assert.equals("catchall /", csp.build(req("a.example", "/", nil)).policy)
        assert.equals("catchall /anything", csp.build(req("other.example", "/anything", nil)).policy)
    end)

    it("returns the matched policy's mode", function()
        csp.policies = { fake("a", nil, "report-only") }
        assert.equals("report-only", csp.build(req("x", "/", nil)).mode)
        csp.policies = { fake("a", nil, "enforce") }
        assert.equals("enforce", csp.build(req("x", "/", nil)).mode)
    end)

    it("passes the cookie and host through untouched", function()
        local p = fake("a", nil)
        csp.policies = { p }
        csp.build(req("x.example", "/", "wordpress_logged_in_1=abc"))
        assert.equals("wordpress_logged_in_1=abc", p.calls[1].cookie)
        assert.equals("x.example", p.calls[1].host)
        csp.build(req("x.example", "/", nil))
        assert.is_nil(p.calls[2].cookie)
    end)
end)

describe("csp.build site matching", function()
    local real_policies = csp.policies
    local p
    before_each(function()
        p = fake("p", {
            { host = "root.example", path = "" },
            { host = "sub.example",  path = "/justice" },
        })
        csp.policies = { p }
    end)
    after_each(function() csp.policies = real_policies end)

    it("matches every path on a root site and passes the path unchanged", function()
        assert.equals("p /", csp.build(req("root.example", "/", nil)).policy)
        assert.equals("p /justice/x", csp.build(req("root.example", "/justice/x", nil)).policy)
    end)

    it("matches a sub-directory site only under its base path", function()
        assert.is_table(csp.build(req("sub.example", "/justice", nil)))
        assert.is_table(csp.build(req("sub.example", "/justice/", nil)))
        assert.is_table(csp.build(req("sub.example", "/justice/wp-admin/", nil)))
        assert.is_nil(csp.build(req("sub.example", "/", nil)))
        assert.is_nil(csp.build(req("sub.example", "/wp-admin/", nil)))
        assert.is_nil(csp.build(req("sub.example", "/justicefoo/", nil)))
        assert.is_nil(csp.build(req("sub.example", "/other/justice/", nil)))
    end)

    it("strips the base path before calling the policy", function()
        assert.equals("p /", csp.build(req("sub.example", "/justice", nil)).policy)
        assert.equals("p /", csp.build(req("sub.example", "/justice/", nil)).policy)
        assert.equals("p /wp-admin/options.php", csp.build(req("sub.example", "/justice/wp-admin/options.php", nil)).policy)
    end)

    it("drops the query string", function()
        assert.equals("p /wp-admin/x.php", csp.build(req("sub.example", "/justice/wp-admin/x.php?a=1&b=2", nil)).policy)
        assert.equals("p /", csp.build(req("root.example", "/?justice", nil)).policy)
        assert.is_nil(csp.build(req("sub.example", "/?justice", nil)))
    end)

    it("treats a missing uri as the root", function()
        assert.equals("p /", csp.build({ host = "root.example" }).policy)
    end)
end)

describe("csp.build with the real policy modules", function()
    it("registers justice before the defaults catch-all", function()
        assert.equals(justice, csp.policies[1])
        assert.equals(defaults, csp.policies[#csp.policies])
        assert.is_nil(defaults.sites)
    end)

    it("serves the justice policy on www.justice.gov.uk and under /justice elsewhere", function()
        for _, r in ipairs({ req(WWW, "/", nil), req(DEV, "/justice/", nil), req("hale.docker", "/justice/", nil) }) do
            local result = csp.build(r)
            assert.equals("enforce", result.mode, r.host)
            assert.equals(justice.policy("/", nil, r.host), result.policy, r.host)
        end
    end)

    it("falls back to the report-only defaults everywhere else", function()
        for _, r in ipairs({ req("example.com", "/", nil), req(DEV, "/", nil), req("hale.docker", "/justicefoo/", nil) }) do
            local result = csp.build(r)
            assert.equals("report-only", result.mode)
            assert.equals(defaults.policy("/", nil, r.host), result.policy, r.host)
        end
    end)
end)

describe("csp.apply", function()
    local real_ngx = _G.ngx
    local real_policies = csp.policies

    local function with_ngx(host, request_uri, cookie)
        _G.ngx = { var = { host = host, request_uri = request_uri, http_cookie = cookie }, header = {} }
        return _G.ngx
    end
    after_each(function()
        _G.ngx = real_ngx
        csp.policies = real_policies
    end)

    it("sets Content-Security-Policy for an enforce policy", function()
        local ngx = with_ngx(WWW, "/", nil)
        csp.apply()
        assert.equals(justice.policy("/", nil, WWW), ngx.header["Content-Security-Policy"])
        assert.is_nil(ngx.header["Content-Security-Policy-Report-Only"])
    end)

    it("sets Content-Security-Policy-Report-Only for a report-only policy", function()
        local ngx = with_ngx("example.com", "/", nil)
        csp.apply()
        assert.equals(defaults.policy("/", nil, "example.com"), ngx.header["Content-Security-Policy-Report-Only"])
        assert.is_nil(ngx.header["Content-Security-Policy"])
    end)

    it("uses request_uri (pre-rewrite) and the cookie", function()
        local ngx = with_ngx(DEV, "/justice/wp-admin/x.php?y=1", "wordpress_logged_in_1=a")
        csp.apply()
        assert.equals(justice.policy("/wp-admin/x.php", "wordpress_logged_in_1=a", DEV), ngx.header["Content-Security-Policy"])
    end)

    it("sets no header when nothing matches", function()
        csp.policies = { fake("a", { { host = "a.example", path = "" } }) }
        local ngx = with_ngx("b.example", "/", nil)
        csp.apply()
        assert.is_nil(next(ngx.header))
    end)
end)
