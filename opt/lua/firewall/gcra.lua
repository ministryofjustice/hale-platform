-- ============================================================================
-- GCRA (Generic Cell Rate Algorithm) MODULE
-- ============================================================================
-- Token bucket rate limiting using Redis Lua script for atomicity.
-- Handles decay naturally - no TTL refresh bugs.
--
-- Optionally tracks per-IP rule hit breakdown (only on allowed requests).
-- Blocked IPs are cached locally in nginx to avoid Redis writes.
--
-- USAGE:
--   local gcra = require "firewall.gcra"
--   local allowed, info = gcra.check(red, ip, cost, config, breakdown)
--
-- CONFIG:
--   emission_interval: ms between token refills (1000 = 1 token/sec)
--   burst: max tokens that can accumulate (capacity)
--   audit_enabled: track rule breakdown (default: false)
--
-- REDIS KEYS (when audit_enabled):
--   gcra:{ip}           - TAT (theoretical arrival time)
--   gcra:{ip}:breakdown - Hash of rule -> hit count (accumulated)
--
-- BLOCKING OPTIMIZATION:
--   - Blocked IPs are cached in nginx shared dict (no Redis hits)
--   - Breakdown tracking only happens for ALLOWED requests (no writes on block)
--   - Audit log written ONCE when first blocked, then IP cached locally
-- ============================================================================

local _M = {}

local cjson = require "cjson.safe"

-- Redis Lua script for GCRA rate limiting with allow/block list short-circuits
-- Runs atomically on Redis server.
--
-- Decision precedence:
--   1. allowlist hit  → ALLOW (no TAT update, no audit) — clean bypass
--   2. blocklist hit  → BLOCK (retry_after = PTTL, or 0 for permanent)
--   3. GCRA           → ALLOW or BLOCK based on token bucket
--
-- KEYS[1] = gcra:{ip}            - TAT key
-- KEYS[2] = gcra:{ip}:breakdown  - breakdown hash (only used if audit enabled)
-- KEYS[3] = firewall:allow:{ip}  - allowlist key (presence = bypass)
-- KEYS[4] = firewall:block:{ip}  - blocklist key (presence = block)
--
-- ARGV[1] = emission_interval (ms)
-- ARGV[2] = burst (ms)
-- ARGV[3] = cost
-- ARGV[4] = audit_enabled ("1" or "0")
-- ARGV[5..N] = breakdown pairs: rule1, hits1, rule2, hits2, ...
--
-- RETURNS:
--   [allowed, retry_after, tat, accumulated_json, reason]
--   reason: "allow" | "block" | "gcra"
--   retry_after: ms until retry; 0 means permanent ban (no PTTL)
--   accumulated_json only populated on GCRA block (for audit logging)
--
_M.SCRIPT = [[
local gcra_key      = KEYS[1]
local breakdown_key = KEYS[2]
local allow_key     = KEYS[3]
local block_key     = KEYS[4]

local emission_interval = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])
local cost = tonumber(ARGV[3]) or 1
local audit_enabled = ARGV[4] == "1"

-- =====================
-- Allowlist short-circuit (clean bypass)
-- =====================
if allow_key and allow_key ~= "" and redis.call('EXISTS', allow_key) == 1 then
    return {1, 0, 0, "", "allow"}
end

-- =====================
-- Blocklist short-circuit
-- =====================
if block_key and block_key ~= "" and redis.call('EXISTS', block_key) == 1 then
    -- PTTL returns ms until expiry, -1 if no TTL (permanent), -2 if missing.
    -- We treat -1 as 0 (signals "permanent" to caller).
    local pttl = redis.call('PTTL', block_key)
    if pttl < 0 then pttl = 0 end
    return {0, pttl, 0, "", "block"}
end

-- Use Redis server time to avoid app/Redis clock skew.
local t = redis.call('TIME')
local now = (tonumber(t[1]) * 1000) + math.floor(tonumber(t[2]) / 1000)

-- =====================
-- GCRA Rate Limit Check
-- =====================
local tat = redis.call('GET', gcra_key)
tat = tat and tonumber(tat) or now

local new_tat = math.max(tat, now) + (emission_interval * cost)
local allow_at = new_tat - burst
local allowed = now >= allow_at

if allowed then
    -- Update TAT
    redis.call('SET', gcra_key, new_tat, 'PX', burst + emission_interval)
    
    -- Track breakdown ONLY for allowed requests (no writes on block)
    if audit_enabled and #ARGV >= 5 then
        local ttl = burst + emission_interval
        for i = 5, #ARGV, 2 do
            local rule = ARGV[i]
            local hits = tonumber(ARGV[i + 1]) or 1
            redis.call('HINCRBY', breakdown_key, rule, hits)
        end
        redis.call('PEXPIRE', breakdown_key, ttl)
    end
    
    return {1, 0, new_tat, "", "gcra"}
else
    -- Blocked: return accumulated breakdown for audit (read-only)
    local acc_json = ""
    if audit_enabled then
        local acc_raw = redis.call('HGETALL', breakdown_key)
        if #acc_raw > 0 then
            -- Convert flat array to JSON object string
            local parts = {}
            for i = 1, #acc_raw, 2 do
                table.insert(parts, '"' .. acc_raw[i] .. '":' .. acc_raw[i + 1])
            end
            acc_json = "{" .. table.concat(parts, ",") .. "}"
        end
    end
    
    return {0, math.ceil(allow_at - now), tat, acc_json, "gcra"}
end
]]

-- Default configuration
_M.DEFAULTS = {
    emission_interval = 1000,  -- 1 token per second
    burst = 100000,            -- 100 seconds of capacity
    key_prefix = "gcra:",
    allow_prefix = "firewall:allow:",
    block_prefix = "firewall:block:",
    audit_enabled = false,     -- track rule breakdown
}

