package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local schema = require "firewall.schema"

-- ============================================================================
-- DEFAULTS
-- ============================================================================
describe("config DEFAULTS", function()
    it("has required GCRA fields", function()
        assert.is_number(schema.DEFAULTS.emission_interval)
        assert.is_number(schema.DEFAULTS.burst)
        assert.is_number(schema.DEFAULTS.penalty_ttl)
        assert.is_boolean(schema.DEFAULTS.audit_enabled)
        assert.is_number(schema.DEFAULTS.audit_maxlen)
    end)

    it("has mode defaulting to 'monitor'", function()
        assert.is_string(schema.DEFAULTS.mode)
        assert.equals("monitor", schema.DEFAULTS.mode)
    end)

    it("emission_interval is positive", function()
        assert.is_true(schema.DEFAULTS.emission_interval > 0)
    end)

    it("burst is non-negative", function()
        assert.is_true(schema.DEFAULTS.burst >= 0)
    end)

    it("penalty_ttl is non-negative", function()
        assert.is_true(schema.DEFAULTS.penalty_ttl >= 0)
    end)
end)

-- ============================================================================
-- VALID_MODES
-- ============================================================================
describe("config VALID_MODES", function()
    it("accepts enforce, monitor, off", function()
        assert.is_truthy(schema.VALID_MODES["enforce"])
        assert.is_truthy(schema.VALID_MODES["monitor"])
        assert.is_truthy(schema.VALID_MODES["off"])
    end)

    it("does not accept unknown keys", function()
        assert.is_falsy(schema.VALID_MODES["turbo"])
        assert.is_falsy(schema.VALID_MODES[""])
    end)
end)

