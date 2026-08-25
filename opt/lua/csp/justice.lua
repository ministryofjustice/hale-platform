-- ============================================================================
-- CONTENT SECURITY POLICY — justice.gov.uk
-- ============================================================================
-- Translated from the legacy justice.gov.uk nginx map blocks, with URI
-- patterns updated to this platform's layout (/wp-admin/,
-- /wp-content/themes/justice/dist/). The legacy /wp-login.php rules are not
-- carried over: wordpress.conf denies that path outright.
--
-- ONE policy for EVERY environment. The site is served at the root of
-- www.justice.gov.uk in production and under /justice (a multisite
-- sub-directory) on every other environment; csp/csp.lua strips the site's
-- base path before calling policy(), so the same policy comes out everywhere.
--
-- The legacy $cdn_build_url (a style/script source) is not carried over: it
-- was never defined in this repo. Add it back once the real CDN build URL is
-- confirmed.
-- ============================================================================

local cdn = require("csp.cdn")

local M = {}

M.mode = "enforce"  -- "enforce" | "report-only"

-- Where the justice site lives on each environment. `path` is the site's
-- base path within the host: "" when it is served at the root, otherwise a
-- "/prefix" with no trailing slash.
M.sites = {
    { host = "hale.docker",                                   path = "/justice" },
    { host = "dev.websitebuilder.service.justice.gov.uk",     path = "/justice" },
    { host = "demo.websitebuilder.service.justice.gov.uk",    path = "/justice" },
    { host = "staging.websitebuilder.service.justice.gov.uk", path = "/justice" },
    { host = "websitebuilder.service.justice.gov.uk",         path = "/justice" },
    { host = "www.justice.gov.uk",                            path = "" },
}

local UNSAFE_INLINE = "'unsafe-inline'"
local GTM = "https://www.googletagmanager.com/"

-- Inline source for logged-out public pages. The legacy maps used sha256
-- hashes here:
--   style:  'sha256-wJhuVOwbaj2m4lNrWw4lhKWa0pNOruaWFSuUso0hIRE='  (error-page styles)
--   script: 'sha256-Ac6EurLc5WNuBriCCA6Gi746Ieu1q/votBRNGQmBSUk='  (Sentry config snippet)
-- On this platform WordPress core emits inline <style>/<script> on every
-- page (global-styles, wp-block-library, speculation rules) whose contents
-- vary with theme settings, so those hashes would block core CSS. Until that
-- is solved (nonces, or a report-only trial) this matches the policy
-- production has enforced via the old wordpress.conf map: 'unsafe-inline'.
-- To tighten, change these two values (a hash alongside 'unsafe-inline'
-- would make browsers IGNORE 'unsafe-inline', so it is one or the other).
local STYLE_PUBLIC  = UNSAFE_INLINE
local SCRIPT_PUBLIC = UNSAFE_INLINE

-- Legacy ~^/... map regexes as anchored prefixes, relative to the site's
-- base path.
local PAGE_PREFIXES = {
    { prefix = "/wp-admin/",                       page = "admin" },
    { prefix = "/wp-content/themes/justice/dist/", page = "theme_dist" },
}

-- Per-page directive templates. %s is the variable slot — the
-- cookie-dependent inline source. Pages without their own entry use
-- `default`. SCRIPT has no theme_dist entry: theme assets fall through to
-- the default, as in the legacy maps (deliberate asymmetry with style-src).
local STYLE = {
    default    = "style-src 'self' %s",
    admin      = "style-src 'self' 'unsafe-inline' 'unsafe-eval'",
    theme_dist = "style-src 'self' 'unsafe-inline'",
}
local SCRIPT = {
    default = "script-src 'self' " .. GTM .. " %s",
    admin   = "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
}
local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function classify(path)
    for _, entry in ipairs(PAGE_PREFIXES) do
        if starts_with(path, entry.prefix) then return entry.page end
    end
    return "default"
end

-- Fill a page's template, falling back to the default. string.format
-- ignores `value` for templates without a %s slot.
local function directive(templates, page, value)
    local template = templates[page] or templates.default
    return string.format(template, value)
end

-- 'self', the environment's CDN if it has one, and data: on admin pages.
local function img_src(page, cdn_origin)
    local sources = { "'self'" }
    if cdn_origin then table.insert(sources, cdn_origin) end
    if page == "admin" then table.insert(sources, "data:") end
    return "img-src " .. table.concat(sources, " ")
end

-- `path` is site-relative (see csp/csp.lua); `cookie` may be nil; `host`
-- picks the environment's CDN (see csp/cdn.lua).
function M.policy(path, cookie, host)
    local page = classify(path or "/")

    -- Legacy "~*wordpress_logged_in" cookie map: case-insensitive substring.
    -- Logged-in users always get 'unsafe-inline' for plugin compatibility
    -- (Query Monitor, Debug Bar), whatever the public-page source is.
    local logged_in = (cookie or ""):lower():find("wordpress_logged_in", 1, true) ~= nil

    local style_source, script_source = STYLE_PUBLIC, SCRIPT_PUBLIC
    if logged_in then
        style_source, script_source = UNSAFE_INLINE, UNSAFE_INLINE
    end

    return table.concat({
        directive(STYLE,  page, style_source),
        directive(SCRIPT, page, script_source),
        img_src(page, cdn.for_host(host)),
        "worker-src 'self' blob:",
        "object-src 'none'",
    }, "; ")
end

return M
