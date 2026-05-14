-- ============================================================================
-- GCRA Integration Tests (requires Redis)
-- ============================================================================
-- Run with: make test-integration
-- These tests connect to real Redis and verify the GCRA script works correctly.
-- ============================================================================

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local gcra = require "firewall.gcra"

-- Mock Redis client that connects to real Redis
local function create_redis_client()
    local socket = require "socket"
    local redis_host = os.getenv("REDIS_HOST") or "redis"
    local redis_port = tonumber(os.getenv("REDIS_PORT")) or 6379

    -- Simple Redis client for testing (not for production!)
    local client = {}
    local tcp = socket.tcp()
    tcp:settimeout(5)

    local ok, err = tcp:connect(redis_host, redis_port)
    if not ok then
        error("Failed to connect to Redis at " .. redis_host .. ":" .. redis_port .. ": " .. (err or "unknown"))
    end

    local redis_db = tonumber(os.getenv("REDIS_DB")) or 0
    if redis_db ~= 0 then
        local db_str = tostring(redis_db)
        tcp:send("*2\r\n$6\r\nSELECT\r\n$" .. #db_str .. "\r\n" .. db_str .. "\r\n")
        local sel_line = tcp:receive("*l")
        if not sel_line or sel_line:sub(1, 1) ~= "+" then
            error("Redis SELECT " .. redis_db .. " failed: " .. (sel_line or "no response"))
        end
    end

    -- Parse Redis response
    local function parse_response()
        local line = tcp:receive("*l")
        if not line then return nil, "no response" end

        local prefix = line:sub(1, 1)
        local data = line:sub(2)

        if prefix == "+" then
            return data  -- Simple string
        elseif prefix == "-" then
            return nil, data  -- Error
        elseif prefix == ":" then
            return tonumber(data)  -- Integer
        elseif prefix == "$" then
            local len = tonumber(data)
            if len == -1 then return nil end
            local bulk = tcp:receive(len)
            tcp:receive(2)  -- consume \r\n
            return bulk
        elseif prefix == "*" then
            local count = tonumber(data)
            if count == -1 then return nil end
            local arr = {}
            for i = 1, count do
                arr[i] = parse_response()
            end
            return arr
        end
        return nil, "unknown response type: " .. prefix
    end

    function client:del(key)
        local cmd = "*2\r\n$3\r\nDEL\r\n$" .. #key .. "\r\n" .. key .. "\r\n"
        tcp:send(cmd)
        return parse_response()
    end

    function client:get(key)
        local cmd = "*2\r\n$3\r\nGET\r\n$" .. #key .. "\r\n" .. key .. "\r\n"
        tcp:send(cmd)
        return parse_response()
    end

    function client:eval(script, num_keys, ...)
        local args = {"EVAL", script, tostring(num_keys), ...}
        local cmd = "*" .. #args .. "\r\n"
        for _, arg in ipairs(args) do
            arg = tostring(arg)
            cmd = cmd .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        tcp:send(cmd)
        return parse_response()
    end

    function client:evalsha(sha, num_keys, ...)
        local args = {"EVALSHA", sha, tostring(num_keys), ...}
        local cmd = "*" .. #args .. "\r\n"
        for _, arg in ipairs(args) do
            arg = tostring(arg)
            cmd = cmd .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        tcp:send(cmd)
        return parse_response()
    end

    function client:script(subcmd, ...)
        local args = {"SCRIPT", subcmd, ...}
        local cmd = "*" .. #args .. "\r\n"
        for _, arg in ipairs(args) do
            arg = tostring(arg)
            cmd = cmd .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        tcp:send(cmd)
        return parse_response()
    end

    -- Generic command helper (used by tests for SET/EXPIRE on allow/block keys)
    function client:cmd(...)
        local args = {...}
        local c = "*" .. #args .. "\r\n"
        for _, arg in ipairs(args) do
            arg = tostring(arg)
            c = c .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        tcp:send(c)
        return parse_response()
    end

    function client:close()
        tcp:close()
    end

    return client
end

describe("GCRA integration", function()
    local red
    local test_key = "firewall:gcra:integration:test"

    setup(function()
        red = create_redis_client()
    end)

    teardown(function()
        if red then
            red:del(test_key)
            red:close()
        end
    end)

    before_each(function()
        red:del(test_key)
        -- Clear cached SHA so each test uses fresh script
        gcra.script_sha = nil
    end)

    it("loads script into Redis", function()
        local sha = gcra.load_script(red)
        assert.is_string(sha)
        assert.equals(40, #sha)  -- SHA1 is 40 hex chars
    end)

    it("allows requests within burst limit", function()
        local config = {
            emission_interval = 1000,  -- 1 token per second
            burst = 10000,             -- 10 seconds of burst
        }

        -- Simulate 10 requests at same time (within burst)
        for i = 1, 10 do
            local allowed = gcra.check_direct(red, test_key, 1, config)
            assert.is_true(allowed, "Request " .. i .. " should be allowed")
        end
    end)

    it("blocks requests exceeding burst", function()
        local config = {
            emission_interval = 1000,
            burst = 10000,
        }

        local allowed_count = 0
        local blocked_count = 0

        -- Send 12 requests - should allow 10, block 2
        for _ = 1, 12 do
            local allowed, info = gcra.check_direct(red, test_key, 1, config)
            if allowed then
                allowed_count = allowed_count + 1
            else
                blocked_count = blocked_count + 1
                assert.is_number(info.retry_after)
                assert.is_true(info.retry_after > 0)
            end
        end

        assert.equals(10, allowed_count)
        assert.equals(2, blocked_count)
    end)

    it("allows requests after tokens refill", function()
        local config = {
            -- Use 100ms emission interval so the refill window (100ms) is
            -- wide enough not to be affected by scheduler jitter.  A sleep
            -- of 150ms is safely inside the 1-token zone (100-199ms); the
            -- test would only flake if the sleep overshot by >50ms.
            emission_interval = 100,
            burst = 500,
        }

        -- Exhaust burst immediately (5 * 100ms = 500ms = burst)
        for _ = 1, 5 do
            gcra.check_direct(red, test_key, 1, config)
        end

        -- Blocked immediately after burst is exhausted
        local allowed = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed)

        -- Wait for one token (100ms) to refill; sleep 150ms for margin
        require("socket").sleep(0.15)
        allowed = gcra.check_direct(red, test_key, 1, config)
        assert.is_true(allowed)

        -- But not 2 — only one token refilled
        allowed = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed)
    end)

    it("handles variable cost", function()
        local config = {
            emission_interval = 1000,
            burst = 10000,
        }

        -- High-cost request (cost=5) consumes 5 tokens
        local allowed = gcra.check_direct(red, test_key, 5, config)
        assert.is_true(allowed)

        -- Another cost=5 request
        allowed = gcra.check_direct(red, test_key, 5, config)
        assert.is_true(allowed)

        -- Cost=1 should fail (only 10 tokens, 10 used)
        allowed = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed)
    end)

    it("caches script SHA after load_script", function()
        -- First, explicitly load the script
        local sha = gcra.load_script(red)
        assert.is_string(sha)
        assert.equals(40, #sha)  -- SHA1 is 40 hex chars

        -- The SHA should be cached
        assert.equals(sha, gcra.script_sha)

        -- Loading again should return the same SHA
        local sha2 = gcra.load_script(red)
        assert.equals(sha, sha2)
    end)
end)

