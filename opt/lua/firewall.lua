-- ============================================================================
-- Firewall orchestrator. See README.md for architecture, request flow, data
-- model, operating modes, and design decisions.
--
-- Wired up in nginx.conf / wordpress.conf:
--   init_worker_by_lua_block   { require("firewall").init() }
--   access_by_lua_block        { require("firewall").req()  }
--   log_by_lua_block           { require("firewall").res()  }
--   content_by_lua_block       { require("firewall").stats()        }
--                              { require("firewall").flush_cache()  }
--                              { require("firewall").clear_penalties() }
-- ============================================================================

local _M = {}

local redis_pool    = require "firewall.redis"
local cost_module   = require "firewall.cost"
local gcra_module   = require "firewall.gcra"
local config_module = require "firewall.config"
local defaults      = require "firewall.defaults"
local cjson         = require "cjson.safe"

-- Kill switch. When false, req()/res() return immediately. Requires nginx
-- restart to flip; for runtime control use firewall:config.mode in Redis.
local FIREWALL_ENABLED = os.getenv("FIREWALL_ENABLED") ~= "false"

-- Per-worker cache of decoded rules+config. Invalidated cluster-wide via the
-- shared version counter that flush_cache() increments.
local _rc_cache = { rules = nil, config = nil, version = -1, expires = 0 }
local RC_CACHE_TTL = 60  -- seconds

local rc_shared = ngx.shared.firewall_rc_cache

-- See firewall.defaults for rationale and any tuning. Pulled into locals
-- here so the hot path doesn't pay table-lookup cost per request.
local PENALTY_404         = defaults.PENALTY_404
local ALLOW_PREFIX        = defaults.GCRA.allow_prefix
local BLOCK_PREFIX        = defaults.GCRA.block_prefix
local CACHE_PREFIX        = defaults.BLOCKED_CACHE_PREFIX
local DEFAULT_AUDIT_STREAM = defaults.GCRA.audit_stream
local DEFAULT_AUDIT_MAXLEN = defaults.GCRA.audit_maxlen


-- Logs resolved firewall settings once per nginx worker.
-- ============================================================================
function _M.init()
    ngx.log(
        ngx.NOTICE,
        "[firewall] startup ENABLED=", tostring(FIREWALL_ENABLED),
        " REDIS_SSL=", tostring(redis_pool.config.ssl)
    )
end


-- Load and validate firewall:rules + firewall:config from Redis. Per-worker
-- cache keyed off a shared version counter so flush_cache() invalidates all
-- workers at once. Validation warnings log at most once per refresh window.
local function load_rules_and_config(red)
    local now            = ngx.now()
    local shared_version = rc_shared:get("version") or 0

    if _rc_cache.expires > now and _rc_cache.version == shared_version then
        return _rc_cache.rules, _rc_cache.config
    end

    local rules_json  = red:get("firewall:rules")
    local config_json = red:get("firewall:config")

    local raw_rules  = (rules_json  and rules_json  ~= ngx.null) and cjson.decode(rules_json)  or nil
    local raw_config = (config_json and config_json ~= ngx.null) and cjson.decode(config_json) or nil

    local rules,       rule_warns   = config_module.parse_rules(raw_rules)
    local gcra_config, config_warns = config_module.parse_config(raw_config)

    for _, w in ipairs(rule_warns)   do ngx.log(ngx.WARN, "[firewall] ", w) end
    for _, w in ipairs(config_warns) do ngx.log(ngx.WARN, "[firewall] ", w) end

    _rc_cache = { rules = rules, config = gcra_config, version = shared_version, expires = now + RC_CACHE_TTL }
    return rules, gcra_config
end


-- PCRE wrapper passed into the (pure, ngx-free) cost module.
-- Flags "ijo" = case-insensitive, JIT-compile, compile-once cached.
local function ngx_regex_match(subject, pattern)
    local m, err = ngx.re.match(subject, pattern, "ijo")
    return m ~= nil
end


-- REQUEST PHASE — access_by_lua. See README.md → "Request flow" /
-- "Operating modes" / "Design decisions".
local blocked_cache = ngx.shared.firewall_cache

