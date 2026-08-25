-- ============================================================================
-- CONTENT SECURITY POLICY — justice.gov.uk
-- ============================================================================
-- Enforced on www.justice.gov.uk (served at the root) and on /justice, a
-- multisite sub-directory, on every other environment. csp/csp.lua strips
-- that base path before calling policy(), so the same rules apply everywhere.
--
-- Public pages currently allow 'unsafe-inline': WordPress core emits inline
-- <style>/<script> on every page whose contents vary with theme settings.
-- Tightening to hashes or nonces is a separate piece of work.
-- ============================================================================

local policy = require("csp.policy")
local cdn = require("csp.cdn")

local M = {}

M.mode = "enforce"  -- "enforce" | "report-only"

-- Where the site lives on each environment: `path` is "" at the root,
-- otherwise "/prefix" with no trailing slash.
M.sites = {
    { host = "hale.docker",                                   path = "/justice" },
    { host = "dev.websitebuilder.service.justice.gov.uk",     path = "/justice" },
    { host = "demo.websitebuilder.service.justice.gov.uk",    path = "/justice" },
    { host = "staging.websitebuilder.service.justice.gov.uk", path = "/justice" },
    { host = "websitebuilder.service.justice.gov.uk",         path = "/justice" },
    { host = "www.justice.gov.uk",                            path = "" },
}

local GTM = "https://www.googletagmanager.com/"

local BASE = policy.new({
    { "style-src",  "'self'", "'unsafe-inline'" },
    { "script-src", "'self'", GTM, "'unsafe-inline'" },
    { "img-src",    "'self'" },
    { "worker-src", "'self'", "blob:" },
    { "object-src", "'none'" },
})

-- request: { path = <site-relative path>, cookie = <Cookie header or nil>,
--            host = <request host> }
function M.build(request)
    local p = BASE:clone()

    -- Theme CSS/JS and images are served from the environment's CDN, if any.
    p:add({ "style-src", "script-src", "img-src" }, cdn.for_host(request.host))

    -- wp-admin needs eval (block editor, older plugins) and data: images.
    if policy.is_admin(request.path) then
        p:add({ "style-src", "script-src" }, "'unsafe-eval'")
        p:add("img-src", "data:")
    end

    return p
end

function M.policy(request)
    return M.build(request):render()
end

return M