describe("GCRA allow/block list integration", function()
    local red
    local test_key  = "firewall:gcra:integration:abtest"
    local allow_key = "firewall:allow:integration:abtest"
    local block_key = "firewall:block:integration:abtest"

    setup(function()
        red = create_redis_client()
    end)

    teardown(function()
        if red then
            red:del(test_key)
            red:del(allow_key)
            red:del(block_key)
            red:close()
        end
    end)

    before_each(function()
        red:del(test_key)
        red:del(allow_key)
        red:del(block_key)
        gcra.script_sha = nil
    end)

    it("short-circuits to allow when allow_key exists, even when bucket is exhausted", function()
        local config = {
            emission_interval = 1000,
            burst             = 5000,  -- 5 tokens
            allow_key         = allow_key,
            block_key         = block_key,
        }

        -- Burn the bucket first
        for _ = 1, 5 do
            gcra.check_direct(red, test_key, 1, config)
        end
        local allowed = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed, "sanity: bucket should be exhausted")

        -- Add to allowlist
        red:cmd("SET", allow_key, "1")

        -- Should now bypass cleanly
        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_true(ok)
        assert.equals("allow", info.reason)
        assert.equals(0,       info.retry_after)
    end)

    it("short-circuits to block when block_key exists, returning PTTL as retry_after", function()
        local config = {
            emission_interval = 1000,
            burst             = 100000,
            allow_key         = allow_key,
            block_key         = block_key,
        }

        -- Block with a 60s TTL
        red:cmd("SET", block_key, "1", "EX", "60")

        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(ok)
        assert.equals("block", info.reason)
        -- PTTL should be roughly 60_000 ms (allow some clock slack)
        assert.is_true(info.retry_after > 50000 and info.retry_after <= 60000,
                       "retry_after should be ~60000ms, got " .. tostring(info.retry_after))
    end)

    it("returns retry_after=0 for permanent ban (no TTL on block_key)", function()
        local config = {
            emission_interval = 1000,
            burst             = 100000,
            allow_key         = allow_key,
            block_key         = block_key,
        }

        -- Permanent block (no EX)
        red:cmd("SET", block_key, "1")

        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(ok)
        assert.equals("block", info.reason)
        assert.equals(0, info.retry_after)
    end)

    it("allow takes precedence over block when both keys are set", function()
        local config = {
            emission_interval = 1000,
            burst             = 100000,
            allow_key         = allow_key,
            block_key         = block_key,
        }

        red:cmd("SET", allow_key, "1")
        red:cmd("SET", block_key, "1")

        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_true(ok)
        assert.equals("allow", info.reason)
    end)

    it("allowlist bypass does not consume tokens (TAT remains untouched)", function()
        local config = {
            emission_interval = 1000,
            burst             = 5000,
            allow_key         = allow_key,
            block_key         = block_key,
        }

        red:cmd("SET", allow_key, "1")

        -- Many bypass requests
        for _ = 1, 100 do
            local ok, info = gcra.check_direct(red, test_key, 1, config)
            assert.is_true(ok)
            assert.equals("allow", info.reason)
        end

        -- TAT key should still not exist
        local tat = red:get(test_key)
        assert.is_nil(tat)
    end)

    -- penalty_ttl=0 means the operator has disabled automatic bans.
    -- When GCRA blocks, the script must NOT write a block key.
    -- FAILS with `config.penalty_ttl or default` because 0 is falsy in Lua
    -- and silently becomes the default (600000ms), writing the ban anyway.
    it("does not write block_key when penalty_ttl=0 (operator-disabled auto-ban)", function()
        local config = {
            emission_interval = 1000,
            burst             = 5000,  -- 5 tokens
            block_key         = block_key,
            penalty_ttl       = 0,     -- explicitly disabled
        }

        -- Exhaust the bucket (5 allowed, 6th blocked)
        for _ = 1, 5 do
            gcra.check_direct(red, test_key, 1, config)
        end
        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(ok,          "sanity: 6th request should be blocked by GCRA")
        assert.equals("gcra", info.reason)

        -- The block key must NOT exist — penalty_ttl=0 means no auto-ban
        local val = red:get(block_key)
        assert.is_nil(val, "block_key must not be written when penalty_ttl=0")
    end)

    it("returns reason='gcra' when neither allow nor block keys are set", function()
        local config = {
            emission_interval = 1000,
            burst             = 10000,
            allow_key         = allow_key,
            block_key         = block_key,
        }

        local ok, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_true(ok)
        assert.equals("gcra", info.reason)
    end)
end)