function _M.req()
    if not FIREWALL_ENABLED then return end

    -- realip module has rewritten remote_addr from X-Forwarded-For.
    local ip = ngx.var.remote_addr

    -- Fast path: 0 Redis ops while this IP is in an active block window.
    -- Value is the mode ("enforce" → 429, "monitor" → allow) so a mid-window
    -- mode flip does not retroactively reinterpret cached entries.
    local cached_mode = blocked_cache:get(CACHE_PREFIX .. ip)
    if cached_mode then
        if cached_mode == "enforce" then
            ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
        end
        return
    end

    -- Match against the original client-visible path, not rewritten /index.php.
    local uri       = (ngx.var.request_uri or ngx.var.uri or ""):gsub("%?.*$", "")
    local ua        = ngx.var.http_user_agent or ""
    local method    = ngx.var.request_method
    local args      = ngx.var.args
    local has_query = (args ~= nil and args ~= "")

    -- ngx.exit() raises a Lua error internally, so it must NOT run inside
    -- pcall (which would swallow it and let the request through). Set a flag
    -- inside the protected block; call ngx.exit() after.
    local blocked = false
    local ok, err = pcall(function()
        local red = redis_pool.connect()
        if not red then return end  -- fail-open

        local rules, gcra_config = load_rules_and_config(red)

        if not rules then
            ngx.log(ngx.ERR, "[firewall] no rules found in Redis (firewall:rules) "
                          .. "— all requests allowed. Run seed_rules() to initialise.")
            redis_pool.release(red)
            return
        end

        local request_cost, breakdown = cost_module.calculate(
            uri, ua, method, has_query, args, rules, ngx_regex_match
        )

        -- Surface cost to the access log via $firewall_cost (set in nginx.conf).
        ngx.var.firewall_cost = tostring(request_cost)

        -- Mode comes from Redis (firewall:config) so it can flip cluster-wide
        -- without an nginx reload. Default "monitor" = safe rollout.
        local mode = (gcra_config and gcra_config.mode) or "monitor"

        if mode == "off" then
            redis_pool.release(red)
            return
        end

        -- info.reason ∈ {allow, block, penalty, gcra}
        --   allow   = allowlist hit (no TAT update, clean bypass)
        --   block   = manual blocklist hit
        --   penalty = automatic ban written by an earlier GCRA block
        --   gcra    = live GCRA decision against the bucket
        local allowed, info = gcra_module.check(red, ip, request_cost, gcra_config, breakdown)

        if allowed and info.reason == "allow" then
            redis_pool.release(red)
            return
        end

        if not allowed then
            -- retry_after is ms; 0 from a "block" reason = permanent ban,
            -- and shared_dict :set(_, _, 0) means "no expiry".
            local cache_ttl
            if info.reason == "block" and info.retry_after == 0 then
                cache_ttl = 0
            else
                cache_ttl = math.ceil(info.retry_after / 1000)
            end

            -- Cache the decision under the current mode so the fast path
            -- can act on it without re-reading config.
            blocked_cache:set(CACHE_PREFIX .. ip, mode, cache_ttl)

            -- One audit entry per block episode per IP (subsequent requests
            -- short-circuit at the fast path and do not re-audit).
            if gcra_config and gcra_config.audit_enabled then
                local now = math.floor(ngx.now() * 1000)
                local audit_stream = gcra_config.audit_stream or DEFAULT_AUDIT_STREAM
                local audit_maxlen = gcra_config.audit_maxlen or DEFAULT_AUDIT_MAXLEN

                local trigger
                if info.reason == "block" then
                    trigger = "blocklist"
                elseif info.reason == "penalty" then
                    trigger = "penalty"
                else
                    local trigger_parts = {}
                    for rule, rule_cost in pairs(breakdown) do
                        table.insert(trigger_parts, rule .. ":" .. rule_cost)
                    end
                    trigger = table.concat(trigger_parts, ",")
                end

                red:xadd(audit_stream, "MAXLEN", "~", audit_maxlen, "*",
                    "ip", ip,
                    "blocked_at", now,
                    "cost", request_cost,
                    "reason", info.reason,
                    "mode", mode,
                    "trigger", trigger,
                    "accumulated", info.accumulated or "",
                    "retry_after", info.retry_after or "")
            end

            ngx.log(ngx.WARN, "[firewall] ",
                    mode == "monitor" and "would-block" or "blocked",
                    " ip=", ip,
                    " reason=", info.reason,
                    " cost=", request_cost,
                    " retry_after=", info.retry_after)

            redis_pool.release(red)

            if mode == "enforce" then
                blocked = true
            end
        end

        redis_pool.release(red)
    end)

    if not ok then
        ngx.log(ngx.ERR, "[firewall] req error (fail-open): ", err)
    elseif blocked then
        -- ngx.exit() here is outside pcall and cannot be swallowed.
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end


