-- ============================================================================
-- Firewall hot path. See README.md for architecture, request flow, data
-- model, operating modes, and design decisions.
--
-- Wired up in nginx.conf / wordpress.conf:
--   init_worker_by_lua_block { require("firewall").init() }
--   access_by_lua_block      { require("firewall").req()  }
--   log_by_lua_block         { require("firewall").res()  }
--
-- Admin endpoints (stats, flush-cache, validate, clear-penalties) live in
-- firewall.admin, dispatched via require("firewall.admin").handle_route().
-- Shared cache state (blocked_cache, load_rules_and_config, flush) lives in
-- firewall.cache.
-- ============================================================================

local _M = {}

local redis_pool    = require "firewall.redis"
local cost_module   = require "firewall.cost"
local gcra_module   = require "firewall.gcra"
local defaults      = require "firewall.defaults"
local cache         = require "firewall.cache"

-- Kill switch. When false, req()/res() return immediately. Requires nginx
-- restart to flip; for runtime control use firewall:config.mode in Redis.
local FIREWALL_ENABLED = os.getenv("FIREWALL_ENABLED") ~= "false"

-- See firewall.defaults for rationale and any tuning. Pulled into locals
-- here so the hot path doesn't pay table-lookup cost per request.
local PENALTY_404          = defaults.PENALTY_404
local CACHE_PREFIX         = defaults.BLOCKED_CACHE_PREFIX
local AUDIT_STREAM         = defaults.AUDIT_STREAM
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



-- PCRE wrapper passed into the (pure, ngx-free) cost module.
-- Flags "ijo" = case-insensitive, JIT-compile, compile-once cached.
local function ngx_regex_match(subject, pattern)
    local m, err = ngx.re.match(subject, pattern, "ijo")
    if err then
        ngx.log(ngx.WARN, "[firewall] regex error in pattern '", pattern, "': ", err)
    end
    return m ~= nil
end



-- REQUEST PHASE — access_by_lua. See README.md → "Request flow" /
-- "Operating modes" / "Design decisions".
local blocked_cache = cache.blocked_cache

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

        local rules, gcra_config = cache.load_rules_and_config(red)

        if not rules then
            ngx.log(ngx.ERR, "[firewall] no rules found in Redis (firewall:rules) "
                          .. "— all requests allowed. Seed via: SET firewall:rules '[...]'")
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

                red:xadd(AUDIT_STREAM, "MAXLEN", "~", audit_maxlen, "*",
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

            local _, gcra_config = cache.load_rules_and_config(red)
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
                    local audit_maxlen = gcra_config.audit_maxlen or DEFAULT_AUDIT_MAXLEN

                    red:xadd(AUDIT_STREAM, "MAXLEN", "~", audit_maxlen, "*",
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


return _M
