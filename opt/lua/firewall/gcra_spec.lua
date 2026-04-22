-- ============================================================================
-- GCRA MODULE TESTS
-- ============================================================================
-- Unit tests for module structure. Integration tests require Redis.
--
-- Run unit tests: docker build -f test.Dockerfile -t firewall-test . && docker run --rm firewall-test
-- Run integration: docker-compose up -d && docker exec firewall busted spec/gcra_integration_spec.lua
-- ============================================================================

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local gcra = require "firewall.gcra"

describe("gcra module", function()
    
    it("exports SCRIPT", function()
        assert.is_string(gcra.SCRIPT)
        assert.truthy(gcra.SCRIPT:find("KEYS%[1%]"))
    end)
    
    it("exports DEFAULTS", function()
        assert.is_table(gcra.DEFAULTS)
        assert.equals(1000, gcra.DEFAULTS.emission_interval)
        assert.equals(100000, gcra.DEFAULTS.burst)
        assert.equals("gcra:", gcra.DEFAULTS.key_prefix)
    end)
    
    it("exports check function", function()
        assert.is_function(gcra.check)
    end)
    
    it("exports check_direct function", function()
        assert.is_function(gcra.check_direct)
    end)
    
    it("exports load_script function", function()
        assert.is_function(gcra.load_script)
    end)
    
end)

describe("gcra SCRIPT logic", function()
    -- These tests verify the Redis Lua script behavior
    -- by manually simulating what Redis would do
    
    local function simulate_gcra(tat_store, key, emission_interval, burst, now, cost)
        -- Simulate the Redis Lua script
        local tat = tat_store[key] or now
        local new_tat = math.max(tat, now) + (emission_interval * cost)
        local allow_at = new_tat - burst
        
        if now < allow_at then
            return {0, math.ceil(allow_at - now), tat}
        else
            tat_store[key] = new_tat
            return {1, 0, new_tat}
        end
    end
    
    it("allows first request", function()
        local store = {}
        local result = simulate_gcra(store, "ip1", 1000, 10000, 1000000, 1)
        
        assert.equals(1, result[1])  -- allowed
        assert.equals(0, result[2])  -- no retry needed
    end)
    
    it("allows requests within burst", function()
        local store = {}
        -- Burst of 10 = 10000ms capacity
        -- 5 requests at cost 1 each = 5000ms consumed
        for i = 1, 5 do
            local result = simulate_gcra(store, "ip1", 1000, 10000, 1000000, 1)
            assert.equals(1, result[1], "request " .. i .. " should be allowed")
        end
    end)
    
    it("blocks when burst exceeded", function()
        local store = {}
        local now = 1000000
        
        -- Consume all 10 tokens (burst=10000, emission=1000)
        for i = 1, 10 do
            simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        end
        
        -- 11th request should be blocked
        local result = simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        assert.equals(0, result[1])  -- blocked
        assert.truthy(result[2] > 0)  -- retry_after > 0
    end)
    
    it("allows after waiting", function()
        local store = {}
        local now = 1000000
        
        -- Consume all tokens
        for i = 1, 10 do
            simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        end
        
        -- Blocked now
        local result1 = simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        assert.equals(0, result1[1])
        
        -- Wait for retry_after + buffer
        now = now + result1[2] + 100
        
        -- Now allowed
        local result2 = simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        assert.equals(1, result2[1])
    end)
    
    it("handles high cost requests", function()
        local store = {}
        local now = 1000000
        
        -- Request with cost=50 (half of burst=100)
        local result1 = simulate_gcra(store, "ip1", 1000, 100000, now, 50)
        assert.equals(1, result1[1])
        
        -- Another cost=50 should work
        local result2 = simulate_gcra(store, "ip1", 1000, 100000, now, 50)
        assert.equals(1, result2[1])
        
        -- Third cost=50 should be blocked (150 > 100 capacity)
        local result3 = simulate_gcra(store, "ip1", 1000, 100000, now, 50)
        assert.equals(0, result3[1])
    end)
    
    it("drains over time", function()
        local store = {}
        local now = 1000000
        
        -- Use 5 tokens
        for i = 1, 5 do
            simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        end
        
        -- Wait 3 seconds (3000ms) = 3 tokens refill
        now = now + 3000
        
        -- Should be able to use 8 more (5 used - 3 refilled + 8 new = 10 = burst)
        for i = 1, 8 do
            local result = simulate_gcra(store, "ip1", 1000, 10000, now, 1)
            assert.equals(1, result[1], "request " .. i .. " should be allowed")
        end
        
        -- 9th should fail
        local result = simulate_gcra(store, "ip1", 1000, 10000, now, 1)
        assert.equals(0, result[1])
    end)
    
end)

