-- ============================================================================
-- CONTENT SECURITY POLICY — ENGINE
-- ============================================================================
-- Picks a policy module for the request and emits exactly one CSP header.
--
-- Policy modules (see csp/justice.lua, csp/defaults.lua) expose:
--   mode   = "enforce" | "report-only"
--   sites  = { { host = "...", path = "" | "/prefix" }, ... }  -- optional;
--            omit it to match every request (a catch-all)
--   policy = function(request) -> "<header value>"
--            request = { path = ..., cookie = ..., host = ... }
--            `path` is relative to the matched site's base path (so
--            "/justice/wp-admin/" on a "/justice" site arrives as
--            "/wp-admin/"), with any query string already removed.
--            `cookie` is the Cookie header (may be nil); `host` is the
--            request host, e.g. for per-environment lookups (csp/cdn.lua).
--            Modules build these with csp/policy.lua.
--
-- M.policies is checked in order; the first module whose `sites` matches
-- the request wins, so the catch-all goes last.
--
-- USAGE — from nginx, in a header_filter_by_lua_block:
--   require("csp.csp").apply()
-- apply() is the only ngx-aware function here. Because a location-level
-- header_filter_by_lua_block REPLACES the server-level one, any location
-- that has its own block must call apply() too.
--
-- build() is pure Lua (no ngx.*) and unit-tested via spec/csp_spec.lua:
--   local result = build({ host = ..., uri = ..., cookie = ... })
--   -- nil when no policy matches, otherwise:
--   -- { policy = "<header value>", mode = "enforce" | "report-only" }
--
-- NOTE: apply() passes ngx.var.request_uri (the ORIGINAL path), not
-- ngx.var.uri. wordpress.conf rewrites /justice/wp-admin/... to
-- /wp-admin/... for multisite, so by the time a header filter runs
-- ngx.var.uri has already lost the /justice prefix that identifies the site.
-- ============================================================================

local M = {}

M.policies = {
    require("csp.justice"),
    require("csp.defaults"),  -- catch-all: keep last
}

local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

-- Does this policy serve host + path? Returns true and the path relative to
-- the matched site's base path, or false.
local function matches(policy, host, path)
    if not policy.sites then
        return true, path
    end
    for _, site in ipairs(policy.sites) do
        if site.host == host then
            if site.path == "" then
                return true, path
            end
            if path == site.path then
                return true, "/"
            end
            if starts_with(path, site.path .. "/") then
                return true, path:sub(#site.path + 1)
            end
        end
    end
    return false
end

function M.build(request)
    if not request or not request.host or request.host == "" then return nil end

    local path = (request.uri or "/"):match("^[^?]*")  -- drop any query string

    for _, policy in ipairs(M.policies) do
        local matched, site_path = matches(policy, request.host, path)
        if matched then
            return {
                policy = policy.policy({
                    path   = site_path,
                    cookie = request.cookie,
                    host   = request.host,
                }),
                mode = policy.mode,
            }
        end
    end
    return nil
end

-- nginx entry point: see USAGE above.
function M.apply()
    local result = M.build({
        host   = ngx.var.host,
        uri    = ngx.var.request_uri,
        cookie = ngx.var.http_cookie,  -- may be nil
    })
    if not result then return end

    local header_name = "Content-Security-Policy"
    if result.mode == "report-only" then
        header_name = "Content-Security-Policy-Report-Only"
    end
    ngx.header[header_name] = result.policy
end

return M