--- Production rate-limit entry point.
-- Builds Redis keys from IP/config, prefers EVALSHA with SCRIPT LOAD fallback,
-- and returns a normalized result table for the firewall request path.
-- @param red: Redis client (resty.redis instance)
-- @param ip: IP address string
-- @param cost: Cost of this request (tokens to consume)
-- @param config: Optional config table {emission_interval, burst, key_prefix, audit_enabled}
-- @param breakdown: Optional table {["rule:id"]=cost, ...} for breakdown tracking
-- @return allowed: boolean, true if request is allowed
-- @return info: table {retry_after=ms, tat=timestamp, accumulated=json_string}
function _M.check(red, ip, cost, config, breakdown)
    config = config or {}
    local emission_interval = config.emission_interval or _M.DEFAULTS.emission_interval
    local burst = config.burst or _M.DEFAULTS.burst
    local key_prefix = config.key_prefix or _M.DEFAULTS.key_prefix
    local allow_prefix = config.allow_prefix or _M.DEFAULTS.allow_prefix
    local block_prefix = config.block_prefix or _M.DEFAULTS.block_prefix
    local audit_enabled = config.audit_enabled or _M.DEFAULTS.audit_enabled
    
    local gcra_key      = key_prefix .. ip
    local breakdown_key = key_prefix .. ip .. ":breakdown"
    local allow_key     = allow_prefix .. ip
    local block_key     = block_prefix .. ip
    
    -- Build args array
    -- ARGV: emission_interval, burst, cost, audit_enabled, [breakdown pairs...]
    local args = {
        emission_interval,
        burst,
        cost,
        audit_enabled and "1" or "0",
    }
    
    -- Append breakdown pairs if audit enabled and breakdown provided
    if audit_enabled and breakdown then
        for rule, _ in pairs(breakdown) do
            table.insert(args, rule)
            table.insert(args, 1)  -- 1 hit per request
        end
    end
    
    local result, err
    
    -- Try EVALSHA first if we have a cached SHA
    if _M.script_sha then
        result, err = red:evalsha(_M.script_sha, 4, gcra_key, breakdown_key, allow_key, block_key, unpack(args))
        if err and err:find("NOSCRIPT") then
            _M.script_sha = nil  -- SHA invalid (Redis restarted), clear it
            result, err = nil, nil
        end
    end
    
    -- Fall back to EVAL and cache the SHA
    if not result and not err then
        -- Load script and cache SHA for future calls
        local sha, load_err = red:script("LOAD", _M.SCRIPT)
        if sha then
            _M.script_sha = sha
            result, err = red:evalsha(sha, 4, gcra_key, breakdown_key, allow_key, block_key, unpack(args))
        else
            -- SCRIPT LOAD failed, fall back to EVAL
            result, err = red:eval(_M.SCRIPT, 4, gcra_key, breakdown_key, allow_key, block_key, unpack(args))
        end
    end
    
    if not result then
        -- Redis error - fail open
        return true, { error = err }
    end
    
    local allowed     = result[1] == 1
    local retry_after = result[2]
    local tat         = result[3]
    local accumulated = result[4] or ""
    local reason      = result[5] or "gcra"
    
    return allowed, {
        retry_after = retry_after,
        tat = tat,
        accumulated = accumulated,  -- JSON string of accumulated breakdown (on GCRA block)
        reason = reason,            -- "allow" | "block" | "gcra"
    }
end

--- Load the script into Redis and cache the SHA
-- Call this once at startup if you want to pre-warm
-- @param red: Redis client
-- @return sha: Script SHA or nil on error
function _M.load_script(red)
    local sha, err = red:script("LOAD", _M.SCRIPT)
    if sha then
        _M.script_sha = sha
    end
    return sha, err
end

--- Direct script execution helper.
-- Bypasses key-prefix construction and script SHA caching so tests can exercise
-- the Redis script contract against an explicit key or a mock Redis client.
-- Despite its test-oriented role, this is not a pure function: it still
-- performs Redis I/O.
-- @param red: Redis client or mock
-- @param key: Full Redis key (gcra:{ip})
-- @param cost: Cost of this request
-- @param config: Config table {emission_interval, burst, audit_enabled,
--                              allow_key, block_key}
--                allow_key/block_key default to empty strings (skipping the
--                short-circuit checks) so existing tests work unchanged.
-- @param breakdown: Optional breakdown table for audit
-- @return allowed, info
function _M.check_direct(red, key, cost, config, breakdown)
    config = config or {}
    local emission_interval = config.emission_interval or _M.DEFAULTS.emission_interval
    local burst = config.burst or _M.DEFAULTS.burst
    local audit_enabled = config.audit_enabled or false
    local allow_key = config.allow_key or ""
    local block_key = config.block_key or ""
    
    local breakdown_key = key .. ":breakdown"
    
    -- Build args (matching script interface)
    local args = {
        emission_interval,
        burst,
        cost,
        audit_enabled and "1" or "0",
    }
    
    if audit_enabled and breakdown then
        for rule, _ in pairs(breakdown) do
            table.insert(args, rule)
            table.insert(args, 1)
        end
    end
    
    local result, err = red:eval(_M.SCRIPT, 4, key, breakdown_key, allow_key, block_key, unpack(args))
    
    if not result then
        return true, { error = err }
    end
    
    return result[1] == 1, {
        retry_after = result[2],
        tat         = result[3],
        accumulated = result[4] or "",
        reason      = result[5] or "gcra",
    }
end

return _M
