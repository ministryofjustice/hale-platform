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
-- VALID_MODES / VALID_PHASES
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

describe("rule VALID_PHASES", function()
    it("accepts req and res", function()
        assert.is_truthy(schema.VALID_PHASES["req"])
        assert.is_truthy(schema.VALID_PHASES["res"])
    end)

    it("does not accept unknown phases", function()
        assert.is_falsy(schema.VALID_PHASES["log"])
        assert.is_falsy(schema.VALID_PHASES[""])
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

    it("passes audit_enabled=false through", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, audit_enabled=false })
        assert.is_false(cfg.audit_enabled)
        assert.equals(0, #warns)
    end)

    it("warns when audit_enabled is a string", function()
        local cfg, warns = schema.parse_config({ audit_enabled="false" })
        assert.equals(schema.DEFAULTS.audit_enabled, cfg.audit_enabled)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("audit_enabled"))
    end)

    it("warns when audit_enabled is a number", function()
        local cfg, warns = schema.parse_config({ audit_enabled=1 })
        assert.equals(schema.DEFAULTS.audit_enabled, cfg.audit_enabled)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("audit_enabled"))
    end)

    it("floors decimal audit_maxlen", function()
        local cfg, _ = schema.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=500.9 })
        assert.equals(500, cfg.audit_maxlen)
    end)

    it("warns on audit_maxlen <= 0, keeps default", function()
        local cfg, warns = schema.parse_config({ emission_interval=1000, burst=1000, audit_maxlen=-1 })
        assert.equals(schema.DEFAULTS.audit_maxlen, cfg.audit_maxlen)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("audit_maxlen"))
    end)

    it("warns on non-numeric audit_maxlen, keeps default", function()
        local cfg, warns = schema.parse_config({ audit_maxlen="lots" })
        assert.equals(schema.DEFAULTS.audit_maxlen, cfg.audit_maxlen)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("audit_maxlen"))
    end)

    it("does not warn when audit_maxlen is absent", function()
        local _, warns = schema.parse_config({})
        assert.equals(0, #warns)
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
-- parse_rules — phased rules
-- ============================================================================
-- Helper to build a minimal valid rule for the given phase (req|res).
local function _req_rule(name, cost, match)
    return { name = name, phase = "req", cost = cost, match = match or { uri_pattern = "x" } }
end

local function _res_rule(name, cost, status)
    return { name = name, phase = "res", cost = cost, match = { status = status or 404 } }
end

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

    it("returns empty table for empty rules array", function()
        local rules, warns = schema.parse_rules({})
        assert.equals(0, #rules)
        assert.equals(0, #warns)
    end)

    it("returns all rules when all are valid (mixed phases)", function()
        local raw = {
            _req_rule("base", 1, { uri_pattern = "\\.php$" }),
            _req_rule("txt-ext", 20, { uri_pattern = "\\.txt$" }),
            _res_rule("res-404", 50, 404),
        }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(3, #rules)
        assert.equals(0, #warns)
    end)

    it("preserves match and other rule fields verbatim", function()
        local raw = { _req_rule("qs", 4, { has_query = true }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals("qs",   rules[1].name)
        assert.equals("req",  rules[1].phase)
        assert.equals(4,      rules[1].cost)
        assert.same({ has_query = true }, rules[1].match)
        assert.equals(0, #warns)
    end)

    -- name --------------------------------------------------------------------

    it("skips rule with missing name and warns", function()
        local raw = { { phase = "req", cost = 1, match = { uri_pattern = "x" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("name"))
    end)

    it("skips rule with non-string name", function()
        local raw = { { name = 42, phase = "req", cost = 1, match = { uri_pattern = "x" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("name"))
    end)

    it("skips rule with empty name", function()
        local raw = { _req_rule("", 1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("name"))
    end)

    it("skips rule with name containing invalid charset (uppercase)", function()
        local raw = { _req_rule("BadName", 1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("charset"))
    end)

    it("skips rule with name containing colon", function()
        local raw = { _req_rule("a:b", 1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("charset"))
    end)

    it("skips rule with name longer than 64 chars", function()
        local long = string.rep("a", 65)
        local raw = { _req_rule(long, 1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("64"))
    end)

    it("accepts a 64-char name at the boundary", function()
        local exact = string.rep("a", 64)
        local raw = { _req_rule(exact, 1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

    it("skips duplicate names within the array", function()
        local raw = { _req_rule("dupe", 1), _req_rule("dupe", 2) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("duplicated"))
    end)

    -- phase -------------------------------------------------------------------

    it("skips rule with missing phase", function()
        local raw = { { name = "x", cost = 1, match = { uri_pattern = "y" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("phase"))
    end)

    it("skips rule with unknown phase", function()
        local raw = { { name = "x", phase = "log", cost = 1, match = { uri_pattern = "y" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("phase"))
    end)

    -- cost --------------------------------------------------------------------

    it("skips rule with missing cost", function()
        local raw = { { name = "x", phase = "req", match = { uri_pattern = "y" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("cost"))
    end)

    it("accepts cost = 0 (audit-only)", function()
        local raw = { _req_rule("audit-only", 0) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

    it("skips rule with negative cost", function()
        local raw = { _req_rule("bad", -1) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("cost"))
    end)

    it("skips rule with non-integer cost", function()
        local raw = { _req_rule("bad", 1.5) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("cost"))
    end)

    it("skips rule with cost above 99999", function()
        local raw = { _req_rule("bad", 100000) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("cost"))
    end)

    it("accepts cost at the 99999 ceiling", function()
        local raw = { _req_rule("max", 99999) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

    -- match -------------------------------------------------------------------

    it("skips rule with missing match", function()
        local raw = { { name = "x", phase = "req", cost = 1 } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("match"))
    end)

    it("skips rule with non-object match", function()
        local raw = { { name = "x", phase = "req", cost = 1, match = "bad" } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("match"))
    end)

    it("skips rule with empty match (no predicates)", function()
        local raw = { { name = "x", phase = "req", cost = 1, match = {} } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("predicate"))
    end)

    -- req-phase predicates ----------------------------------------------------

    it("skips req-rule whose match.uri_pattern is not a string", function()
        local raw = { _req_rule("x", 1, { uri_pattern = 5 }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("uri_pattern"))
    end)

    it("skips req-rule whose match.ua_pattern is not a string", function()
        local raw = { _req_rule("x", 1, { ua_pattern = {} }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("ua_pattern"))
    end)

    it("skips req-rule whose match.query_pattern is not a string", function()
        local raw = { _req_rule("x", 1, { query_pattern = 99 }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("query_pattern"))
    end)

    it("accepts req-rule with valid query_pattern string", function()
        local raw = { _req_rule("probe", 15, { query_pattern = "^[a-z]{6}=[0-9]{6}$" }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
        assert.equals("^[a-z]{6}=[0-9]{6}$", rules[1].match.query_pattern)
    end)

    it("skips req-rule whose match.method is not a string", function()
        local raw = { _req_rule("x", 1, { method = 99 }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("method"))
    end)

    it("skips req-rule whose match.has_query is not a boolean", function()
        local raw = { _req_rule("x", 1, { has_query = "yes" }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("has_query"))
    end)

    it("skips req-rule with unknown match key", function()
        local raw = { _req_rule("x", 1, { uri_path = "/foo" }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("uri_path"))
    end)

    it("rejects res-only predicate on a req-phase rule", function()
        local raw = { _req_rule("x", 1, { status = 404 }) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("status"))
    end)

    -- res-phase predicates ----------------------------------------------------

    it("accepts res-rule with valid status", function()
        local raw = { _res_rule("res-404", 50, 404) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(0, #warns)
    end)

    it("skips res-rule with non-integer status", function()
        local raw = { { name = "x", phase = "res", cost = 1, match = { status = 200.5 } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("status"))
    end)

    it("skips res-rule with status below 100", function()
        local raw = { _res_rule("x", 1, 99) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("status"))
    end)

    it("skips res-rule with status above 599", function()
        local raw = { _res_rule("x", 1, 600) }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("status"))
    end)

    it("rejects req-only predicate on a res-phase rule", function()
        local raw = { { name = "x", phase = "res", cost = 1, match = { uri_pattern = "/foo" } } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("uri_pattern"))
    end)

    -- top-level unknown keys --------------------------------------------------

    it("skips rule with unknown top-level key", function()
        local raw = { {
            name = "x", phase = "req", cost = 1,
            match = { uri_pattern = "y" }, action = "block",
        } }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(0, #rules)
        assert.is_truthy(warns[1]:find("action"))
    end)

    it("skips non-table entry in rules array", function()
        local raw = { _req_rule("ok", 1), "oops" }
        local rules, warns = schema.parse_rules(raw)
        assert.equals(1, #rules)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not an object"))
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
        local r = schema.validate_rules_strict({ _req_rule("base", 1) })
        assert.is_true(r.ok)
        assert.equals(0, #r.errors)
        assert.equals(1, #r.normalised)
    end)

    it("promotes parse_rules warnings to errors", function()
        local r = schema.validate_rules_strict({ _req_rule("bad", -1) })
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
local cjson = require "cjson.safe"

local function _errors_string(r)
    return table.concat(r.errors or {}, " | ")
end

describe("validate_rules_strict — failing payloads", function()
    local cases = {
        { name = "nil",                   payload = nil,                                    match = "array" },
        { name = "number",                payload = 42,                                     match = "array" },
        { name = "boolean",               payload = true,                                   match = "array" },
        { name = "JSON object",           payload = { foo = "bar" },                        match = "array" },
        { name = "rule is a string",      payload = { "not a rule" },                       match = "not an object" },
        { name = "rule is a number",      payload = { 99 },                                 match = "not an object" },
        { name = "missing name",          payload = { { phase = "req", cost = 1, match = { uri_pattern = "y" } } },          match = "name" },
        { name = "empty name",            payload = { _req_rule("", 1) },                                                    match = "name" },
        { name = "non-string name",       payload = { { name = 42, phase = "req", cost = 1, match = { uri_pattern = "y" } } }, match = "name" },
        { name = "name with uppercase",   payload = { _req_rule("Bad", 1) },                                                  match = "charset" },
        { name = "duplicate name",        payload = { _req_rule("dupe", 1), _req_rule("dupe", 2) },                           match = "duplicated" },
        { name = "missing phase",         payload = { { name = "x", cost = 1, match = { uri_pattern = "y" } } },              match = "phase" },
        { name = "unknown phase",         payload = { { name = "x", phase = "log", cost = 1, match = { uri_pattern = "y" } } }, match = "phase" },
        { name = "missing cost",          payload = { { name = "x", phase = "req", match = { uri_pattern = "y" } } },         match = "cost" },
        { name = "negative cost",         payload = { _req_rule("x", -1) },                                                   match = "cost" },
        { name = "non-integer cost",      payload = { _req_rule("x", 1.5) },                                                  match = "cost" },
        { name = "cost above ceiling",    payload = { _req_rule("x", 100000) },                                               match = "cost" },
        { name = "string cost",           payload = { { name = "x", phase = "req", cost = "5", match = { uri_pattern = "y" } } }, match = "cost" },
        { name = "missing match",         payload = { { name = "x", phase = "req", cost = 1 } },                              match = "match" },
        { name = "match not object",      payload = { { name = "x", phase = "req", cost = 1, match = "y" } },                 match = "match" },
        { name = "empty match",           payload = { { name = "x", phase = "req", cost = 1, match = {} } },                  match = "predicate" },
        { name = "uri_pattern not string",payload = { _req_rule("x", 1, { uri_pattern = 5 }) },                                match = "uri_pattern" },
        { name = "ua_pattern not string", payload = { _req_rule("x", 1, { ua_pattern  = {} }) },                               match = "ua_pattern" },
        { name = "method not string",     payload = { _req_rule("x", 1, { method      = 1 }) },                                match = "method" },
        { name = "has_query not bool",    payload = { _req_rule("x", 1, { has_query   = "y" }) },                              match = "has_query" },
        { name = "unknown rule key",      payload = { { name = "x", phase = "req", cost = 1, match = { uri_pattern = "y" }, cosst = 5 } }, match = "cosst" },
        { name = "unknown match key",     payload = { _req_rule("x", 1, { uri = "/foo" }) },                                   match = "uri" },
        { name = "res-rule status low",   payload = { _res_rule("x", 1, 50) },                                                 match = "status" },
        { name = "res-rule status high",  payload = { _res_rule("x", 1, 700) },                                                match = "status" },
        { name = "cross-phase predicate", payload = { _req_rule("x", 1, { status = 404 }) },                                   match = "status" },
        { name = "second rule bad",       payload = { _req_rule("ok", 1), _req_rule("bad", -1) },                              match = "cost" },
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
              {"name":"req-base",        "phase":"req","cost":1,
                 "match":{"uri_pattern":"\\.php$"}},
              {"name":"req-query-string","phase":"req","cost":4,
                 "match":{"has_query":true}},
              {"name":"req-txt-ext",     "phase":"req","cost":20,
                 "match":{"uri_pattern":"\\.txt$"}},
              {"name":"req-post",        "phase":"req","cost":2,
                 "match":{"method":"POST"}},
              {"name":"req-bad-bot",     "phase":"req","cost":50,
                 "match":{"ua_pattern":"zgrab|masscan"}},
              {"name":"res-404",         "phase":"res","cost":50,
                 "match":{"status":404}},
              {"name":"res-499",         "phase":"res","cost":25,
                 "match":{"status":499}}
            ]
        ]])
        assert.is_true(r.ok, _errors_string(r))
        assert.equals(7, #r.normalised)
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
        local r = decode_and_validate_rules('{"name":"x","phase":"req","cost":1,"match":{"uri_pattern":"y"}}')
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

-- ============================================================================
-- parse_allowlist / parse_blocklist
-- ============================================================================
describe("parse_allowlist", function()
    it("returns empty list for nil input", function()
        local list, warns = schema.parse_allowlist(nil)
        assert.same({}, list)
        assert.same({}, warns)
    end)

    it("accepts valid CIDRs and bare IPs", function()
        local list, warns = schema.parse_allowlist({
            "10.0.0.0/8", "192.168.1.0/24", "172.16.5.5",
        })
        assert.equals(3, #list)
        assert.same({}, warns)
    end)

    it("skips invalid entries with a warning", function()
        local list, warns = schema.parse_allowlist({ "10.0.0.0/8", "not-valid", "1.2.3.4" })
        assert.equals(2, #list)
        assert.equals(1, #warns)
        assert.is_truthy(warns[1]:find("not%-valid"))
    end)

    it("skips non-string entries", function()
        local list, warns = schema.parse_allowlist({ 123, "10.0.0.0/8" })
        assert.equals(1, #list)
        assert.equals(1, #warns)
    end)

    it("skips empty-string entries", function()
        local list, warns = schema.parse_allowlist({ "", "10.0.0.0/8" })
        assert.equals(1, #list)
        assert.equals(1, #warns)
    end)

    it("warns when input is not a table", function()
        local list, warns = schema.parse_allowlist("10.0.0.0/8")
        assert.same({}, list)
        assert.equals(1, #warns)
    end)
end)

describe("parse_blocklist", function()
    it("accepts valid CIDRs and bare IPs", function()
        local list, warns = schema.parse_blocklist({ "203.0.113.0/24", "198.51.100.1" })
        assert.equals(2, #list)
        assert.same({}, warns)
    end)

    it("returns empty list for nil input", function()
        local list, warns = schema.parse_blocklist(nil)
        assert.same({}, list)
        assert.same({}, warns)
    end)

    it("skips entries with invalid prefix", function()
        local list, warns = schema.parse_blocklist({ "10.0.0.0/33" })
        assert.equals(0, #list)
        assert.equals(1, #warns)
    end)
end)

describe("validate_allowlist_strict", function()
    it("returns ok=true for a valid list", function()
        local r = schema.validate_allowlist_strict({ "10.0.0.0/8", "192.168.0.1" })
        assert.is_true(r.ok)
        assert.equals(2, #r.normalised)
    end)

    it("returns ok=false for a non-array", function()
        local r = schema.validate_allowlist_strict("10.0.0.0/8")
        assert.is_false(r.ok)
    end)

    it("returns ok=false when any entry is invalid", function()
        local r = schema.validate_allowlist_strict({ "10.0.0.0/8", "bad!" })
        assert.is_false(r.ok)
        assert.equals(1, #r.errors)
    end)

    it("returns ok=true for an empty array", function()
        local r = schema.validate_allowlist_strict({})
        assert.is_true(r.ok)
    end)
end)

describe("validate_blocklist_strict", function()
    it("returns ok=true for a valid list", function()
        local r = schema.validate_blocklist_strict({ "203.0.113.0/24" })
        assert.is_true(r.ok)
        assert.equals(1, #r.normalised)
    end)

    it("returns ok=false when any entry is invalid", function()
        local r = schema.validate_blocklist_strict({ "300.0.0.0/8" })
        assert.is_false(r.ok)
    end)
end)
