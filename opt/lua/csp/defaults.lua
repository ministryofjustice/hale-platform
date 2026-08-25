-- ============================================================================
-- CONTENT SECURITY POLICY — DEFAULTS
-- ============================================================================
-- Catch-all for every host/path not claimed by a more specific policy module
-- (no `sites`, so it matches everything — keep it LAST in csp/csp.lua).
-- Report-only: violations are surfaced in the browser console / reports
-- without blocking anything.
-- ============================================================================

local M = {}

M.mode = "report-only"

-- Sites on the platform load theme assets and fonts from their environment's
-- CDN (cdn.<env>.websitebuilder.service.justice.gov.uk), hence the wildcard.
local PLATFORM = "https://*.websitebuilder.service.justice.gov.uk"

M.policy_string = "default-src 'self'; "
    .. "script-src 'self' 'unsafe-inline' 'unsafe-eval' " .. PLATFORM .. "; "
    .. "style-src 'self' 'unsafe-inline' " .. PLATFORM .. "; "
    .. "img-src 'self' data: https:; "
    .. "font-src 'self' data: " .. PLATFORM .. "; "
    .. "frame-ancestors 'self'; object-src 'none';"

-- Same policy for every page; the arguments are ignored.
function M.policy()
    return M.policy_string
end

return M
