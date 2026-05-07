-- ============================================================================
-- defaults module — pins the canonical firewall constants so accidental
-- edits to firewall/defaults.lua trip a test rather than only surfacing at
-- runtime. Also asserts that gcra.DEFAULTS / schema.DEFAULTS are the same
-- table as defaults.GCRA (re-export contract).
-- ============================================================================

package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local defaults = require "firewall.defaults"

describe("firewall.defaults", function()

    it("exports GCRA table with expected shape", function()
        assert.is_table(defaults.GCRA)
        assert.is_number(defaults.GCRA.emission_interval)
        assert.is_number(defaults.GCRA.burst)
        assert.is_number(defaults.GCRA.penalty_ttl)
        assert.is_boolean(defaults.GCRA.audit_enabled)
        assert.is_number(defaults.GCRA.audit_maxlen)
        assert.is_string(defaults.GCRA.mode)
    end)

    it("pins canonical GCRA values", function()
        assert.equals(100,     defaults.GCRA.emission_interval)
        assert.equals(150000,  defaults.GCRA.burst)
        assert.equals(600000,  defaults.GCRA.penalty_ttl)
        assert.equals(10000,   defaults.GCRA.audit_maxlen)
        assert.equals("monitor", defaults.GCRA.mode)
        assert.is_false(defaults.GCRA.audit_enabled)
    end)

    it("pins canonical Redis key constants", function()
        assert.equals("firewall:gcra:",  defaults.GCRA_KEY_PREFIX)
        assert.equals("firewall:allow:", defaults.ALLOW_KEY_PREFIX)
        assert.equals("firewall:block:", defaults.BLOCK_KEY_PREFIX)
        assert.equals("firewall:audit",  defaults.AUDIT_STREAM)
    end)

    it("pins PENALTY_404 and BLOCKED_CACHE_PREFIX", function()
        assert.equals(50,        defaults.PENALTY_404)
        assert.equals("blocked:", defaults.BLOCKED_CACHE_PREFIX)
    end)

    it("default mode is in the valid set", function()
        local schema = require "firewall.schema"
        assert.is_true(schema.VALID_MODES[defaults.GCRA.mode])
    end)

    it("gcra.DEFAULTS is the same table as defaults.GCRA", function()
        local gcra = require "firewall.gcra"
        assert.equals(defaults.GCRA, gcra.DEFAULTS)
    end)

    it("schema.DEFAULTS is the same table as defaults.GCRA", function()
        local schema = require "firewall.schema"
        assert.equals(defaults.GCRA, schema.DEFAULTS)
    end)

end)
