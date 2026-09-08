-- ============================================================================
-- CONTENT SECURITY POLICY — CDN ORIGINS
-- ============================================================================
-- Maps the HTML host a page is served from to the CDN origin its assets come
-- from, per environment. Consumed by policy modules (csp/justice.lua) via
-- for_host(); the engine (csp/csp.lua) passes the request host through.
-- ============================================================================

local M = {}

-- Used for any host not listed below (production, www.justice.gov.uk).
M.default = "https://cdn.websitebuilder.service.justice.gov.uk"

-- HTML host -> CDN origin. `false` means this environment has no CDN, so
-- policies should not allow one (Lua tables cannot hold nil).
M.hosts = {
    ["hale.docker"]                                   = false,
    ["dev.websitebuilder.service.justice.gov.uk"]     = "https://cdn.dev.websitebuilder.service.justice.gov.uk",
    ["demo.websitebuilder.service.justice.gov.uk"]    = "https://cdn.demo.websitebuilder.service.justice.gov.uk",
    ["staging.websitebuilder.service.justice.gov.uk"] = "https://cdn.staging.websitebuilder.service.justice.gov.uk",
}

-- CDN origin for an HTML host: the mapped value, M.default when unmapped,
-- nil when the environment has no CDN.
function M.for_host(host)
    local cdn = M.hosts[host]
    if cdn == nil then
        return M.default
    end
    return cdn or nil
end

return M
