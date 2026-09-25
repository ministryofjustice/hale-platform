package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local params = require "pagecache.params"

describe("pagecache.params.is_tracking", function()
    it("matches utm_ prefixed keys", function()
        assert.is_true(params.is_tracking("utm_source"))
        assert.is_true(params.is_tracking("utm_campaign"))
        assert.is_true(params.is_tracking("utm_anything_new"))
    end)

    it("matches click IDs and Relevanssi tracking", function()
        for _, k in ipairs({ "gclid", "dclid", "fbclid", "gad_source", "_rt", "_rt_nonce" }) do
            assert.is_true(params.is_tracking(k), k)
        end
    end)

    it("is case-insensitive", function()
        assert.is_true(params.is_tracking("UTM_Source"))
        assert.is_true(params.is_tracking("GCLID"))
    end)

    it("leaves real WordPress parameters alone", function()
        for _, k in ipairs({ "s", "p", "page_id", "paged", "orderby", "utm", "rt", "_rtx", "" }) do
            assert.is_false(params.is_tracking(k), k)
        end
    end)

    it("does not match bracketed scanner keys", function()
        assert.is_false(params.is_tracking("_rt_nonce%5B%24eq%5D"))
    end)
end)

describe("pagecache.params.strip", function()
    it("returns empty input unchanged", function()
        assert.same({ "", false }, { params.strip("") })
        assert.same({ "", false }, { params.strip(nil) })
    end)

    it("empties a query made only of tracking parameters", function()
        local q = "utm_campaign=probation_2627_localaction&utm_medium=audio&utm_source=spotify"
            .. "&utm_content=x&dclid=CjgKEAjw&gad_source=7"
        assert.same({ "", true }, { params.strip(q) })
    end)

    it("empties a Relevanssi click-tracking query", function()
        assert.same({ "", true }, { params.strip("_rt=NDF8NXx2aXByZWc&_rt_nonce=abc123") })
    end)

    it("keeps real parameters in their original order and encoding", function()
        assert.same({ "s=foo%20bar&paged=2", true },
            { params.strip("utm_source=x&s=foo%20bar&gclid=1&paged=2") })
    end)

    it("returns the original string when nothing matched", function()
        local q = "s=a&&b=2"
        local out, removed = params.strip(q)
        assert.equals(q, out)
        assert.is_false(removed)
    end)

    it("handles keys with no value", function()
        assert.same({ "preview", true }, { params.strip("utm_source&preview") })
    end)
end)
