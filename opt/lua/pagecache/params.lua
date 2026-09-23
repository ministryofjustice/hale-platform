-- ============================================================================
-- Tracking query parameters, stripped before the page cache looks at a request.
-- ============================================================================
-- Ad platforms and analytics tag every click with parameters the server never
-- reads: utm_*, gclid, dclid, fbclid and friends. Each click carries a unique
-- value, and request_cacheable() treats any query string as dynamic, so every
-- campaign landing used to be a guaranteed MISS and a full PHP render. On
-- 2026-09-23 a Spotify campaign sent 1,246 renders of one prisonandprobationjobs
-- page to PHP at 2-10s each; 77% of mobile visitors gave up before it loaded.
--
-- Analytics is unaffected by stripping: GA and the ad pixels read these values
-- from the browser's address bar, which still has them. Only the copy nginx
-- hands to PHP (and uses for the cache decision) is cleaned.
--
-- _rt and _rt_nonce are Relevanssi Premium click tracking. They are appended to
-- every search-result link and crawlers replay them for years (tokens dated
-- 2024-10 were still being crawled in 2026-09), each one a unique URL. Stripping
-- them costs the Relevanssi click log, which nothing reads.
--
-- Pure Lua, no ngx dependency, so it is unit tested directly
-- (spec/pagecache_params_spec.lua).
-- ============================================================================

local _M = {}

-- Matched case-insensitively against the raw (still percent-encoded) key.
local EXACT = {
    -- Google Ads / Campaign Manager / Display & Video 360
    gclid = true, gclsrc = true, dclid = true, gbraid = true, wbraid = true,
    gad_source = true, gad_campaignid = true, srsltid = true,
    -- Google Analytics cross-domain linker
    _ga = true, _gl = true,
    -- Meta, Microsoft, TikTok, X, LinkedIn, Mailchimp
    fbclid = true, msclkid = true, ttclid = true, twclid = true,
    li_fat_id = true, mc_cid = true, mc_eid = true,
    -- Relevanssi click tracking
    _rt = true, _rt_nonce = true,
}

local PREFIXES = { "utm_" }

function _M.is_tracking(key)
    if not key or key == "" then return false end
    key = key:lower()
    if EXACT[key] then return true end
    for _, prefix in ipairs(PREFIXES) do
        if key:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- Remove tracking pairs from a raw query string ($args, no leading "?").
-- Returns the cleaned string and whether anything was removed. The original
-- string comes back untouched when nothing matched, so encoding and ordering
-- of real parameters are never rewritten.
function _M.strip(args)
    if not args or args == "" then return args or "", false end

    local kept, removed = {}, false
    for pair in args:gmatch("[^&]+") do
        local key = pair:match("^([^=]*)")
        if _M.is_tracking(key) then
            removed = true
        else
            kept[#kept + 1] = pair
        end
    end

    if not removed then return args, false end
    return table.concat(kept, "&"), true
end

return _M
