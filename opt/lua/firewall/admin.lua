-- ============================================================================
-- Firewall admin endpoints. Wired up via a single nginx location block:
--
--   location ^~ /firewall/ {
--       content_by_lua_block { require("firewall.admin").handle_route() }
--   }
--
-- handle_route() dispatches to the four named endpoints below. None of these
-- functions are on the request hot path — see firewall.lua for init/req/res.
--
-- See README.md → "The firewall contract" for the HTTP surface, validate
-- response shape, and trust/access-control model.
-- ============================================================================

local _M = {}

local redis_pool    = require "firewall.redis"
local schema = require "firewall.schema"
local gcra_module   = require "firewall.gcra"
local defaults      = require "firewall.defaults"
local cache         = require "firewall.cache"
local cjson         = require "cjson.safe"

local BLOCK_PREFIX = defaults.BLOCK_KEY_PREFIX
local CACHE_PREFIX = defaults.BLOCKED_CACHE_PREFIX

-- Expected top-level JSON type for each validate kind.
-- Adding a new kind only requires updating this table.
local _KIND_TYPE = {
    rules     = "array",
    allowlist = "array",
    blocklist = "array",
    config    = "object",
}


-- Compile-check every PCRE pattern field on a normalised ruleset. Returns
-- a list of human-readable error strings (empty when all patterns are valid).
--
-- Lives here, not in firewall.schema, because schema.lua is a pure-Lua
-- module (no ngx dependency) kept unit-testable with plain busted. ngx.re
-- is only available inside a running OpenResty worker.
--
-- ngx.re.match("", pattern, "o") always attempts to compile; a non-nil err
-- means the pattern is invalid — a pattern that merely doesn't match "" is fine.
local PATTERN_FIELDS = { "uri_pattern", "ua_pattern", "query_pattern" }

local function compile_check_patterns(rules)
    local errors = {}
    for _, rule in ipairs(rules) do
        if rule.match then
            for _, field in ipairs(PATTERN_FIELDS) do
                local pattern = rule.match[field]
                if pattern then
                    local _, compile_err = ngx.re.match("", pattern, "o")
                    if compile_err then
                        table.insert(errors,
                            "Rule name=" .. tostring(rule.name)
                            .. " match." .. field
                            .. " is not valid PCRE: " .. compile_err)
                    end
                end
            end
        end
    end
    return errors
end