-- ============================================================================
-- parse_config
-- ============================================================================
describe("parse_config", function()

    it("returns all defaults when raw is nil", function()
        local cfg, warns = schema.parse_config(nil)
        assert.equals(schema.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(schema.DEFAULTS.burst,             cfg.burst)
        assert.equals(schema.DEFAULTS.audit_enabled,     cfg.audit_enabled)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not found"))
    end)

    it("returns all defaults when raw is not a table", function()
        local cfg, warns = schema.parse_config("bad")
        assert.equals(schema.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not a JSON object"))
    end)

    it("uses valid numeric values from raw", function()
        local cfg, warns = schema.parse_config({ emission_interval = 500, burst = 5000 })
        assert.equals(500,  cfg.emission_interval)
        assert.equals(5000, cfg.burst)
        assert.equals(0,    #warns)
    end)

    it("coerces string numbers", function()
        local cfg, warns = schema.parse_config({ emission_interval = "200", burst = "2000" })
        assert.equals(200,  cfg.emission_interval)
        assert.equals(2000, cfg.burst)
        assert.equals(0, #warns)
    end)

    it("warns and defaults when emission_interval is zero", function()
        local cfg, warns = schema.parse_config({ emission_interval = 0, burst = 5000 })
        assert.equals(schema.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("emission_interval"))
    end)

    it("warns and defaults when emission_interval is negative", function()
        local cfg, warns = schema.parse_config({ emission_interval = -1, burst = 5000 })
        assert.equals(schema.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
    end)

    it("warns and defaults when emission_interval is a non-numeric string", function()
        local cfg, warns = schema.parse_config({ emission_interval = "abc", burst = 5000 })
        assert.equals(schema.DEFAULTS.emission_interval, cfg.emission_interval)
        assert.equals(1, #warns)
    end)

    it("allows burst = 0 without warning", function()
        local cfg, warns = schema.parse_config({ emission_interval = 1000, burst = 0 })
        assert.equals(0, cfg.burst)
        assert.equals(0, #warns)
    end)

    it("warns and defaults when burst is negative", function()
        local cfg, warns = schema.parse_config({ emission_interval = 1000, burst = -100 })
        assert.equals(schema.DEFAULTS.burst, cfg.burst)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("burst"))
    end)

    it("passes audit_enabled=true through", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, audit_enabled=true })
        assert.is_true(cfg.audit_enabled)
        assert.equals(0, #warns)
    end)

    it("floors decimal audit_maxlen", function()
        local cfg, _ = schema.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=500.9 })
        assert.equals(500, cfg.audit_maxlen)
    end)

    it("ignores invalid audit_maxlen, keeps default", function()
        local cfg, _ = schema.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=-1 })
        assert.equals(schema.DEFAULTS.audit_maxlen, cfg.audit_maxlen)
    end)

    it("accumulates multiple warnings for multiple bad fields", function()
        local _, warns = schema.parse_config({ emission_interval = "bad", burst = -1 })
        assert.equals(2, #warns)
    end)

    it("passes mode='enforce' through without warning", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, mode="enforce" })
        assert.equals("enforce", cfg.mode)
        assert.equals(0, #warns)
    end)

    it("passes mode='monitor' through without warning", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, mode="monitor" })
        assert.equals("monitor", cfg.mode)
        assert.equals(0, #warns)
    end)

    it("passes mode='off' through without warning", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, mode="off" })
        assert.equals("off", cfg.mode)
        assert.equals(0, #warns)
    end)

    it("warns and falls back to default on unknown mode", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, mode="turbo" })
        assert.equals(schema.DEFAULTS.mode, cfg.mode)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("mode"))
    end)

    it("partial merge: only mode key produces zero warnings", function()
        local cfg, warns = schema.parse_config({ mode="enforce" })
        assert.equals("enforce", cfg.mode)
        assert.equals(0, #warns)
    end)

    it("returns default penalty_ttl when absent", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000 })
        assert.equals(schema.DEFAULTS.penalty_ttl, cfg.penalty_ttl)
        assert.equals(0, #warns)
    end)

    it("passes valid penalty_ttl through", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, penalty_ttl=600000 })
        assert.equals(600000, cfg.penalty_ttl)
        assert.equals(0, #warns)
    end)

    it("allows penalty_ttl = 0 (disables penalty key)", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, penalty_ttl=0 })
        assert.equals(0, cfg.penalty_ttl)
        assert.equals(0, #warns)
    end)

    it("floors decimal penalty_ttl", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, penalty_ttl=600000.9 })
        assert.equals(600000, cfg.penalty_ttl)
        assert.equals(0, #warns)
    end)

    it("warns and defaults when penalty_ttl is negative", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, penalty_ttl=-1 })
        assert.equals(schema.DEFAULTS.penalty_ttl, cfg.penalty_ttl)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("penalty_ttl"))
    end)

    it("warns and defaults when penalty_ttl is non-numeric", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, penalty_ttl="bad" })
        assert.equals(schema.DEFAULTS.penalty_ttl, cfg.penalty_ttl)
        assert.equals(1, #warns)
    end)

end)

