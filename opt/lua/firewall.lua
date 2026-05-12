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
local CACHE_PREFIX         = defaults.BLOCKED_CACHE_PREFIX
local AUDIT_STREAM         = defaults.AUDIT_STREAM
local DEFAULT_AUDIT_MAXLEN = defaults.GCRA.audit_maxlen
-- Pulled up here (rather than just before _M.req) so ngx_regex_match can
-- use it for the log-flood dedup guard without a forward reference.
local blocked_cache        = cache.blocked_cache


-- Logs resolved firewall settings once per nginx worker and pre-warms the
-- per-worker CIDR/rules cache so is_allowed/is_blocked have populated lists
-- before the first request arrives.
-- ============================================================================
function _M.init()
    ngx.log(
        ngx.NOTICE,
        "[firewall] event=startup enabled=", tostring(FIREWALL_ENABLED),
        " redis_ssl=", tostring(redis_pool.config.ssl)
    )
    if not FIREWALL_ENABLED then return end
    -- Warm the cache eagerly. Fail-open: if Redis is unavailable here the
    -- first request will re-attempt via the normal pcall path in req().
    local red = redis_pool.connect()
    if red then
        cache.load_rules_and_config(red)
        redis_pool.release(red)
    end
end



-- PCRE wrapper passed into the (pure, ngx-free) cost module.
-- Flags "ijo" = case-insensitive, JIT-compile, compile-once cached.
--
-- Log-flood guard: a bad pattern fires on every request, so we deduplicate
-- via a shared-dict key.  blocked_cache is already present; we namespace
-- the key with "logged:regex:" to avoid any collision with block entries.
-- TTL of 3600 s means: log once per hour per pattern while the problem
-- persists, rather than once per request.  The admin /validate endpoint
-- catches bad patterns before they reach Redis in normal operation, so this
-- branch should never fire in production — but if a rule is written to Redis
-- directly (e.g. a migration script), the operator will still get a signal.
local REGEX_WARN_TTL = 3600  -- seconds between repeat warnings for the same bad pattern
local function ngx_regex_match(subject, pattern)
    local m, err = ngx.re.match(subject, pattern, "ijo")
    if err then
        local seen_key = "logged:regex:" .. pattern
        if not blocked_cache:get(seen_key) then
            blocked_cache:set(seen_key, 1, REGEX_WARN_TTL)
            ngx.log(ngx.WARN, "[firewall] event=regex_error pattern=", pattern, " err=", err)
        end
    end
    return m ~= nil
end



-- REQUEST PHASE — access_by_lua. See README.md → "Request flow" /
-- "Operating modes" / "Design decisions".

function _M.req()
    if not FIREWALL_ENABLED then return end

    -- realip module has rewritten remote_addr from X-Forwarded-For.
    local ip = ngx.var.remote_addr

    -- CIDR allow/block: pure in-memory check against the per-worker cache.
    -- Runs before the shared-dict lookup and all Redis I/O. Uses the list
    -- populated at the last cache refresh; a cold worker (empty lists) fails
    -- open, consistent with rules/config on worker startup.
    if cache.is_allowed(ip) then return end
    if cache.is_blocked(ip) then ngx.exit(ngx.HTTP_FORBIDDEN) end

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
            ngx.log(ngx.ERR, "[firewall] event=no_rules msg=firewall:rules missing or empty, all requests allowed")
            redis_pool.release(red)
            return
        end

        local req_rules = cache.get_rules("req")
        local request_cost, breakdown = cost_module.calculate(
            { uri = uri, ua = ua, method = method, has_query = has_query, query = args },
            req_rules,
            ngx_regex_match
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

        if allowed then
            redis_pool.release(red)
            return
        end

        -- here, handle the case where allowed is false

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
                -- Sort so the audit `trigger` field is deterministic across
                -- requests with the same matching rule set (pairs() order is
                -- otherwise hash-dependent).
                table.sort(trigger_parts)
                trigger = table.concat(trigger_parts, ",")
            end

            local _, xadd_err = red:xadd(AUDIT_STREAM, "MAXLEN", "~", audit_maxlen, "*",
                "ip", ip,
                "blocked_at", now,
                "cost", request_cost,
                "reason", info.reason,
                "mode", mode,
                "trigger", trigger,
                "accumulated", info.accumulated or "",
                "retry_after", info.retry_after or "")
            if xadd_err then
                ngx.log(ngx.ERR, "[firewall] event=audit_write_failed phase=req ip=", ip, " err=", xadd_err)
            end
        end

        ngx.log(ngx.INFO, "[firewall] event=block phase=req mode=", mode,
                " ip=", ip,
                " reason=", info.reason,
                " cost=", request_cost,
                " retry_after=", info.retry_after)

        redis_pool.release(red)

        if mode == "enforce" then
            blocked = true
        end
    end)

    if not ok then
        ngx.log(ngx.ERR, "[firewall] event=req_error err=", err)
    elseif blocked then
        -- ngx.exit() here is outside pcall and cannot be swallowed.
        ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
    end
