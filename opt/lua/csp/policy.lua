-- ============================================================================
-- CONTENT SECURITY POLICY — BUILDER
-- ============================================================================
-- A policy is an ordered list of directives, each with a list of sources.
-- Site modules (csp/justice.lua, csp/defaults.lua) declare a base policy
-- once, then per request clone it, layer on whatever applies (the CDN, admin
-- pages, ...) and render the header value.
--
--   local BASE = policy.new({
--       { "style-src",  "'self'", "'unsafe-inline'" },
--       { "img-src",    "'self'" },
--   })
--   local p = BASE:clone()
--   p:add({ "style-src", "img-src" }, cdn_origin)   -- nil sources are skipped
--   p:add("img-src", "data:")
--   p:render()   --> "style-src 'self' 'unsafe-inline' CDN; img-src 'self' CDN data:"
--
-- add() ignores nil (so optional sources need no `if`) and duplicates (so
-- overlays are safe to apply more than once). Adding to a directive the
-- policy does not have yet appends it.
-- ============================================================================

local unpack = table.unpack or unpack  -- Lua 5.2+ / LuaJIT

local M = {}

local Policy = {}
Policy.__index = Policy

-- directives: ordered list of { name, source, source, ... }
function M.new(directives)
    local p = setmetatable({ order = {}, sources = {} }, Policy)
    for _, entry in ipairs(directives) do
        local name = entry[1]
        table.insert(p.order, name)
        p.sources[name] = {}
        for i = 2, #entry do
            table.insert(p.sources[name], entry[i])
        end
    end
    return p
end

function Policy:clone()
    local copy = M.new({})
    for _, name in ipairs(self.order) do
        table.insert(copy.order, name)
        copy.sources[name] = { unpack(self.sources[name]) }
    end
    return copy
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

-- Add one or more sources to one directive (a name) or several (a list of
-- names). Returns self so calls can be chained.
function Policy:add(names, ...)
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names) do
        if not self.sources[name] then
            table.insert(self.order, name)
            self.sources[name] = {}
        end
        for i = 1, select("#", ...) do
            local source = select(i, ...)
            if source ~= nil and not contains(self.sources[name], source) then
                table.insert(self.sources[name], source)
            end
        end
    end
    return self
end

-- The sources of one directive (a copy), or nil if the policy lacks it.
function Policy:get(name)
    local list = self.sources[name]
    if not list then return nil end
    return { unpack(list) }
end

-- Header value: "name src src; name src".
function Policy:render()
    local clauses = {}
    for _, name in ipairs(self.order) do
        table.insert(clauses, name .. " " .. table.concat(self.sources[name], " "))
    end
    return table.concat(clauses, "; ")
end

-- Is this site-relative path inside WordPress admin?
function M.is_admin(path)
    return (path or ""):sub(1, #"/wp-admin/") == "/wp-admin/"
end

return M
