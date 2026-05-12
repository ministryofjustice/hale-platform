-- luacheck configuration for the OpenResty firewall modules + busted test suite.
-- https://luacheck.readthedocs.io/en/stable/config.html

-- OpenResty injects `ngx` as a global
globals = {
    "ngx"
}

files["spec/*"] = { 
    -- Test data strings (JSON payloads) legitimately exceed 120 chars.
    max_line_length = false,
    -- Busted mocks and setup functions commonly have unused `self` / signature args.
    unused_args = false
}