-- RESPONSE PHASE — log_by_lua. 404s get an extra GCRA charge; the work is
-- deferred into a 0-delay timer because log_by_lua forbids socket I/O.
function _M.res()
    if not FIREWALL_ENABLED then return end
    if ngx.status ~= ngx.HTTP_NOT_FOUND then return end

    -- Capture ngx.var NOW; it is unavailable inside the timer callback.
    local ip = ngx.var.remote_addr

    if blocked_cache:get(CACHE_PREFIX .. ip) then return end

    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end  -- nginx shutting down

        local timer_ok, timer_err = pcall(function()
            -- Recheck cache: another worker may have blocked this IP since.
            if blocked_cache:get(CACHE_PREFIX .. ip) then return end

            local red = redis_pool.connect()
            if not red then return end

            local _, gcra_config = load_rules_and_config(red)
            local mode = (gcra_config and gcra_config.mode) or "monitor"

            if mode == "off" then
                redis_pool.release(red)
                return
            end

            local breakdown = { ["rule:404-penalty"] = PENALTY_404 }
            local allowed, info = gcra_module.check(red, ip, PENALTY_404, gcra_config, breakdown)

            if not allowed then
                local cache_ttl = math.ceil(info.retry_after / 1000)
                blocked_cache:set(CACHE_PREFIX .. ip, mode, cache_ttl)

                if gcra_config and gcra_config.audit_enabled then
                    local now = math.floor(ngx.now() * 1000)
                    local audit_stream = gcra_config.audit_stream or DEFAULT_AUDIT_STREAM
                    local audit_maxlen = gcra_config.audit_maxlen or DEFAULT_AUDIT_MAXLEN

                    red:xadd(audit_stream, "MAXLEN", "~", audit_maxlen, "*",
                        "ip", ip,
                        "blocked_at", now,
                        "cost", PENALTY_404,
                        "mode", mode,
                        "trigger", "rule:404-penalty:" .. PENALTY_404,
                        "accumulated", info.accumulated or "")
                end

                ngx.log(ngx.WARN, "[firewall] ",
                        mode == "monitor" and "would-block" or "blocked",
                        " by 404 penalty ip=", ip,
                        " retry_after=", info.retry_after)
            else
                ngx.log(ngx.INFO, "[firewall] 404 penalty ip=", ip,
                        " cost=", PENALTY_404)
            end

            redis_pool.release(red)
        end)

        if not timer_ok then
            ngx.log(ngx.ERR, "[firewall] res timer error: ", timer_err)
        end
    end)

    if not ok then
        ngx.log(ngx.ERR, "[firewall] timer schedule error: ", err)
    end
end


-- /firewall/stats — JSON snapshot of rules, config and live GCRA TATs.
-- Uses KEYS gcra:* — fine for ops/debug, do not call in hot paths.
function _M.stats()
    ngx.header.content_type = "application/json"

    local red = redis_pool.connect()
    if not red then
        ngx.say('{"error": "redis connection failed"}')
        return
    end

    local rules, config = load_rules_and_config(red)

    local gcra_keys = red:keys("gcra:*")
    local tat_data = {}
    if gcra_keys and #gcra_keys > 0 then
        for _, key in ipairs(gcra_keys) do
            local tat = red:get(key)
            if tat and tat ~= ngx.null then
                tat_data[key:sub(6)] = tonumber(tat)  -- strip "gcra:" prefix
            end
        end
    end

    redis_pool.release(red)

    ngx.say(cjson.encode({
        enabled     = FIREWALL_ENABLED,
        rules_count = rules and #rules or 0,
        config      = config or gcra_module.DEFAULTS,
        active_ips  = tat_data,
    }))
end


-- /firewall/flush-cache — clear local block cache and bump the shared
-- version counter so every worker re-reads rules/config from Redis.
-- Called by PHP after rule/config edits, and by the test suite.
function _M.flush_cache()
    blocked_cache:flush_all()
    local ok, err = rc_shared:incr("version", 1, 0)
    if not ok then
        ngx.log(ngx.ERR, "[firewall] flush_cache: rc_shared:incr failed: ", err)
        rc_shared:set("version", 1)
    end
    _rc_cache.expires = 0  -- invalidate this worker immediately too
    ngx.header.content_type = "application/json"
    ngx.say('{"ok":true}')
end