describe("check_direct with mock Redis", function()
    -- Builds a mock Redis that captures eval calls and returns a preset result.
    -- This tests that check_direct correctly wires args in and maps return values out,
    -- without needing a running Redis or the ngx.* context.
    local function mock_redis(eval_result)
        local captured = {}
        local red = {}
        function red:eval(script, num_keys, key, breakdown_key, ...)
            captured.script     = script
            captured.num_keys   = num_keys
            captured.key        = key
            captured.breakdown_key = breakdown_key
            captured.argv       = { ... }
            return eval_result
        end
        return red, captured
    end

    local BASE_CONFIG = { emission_interval = 1000, burst = 10000 }

    it("returns allowed=true and info when Redis says allowed", function()
        local tat = 1500000
        local red, _ = mock_redis({ 1, 0, tat, "" })

        local allowed, info = gcra.check_direct(red, "gcra:1.2.3.4", 1, BASE_CONFIG)

        assert.is_true(allowed)
        assert.equals(0,   info.retry_after)
        assert.equals(tat, info.tat)
        assert.equals("",  info.accumulated)
    end)

    it("returns allowed=false with retry_after when Redis says blocked", function()
        local red, _ = mock_redis({ 0, 3500, 1003500, "" })

        local allowed, info = gcra.check_direct(red, "gcra:1.2.3.4", 1, BASE_CONFIG)

        assert.is_false(allowed)
        assert.equals(3500, info.retry_after)
    end)

    it("fails open when Redis returns nil", function()
        local red, _ = mock_redis(nil)
        -- eval returns (nil, err_string) on failure; simulate that
        function red:eval(...)
            return nil, "ERR mock redis error"
        end

        local allowed, info = gcra.check_direct(red, "gcra:1.2.3.4", 1, BASE_CONFIG)

        assert.is_true(allowed)
        assert.is_string(info.error)
    end)

    it("passes correct ARGV order: emission_interval, burst, cost, audit_enabled", function()
        local red, captured = mock_redis({ 1, 0, 1001000, "" })

        gcra.check_direct(red, "gcra:1.2.3.4", 5, BASE_CONFIG)

        assert.equals(1000,    tonumber(captured.argv[1]))  -- emission_interval
        assert.equals(10000,   tonumber(captured.argv[2]))  -- burst
        assert.equals(5,       tonumber(captured.argv[3]))  -- cost
        assert.equals("0",     captured.argv[4])            -- audit_enabled=false
    end)

    it("passes audit_enabled=1 and breakdown pairs when audit is on", function()
        local config = { emission_interval = 1000, burst = 10000, audit_enabled = true }
        local breakdown = { ["rule:base"] = 1, ["rule:php-ext"] = 20 }
        local red, captured = mock_redis({ 1, 0, 1021000, "" })

        gcra.check_direct(red, "gcra:1.2.3.4", 21, config, breakdown)

        assert.equals("1", captured.argv[4])  -- audit_enabled=true
        -- ARGV[5..N] should contain breakdown pairs (rule, hits)
        assert.truthy(#captured.argv >= 7, "should have at least 2 breakdown pairs in ARGV")
    end)

    it("passes correct keys to eval", function()
        local red, captured = mock_redis({ 1, 0, 1001000, "" })

        gcra.check_direct(red, "gcra:10.0.0.1", 1, BASE_CONFIG)

        assert.equals(2,                        captured.num_keys)
        assert.equals("gcra:10.0.0.1",          captured.key)
        assert.equals("gcra:10.0.0.1:breakdown", captured.breakdown_key)
    end)

end)