-- /firewall/* dispatcher — routes all admin endpoints from a single nginx
-- location block, keeping nginx config minimal and access control in one place.
local _routes = {
    ["/firewall/stats"]            = function() _M.stats() end,
    ["/firewall/flush-cache"]      = function() _M.flush_cache() end,
    ["/firewall/clear-penalties"]  = function() _M.clear_penalties() end,
    ["/firewall/admin/validate"]   = function() _M.validate() end,
}

function _M.handle_route()
    local handler = _routes[ngx.var.uri]
    if handler then
        handler()
    else
        ngx.status = 404
        ngx.header.content_type = "application/json"
        ngx.say(cjson.encode({ error = "not found" }))
    end
end


-- /firewall/stats — JSON snapshot of rules, config and live GCRA TATs.
-- Uses SCAN over firewall:gcra:* with TYPE=string so the per-IP breakdown
-- hashes (firewall:gcra:{ip}:breakdown) are filtered out at the Redis level —
-- a plain GET on those would return WRONGTYPE. SCAN is non-blocking
-- (cursor-paged) so it's safe even if the keyspace grows large.
function _M.stats()
    ngx.header.content_type = "application/json"

    local red = redis_pool.connect()
    if not red then
        ngx.status = 503
        ngx.say('{"error": "redis connection failed"}')
        return
    end

    local rules, config = cache.load_rules_and_config(red)

    local gcra_prefix = defaults.GCRA_KEY_PREFIX
    local tat_data = {}
    local cursor = "0"
    repeat
        local res, err = red:scan(cursor,
            "MATCH", gcra_prefix .. "*",
            "COUNT", 100,
            "TYPE",  "string")
        if not res then
            ngx.log(ngx.ERR, "[firewall] SCAN failed: ", err)
            break
        end
        cursor = res[1]
        local keys = res[2]
        if keys and #keys > 0 then
            for _, key in ipairs(keys) do
                local tat = red:get(key)
                if tat and tat ~= ngx.null then
                    tat_data[key:sub(#gcra_prefix + 1)] = tonumber(tat)  -- strip prefix
                end
            end
        end
    until cursor == "0"

    redis_pool.release(red)

    ngx.say(cjson.encode({
        enabled     = os.getenv("FIREWALL_ENABLED") ~= "false",
        rules_count = rules and #rules or 0,
        config      = config or gcra_module.DEFAULTS,
        active_ips  = tat_data,
    }))
end


-- /firewall/flush-cache — clear local block cache and bump the shared
-- version counter so every worker re-reads rules/config from Redis.
-- Called by PHP after rule/config edits, and by the test suite.
function _M.flush_cache()
    cache.flush()
    ngx.header.content_type = "application/json"
    ngx.say('{"ok":true}')
end


-- /firewall/admin/validate — strict schema check for admin saves.
-- Request:  POST  body = raw JSON for either rules, config, allowlist, or blocklist
--           query: kind=rules | kind=config | kind=allowlist | kind=blocklist
-- Response: 200 application/json
--   { "ok": bool, "errors": [string,...], "normalised": <array|object|null> }
--
-- The Lua schema (firewall.schema) is the single source of truth. The
-- WordPress admin form posts the operator's input here before writing to
-- Redis so that errors and warnings cannot diverge from the runtime
-- parser. The endpoint is read-only (no Redis writes) and matches the
-- trust level of the other /firewall/* admin endpoints — restricted by
-- nginx to loopback in production.
function _M.validate()
    ngx.header.content_type = "application/json"

    local kind = ngx.var.arg_kind
    if kind ~= "rules" and kind ~= "config"
                       and kind ~= "allowlist" and kind ~= "blocklist" then
        ngx.status = 400
        ngx.say(cjson.encode({
            ok = false,
            errors = { "Query parameter 'kind' must be 'rules', 'config', 'allowlist', or 'blocklist'." },
        }))
        return
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then
        ngx.status = 400
        ngx.say(cjson.encode({
            ok = false,
            errors = { "Request body is empty." },
        }))
        return
    end

    local expected_type = _KIND_TYPE[kind]
    if schema.json_top_level_type(body) ~= expected_type then
        ngx.status = 400
        ngx.say(cjson.encode({ ok = false, errors = { "'" .. kind .. "' must be a JSON " .. expected_type .. "." } }))
        return
    end

    local decoded, decode_err = cjson.decode(body)
    if decoded == nil then
        ngx.status = 400
        ngx.say(cjson.encode({
            ok = false,
            errors = { "Request body must be valid JSON: " .. tostring(decode_err) },
        }))
        return
    end

    local result
    if kind == "rules" then
        result = schema.validate_rules_strict(decoded)

        if result.ok and result.normalised then
            local regex_errors = compile_check_patterns(result.normalised)
            if #regex_errors > 0 then
                result = { ok = false, errors = regex_errors, normalised = nil }
            end
        end
    elseif kind == "config" then
        result = schema.validate_config_strict(decoded)
    elseif kind == "allowlist" then
        result = schema.validate_allowlist_strict(decoded)
    else
        result = schema.validate_blocklist_strict(decoded)
    end

    -- cjson encodes empty Lua tables as objects by default; force list-typed
    -- payloads to serialise as JSON arrays.
    if (kind == "rules" or kind == "allowlist" or kind == "blocklist") and result.normalised then
        if next(result.normalised) == nil then
            result.normalised = cjson.empty_array
        end
    end

    ngx.say(cjson.encode(result))
end


-- /firewall/clear-penalties — delete every firewall:block:{ip} key whose
-- value is "gcra" (i.e. written automatically by GCRA penalty). Manual admin
-- bans (value "1") are left intact. Admin/test path only.
function _M.clear_penalties()
    local red = redis_pool.connect()
    if not red then
        ngx.status = 503
        ngx.say('{"ok":false,"error":"redis unavailable"}')
        return
    end

    -- SCAN (cursor-paged, non-blocking) instead of KEYS (O(N), blocks Redis).
    -- TYPE=string filters to firewall:block:{ip} entries directly so we don't
    -- GET keys we're not going to touch. Mirrors the SCAN pattern in _M.stats().
    local deleted = 0
    local cursor = "0"
    repeat
        local res, scan_err = red:scan(cursor,
            "MATCH", BLOCK_PREFIX .. "*",
            "COUNT", 100,
            "TYPE",  "string")
        if not res then
            ngx.log(ngx.ERR, "[firewall] failed to scan block keys: ", scan_err)
            break
        end
        cursor = res[1]
        local keys = res[2]
        if keys and #keys > 0 then
            for _, key in ipairs(keys) do
                local val = red:get(key)
                if val == "gcra" then
                    red:del(key)
                    local ip = key:sub(#BLOCK_PREFIX + 1)
                    cache.blocked_cache:delete(CACHE_PREFIX .. ip)
                    deleted = deleted + 1
                end
            end
        end
    until cursor == "0"

    redis_pool.release(red)
    ngx.header.content_type = "application/json"
    ngx.say('{"ok":true,"deleted":' .. deleted .. '}')
end


return _M
