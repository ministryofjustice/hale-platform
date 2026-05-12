package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
local cidr = require "firewall.cidr"

describe("cidr.parse", function()
    it("parses a /8 CIDR", function()
        local e = cidr.parse("10.0.0.0/8")
        assert.is_not_nil(e)
        assert.equals(10 * 16777216, e.net)
        assert.equals(2 ^ 24, e.host_count)
    end)

    it("parses a /24 CIDR", function()
        local e = cidr.parse("192.168.1.0/24")
        assert.is_not_nil(e)
        assert.equals(192 * 16777216 + 168 * 65536 + 1 * 256, e.net)
        assert.equals(256, e.host_count)
    end)

    it("parses a /32 CIDR", function()
        local e = cidr.parse("1.2.3.4/32")
        assert.is_not_nil(e)
        assert.equals(1 * 16777216 + 2 * 65536 + 3 * 256 + 4, e.net)
        assert.equals(1, e.host_count)
    end)

    it("treats a bare IP as /32", function()
        local bare   = cidr.parse("1.2.3.4")
        local slash32 = cidr.parse("1.2.3.4/32")
        assert.is_not_nil(bare)
        assert.equals(bare.net,        slash32.net)
        assert.equals(bare.host_count, slash32.host_count)
    end)

    it("parses /0 (matches all addresses)", function()
        local e = cidr.parse("0.0.0.0/0")
        assert.is_not_nil(e)
        assert.equals(0, e.net)
        assert.equals(2 ^ 32, e.host_count)
    end)

    it("returns nil for an octet out of range", function()
        assert.is_nil(cidr.parse("256.0.0.0/8"))
        assert.is_nil(cidr.parse("10.0.999.0/24"))
    end)

    it("returns nil for a prefix out of range", function()
        assert.is_nil(cidr.parse("10.0.0.0/33"))
        assert.is_nil(cidr.parse("10.0.0.0/-1"))
    end)

    it("returns nil for non-IP strings", function()
        assert.is_nil(cidr.parse("not-an-ip"))
        assert.is_nil(cidr.parse(""))
        assert.is_nil(cidr.parse("10.0.0"))
    end)

    it("returns nil for non-string input", function()
        assert.is_nil(cidr.parse(nil))
        assert.is_nil(cidr.parse(123))
        assert.is_nil(cidr.parse({}))
    end)
end)

describe("cidr.contains", function()
    it("matches an IP within a /8 range", function()
        local list = { cidr.parse("10.0.0.0/8") }
        assert.is_true(cidr.contains(list, "10.0.0.1"))
        assert.is_true(cidr.contains(list, "10.255.255.255"))
    end)

    it("does not match an IP outside the range", function()
        local list = { cidr.parse("10.0.0.0/8") }
        assert.is_false(cidr.contains(list, "11.0.0.0"))
        assert.is_false(cidr.contains(list, "9.255.255.255"))
    end)

    it("matches a /32 (single host)", function()
        local list = { cidr.parse("192.168.1.5") }
        assert.is_true(cidr.contains(list, "192.168.1.5"))
        assert.is_false(cidr.contains(list, "192.168.1.6"))
    end)

    it("matches the network address and broadcast address of a /24", function()
        local list = { cidr.parse("192.168.1.0/24") }
        assert.is_true(cidr.contains(list, "192.168.1.0"))
        assert.is_true(cidr.contains(list, "192.168.1.255"))
        assert.is_false(cidr.contains(list, "192.168.2.0"))
        assert.is_false(cidr.contains(list, "192.168.0.255"))
    end)

    it("returns false for an empty list", function()
        assert.is_false(cidr.contains({}, "10.1.2.3"))
    end)

    it("returns false for a nil list", function()
        assert.is_false(cidr.contains(nil, "10.1.2.3"))
    end)

    it("returns false for an unparseable IP string", function()
        local list = { cidr.parse("10.0.0.0/8") }
        assert.is_false(cidr.contains(list, "not-an-ip"))
        assert.is_false(cidr.contains(list, ""))
    end)

    it("checks multiple entries and returns true on any match", function()
        local list = {
            cidr.parse("10.0.0.0/8"),
            cidr.parse("172.16.0.0/12"),
        }
        assert.is_true(cidr.contains(list,  "10.5.0.1"))
        assert.is_true(cidr.contains(list,  "172.20.0.1"))
        assert.is_false(cidr.contains(list, "192.168.0.1"))
    end)

    it("matches /0 (all addresses)", function()
        local list = { cidr.parse("0.0.0.0/0") }
        assert.is_true(cidr.contains(list, "1.2.3.4"))
        assert.is_true(cidr.contains(list, "255.255.255.255"))
    end)
end)