-- ============================================================================
-- parse_rules
-- ============================================================================
describe("parse_rules", function()

    it("returns nil and no warnings when raw is nil", function()
        local rules, warns = schema.parse_rules(nil)
        assert.is_nil(rules)
        assert.equals(0, #warns)
    end)

    it("returns nil and a warning when raw is not a table", function()
        local rules, warns = schema.parse_rules("bad")
        assert.is_nil(rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not a JSON array"))
    end)

    it("returns all rules when all are valid", function()
        local raw = {
            { id = "base",    cost = 1 },
            { id = "txt-ext", cost = 20 },
        }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(2, #rules)
        assert.equals(0, #warns)
    end)

    it("skips rule with non-numeric cost and warns", function()
        local raw = {
            { id = "base",  cost = 1 },
            { id = "bad",   cost = "notanumber" },
        }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals("base", rules[1].id)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("invalid cost"))
    end)

    it("skips rule with zero cost and warns", function()
        local raw = { { id = "base", cost = 0 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule with negative cost and warns", function()
        local raw = { { id = "base", cost = -5 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips non-table entry in rules array and warns", function()
        local raw = { { id = "base", cost = 1 }, "oops" }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not an object"))
    end)

    it("returns empty table for empty rules array", function()
        local rules, warns = schema.parse_rules({})
        assert.equals(0, #rules)
        assert.equals(0, #warns)
    end)

    it("preserves rule fields other than cost", function()
        local raw = {
            { id = "qs", cost = 4, enabled = false, conditions = { has_query = true } },
        }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.is_false(rules[1].enabled)
        assert.same({ has_query = true }, rules[1].conditions)
        assert.equals(0, #warns)
    end)

    it("skips rule with missing id and warns", function()
        local raw = { { cost = 1 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("missing or non%-string id"))
    end)

    it("skips rule with numeric id and warns", function()
        local raw = { { id = 42, cost = 1 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule with empty string id and warns", function()
        local raw = { { id = "", cost = 1 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
    end)

    it("skips rule where conditions is not a table and warns", function()
        local raw = { { id = "base", cost = 1, conditions = "bad" } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("conditions is not an object"))
    end)

    it("skips rule where conditions.uri_pattern is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { uri_pattern = 123 } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("uri_pattern"))
    end)

    it("skips rule where conditions.ua_pattern is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { ua_pattern = true } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("ua_pattern"))
    end)

    it("skips rule where conditions.query_pattern is not a string and warns", function()
        local raw = { { id = "probe", cost = 15, conditions = { query_pattern = 99 } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("query_pattern"))
    end)

    it("accepts rule with valid query_pattern string", function()
        local raw = { { id = "probe", cost = 15, conditions = { query_pattern = "^[a-z]{6}=[0-9]{6}$" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
        assert.equals("^[a-z]{6}=[0-9]{6}$", rules[1].conditions.query_pattern)
    end)

    it("skips rule where conditions.method is not a string and warns", function()
        local raw = { { id = "base", cost = 1, conditions = { method = 99 } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("method"))
    end)

    it("accepts rule with valid string conditions", function()
        local raw = { { id = "txt", cost = 20, conditions = { uri_pattern = "\\.txt$", method = "GET" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

end)

-- ============================================================================
-- STRICT VALIDATORS (admin write path)
-- ============================================================================
describe("validate_rules_strict", function()
    it("rejects non-table input", function()
        local r = schema.validate_rules_strict("not a table")
        assert.is_false(r.ok)
        assert.equals(1, #r.errors)
        assert.is_truthy(r.errors[1]:find("array"))
    end)

    it("rejects a JSON object where an array is expected", function()
        local r = schema.validate_rules_strict({ foo = "bar" })
        assert.is_false(r.ok)
        assert.is_truthy(r.errors[1]:find("array"))
    end)

    it("accepts an empty rules array and normalises it", function()
        local r = schema.validate_rules_strict({})
        assert.is_true(r.ok)
        assert.equals(0, #r.errors)
        assert.is_table(r.normalised)
    end)

    it("accepts a clean rules array", function()
        local r = schema.validate_rules_strict({ { id = "base", cost = 1 } })
        assert.is_true(r.ok)
        assert.equals(0, #r.errors)
        assert.equals(1, #r.normalised)
    end)

    it("promotes parse_rules warnings to errors", function()
        local r = schema.validate_rules_strict({ { id = "bad", cost = -1 } })
        assert.is_false(r.ok)
        assert.is_true(#r.errors >= 1)
        assert.is_truthy(r.errors[1]:find("cost"))
    end)
end)

describe("validate_config_strict", function()
    it("rejects non-table input", function()
        local r = schema.validate_config_strict("not a table")
        assert.is_false(r.ok)
        assert.is_truthy(r.errors[1]:find("object"))
    end)

    it("rejects a JSON array where an object is expected", function()
        local r = schema.validate_config_strict({ "a", "b", "c" })
        assert.is_false(r.ok)
        assert.is_truthy(r.errors[1]:find("array"))
    end)

    it("accepts an empty config and applies defaults", function()
        local r = schema.validate_config_strict({})
        assert.is_true(r.ok)
        assert.equals(0, #r.errors)
        assert.equals(schema.DEFAULTS.mode, r.normalised.mode)
    end)

    it("rejects unknown keys (catches typos)", function()
        local r = schema.validate_config_strict({ burts = 50000 })
        assert.is_false(r.ok)
        local found = false
        for _, e in ipairs(r.errors) do
            if e:find("burts") then found = true end
        end
        assert.is_true(found)
    end)

    it("promotes parse_config warnings to errors", function()
        local r = schema.validate_config_strict({ emission_interval = -10 })
        assert.is_false(r.ok)
        assert.is_truthy(r.errors[1]:find("emission_interval"))
    end)

    it("accepts a clean config and returns normalised values", function()
        local r = schema.validate_config_strict({
            emission_interval = 500,
            burst = 50000,
            mode = "enforce",
        })
        assert.is_true(r.ok)
        assert.equals(0, #r.errors)
        assert.equals(500, r.normalised.emission_interval)
        assert.equals("enforce", r.normalised.mode)
    end)
end)

-- ============================================================================
-- STRICT VALIDATORS — table-driven failure payloads
-- ============================================================================
-- Each entry exercises the strict path with input that should be rejected.
-- The match string is asserted against the joined error list so re-wording
-- a single error message in parse_* doesn't silently weaken these tests.
-- ============================================================================
local cjson = require "cjson.safe"

local function _errors_string(r)
    return table.concat(r.errors or {}, " | ")
end

describe("validate_rules_strict — failing payloads", function()
    local cases = {
        { name = "nil",                    payload = nil,                                       match = "array" },
        { name = "number",                 payload = 42,                                        match = "array" },
        { name = "boolean",                payload = true,                                      match = "array" },
        { name = "JSON object",            payload = { foo = "bar" },                           match = "array" },
        { name = "rule is a string",       payload = { "not a rule" },                          match = "not an object" },
        { name = "rule is a number",       payload = { 99 },                                    match = "not an object" },
        { name = "missing id",             payload = { { cost = 1 } },                          match = "id" },
        { name = "empty string id",        payload = { { id = "", cost = 1 } },                 match = "id" },
        { name = "non-string id",          payload = { { id = 42, cost = 1 } },                 match = "id" },
        { name = "missing cost",           payload = { { id = "x" } },                          match = "cost" },
        { name = "negative cost",          payload = { { id = "x", cost = -1 } },               match = "cost" },
        { name = "zero cost",              payload = { { id = "x", cost = 0 } },                match = "cost" },
        { name = "string cost",            payload = { { id = "x", cost = "5" } },              match = "cost" },
        { name = "conditions not object",  payload = { { id = "x", cost = 1, conditions = "y" } }, match = "conditions" },
        { name = "uri_pattern not string", payload = { { id = "x", cost = 1, conditions = { uri_pattern = 5 } } }, match = "uri_pattern" },
        { name = "ua_pattern not string",  payload = { { id = "x", cost = 1, conditions = { ua_pattern  = {} } } }, match = "ua_pattern" },
        { name = "method not string",      payload = { { id = "x", cost = 1, conditions = { method      = 1 } } }, match = "method" },
        { name = "second rule bad",        payload = { { id = "ok", cost = 1 }, { id = "bad", cost = -1 } },        match = "cost" },
        { name = "enabled is string",      payload = { { id = "x", cost = 1, enabled = "falsse" } },                match = "enabled" },
        { name = "enabled is number",      payload = { { id = "x", cost = 1, enabled = 0 } },                       match = "enabled" },
        { name = "unknown rule key",       payload = { { id = "x", cost = 1, cosst = 5 } },                         match = "cosst" },
        { name = "unknown condition key",  payload = { { id = "x", cost = 1, conditions = { uri = "/foo" } } },     match = "uri" },
    }

    for _, case in ipairs(cases) do
        it("rejects: " .. case.name, function()
            local r = schema.validate_rules_strict(case.payload)
            assert.is_false(r.ok, "expected ok=false for " .. case.name)
            assert.is_true(#r.errors >= 1, "expected at least one error for " .. case.name)
            assert.is_truthy(_errors_string(r):find(case.match),
                "expected error to mention '" .. case.match .. "' for " .. case.name
                .. ", got: " .. _errors_string(r))
        end)
    end
end)

describe("validate_config_strict — failing payloads", function()
    local cases = {
        { name = "nil",                       payload = nil,                                  match = "object" },
        { name = "string",                    payload = "hello",                              match = "object" },
        { name = "number",                    payload = 7,                                    match = "object" },
        { name = "JSON array",                payload = { 1, 2, 3 },                          match = "array" },
        { name = "unknown key (typo)",        payload = { burts = 100 },                      match = "burts" },
        { name = "two unknown keys",          payload = { foo = 1, bar = 2 },                 match = "foo" },
        { name = "emission_interval = 0",     payload = { emission_interval = 0 },            match = "emission_interval" },
        { name = "emission_interval string",  payload = { emission_interval = "fast" },       match = "emission_interval" },
        { name = "burst negative",            payload = { burst = -1 },                       match = "burst" },
        { name = "mode unknown",              payload = { mode = "panic" },                   match = "mode" },
        { name = "mode wrong type",           payload = { mode = true },                      match = "mode" },
        { name = "penalty_ttl negative",      payload = { penalty_ttl = -5 },                 match = "penalty_ttl" },
        { name = "unknown key + bad value",   payload = { foo = 1, mode = "panic" },          match = "mode" },
    }

    for _, case in ipairs(cases) do
        it("rejects: " .. case.name, function()
            local r = schema.validate_config_strict(case.payload)
            assert.is_false(r.ok, "expected ok=false for " .. case.name)
            assert.is_true(#r.errors >= 1, "expected at least one error for " .. case.name)
            assert.is_truthy(_errors_string(r):find(case.match),
                "expected error to mention '" .. case.match .. "' for " .. case.name
                .. ", got: " .. _errors_string(r))
        end)
    end

    it("collects multiple errors in one pass (does not bail on first)", function()
        local r = schema.validate_config_strict({
            foo = 1,
            burst = -1,
            mode = "panic",
        })
        assert.is_false(r.ok)
        assert.is_true(#r.errors >= 3,
            "expected >=3 errors, got " .. #r.errors .. ": " .. _errors_string(r))
    end)
end)

-- ============================================================================
-- Round-trip via cjson — exercises the path the HTTP endpoint takes
-- ============================================================================
describe("strict validators via JSON round-trip", function()
    local function decode_and_validate_rules(json_str)
        local decoded = cjson.decode(json_str)
        return schema.validate_rules_strict(decoded)
    end
    local function decode_and_validate_config(json_str)
        local decoded = cjson.decode(json_str)
        return schema.validate_config_strict(decoded)
    end

    it("rules: accepts the example from the schema docstring", function()
        local r = decode_and_validate_rules([[
            [
              {"id":"base",        "cost":1},
              {"id":"query-string","cost":4,  "conditions":{"has_query":true}},
              {"id":"txt-ext",     "cost":20, "conditions":{"uri_pattern":"\\.txt$"}},
              {"id":"post",        "cost":2,  "conditions":{"method":"POST"}},
              {"id":"bad-bot",     "cost":50, "conditions":{"ua_pattern":"zgrab|masscan"}}
            ]
        ]])
        assert.is_true(r.ok, _errors_string(r))
        assert.equals(5, #r.normalised)
    end)

    it("config: accepts the example from the schema docstring", function()
        local r = decode_and_validate_config(
            [[{"emission_interval":500,"burst":50000,"audit_enabled":true,"audit_maxlen":5000}]])
        assert.is_true(r.ok, _errors_string(r))
        assert.equals(500, r.normalised.emission_interval)
        assert.equals(true, r.normalised.audit_enabled)
        assert.equals(5000, r.normalised.audit_maxlen)
    end)

    it("rules: rejects a JSON object posted where an array was expected", function()
        local r = decode_and_validate_rules('{"id":"base","cost":1}')
        assert.is_false(r.ok)
        assert.is_truthy(_errors_string(r):find("array"))
    end)

    it("config: rejects a JSON array posted where an object was expected", function()
        local r = decode_and_validate_config('[1,2,3]')
        assert.is_false(r.ok)
        assert.is_truthy(_errors_string(r):find("array"))
    end)

    it("config: rejects a payload with both an unknown key and a bad value", function()
        local r = decode_and_validate_config([[{"burts":50000,"mode":"panic"}]])
        assert.is_false(r.ok)
        local s = _errors_string(r)
        assert.is_truthy(s:find("burts"))
        assert.is_truthy(s:find("mode"))
    end)
end)