-- /firewall/admin/validate — strict schema check for admin saves.
-- Request:  POST  body = raw JSON for either rules or config
--           query: kind=rules | kind=config
-- Response: 200 application/json
--   { "ok": bool, "errors": [string,...], "normalised": <array|object|null> }
--
-- The Lua schema (firewall.config) is the single source of truth. The
-- WordPress admin form posts the operator's input here before writing to
-- Redis so that errors and warnings cannot diverge from the runtime
-- parser. The endpoint is read-only (no Redis writes) and matches the
-- trust level of the other /firewall/* admin endpoints — restricted by
-- nginx to loopback in production.
function _M.validate()
    ngx.header.content_type = "application/json"

    local kind = ngx.var.arg_kind
    if kind ~= "rules" and kind ~= "config" then
        ngx.status = 400
        ngx.say(cjson.encode({
            ok = false,
            errors = { "Query parameter 'kind' must be 'rules' or 'config'." },
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
        result = config_module.validate_rules_strict(decoded)
    else
        result = config_module.validate_config_strict(decoded)
    end

    -- cjson encodes empty Lua tables as objects by default; force the
    -- normalised rules payload to serialise as a JSON array.
    if kind == "rules" and result.normalised then
        if next(result.normalised) == nil then
            result.normalised = cjson.empty_array
        end
    end

    ngx.say(cjson.encode(result))
end


-- Initialise firewall:rules with a minimal safe ruleset. Run once on a
-- fresh Redis; admins tune from the WordPress UI afterwards.
function _M.seed_rules()
    local red = redis_pool.connect()
    if not red then
        return nil, "redis connection failed"
    end

    local seed = {
        { id = "base",         conditions = {},                   cost = 1  },
        { id = "query-string", conditions = { has_query = true }, cost = 4  }
    }
    local rules_json = cjson.encode(seed)
    local ok, err = red:set("firewall:rules", rules_json)

    redis_pool.release(red)

    return ok, err
end


-- ============================================================================
-- Allow / block list helpers — thin Redis wrappers. Each IP is its own key
-- so native EXPIRE manages lifetime; the GCRA Redis script reads these keys
-- before running the rate-limit check. Prefixes come from firewall.defaults.
-- ============================================================================

-- Allowlist `ip` for `ttl` seconds (nil/0 = permanent).
function _M.allow_ip(ip, ttl)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end

    local ok, err
    if ttl and ttl > 0 then
        ok, err = red:set(ALLOW_PREFIX .. ip, "1", "EX", ttl)
    else
        ok, err = red:set(ALLOW_PREFIX .. ip, "1")
    end

    redis_pool.release(red)
    -- Drop any cached block so the new allow takes effect immediately.
    blocked_cache:delete(CACHE_PREFIX .. ip)
    return ok, err
end

function _M.unallow_ip(ip)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end

    local ok, err = red:del(ALLOW_PREFIX .. ip)
    redis_pool.release(red)
    return ok, err
end

-- Blocklist `ip` for `ttl` seconds (nil/0 = permanent).
function _M.block_ip(ip, ttl)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end

    local ok, err
    if ttl and ttl > 0 then
        ok, err = red:set(BLOCK_PREFIX .. ip, "1", "EX", ttl)
    else
        ok, err = red:set(BLOCK_PREFIX .. ip, "1")
    end

    redis_pool.release(red)
    -- Pre-warm the local cache so this worker blocks immediately.
    if ok then
        blocked_cache:set(CACHE_PREFIX .. ip, true, ttl or 0)
    end
    return ok, err
end

function _M.unblock_ip(ip)
    local red = redis_pool.connect()
    if not red then return nil, "redis connection failed" end

    local ok, err = red:del(BLOCK_PREFIX .. ip)
    redis_pool.release(red)
    blocked_cache:delete(CACHE_PREFIX .. ip)
    return ok, err
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

    local keys, err = red:keys(BLOCK_PREFIX .. "*")
    local deleted = 0
    if keys and type(keys) == "table" then
        for _, key in ipairs(keys) do
            local val = red:get(key)
            if val == "gcra" then
                red:del(key)
                local ip = key:sub(#BLOCK_PREFIX + 1)
                blocked_cache:delete(CACHE_PREFIX .. ip)
                deleted = deleted + 1
            end
        end
    end

    redis_pool.release(red)
    ngx.header.content_type = "application/json"
    ngx.say('{"ok":true,"deleted":' .. deleted .. '}')
end


return _M
