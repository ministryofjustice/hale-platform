-- ============================================================================
-- CONTENT SECURITY POLICY — justice.gov.uk
-- ============================================================================
-- Enforced on www.justice.gov.uk (served at the root) and on /justice, a
-- multisite sub-directory, on every other environment. csp/csp.lua strips
-- that base path before calling policy(), so the same rules apply everywhere.
--
-- Inline SCRIPTS are never 'unsafe-inline' on public pages: only known
-- snippets, allowed by hash (INLINE_SCRIPT_HASHES), as on the legacy site.
-- Logged-in users and wp-admin get 'unsafe-inline' for plugin compatibility.
--
-- Inline STYLES still allow 'unsafe-inline' everywhere: WordPress core emits
-- inline <style> on every page (global-styles, wp-block-library) whose
-- contents vary with theme settings. Tightening that is separate work.
-- ============================================================================

local policy = require("csp.policy")
local cdn = require("csp.cdn")

local unpack = table.unpack or unpack  -- Lua 5.2+ / LuaJIT

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

-- Google Analytics 4, loaded through GTM. Hits go over fetch/sendBeacon and
-- fall back to an image pixel; GTM's own host is needed for preview mode.
local GA_IMG = { "https://www.googletagmanager.com", "https://*.google-analytics.com" }

-- Inline scripts the theme emits on public pages, allowed by hash. To add or
-- recompute one, hash the exact text between the <script> tags:
--   printf '%s' "<script text>" | openssl dgst -sha256 -binary | base64
local INLINE_SCRIPT_HASHES = {
    -- (function() { if (typeof mojLoadLocalizedData === 'function') { mojLoadLocalizedData(); } })();
    "'sha256-Ac6EurLc5WNuBriCCA6Gi746Ieu1q/votBRNGQmBSUk='",
}

local BASE = policy.new({
    { "style-src",  "'self'", "'unsafe-inline'" },
    { "script-src", "'self'", GTM },
    { "img-src",    "'self'" },
    { "worker-src", "'self'", "blob:" },
    { "object-src", "'none'" },
})

-- request: { path = <site-relative path>, cookie = <Cookie header or nil>,
--            host = <request host> }
function M.build(request)
    local p = BASE:clone()
    local admin = policy.is_admin(request.path)

    -- Theme CSS/JS and images are served from the environment's CDN, if any.
    p:add({ "style-src", "script-src", "img-src" }, cdn.for_host(request.host))

    -- Analytics pixels (see GA_IMG).
    p:add("img-src", unpack(GA_IMG))

    -- Inline scripts: logged-in users and wp-admin get 'unsafe-inline' (Query
    -- Monitor, Debug Bar, the block editor); public pages get only the known
    -- snippets by hash, plus WordPress's <script type="speculationrules">
    -- prefetch block. Never both: a hash makes browsers ignore 'unsafe-inline'.
    if admin or policy.is_logged_in(request.cookie) then
        p:add("script-src", "'unsafe-inline'")
    else
        p:add("script-src", unpack(INLINE_SCRIPT_HASHES))
        p:add("script-src", "'inline-speculation-rules'")
    end

    -- wp-admin needs eval (block editor, older plugins) and data: images.
    if admin then
        p:add({ "style-src", "script-src" }, "'unsafe-eval'")
        p:add("img-src", "data:")
    end

    return p
end

function M.policy(request)
    return M.build(request):render()
end

return M
