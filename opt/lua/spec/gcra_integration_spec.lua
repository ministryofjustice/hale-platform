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
    
    -- Send raw Redis command and get response
    local function send_command(...)
        local args = {...}
        local cmd = "*" .. #args .. "\r\n"
        for _, arg in ipairs(args) do
            arg = tostring(arg)
            cmd = cmd .. "$" .. #arg .. "\r\n" .. arg .. "\r\n"
        end
        tcp:send(cmd)
        return tcp:receive("*l")
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
    local test_key = "gcra:integration:test"
    
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
            key_prefix = "gcra:integration:",
        }
        
        -- Simulate 10 requests at same time (within burst)
        for i = 1, 10 do
            local allowed, info = gcra.check_direct(red, test_key, 1, config)
            assert.is_true(allowed, "Request " .. i .. " should be allowed")
        end
    end)
    
    it("blocks requests exceeding burst", function()
        local config = {
            emission_interval = 1000,
            burst = 10000,
            key_prefix = "gcra:integration:",
        }
        
        local allowed_count = 0
        local blocked_count = 0
        
        -- Send 12 requests - should allow 10, block 2
        for i = 1, 12 do
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
            emission_interval = 20,
            burst = 100,
            key_prefix = "gcra:integration:",
        }
        
        -- Exhaust burst immediately
        for i = 1, 5 do
            gcra.check_direct(red, test_key, 1, config)
        end
        
        -- Blocked immediately after burst is exhausted
        local allowed, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed)
        
        -- Wait for one token (20ms) to refill
        require("socket").sleep(0.03)
        allowed, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_true(allowed)
        
        -- But not 2
        allowed, info = gcra.check_direct(red, test_key, 1, config)
        assert.is_false(allowed)
    end)
    
    it("handles variable cost", function()
        local config = {
            emission_interval = 1000,
            burst = 10000,
            key_prefix = "gcra:integration:",
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
    local test_key  = "gcra:integration:abtest"
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
        for i = 1, 5 do
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
        for i = 1, 100 do
            local ok, info = gcra.check_direct(red, test_key, 1, config)
            assert.is_true(ok)
            assert.equals("allow", info.reason)
        end
        
        -- TAT key should still not exist
        local tat = red:get(test_key)
        assert.is_nil(tat)
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
