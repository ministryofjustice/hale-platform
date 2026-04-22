-- Example busted test suite
-- Run with: busted opt/lua/firewall/example_spec.lua

describe("example tests", function()

    it("passes: basic arithmetic", function()
        assert.are.equal(4, 2 + 2)
    end)

    it("fails: intentional failure example", function()
        assert.are.equal(5, 2 + 2)  -- 4 ~= 5, this will fail
    end)

end)
