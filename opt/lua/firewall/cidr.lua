-- ============================================================================
-- CIDR MATCHING MODULE
-- ============================================================================
-- Pure IPv4 matching for allowlist/blocklist lookups. No ngx.* dependencies.
--
-- USAGE (parse once at cache refresh, match on every request):
--   local cidr = require "firewall.cidr"
--
--   local entry = cidr.parse("10.0.0.0/8")   -- {net=..., host_count=...}
--   local entry = cidr.parse("192.168.1.5")   -- bare IP treated as /32
--
--   cidr.contains(parsed_list, "10.1.2.3")    -- true
--   cidr.contains(parsed_list, "11.0.0.0")    -- false
--
-- Pre-parse entries at cache load time (cidr.parse is not on the hot path).
-- cidr.contains IS on the hot path: it is a tight integer loop — one modulo
-- and one equality check per list entry.
-- ============================================================================

local _M = {}

-- Parse a dotted-decimal IPv4 address string into a 32-bit integer.
-- Returns nil if the string is not a valid IPv4 address.
local function _ip_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (a and b and c and d) then return nil end
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return a * 16777216 + b * 65536 + c * 256 + d
end

--- Parse a CIDR string or bare IPv4 address into a match descriptor.
-- Bare IPs (no "/prefix") are treated as /32 (exact host match).
--
-- @param  entry  string  e.g. "10.0.0.0/8" or "192.168.1.5"
-- @return table|nil      {net=<int>, host_count=<int>}, or nil on error
--                        net        = integer value of the network address
--                        host_count = 2^(32-prefix); 1 for /32, 256 for /24
function _M.parse(entry)
    if type(entry) ~= "string" then return nil end

    local ip_part, prefix_str = entry:match("^([^/]+)/(%d+)$")
    if not ip_part then
        -- Bare IP — treat as /32 (single-host match).
        ip_part    = entry
        prefix_str = "32"
    end

    local prefix = tonumber(prefix_str)
    if not prefix or prefix < 0 or prefix > 32 then return nil end

    local ip_int = _ip_to_int(ip_part)
    if not ip_int then return nil end

    -- host_count = 2^(32-prefix): the number of host addresses in the block.
    -- Using modulo arithmetic instead of bitwise ops keeps this compatible
    -- with both plain Lua 5.1 and LuaJIT without requiring the bit library.
    local host_count = 2 ^ (32 - prefix)

    -- Mask off the host portion to get the canonical network address.
    local net = ip_int - (ip_int % host_count)

    return { net = net, host_count = host_count }
end

--- Return true if ip_str falls within any range in parsed_list.
-- parsed_list is an array of tables returned by _M.parse().
-- Returns false (not an error) for nil/empty list or unparseable IP strings.
--
-- @param  parsed_list  table   array of {net, host_count} entries
-- @param  ip_str       string  IPv4 address to look up
-- @return boolean
function _M.contains(parsed_list, ip_str)
    if not parsed_list or #parsed_list == 0 then return false end
    local ip_int = _ip_to_int(ip_str)
    if not ip_int then return false end
    for _, entry in ipairs(parsed_list) do
        if ip_int - (ip_int % entry.host_count) == entry.net then
            return true
        end
    end
    return false
end

return _M
