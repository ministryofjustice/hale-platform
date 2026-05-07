-- luacheck configuration for the OpenResty firewall modules + busted test suite.
-- https://luacheck.readthedocs.io/en/stable/config.html

-- OpenResty injects `ngx` as a global
globals = {
    "ngx"
}

-- busted test framework globals (injected by the test runner)
read_globals = {
    "describe", "it", "pending", "context",
    "before_each", "after_each", "setup", "teardown",
    "insulate", "expose",
    "spy", "stub", "mock",
    "assert",
}

