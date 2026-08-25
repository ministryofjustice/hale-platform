-- ============================================================================
-- CONTENT SECURITY POLICY — DEFAULTS
-- ============================================================================
-- Catch-all for every host/path not claimed by a more specific policy module
-- (no `sites`, so it matches everything — keep it LAST in csp/csp.lua).
-- Report-only: violations are surfaced in the browser console / reports
-- without blocking anything.
--
-- Sites on the platform load theme assets and fonts from their environment's
-- CDN, so script-src, style-src and font-src allow the CDN for the request
-- host (see csp/cdn.lua); none is added where the environment has no CDN.
-- ============================================================================

local cdn = require("csp.cdn")

local M = {}

M.mode = "report-only"

-- Append the environment's CDN, if it has one.
local function with_cdn(directive_string, cdn_origin)
    if not cdn_origin then return directive_string end
    return directive_string .. " " .. cdn_origin
end

-- Same policy for every page; only the CDN varies, by host.
function M.policy(_, _, host)
    local cdn_origin = cdn.for_host(host)

    return table.concat({
        "default-src 'self'",
        with_cdn("script-src 'self' 'unsafe-inline' 'unsafe-eval'", cdn_origin),
        with_cdn("style-src 'self' 'unsafe-inline'", cdn_origin),
        with_cdn("img-src 'self' data: https:", cdn_origin),
        with_cdn("font-src 'self' data:", cdn_origin),
        "frame-ancestors 'self'",
        "object-src 'none';",
    }, "; ")
end

return M
