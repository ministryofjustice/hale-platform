package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local config_mod = require "firewall.config"

-- ============================================================================
-- DEFAULTS
-- ============================================================================
describe("config DEFAULTS", function()
    it("has required GCRA fields", function()
        assert.is_number(config_mod.DEFAULTS.emission_interval)
        assert.is_number(config_mod.DEFAULTS.burst)
        assert.is_boolean(config_mod.DEFAULTS.audit_enabled)
        assert.is_string(config_mod.DEFAULTS.audit_stream)
        assert.is_number(config_mod.DEFAULTS.audit_maxlen)
    end)

    it("emission_interval is positive", function()
        assert.is_true(config_mod.DEFAULTS.emission_interval > 0)
    end)

    it("burst is non-negative", function()
        assert.is_true(config_mod.DEFAULTS.burst >= 0)
    end)
end)

-- ============================================================================
-- parse_config
-- ============================================================================
describe("parse_config", function()

    it("returns all defaults when raw is nil", function()
        local cfg, warns = config_mod.parse_config(nil)
        assert.equals(config_mod.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(config_mod.DEFAULTS.burst,             cfg.burst)
        assert.equals(config_mod.DEFAULTS.audit_enabled,     cfg.audit_enabled)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not found"))
    end)

    it("returns all defaults when raw is not a table", function()
        local cfg, warns = config_mod.parse_config("bad")
        assert.equals(config_mod.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not a JSON object"))
    end)

    it("uses valid numeric values from raw", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = 500, burst = 5000 })
        assert.equals(500,  cfg.emission_interval)
        assert.equals(5000, cfg.burst)
        assert.equals(0,    #warns)
    end)

    it("coerces string numbers", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = "200", burst = "2000" })
        assert.equals(200,  cfg.emission_interval)
        assert.equals(2000, cfg.burst)
        assert.equals(0, #warns)
    end)

    it("warns and defaults when emission_interval is zero", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = 0, burst = 5000 })
        assert.equals(config_mod.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("emission_interval"))
    end)

    it("warns and defaults when emission_interval is negative", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = -1, burst = 5000 })
        assert.equals(config_mod.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
    end)

    it("warns and defaults when emission_interval is a non-numeric string", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = "abc", burst = 5000 })
        assert.equals(config_mod.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
    end)

    it("allows burst = 0 without warning", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = 1000, burst = 0 })
        assert.equals(0, cfg.burst)
        assert.equals(0, #warns)
    end)

    it("warns and defaults when burst is negative", function()
        local cfg, warns = config_mod.parse_config({ emission_interval = 1000, burst = -100 })
        assert.equals(config_mod.DEFAULTS.burst, cfg.burst)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("burst"))
    end)

    it("passes audit_enabled=true through", function()
        local cfg, warns = config_mod.parse_config({ emission_interval=1000, burst=1000, audit_enabled=true })
        assert.is_true(cfg.audit_enabled)
        assert.equals(0, #warns)
    end)

    it("uses custom audit_stream", function()
        local cfg, _ = config_mod.parse_config({ emission_interval=1000, burst=1000, audit_stream="my:stream" })
        assert.equals("my:stream", cfg.audit_stream)
    end)

    it("ignores empty string audit_stream, keeps default", function()
        local cfg, _ = config_mod.parse_config({ emission_interval=1000, burst=1000, audit_stream="" })
        assert.equals(config_mod.DEFAULTS.audit_stream, cfg.audit_stream)
    end)

    it("floors decimal audit_maxlen", function()
        local cfg, _ = config_mod.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=500.9 })
        assert.equals(500, cfg.audit_maxlen)
    end)

    it("ignores invalid audit_maxlen, keeps default", function()
        local cfg, _ = config_mod.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=-1 })
        assert.equals(config_mod.DEFAULTS.audit_maxlen, cfg.audit_maxlen)
    end)

    it("accumulates multiple warnings for multiple bad fields", function()
        local _, warns = config_mod.parse_config({ emission_interval = "bad", burst = -1 })
        assert.equals(2, #warns)
    end)

end)

-- ============================================================================
-- parse_rules
-- ============================================================================
describe("parse_rules", function()

    it("returns nil and no warnings when raw is nil", function()
        local rules, warns = config_mod.parse_rules(nil)
        assert.is_nil(rules)
        assert.equals(0, #warns)
    end)

    it("returns nil and a warning when raw is not a table", function()
        local rules, warns = config_mod.parse_rules("bad")
        assert.is_nil(rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not a JSON array"))
    end)

    it("returns all rules when all are valid", function()
        local raw = {
            { id = "base",    cost = 1 },
            { id = "txt-ext", cost = 20 },
        }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(2, #rules)
        assert.equals(0, #warns)
    end)

    it("skips rule with non-numeric cost and warns", function()
        local raw = {
            { id = "base",  cost = 1 },
            { id = "bad",   cost = "notanumber" },
        }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals("base", rules[1].id)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("invalid cost"))
    end)

    it("skips rule with zero cost and warns", function()
        local raw = { { id = "base", cost = 0 } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule with negative cost and warns", function()
        local raw = { { id = "base", cost = -5 } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips non-table entry in rules array and warns", function()
        local raw = { { id = "base", cost = 1 }, "oops" }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not an object"))
    end)

    it("returns empty table for empty rules array", function()
        local rules, warns = config_mod.parse_rules({})
        assert.equals(0, #rules)
        assert.equals(0, #warns)
    end)

    it("preserves rule fields other than cost", function()
        local raw = {
            { id = "qs", cost = 4, enabled = false, conditions = { has_query = true } },
        }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(1, #rules)
        assert.is_false(rules[1].enabled)
        assert.same({ has_query = true }, rules[1].conditions)
        assert.equals(0, #warns)
    end)

    it("skips rule with missing id and warns", function()
        local raw = { { cost = 1 } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("missing or non%-string id"))
    end)

    it("skips rule with numeric id and warns", function()
        local raw = { { id = 42, cost = 1 } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule with empty string id and warns", function()
        local raw = { { id = "", cost = 1 } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule where conditions is not a table and warns", function()
        local raw = { { id = "base", cost = 1, conditions = "bad" } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("conditions is not an object"))
    end)

    it("skips rule where conditions.uri_pattern is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { uri_pattern = 123 } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("uri_pattern"))
    end)

    it("skips rule where conditions.ua_pattern is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { ua_pattern = true } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("ua_pattern"))
    end)

    it("skips rule where conditions.query_pattern is not a string and warns", function()
        local raw = { { id = "probe", cost = 15, conditions = { query_pattern = 99 } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("query_pattern"))
    end)

    it("accepts rule with valid query_pattern string", function()
        local raw = { { id = "probe", cost = 15, conditions = { query_pattern = "^[a-z]{6}=[0-9]{6}$" } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
        assert.equals("^[a-z]{6}=[0-9]{6}$", rules[1].conditions.query_pattern)
    end)

    it("skips rule where conditions.method is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { method = 99 } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("method"))
    end)

    it("accepts rule with valid string conditions", function()
        local raw = { { id = "txt", cost = 20, conditions = { uri_pattern = "\\.txt$", method = "GET" } } }
        local rules, warns = config_mod.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

end)
