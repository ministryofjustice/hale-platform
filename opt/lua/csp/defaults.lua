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

M.policy_string = "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
    .. "style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' data:; "
    .. "frame-ancestors 'self'; object-src 'none';"

-- Same policy for every page; the arguments are ignored.
function M.policy()
    return M.policy_string
end

return M