end


-- RESPONSE PHASE — log_by_lua. Iterates the cached res-phase rules and
-- charges the per-IP GCRA bucket once with the sum of all matching costs
-- (e.g. a 404 → probing, 499 → client-closed scanner fire-and-forget).
-- The work is deferred into a 0-delay timer because log_by_lua forbids
-- socket I/O. The breakdown table is keyed by rule name so the audit
-- trigger format ('rule:res-score:<name>:<cost>') is symmetric with req().
function _M.res()
    if not FIREWALL_ENABLED then return end

    -- CIDR checks mirror req(): allowed IPs bypass scoring entirely;
    -- already-blocked IPs skip GCRA (response already sent, just avoid noise).
    local ip = ngx.var.remote_addr
    if cache.is_allowed(ip) then return end
    if cache.is_blocked(ip) then return end

    local res_rules = cache.get_rules("res")
    if #res_rules == 0 then return end

    local status = ngx.status
    local total_cost, breakdown = cost_module.calculate(
        { status = status }, res_rules, nil
    )
    if total_cost == 0 and next(breakdown) == nil then return end

    -- ip already captured above; ngx.var is unavailable inside the timer.
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

            local allowed, info = gcra_module.check(red, ip, total_cost, gcra_config, breakdown)

            if not allowed then
                local cache_ttl = math.ceil(info.retry_after / 1000)
                blocked_cache:set(CACHE_PREFIX .. ip, mode, cache_ttl)

                if gcra_config and gcra_config.audit_enabled then
                    local now = math.floor(ngx.now() * 1000)
                    local audit_maxlen = gcra_config.audit_maxlen or DEFAULT_AUDIT_MAXLEN

                    -- Stable, comma-separated 'rule:res-score:<name>:<cost>' pairs.
                    -- Sorted so the audit `trigger` field is deterministic
                    -- across requests with the same matching rule set.
                    local trigger_parts = {}
                    for rule, rule_cost in pairs(breakdown) do
                        table.insert(trigger_parts, rule .. ":" .. rule_cost)
                    end
                    table.sort(trigger_parts)
                    local trigger = table.concat(trigger_parts, ",")

                    local _, xadd_err = red:xadd(AUDIT_STREAM, "MAXLEN", "~", audit_maxlen, "*",
                        "ip", ip,
                        "blocked_at", now,
                        "cost", total_cost,
                        "mode", mode,
                        "trigger", trigger,
                        "accumulated", info.accumulated or "")
                    if xadd_err then
                        ngx.log(ngx.ERR, "[firewall] event=audit_write_failed phase=res ip=", ip, " err=", xadd_err)
                    end
                end

                ngx.log(ngx.INFO, "[firewall] event=block phase=res mode=", mode,
                        " ip=", ip,
                        " status=", status,
                        " cost=", total_cost,
                        " retry_after=", info.retry_after)
            else
                ngx.log(ngx.INFO, "[firewall] event=res_charge phase=res ip=", ip,
                        " status=", status,
                        " cost=", total_cost)
            end

            redis_pool.release(red)
        end)

        if not timer_ok then
            ngx.log(ngx.ERR, "[firewall] event=res_timer_error err=", timer_err)
        end
    end)

    if not ok then
        ngx.log(ngx.ERR, "[firewall] event=timer_schedule_error err=", err)
    end
end


return _M
