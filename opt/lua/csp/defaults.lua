-- ============================================================================
-- CONTENT SECURITY POLICY — DEFAULTS
-- ============================================================================
-- Catch-all for every host/path not claimed by a more specific site module
-- (no `sites`, so it matches everything — keep it LAST in csp/csp.lua).
-- Report-only: violations are surfaced in the browser console / reports
-- without blocking anything.
-- ============================================================================

local policy = require("csp.policy")
local cdn = require("csp.cdn")

local M = {}

M.mode = "report-only"

local BASE = policy.new({
    { "default-src",     "'self'" },
    { "script-src",      "'self'", "'unsafe-inline'", "'unsafe-eval'" },
    { "style-src",       "'self'", "'unsafe-inline'" },
    { "img-src",         "'self'", "data:", "https:" },
    { "font-src",        "'self'", "data:" },
    { "frame-ancestors", "'self'" },
    { "object-src",      "'none'" },
})

-- request: { path = ..., cookie = ..., host = ... } — only host is used.
function M.build(request)
    local p = BASE:clone()

    -- Sites load theme assets and fonts from the environment's CDN, if any.
    p:add({ "script-src", "style-src", "img-src", "font-src" }, cdn.for_host(request.host))

    return p
end

function M.policy(request)
    return M.build(request):render()
end

return M
