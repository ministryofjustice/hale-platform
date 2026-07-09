<<<<<<< HEAD
# Hale Firewall

Per-IP request rate limiting that runs inside nginx (OpenResty) and shares
state via Redis. Rules and config are edited from WordPress admin; decisions
are taken on the request hot path in Lua; an audit stream records what was
blocked and why.

This README is the **single source of truth** for how the firewall is wired
together. Per-file headers may go into more depth on particular concerns,
but if you only read one document, read this one.
=======
# Hale OpenResty modules — Firewall & Page Cache

Two independent subsystems run inside nginx (OpenResty) and share state via
Redis:

- **Firewall** ([firewall/](firewall/)) — per-IP request rate limiting.
  Rules and config are edited from WordPress admin; decisions are taken on
  the request hot path in Lua; an audit stream records what was blocked and
  why. Redis **db0**.
- **Page cache** ([pagecache/](pagecache/)) — full-page HTML cache. Serves
  anonymous GET responses straight from Redis, skipping PHP entirely on a
  HIT; invalidated per-URL by the WordPress purge mu-plugin on publish.
  Redis **db1**.

They share one connection-pool factory ([redis_pool.lua](redis_pool.lua))
and nothing else: separate logical Redis databases, separate keepalive
pools, separate kill-switches (`FIREWALL_ENABLED` / `PAGECACHE_ENABLED`).
Both **fail open** — if Redis is down, the firewall is effectively off and
the page cache falls through to PHP; a Redis outage must never take the
site down.

This README is the **single source of truth** for how both subsystems are
wired together. Per-file headers may go into more depth on particular
concerns, but if you only read one document, read this one.
>>>>>>> prototype-cache-lua-implementation

---

## Contents

<<<<<<< HEAD
=======
**Firewall**
>>>>>>> prototype-cache-lua-implementation
1. [What it does](#what-it-does)
2. [The firewall contract](#the-firewall-contract)
3. [Architecture at a glance](#architecture-at-a-glance)
4. [Request flow](#request-flow)
5. [Data model (Redis keys)](#data-model-redis-keys)
6. [Operating modes](#operating-modes)
7. [Logging](#logging)
8. [File map](#file-map)
9. [How to operate](#how-to-operate)
10. [How to test](#how-to-test)
<<<<<<< HEAD
11. [Design decisions](#design-decisions)

---

=======

**Page cache**

11. [Page cache](#page-cache) — lifecycle, cacheability, Redis keys, purge
    fence, configuration, observability, operating

**Both**

12. [Design decisions](#design-decisions)

---

# Firewall

>>>>>>> prototype-cache-lua-implementation
## What it does

For every incoming HTTP request:

1. Check the client IP against the **CIDR allowlist** (`firewall:allowlist`).
   If it matches, bypass all firewall logic and pass through.
2. Check the client IP against the **CIDR blocklist** (`firewall:blocklist`).
   If it matches, return 403 immediately — no scoring, no GCRA.
3. Look up the client IP in a small in-nginx cache. If we already decided to
   block it within a recent window, short-circuit (no Redis hit).
4. Otherwise, score the request against a list of **rules** (patterns on
   URI, User-Agent, method, query string) loaded from Redis. Each matching
   rule contributes a **cost**.
5. Run **GCRA** (a token-bucket rate limit) in a Redis Lua script, charging
   the IP that cost. Per-IP allow/block keys short-circuit inside the same
   script.
6. Allow the request, or return 429. In `monitor` mode, log the would-block
   decision and let the request through.
7. After the response, if any `res`-phase rules match, schedule an extra
   charge asynchronously (e.g. a 404 penalty for path probing).

The point of GCRA over a naïve counter is that it handles decay naturally
and does not have the "TTL refresh" bug where a slow attacker can accumulate
score forever.

---

## The firewall contract

Four separate codebases (nginx Lua, WordPress PHP, nginx config, busted/e2e
tests) cooperate without ever calling each other directly. They agree on
four things, listed here so each is documented in exactly one place. Any
change to these is a breaking change — update this section first.

### 1. HTTP endpoints (`/firewall/*`)

All dispatched by `firewall.admin.handle_route()` in [firewall/admin.lua](firewall/admin.lua).
Access is restricted to loopback in production by a single `location ^~
/firewall/` block.

| Method | Path | Purpose | Caller |
|---|---|---|---|
| `GET`  | `/firewall/stats`            | JSON snapshot of rules, config, live GCRA TATs, and current `cache_version`/`penalties_version` counters | Ops, debug |
| `GET`  | `/firewall/clear-penalties[?ip=x.x.x.x]`  | Clear auto-bans (`firewall:block:{ip}` with value `"gcra"`). For each IP cleared also deletes the matching `firewall:gcra:{ip}` (TAT) and `firewall:gcra:{ip}:breakdown` keys so the IP starts with a fresh GCRA bucket. With `?ip=` clears one IP (`404` if not banned, `409` if it's a manual ban); without `?ip=` scans and clears all. Manual bans are never touched in either mode. Increments `firewall:penalties_version` so every pod flushes its per-pod block cache within ~1 s | Ops |
| `POST` | `/firewall/admin/validate?kind=rules\|config\|allowlist\|blocklist` | Strict schema check, body is the candidate JSON; **read-only, no Redis writes** | PHP admin form before save |
| `GET`  | `/firewall/clear-rate-limits`  | **Local/test only (`ENV=local`).** Wipe all `firewall:block:*` and `firewall:gcra:*` keys and flush the per-pod `blocked_cache` shared dict. Returns 404 in any other environment. | E2e tests (`resetRateLimitState`) |

Cache invalidation is **not** an admin endpoint. Writers (PHP admin save,
ops scripts) bump `firewall:cache_version` in Redis directly after
writing `firewall:rules`/`:config`/`:allowlist`/`:blocklist`; every nginx
pod's background poller picks up the change within ~1 second. See
[Per-pod rules cache + Redis-backed version counter](#per-pod-rules-cache--redis-backed-version-counter).

### 2. Redis keys

See [Data model](#data-model-redis-keys) below for the full table. Key
names are pinned as constants in [firewall/defaults.lua](firewall/defaults.lua):
`GCRA_KEY_PREFIX`, `ALLOW_KEY_PREFIX`, `BLOCK_KEY_PREFIX`, `AUDIT_STREAM`.
PHP hardcodes the same strings; if you rename one, update both sides.

### 3. Audit stream fields (`firewall:audit`)

Written by `firewall.req()` for GCRA/penalty/per-IP-block decisions and by the `firewall.res()`
response-phase timer. Read by the WordPress admin audit table.

**Not written** for CIDR allowlist hits (the request bypasses all firewall logic) or CIDR
blocklist hits (the request exits with 403 before the GCRA/audit path runs). Those decisions
are visible in the nginx access log (`fw_info=allow` / `fw_info=block`) but produce no audit
row. If you need a record of CIDR-blocked traffic, use the access log.

| Field | Type | Always present | Meaning |
|---|---|---|---|
| `ip`           | string  | yes | Client IP that triggered the block |
| `blocked_at`   | int (ms epoch) | yes | When the block decision was taken |
| `cost`         | int  | yes | GCRA cost charged on this request |
| `mode`         | string  | yes | `enforce` or `monitor` — mode in force at the moment of the block |
| `trigger`      | string  | yes | What caused the block: `ip-block`, `penalty`, or comma-separated `rule:<phase>-score:<name>:<cost>` pairs (e.g. `rule:req-score:php-probe:20`, `rule:res-score:res-404:50`). `ip-block` means the per-IP `firewall:block:{ip}` key is set (manual or time-limited ban) — distinct from the CIDR `firewall:blocklist`, whose hits exit with 403 before the audit path and are never written to the stream. |
| `accumulated`  | JSON object string | yes | Per-rule hit counts accumulated in the GCRA breakdown hash at the moment of the block, keyed by the same `rule:<phase>-score:<name>` strings used by the scorer (e.g. `{"rule:req-score:php-probe":3,"rule:req-score:high-ua":1}` or `{"rule:res-score:res-404":2}`). `""` when the breakdown hash is empty or Redis returned nil (e.g. `ip-block`/`penalty` blocks, or audit disabled). |
| `reason`       | string  | request only | `block` / `penalty` / `gcra` — which arm of the GCRA script fired (omitted on response-phase entries) |
| `retry_after`  | int (ms) | request only | Suggested cooldown for the client; same value used for the local cache TTL |

The stream is capped by `XADD MAXLEN ~ audit_maxlen` (default 10 000,
tunable via `firewall:config.audit_maxlen`).

### 4. Validate response shape

`POST /firewall/admin/validate` always returns `200 application/json` with
this exact shape, regardless of whether validation succeeded:

```json
{
  "ok": true,
  "errors": [],
  "normalised": [ /* rules array */ ] | { /* config object */ } | null
}
```

- `ok`: `true` only if every rule / every config field passed strict
  validation **and** (for rules) every PCRE pattern compiled.
- `errors`: human-readable strings, one per problem found. Empty when `ok`.
- `normalised`: the payload as it would be persisted to Redis — defaults
  applied, types coerced, unknown keys stripped. `null` when `ok` is
  `false`. PHP writes this verbatim to Redis on success; never the raw
  operator input. For `allowlist` and `blocklist` kinds this is a JSON
  array of strings (CIDR notation, e.g. `["10.0.0.0/8", "192.168.1.5"]`);
  bare IPs are accepted and stored as-is (treated as /32 at match time).

A non-200 response indicates a request-shape problem (missing `kind`,
empty body, malformed JSON), not a schema problem.

---

## Architecture at a glance

```mermaid
flowchart LR
    subgraph Browser
      C[Client]
    end

    subgraph nginx["nginx / OpenResty pod"]
      A[access_by_lua<br/>firewall.req]
      L[log_by_lua<br/>firewall.res]
      D[(shared dict<br/>firewall_cache<br/>firewall_rc_cache)]
      ADMIN[/firewall/stats<br/>/firewall/clear-penalties/]
    end

    subgraph Redis
      R[(rules / config<br/>allow / block<br/>gcra TAT<br/>audit stream)]
    end

    subgraph WordPress
      WP[Network admin<br/>Firewall page]
      PHP[Firewall PHP class]
    end

    C --> A
    A -- read rules+config<br/>EVALSHA gcra script --> R
    A <-- block decision --> D
    A -- 200 / 429 --> C
    A --> WPB[upstream WordPress] --> L
    L -- async timer --> R

    WP --> PHP
    PHP -- saveRulesAndNotify<br/>saveConfigAndNotify<br/>getRules/getConfig<br/>read audit<br/>INCR cache_version --> R
    ADMIN -- read stats<br/>INCR penalties_version --> R
```

**Three independent processes share state through Redis:**

| Process | Role | Lives in |
|---|---|---|
| nginx (Lua) | Request hot path: scoring, rate-limit, block | `opt/lua/` |
<<<<<<< HEAD
| WordPress (PHP) | Admin UI: edit rules/config, view audit | `dev/mu-plugins/hale-components/inc/firewall.php` |
=======
| WordPress (PHP) | Admin UI: edit rules/config, view audit | `hale-components/inc/firewall.php` |
>>>>>>> prototype-cache-lua-implementation
| Redis | Shared state | external (ElastiCache in prod, container locally) |

Redis is the **only** coupling between Lua and PHP. They never talk
directly; the schema in [firewall/schema.lua](firewall/schema.lua) is the
contract.

---

## Request flow

The hot path splits naturally into three stages. Each diagram covers one
stage; together they describe the full lifecycle of a request through the
firewall.

### 1. Fast path — cached decisions (zero Redis I/O)

Every request first consults the per-worker shared dict `firewall_cache`.
If this IP triggered a block within its cooldown window, the decision has
already been made and we short-circuit without touching Redis.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant N as nginx access_by_lua
    participant M as per-worker CIDR cache
    participant SD as shared dict<br/>firewall_cache

    C->>N: HTTP request
    N->>M: is_allowed(ip)?
    alt CIDR allowlist hit
        Note over N: bypass — pass through
    end
    N->>M: is_blocked(ip)?
    alt CIDR blocklist hit
        N-->>C: 403 (no Redis I/O)
    end
    N->>SD: get blocked:<ip>
    alt cached "enforce"
        N-->>C: 429 (no Redis I/O)
    else cached "monitor"
        Note over N: allow through<br/>(episode already audited)
    else not cached
        Note over N: continue to slow path
    end
```

The cached *value* is the mode (`enforce` or `monitor`) that decided the
original block, not a boolean. That is what lets monitor mode skip the
audit on subsequent hits without re-reading config from Redis.

### 2. Slow path — score, rate-limit, decide

If the fast path didn't short-circuit, the request is scored against rules
loaded from Redis (cached per-worker until `firewall:cache_version` advances)
and a single atomic GCRA Lua script runs server-side in Redis. The script
also checks the allow/block lists in the same round-trip.

```mermaid
sequenceDiagram
    autonumber
    participant N as nginx access_by_lua
    participant R as Redis
    participant SD as shared dict<br/>firewall_cache
    participant C as Client
    participant U as upstream

    N->>R: load rules + config<br/>(worker-cached, version-counter invalidated)
    N->>N: cost.calculate(uri, ua, method, …)
    N->>R: EVALSHA gcra script<br/>(allow / block / gcra)
    alt allowed
        N->>U: pass through
    else blocked, mode=enforce
        N->>SD: set blocked:<ip>=enforce TTL=retry_after
        N->>R: XADD firewall:audit
        N-->>C: 429
    else blocked, mode=monitor
        N->>SD: set blocked:<ip>=monitor TTL=retry_after
        N->>R: XADD firewall:audit (mode=monitor)
        N->>U: pass through
    end
```

A block writes exactly one audit entry and one cache entry per episode per
IP. Subsequent requests within the cooldown window land back on the fast
path and never reach this stage.

### 3. Response phase — 404 penalty (deferred)

After nginx finishes responding, `log_by_lua` fires. For 404 responses
only, an extra GCRA charge is applied — probing for vulnerable URLs is
expensive, so we make the attacker pay for it. `log_by_lua` cannot do
socket I/O directly, so the work is deferred into a 0-delay timer.

```mermaid
sequenceDiagram
    autonumber
    participant U as upstream
    participant C as Client
    participant L as log_by_lua
    participant T as timer (ngx.timer.at 0)
    participant R as Redis
    participant SD as shared dict<br/>firewall_cache

    U-->>C: response
    U->>L: log_by_lua fires
    alt no res-phase rules match OR ip already cached
        Note over L: no-op
    else any res-phase rule matches AND not cached
        L->>T: schedule 0-delay timer
        T->>R: GCRA charge sum of matching res-rule costs
        alt blocked
            T->>SD: set blocked:<ip>=mode TTL=retry_after
            T->>R: XADD firewall:audit (trigger=rule:res-score:<name>:<cost>,...)
        end
    end
```

The response-phase charge runs through the same GCRA path as a normal
request, so it participates in the same bucket arithmetic and respects
the same mode.

---

## Data model (Redis keys)

| Key | Type | Owner writes | Owner reads | Purpose |
|---|---|---|---|---|
| `firewall:rules` | JSON string | PHP | Lua | Array of scoring rules |
| `firewall:config` | JSON string | PHP | Lua | GCRA params, mode, audit settings |
| `firewall:allowlist` | JSON string | PHP/CLI | Lua | Array of IPv4 CIDR strings (or bare IPs) that bypass all firewall logic |
| `firewall:blocklist` | JSON string | PHP/CLI | Lua | Array of IPv4 CIDR strings (or bare IPs) that receive an immediate 403 |
| `firewall:allow:{ip}` | string `"1"` | PHP/CLI | Lua script | Per-IP bypass flag (checked inside GCRA script) |
| `firewall:block:{ip}` | string (`"1"` manual, `"gcra"` auto) | PHP/CLI + Lua | Lua script | Per-IP block flag; TTL = ban duration |
| `firewall:gcra:{ip}` | string (TAT, ms epoch) | Lua script | Lua script | GCRA bucket state |
| `firewall:gcra:{ip}:breakdown` | hash | Lua script | Lua script | Per-rule hit counts (audit only) |
| `firewall:cache_version` | int | PHP/CLI | Lua | Cluster-wide cache invalidation counter; bump (`INCR`) after writing rules/config/allow/block to signal all pods to re-read |
| `firewall:penalties_version` | int | Lua (`/firewall/clear-penalties`) | Lua | Cluster-wide penalty-cache invalidation counter; bumped by `clear_penalties()` after deleting auto-ban keys; every pod's poller flushes `blocked_cache` when the value advances |
| `firewall:audit` | stream | Lua | PHP | Decision log, capped by `audit_maxlen` |

The schema for `firewall:rules` and `firewall:config` is documented in the
header of [firewall/schema.lua](firewall/schema.lua) — that file is the
authoritative schema reference.

### Rule schema (summary)

Each entry in `firewall:rules` is `{name, phase, cost, match}`:

- **`name`** — required, `[a-z0-9-]{1,64}`, unique within the array. Used
  as the audit trigger identity (`rule:<phase>-score:<name>:<cost>`).
- **`phase`** — required, `"req"` (evaluated in `access_by_lua`) or
  `"res"` (evaluated in `log_by_lua`).
- **`cost`** — required integer in `0..99999`. `0` = audit-only (matches
  appear in the breakdown but add no tokens); a value `>=` bucket
  capacity guarantees a block on first match.
- **`match`** — required object. An empty `{}` matches every request.
  Predicate keys are phase-specific:
  - **req** — `uri_pattern` / `ua_pattern` / `query_pattern` (PCRE,
    case-insensitive), `method` (exact, case-sensitive), `has_query`
    (boolean). Predicates within a rule are AND'd.
  - **res** — `status` (integer 100–599).

There is **no separate action enum**: every rule contributes to the
single per-IP GCRA bucket, and the bucket is the only blocking
mechanism. Operators tune behaviour via `cost` (0 → audit, large →
guaranteed block).

An empty `firewall:rules` array means no scoring is applied — by design,
this is a "no firewall" deployment. To enable scoring you must seed
rules.

---

## Operating modes

There are **two switches** that affect whether the firewall runs:

| Switch | Where | Effect | Use when |
|---|---|---|---|
| `FIREWALL_ENABLED` env var | nginx pod | When `false`, `req()` and `res()` return immediately. Zero overhead. | Emergency kill-switch; needs nginx restart to flip. |
| `firewall:config.mode` | Redis | `enforce` blocks, `monitor` logs only, `off` skips GCRA but still runs the Lua module. | Normal operation; flips cluster-wide within ~1 s of `INCR firewall:cache_version`. |

**Mode precedence:** if `FIREWALL_ENABLED=false`, nothing runs regardless
of `mode`. Otherwise `mode` takes effect.

**Why `monitor` shares the block cache with `enforce`:** so that the GCRA
bucket evolves identically under both modes, which is what makes monitor an
accurate predictor of what enforce *would* do. See the function-header
<<<<<<< HEAD
comment on `_M.req` in [firewall.lua](firewall.lua) for the full reasoning.
=======
comment on `_M.req` in [firewall/init.lua](firewall/init.lua) for the full reasoning.
>>>>>>> prototype-cache-lua-implementation

---

## Logging

The firewall writes to **three independent destinations**. Each answers a
different operational question; together they make every decision
traceable from a single request line back to the rule that scored it.

| Destination | Where it goes | What it answers | Cardinality |
|---|---|---|---|
| nginx access log | `/dev/stdout` (pod stdout) | "What was the score on *this* request?" | One line per request |
| nginx error log  | `/dev/stderr` at `info` level (pod stderr) | "Did the firewall behave as expected, and if not, why?" | One line per event |
| Redis stream `firewall:audit` | Redis (read by WP admin) | "Which IPs got blocked, when, and what triggered it?" | One entry per block episode per IP |

### 1. nginx access log

Declared once in [nginx.conf](../nginx/nginx.conf) and applied to every
server block:

```nginx
log_format main '$remote_addr - $remote_user [$time_local] '
                '"$request" $status $body_bytes_sent '
                '"$http_referer" "$http_user_agent" '
<<<<<<< HEAD
                'fw_info=$firewall_info cache=$upstream_cache_status';
access_log /dev/stdout main;
```

=======
                'fw_info=$firewall_info pc=$pagecache_status';
access_log /dev/stdout main;
```

(`pc=` is the page cache's field — see [Page cache → Observability](#observability).)

>>>>>>> prototype-cache-lua-implementation
The firewall contributes one field: **`fw_info`**, set in `firewall.req()`
via `ngx.var.firewall_info`. The value is either a numeric cost string or a
named reason:

| Value | Meaning |
|---|---|
| `-` | Lua never ran — request handled by a non-PHP location (static file, `/firewall/` admin) |
| `disabled` | `FIREWALL_ENABLED=false` kill-switch is set |
| `allow` | CIDR allowlist hit — request bypassed all firewall logic |
| `block` | CIDR blocklist hit — 403 returned without Redis I/O |
| `cached` | Fast-path shared-dict hit — block decision replayed from previous scoring |
| `0` | Scored; no rules matched |
| `N` (integer > 0) | Sum of costs of all matching `req`-phase rules |

Response-phase (`res`) costs do **not** appear in the access log — by the
time `log_by_lua` runs, the line has already been formatted. They appear
in the audit stream and the error log instead.

### 2. nginx error log

Written via `ngx.log(level, ...)` from Lua. Goes to `/dev/stderr` at
`info` level and above (set in [nginx.conf](../nginx/nginx.conf)). Every
firewall message is prefixed `[firewall]`, `[redis]`, or `[gcra]` so
`grep '\[firewall\]' …` is the canonical way to read it.

What each level means in this codebase:

| Level | Meaning | Operator action |
|---|---|---|
| `NOTICE`  | Lifecycle / configuration events (startup, cache reload, flush) | None — confirms the system is behaving as expected |
| `INFO`    | Normal decisions — block episodes, res-phase charges | None — useful for incident post-mortems |
| `WARN`    | Something is off but the request was handled (schema problem, regex error, GCRA script fallback) | Investigate if frequent |
| `ERR`     | Internal failure; firewall failed open, or a write to the audit stream was lost | Page if sustained |

Every firewall message begins with `[firewall]` and uses a consistent
`event=<name> key=value …` format so log shippers (Fluent Bit, Loki) can
parse them without a custom regex per message type. The pattern is:

```
[firewall] event=<event> [field=value ...]
```

Complete catalogue of events, by source file:

<<<<<<< HEAD
#### [firewall.lua](firewall.lua) — request hot path
=======
#### [firewall/init.lua](firewall/init.lua) — request hot path
>>>>>>> prototype-cache-lua-implementation

| Level | `event=` | Fields | When |
|---|---|---|---|
| `NOTICE` | `startup` | `enabled=` `redis_ssl=` | Once per nginx worker from `init()`. Confirms kill-switch and SSL config. `init()` also pre-warms the CIDR/rules cache via a Redis call so `is_allowed`/`is_blocked` have populated lists before the first request. Fail-open: if Redis is unavailable at startup the first request re-attempts via the normal `pcall` path. |
| `WARN`   | `regex_error` | `pattern=` `err=` | A rule's PCRE failed at match time. **Deduplicated:** logged at most once per hour per pattern via a shared-dict key (`logged:regex:<pattern>`, TTL 3600 s) to prevent a single bad rule flooding stderr on every request. Should never fire in production — admin validate runs `compile_check_patterns` first. Indicates a rule was written directly to Redis. |
| `ERR`    | `no_rules` | `msg=` | `firewall:rules` is missing or empty. Fail-open; firewall is effectively off until rules are seeded. |
| `INFO`   | `block` | `phase=req` `mode=` `ip=` `reason=` `cost=` `retry_after=` | Block decision (req phase). `mode=enforce` → 429 was returned; `mode=monitor` → request passed through. One entry per block episode per IP (fast-path cache deduplicates). |
| `ERR`    | `audit_write_failed` | `phase=req` `ip=` `err=` | `XADD firewall:audit` failed. The block decision was enforced correctly but the audit record was lost. |
| `ERR`    | `req_error` | `err=` | The protected `pcall` block in `req()` raised. Request was allowed through (fail-open). Almost always a Lua bug; investigate immediately. |
| `INFO`   | `block` | `phase=res` `mode=` `ip=` `status=` `cost=` `retry_after=` | Response-phase charge tripped the bucket. The current response was already sent; the *next* request from this IP hits the fast path. |
| `ERR`    | `audit_write_failed` | `phase=res` `ip=` `err=` | `XADD firewall:audit` failed in the res-phase timer. |
| `INFO`   | `res_charge` | `phase=res` `ip=` `status=` `cost=` | Res-phase rule matched and charged the bucket but did **not** block. Confirms res-rules are scoring without yet tipping the bucket. |
| `ERR`    | `res_timer_error` | `err=` | The deferred res-phase work raised inside the timer. The charge was lost; the response was already sent. |
| `ERR`    | `timer_schedule_error` | `err=` | `ngx.timer.at(0, …)` itself failed (typically out of timers). Res-phase scoring skipped entirely for this request. |

**`reason=` values** in `event=block` entries, mirroring the audit stream's
`reason` field:

- `block`   — `firewall:block:<ip>` is set (manual ban).
- `penalty` — `firewall:block:<ip>` is set with value `"gcra"` (automatic ban from a previous GCRA block).
- `gcra`    — live GCRA bucket exhausted.
- `allow`   — never logged (suppressed: an allowlisted IP is not a block event).

#### [firewall/cache.lua](firewall/cache.lua)

| Level | `event=` | Fields | When |
|---|---|---|---|
| `NOTICE` | `rules_reload` | `version=` `rule_count=` | Fired once per worker each time the per-worker cache is refreshed from Redis (i.e. the per-pod poller observed a `firewall:cache_version` bump). Correlate `version=` across workers to confirm a config change propagated everywhere. |
| `ERR`    | `json_decode_error` | `key=` `err=` | A Redis key (`firewall:rules`, `:config`, `:allowlist`, or `:blocklist`) contained invalid JSON. The affected list is treated as empty (fail-open). Indicates a bad direct write to Redis bypassing the admin validate endpoint. |
| `WARN`   | `schema_warn` | `kind=rules\|config\|allowlist\|blocklist` + the warning text | A rule / config field / CIDR entry in Redis failed structural validation. The offending entry is dropped; the rest are kept. Should never fire in production — admin validate catches this before save. |
| `NOTICE` | `penalties_flush` | `version=` | The per-pod poller observed a new `firewall:penalties_version` value in Redis (set by `/firewall/clear-penalties`). The per-pod `blocked_cache` shared dict was flushed so all workers immediately stop serving stale auto-ban 429s. |
| `WARN`    | `version_poll_error` | `err=` | The 1 s poller failed to read version counters from Redis. The previous values remain in place; the next tick retries. |

#### [firewall/cost.lua](firewall/cost.lua)

| Level | Message | When |
|---|---|---|
| `WARN` | `[firewall] cost.calculate skipped rule name=<n> with unknown phase=<p>` | A rule with a phase other than `req`/`res` reached the scorer. Defensive; `schema.parse_rules` already rejects this, so this only fires if rules were written directly to Redis. |

#### [firewall/redis.lua](firewall/redis.lua)

| Level | Message | When |
|---|---|---|
| `ERR` | `[redis] connect failed (fail-open): <err>` | TCP connect to Redis failed. Caller returns early; firewall behaves as if disabled until Redis returns. |
| `ERR` | `[redis] auth failed (fail-open): <err>` | `REDIS_AUTH` was set but `AUTH` was rejected. Fail-open. |
<<<<<<< HEAD
| `ERR` | `[redis] select db failed (fail-open): <err>` | `SELECT <REDIS_DB>` failed. Fail-open. |
=======
| `ERR` | `[redis] select db failed (fail-open): <err>` | `SELECT <FIREWALL_DB>` failed. Fail-open. |
>>>>>>> prototype-cache-lua-implementation

#### [firewall/gcra.lua](firewall/gcra.lua)

| Level | Message | When |
|---|---|---|
| `WARN` | `[gcra] SCRIPT LOAD failed, falling back to EVAL: <err>` | The GCRA Lua script could not be cached server-side. The script still runs via `EVAL` (slower but functionally identical). Usually transient (Redis restart flushed the script cache). |

#### [firewall/admin.lua](firewall/admin.lua)

| Level | Message | When |
|---|---|---|
| `ERR` | `[firewall] failed to list block keys: <err>` | `KEYS firewall:block:*` failed during `/firewall/clear-penalties`. Endpoint continues with whatever keys were returned. |

### 3. Audit stream — `firewall:audit`

The structured, machine-readable record of every block decision. Written
from two places:

- `firewall.req()` — request-phase blocks (allowlist/blocklist, GCRA bucket, manual/automatic bans).
- The deferred timer in `firewall.res()` — response-phase blocks (404/499 penalty tripped the bucket).

Written with `XADD firewall:audit MAXLEN ~ <audit_maxlen> * field value …`.
The `~` makes the trim approximate (cheap); `audit_maxlen` defaults to
10 000 and is set in `firewall:config.audit_maxlen`. Writes are gated by
`firewall:config.audit_enabled` — set it to `false` to silence the stream
entirely without touching the rest of the firewall.

Fields are documented in full in
[The firewall contract → Audit stream fields](#3-audit-stream-fields-firewallaudit).
The key invariants:

- **One entry per block episode per IP.** The fast-path `firewall_cache`
  short-circuits subsequent requests within the cooldown window before
  they reach the audit code, so a 10 000-request burst from one IP
  produces one row, not 10 000.
- **`mode` is captured at write time**, not read time. Audit reflects what
  the firewall did — flipping `mode` later does not rewrite history.
- **Monitor mode writes audit entries** the same way enforce does. That
  is the whole point of monitor: see what enforce *would* have done.
- **`trigger` is sorted** so the same matching rule set always produces
  the same string, making `XREVRANGE` output diff-able across requests.

Read it from the WordPress admin (Network dashboard → Firewall → audit
table) or directly:

```
XREVRANGE firewall:audit + - COUNT 50
XLEN firewall:audit
```

### Quick reference — "why was this request blocked?"

Given a **429** response, walk these in order:

1. **Access log** for the request: confirm `fw_info=N` (req-phase score). Named values (`allow`, `block`, `cached`, `disabled`) explain why scoring was skipped.
2. **Audit stream** filtered to the IP: `XREVRANGE firewall:audit + - COUNT 100` then grep. The `trigger`, `reason`, and `cost` fields fully explain the decision.
3. **Error log** filtered to the IP: `grep 'event=block.*ip=<ip>'` shows the corresponding INFO line and any preceding ERR (e.g. `event=audit_write_failed` means the audit row may be missing).

Given a **403** response (`fw_info=block` in the access log), the IP matched the CIDR
`firewall:blocklist`. These decisions exit before the audit path — the **access log is the
only record**. No audit stream entry is written.

---

## File map

### Lua (`opt/lua/`)

| File | Responsibility |
|---|---|
<<<<<<< HEAD
| [firewall.lua](firewall.lua) | **Hot path only.** Exports `init`, `req`, `res`. Called by `init_worker_by_lua_block`, `access_by_lua_block`, `log_by_lua_block`. |
=======
| [firewall/init.lua](firewall/init.lua) | **Hot path only.** Exports `init`, `req`, `res`. Called by `init_worker_by_lua_block`, `access_by_lua_block`, `log_by_lua_block`. |
>>>>>>> prototype-cache-lua-implementation
| [firewall/admin.lua](firewall/admin.lua) | Admin endpoints. Exports `handle_route`, `stats`, `validate`, `clear_penalties`, `clear_rate_limits`. Called by `content_by_lua_block` in the `/firewall/*` location. |
| [firewall/cache.lua](firewall/cache.lua) | Shared cache state: `blocked_cache` (shared dict), `load_rules_and_config` (per-worker cache, invalidated by Redis `firewall:cache_version`), `poll_versions`. Required by both `firewall` and `firewall.admin`. |
| [firewall/cost.lua](firewall/cost.lua) | Pure function — score a request against rules. No `ngx.*` deps; unit-testable. |
| [firewall/gcra.lua](firewall/gcra.lua) | GCRA algorithm + the Redis Lua script that runs server-side. EVALSHA + cache. |
| [firewall/schema.lua](firewall/schema.lua) | Pure validators for `firewall:rules` and `firewall:config`. **Authoritative schema lives here.** Exposes `parse_*` (fail-soft, runtime) and `validate_*_strict` (fail-hard, admin path). |
| [firewall/defaults.lua](firewall/defaults.lua) | Single source of truth for constants (`GCRA_KEY_PREFIX` etc.) and GCRA tunable defaults. |
| [firewall/cidr.lua](firewall/cidr.lua) | Pure IPv4 CIDR matching. No `ngx.*` deps; unit-testable. `parse(entry)` → `{net, host_count}` or nil. `contains(parsed_list, ip)` → bool. Bare IPs treated as /32. |
<<<<<<< HEAD
| [firewall/redis.lua](firewall/redis.lua) | Connection pool, fail-open. Reads `REDIS_*` env. |
| [spec/](spec/) | busted unit + integration tests (run with `make test-firewall`). |
| [firewall_e2e_test.mjs](firewall_e2e_test.mjs) | Node.js e2e tests + CSV fixture replay against a running stack. |
| [fixtures/](fixtures/) | CSV replay inputs from Ingress log exports. |
=======
| [redis_pool.lua](redis_pool.lua) | Shared Redis connection-pool factory (fail-open, per-db keepalive pools). Used by BOTH subsystems. Reads `REDIS_*` env. `new{db, pool_prefix, log_prefix}` builds a pool module. |
| [firewall/redis.lua](firewall/redis.lua) | Thin wrapper: `redis_pool.new` bound to `FIREWALL_DB` (default 0), pool `firewall_db<N>`. |
| [pagecache/init.lua](pagecache/init.lua) | Page cache hot path. Exports `fetch`, `filter_headers`, `capture_body`, `store` — one per nginx phase. See [Page cache](#page-cache). |
| [pagecache/redis.lua](pagecache/redis.lua) | Thin wrapper: `redis_pool.new` bound to `PAGECACHE_DB` (default 1), pool `pagecache_db<N>`. |
| [spec/](spec/) | busted unit + integration tests (run with `make test-firewall`; the lint pass covers the pagecache files too). |
| [firewall_e2e_test.mjs](firewall/firewall_e2e_test.mjs) | Node.js e2e tests + CSV fixture replay against a running stack. |
| [fixtures/](firewall/fixtures/) | CSV replay inputs from Ingress log exports. |
>>>>>>> prototype-cache-lua-implementation

### nginx (`opt/nginx/`)

| File | Responsibility |
|---|---|
<<<<<<< HEAD
| `nginx.conf` | `lua_package_path`, shared dicts, `init_worker_by_lua_block`, `env FIREWALL_ENABLED`, log format. |
| `wordpress.conf` | Production server block. `access_by_lua_block { firewall.req() }`, `log_by_lua_block { firewall.res() }`. `location ^~ /firewall/` restricted to loopback — dispatches all admin endpoints via `firewall.admin.handle_route()`. |
=======
| `nginx.conf` | `lua_package_path`, shared dicts, `init_worker_by_lua_block`, the `env` whitelist (`FIREWALL_*`, `PAGECACHE_*`, `REDIS_*`), log format (`fw_info=` + `pc=`). |
| `wordpress.conf` | Production server block. Firewall: `access_by_lua_block { firewall.req() }`, `log_by_lua_block { firewall.res() }`; `location ^~ /firewall/` restricted to loopback — dispatches all admin endpoints via `firewall.admin.handle_route()`. Page cache: all four `*_by_lua` hooks in the PHP location (see [Page cache → Request lifecycle](#request-lifecycle)) plus the `$pagecache_status` map var. |
>>>>>>> prototype-cache-lua-implementation
| `localwordpress.conf` | Local-dev equivalent. Same structure, no loopback restriction on `/firewall/`. |

### PHP (`hale-components/inc/`)

| File | Responsibility |
|---|---|
| `network-dashboard.php` | Registers the network admin page (`Settings → Hale Network Dashboard`) and includes the firewall view. |
| `lua-firewall-controller.php` | Controller layer: Redis client (`hc_firewall_redis_*`), config/mode/list/rules getters, `admin-post` form handlers (`hc_firewall_handle_update_mode`, `_update_list`, `_update_rules`, `_clear_penalties`, `_clear_penalty_ip`), and Redis readers for the blocked IPs table (`hc_firewall_get_active_blocks`) and audit stream (`hc_firewall_get_audit_entries`). Delegates schema validation to `/firewall/admin/validate`; proxies clear actions through `/firewall/clear-penalties`. |
| `parts/lua-firewall.php` | The admin view rendered on the network dashboard: mode selector, allow/block list editors, rules editor, blocked IPs table with per-row Unblock + View Audit buttons, audit history table, manual IP lookup form. |

---

## How to operate

### Change rules or config

WordPress admin → Network dashboard → Firewall section. Edit JSON, save.
The form POSTs the payload to `/firewall/admin/validate?kind=rules|config`
first — the Lua schema in [firewall/schema.lua](firewall/schema.lua) is the
single source of truth, so any error you see in the admin form is the
same error the runtime parser would log. On success PHP writes the
*normalised* payload to Redis (defaults applied, types coerced) and
`INCR firewall:cache_version`. Every nginx pod's background poller picks
up the bump within ~1 s and signals its workers to re-read.

### Allow or block a CIDR range (or single IP)

Edit `firewall:allowlist` or `firewall:blocklist` in Redis as a JSON array
of IPv4 CIDR strings. Bare IPs are accepted and treated as /32.

```
# Allow a whole subnet (bypass all firewall logic)
SET firewall:allowlist '["10.0.0.0/8", "172.16.0.0/12"]'

# Block a range (return 403 before GCRA)
SET firewall:blocklist '["198.51.100.0/24"]'

# Clear a list
SET firewall:allowlist '[]'
```

Validate the payload before writing:

```
POST /firewall/admin/validate?kind=allowlist
Content-Type: application/json
["10.0.0.0/8"]
```

After writing, `INCR firewall:cache_version` so all pods reload the
lists within ~1 s (otherwise their existing copies stay valid until the
next bump).

### Allow or block a single IP (GCRA-level)

For per-IP overrides that live inside the GCRA script rather than the
early-return path:

```
SET firewall:allow:1.2.3.4 1 EX 3600  # allow for 1 hour
SET firewall:allow:1.2.3.4 1           # allow permanently
DEL firewall:allow:1.2.3.4

SET firewall:block:1.2.3.4 1           # permanent manual ban
DEL firewall:block:1.2.3.4
```

After writing, `INCR firewall:cache_version` so all pods pick up the
change within ~1 s.

### Inspect state

| What | How |
|---|---|
| Current rules/config + active GCRA TATs | `GET /firewall/stats` (returns JSON) |
| Dry-run schema check on a payload | `POST /firewall/admin/validate?kind=rules\|config\|allowlist\|blocklist` with the JSON body |
| Recent decisions | WordPress admin → audit table, or `XREVRANGE firewall:audit + - COUNT 50` |
| Currently active blocks | `KEYS firewall:block:*` then `PTTL` per key |
| nginx access log | `fw_info` field on every line — integer cost or named reason (see [Access log](#1-nginx-access-log)) |
| Browse Redis keys interactively (local only) | http://redis-insight.docker — RedisInsight UI shipped with the local Docker stack |

### Flip mode without a deploy

```
SET firewall:config '{"mode":"enforce", ...}'
INCR firewall:cache_version            # propagate cluster-wide within ~1 s
```

<<<<<<< HEAD
=======
**Locked out of WordPress?** If a mis-configured firewall is blocking
legitimate admin traffic, you can flip the mode from WP-CLI inside the
WordPress container without touching Redis directly. This re-uses the same
validate → write → version-bump path as the admin UI:

```sh
# Stop enforcing — auto-bans are still recorded but no longer served as 429s.
wp lua-firewall mode monitor

# Or turn the firewall off entirely.
wp lua-firewall mode off
```

Prints `Success: Firewall mode set to <mode>.` and exits 0 on success, or
`Error: <validator message>` and exits non-zero on failure. All nginx pods
pick up the change within ~1 s via the `firewall:cache_version` poller —
no restart needed.

>>>>>>> prototype-cache-lua-implementation
### Clear automatic penalties (manual bans untouched)

```
GET /firewall/clear-penalties
```

Deletes every `firewall:block:{ip}` key whose value is `"gcra"` (auto-ban)
and increments `firewall:penalties_version`. Every pod's background poller
picks up the bump within ~1 s and flushes its per-pod `blocked_cache` so
all workers stop serving stale 429s cluster-wide.

### Disable everything immediately

Set `FIREWALL_ENABLED=false` in the nginx Helm values and redeploy. This is
the only switch that requires a restart.

<<<<<<< HEAD
=======
For a faster, no-deploy alternative when admins are locked out, see the
WP-CLI snippet under [Flip mode without a deploy](#flip-mode-without-a-deploy).

>>>>>>> prototype-cache-lua-implementation
---

## How to test

### Unit + integration (busted, fast, in-container)

```
make test-firewall
```

Builds the `test` stage of [nginx.local.dockerfile](../../nginx.local.dockerfile),
<<<<<<< HEAD
runs busted with `REDIS_DB=1` against the dev Redis container so it does
=======
runs busted with `FIREWALL_DB=1` against the dev Redis container so it does
>>>>>>> prototype-cache-lua-implementation
not collide with anything live.

### End-to-end (Node.js, slow, against a running stack)

Bring the stack up with the firewall enabled:

```
make run-with-firewall
```

The e2e tests call `GET /firewall/clear-rate-limits` before each stateful test to wipe
all `firewall:block:*` and `firewall:gcra:*` keys and flush the per-pod `blocked_cache`.
This endpoint is only available when `ENV=local` and returns 404 in production.

<<<<<<< HEAD
Then (run from `opt/lua/`):
=======
Then (run from `opt/lua/firewall/`):
>>>>>>> prototype-cache-lua-implementation

```
node --test firewall_e2e_test.mjs
```

Redis is reached at `127.0.0.1:6379` by default. Override with
`REDIS_URL=host:port` if needed.

<<<<<<< HEAD
Drop a CSV from Cloud Platform ingress logs into [fixtures/](fixtures/) 
=======
Drop a CSV from Cloud Platform ingress logs into [fixtures/](firewall/fixtures/) 
>>>>>>> prototype-cache-lua-implementation
to replay real traffic against the firewall — the test discovers them
automatically.

---

<<<<<<< HEAD
## Design decisions

These are recorded here rather than scattered through file headers.
=======
# Page cache

Full-page HTML cache for anonymous traffic, implemented in
[pagecache/init.lua](pagecache/init.lua). On a HIT, nginx serves the stored
page straight from Redis in the access phase — PHP is never invoked. The
cache lives in Redis (not nginx's per-pod `fastcgi_cache`, which it
replaces) so it is shared across all pods and can be invalidated per-URL
from WordPress.

Like the firewall, it never talks to PHP directly: the Redis key scheme is
the contract. The other side of that contract is the **WordPress purge
mu-plugin** in the hale-components repo
(`hale-components/inc/pagecache-purge.php`), which deletes keys and stamps
purge fences when content is published.

## Request lifecycle

Wired into the `location ~ \.php$` block in
[wordpress.conf](../nginx/wordpress.conf) /
[localwordpress.conf](../nginx/localwordpress.conf) — four nginx phases,
one exported function each:

| Phase | Hook | Function | Job |
|---|---|---|---|
| access | `access_by_lua` | `fetch()` | Serve a HIT (`ngx.print` + exit, PHP skipped), or snapshot Redis time and flag the request to be stored on MISS |
| header filter | `header_filter_by_lua` | `filter_headers()` | Confirm the *response* is safe to store; emit `X-Page-Cache` |
| body filter | `body_filter_by_lua` | `capture_body()` | Buffer the HTML chunks; enforce `PAGECACHE_MAX_BYTES`; record eof. No cosockets allowed in this phase, so no Redis I/O here |
| log | `log_by_lua` | `store()` | Schedule the Redis write in a 0-delay timer (timer contexts allow cosockets), after the response has been sent |

## What gets cached

**The request is eligible** (`request_cacheable()`) only if all of:

- method is `GET`;
- query string is empty (any query → assumed dynamic);
- URI matches none of the bypass patterns: `/wp-admin`, `/wp-login`,
  `/wp-json`, `/xmlrpc.php`, `wp-cron`, `/feed`, `sitemap`;
- no personalisation cookie: `wordpress_logged_in`, `wordpress_<hash>`,
  `comment_author`, `wp-postpass`, `wordpress_no_cache`.

**The response is storeable** (`filter_headers()` + `capture_body()`) only
if all of:

- status is 200;
- `Content-Type` contains `text/html`;
- no `Set-Cookie` header (personalised response);
- no `Content-Encoding` header (bodies are stored uncompressed only);
- `Cache-Control` contains none of `no-cache` / `no-store` / `private` —
  so PHP can veto caching per-page with a single header;
- body stays under `PAGECACHE_MAX_BYTES`;
- the body reached **eof** — a client abort mid-response must not cache a
  truncated page for the full TTL.

Everything else falls through to PHP untouched.

## Data model (Redis keys, db1)

| Key | Type | Writer | Reader | Purpose |
|---|---|---|---|---|
| `pagecache:v{version}:{host}:{path}` | string, TTL = `PAGECACHE_TTL` | Lua (deferred write); deleted by PHP purge | Lua | Cached page: `"<content-type>\n<body>"` (split on first newline) |
| `pagecache:fence:{host}:{path}` | string (integer microseconds from Redis `TIME`), TTL = `PAGECACHE_FENCE_TTL` | PHP purge plugin | Lua CAS script | Purge fence — blocks a stale in-flight render from re-caching (see below) |
| `pagecache:version` | int | **Operator only** (`INCR`) | Lua + PHP | Site-wide flush counter, embedded in every content key |

Key anatomy:

- `{path}` is `$request_uri` with any query portion stripped (`cache_path()`).
  `$uri` can't be used — the permalink rewrite has already turned it into
  `/index.php`.
- `{host}` isolates multisite sites from each other.
- The scheme is deliberately omitted: TLS terminates upstream, so the
  scheme nginx sees can differ from what WordPress sees. Host + path is
  canonical.
- `{version}` comes from `pagecache:version`, normalised to an integer on
  **both** sides (Lua `math.floor`, PHP `(int)`) so they derive identical
  keys.

Everything the page cache writes goes through `SETEX`, so every key has a
TTL and is eligible for `volatile-lru` eviction — on a shared Redis
instance the cache can never cause eviction of the firewall's persistent
keys.

## The purge/write race (fence keys)

The cache write is deferred until after the response is sent, which opens
a race: a request MISSes, PHP starts rendering, an editor publishes and
the purge plugin deletes that path's key — then the deferred write lands
and re-caches the now-stale render into the just-purged key, for the full
TTL.

The fence closes it:

1. On MISS, `fetch()` snapshots **Redis's own clock** (`TIME`, converted
   to integer microseconds — not local wall-clock, which drifts across
   pods) as the render start time.
2. On publish, the purge plugin `DEL`s the content key **and** stamps
   `pagecache:fence:{host}:{path}` with the current Redis time.
3. The deferred write runs a check-and-write `EVAL`
   (`CAS_WRITE_SCRIPT`): if a fence exists with a timestamp **at or
   after** the render start time, the write is silently dropped. Check and
   write happen in one script, so there is no gap between them.

The fence value format (integer microseconds) is a **lockstep contract**
with the PHP purge module — `"sec.usec"` string concatenation was
rejected because it mis-orders within a second (`{1234, 5}` →
`"1234.5"` reads as half a second, not 5 µs). If the format changes, both
repos must ship together (a brief mixed-format window is tolerable: the
fence TTL is 60 s).

If Redis `TIME` failed on the MISS, the write falls back to an unfenced
`SETEX` — a rare partial-failure mode, preferred over never caching.

## Configuration (env vars)

All read once at module load; all must be in the `env` whitelist in
[nginx.conf](../nginx/nginx.conf) or `os.getenv` returns nothing.

| Var | Default | Meaning |
|---|---|---|
| `PAGECACHE_ENABLED` | unset (off) | Kill-switch. Must be exactly the string `true`. Needs an nginx restart to flip. |
| `PAGECACHE_TTL` | `300` | Content key TTL, seconds. Also the worst-case staleness if a purge is missed. |
| `PAGECACHE_MAX_BYTES` | `2097152` (2 MiB) | Bodies larger than this are never stored. |
| `PAGECACHE_DB` | `1` | Logical Redis db. **Must match the WP purge plugin's value** — it reads the same env var with the same default; if they diverge, purges silently stop working. |
| `PAGECACHE_FENCE_TTL` | `60` | Fence key TTL, seconds. Read by the PHP purge plugin only. |

Connection settings (`REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH`,
`REDIS_SSL`, `REDIS_POOL_SIZE`, `REDIS_KEEPALIVE_MS`) are shared with the
firewall and documented in [redis_pool.lua](redis_pool.lua).

## Observability

**Response header `X-Page-Cache`** — visible in browser devtools/curl:

| Value | Meaning |
|---|---|
| `HIT` | Served from Redis; PHP never ran |
| `MISS` | Served by PHP; response was storeable and will be written to Redis |
| `BYPASS` | Not cacheable — either the request (method/query/URI/cookie) or the response (status/headers) disqualified it |
| *absent* | Cache is off (`PAGECACHE_ENABLED` unset), Redis is down, or the location isn't wired |

One edge: a body that exceeds `PAGECACHE_MAX_BYTES` mid-stream still shows
`MISS` (headers were already sent) but is not stored — the access log says
`bypass`.

**Access log field `pc=`** — `$pagecache_status`, set via `set_status()`:

| Value | Meaning |
|---|---|
| `hit` / `miss` / `bypass` | As per the header above (and `bypass` covers the too-big edge case correctly) |
| `off` | `PAGECACHE_ENABLED` is not `true` |
| `down` | Redis connect failed — request failed open to PHP |
| `-` | Lua never ran (non-PHP location) |

**Error log** — prefixed `[pagecache]`: `fenced write failed: <err>`
(the CAS EVAL errored), `store timer failed: <err>` (`ngx.timer.at`
refused, typically out of timers). Connection errors appear with the same
`[pagecache]` prefix via the pool's `log_prefix`.

## How to operate

### Turn it on / off

Locally: `make run-with-pagecache` / `make down-pagecache` (preserves the
firewall's state). In production: set `PAGECACHE_ENABLED` in the nginx
Helm values and redeploy — like `FIREWALL_ENABLED`, it needs a restart.

### Flush the entire cache

Content keys embed a version number read from `pagecache:version`.
Nothing in the codebase writes this key — bumping it is a manual,
operator-only action:

```
# In the page cache db (PAGECACHE_DB, default 1)
INCR pagecache:version
```

Every pod starts keying reads/writes under the new version immediately, so
the whole cache MISSes at once — an instant site-wide flush with no key
scanning. Old-version keys are not deleted; they expire via their TTL.

### Purge a single URL

Automatic: the WP purge mu-plugin does it on publish/update. Manual:

```
# In db1 — delete the content key for the current version
DEL pagecache:v0:example.hale.docker:/some/page/
```

(Deleting without stamping a fence is fine for a manual purge — the fence
only matters for the publish-while-rendering race.)

### Inspect state

| What | How |
|---|---|
| What's cached right now | `redis-cli -n 1 --scan --match 'pagecache:v*'` |
| Current version counter | `redis-cli -n 1 GET pagecache:version` (nil = 0) |
| Live fences | `redis-cli -n 1 --scan --match 'pagecache:fence:*'` |
| Per-request decision | `X-Page-Cache` response header, or `pc=` in the access log |
| Browse keys interactively (local only) | http://redis-insight.docker — select db1 |

---

## Design decisions

These are recorded here rather than scattered through file headers.
Firewall decisions first, then page cache, then shared.
>>>>>>> prototype-cache-lua-implementation

### Why GCRA, not a sliding-window counter

A counter that's bumped on each request and given a TTL has a refresh bug:
every hit pushes the TTL out, so a slow attacker keeps the counter alive
forever and accumulates unbounded score. GCRA stores a *theoretical
arrival time* instead — there is no "score" to refresh, only a moving
deadline. Decay is implicit.

Further reading:
- [Generic cell rate algorithm (Wikipedia)](https://en.wikipedia.org/wiki/Generic_cell_rate_algorithm)
  — the original spec; explains TAT, emission interval, and the
  leaky-bucket equivalence.
- [Distributed Rate Limiter with Redis & Lua | GCRA Algorithm Demo (YouTube)](https://www.youtube.com/watch?v=HqAjClwTBy0)
  — walks through the same Redis+Lua pattern used in [firewall/gcra.lua](firewall/gcra.lua).

### Why both modes share `firewall_cache`

Three reasons, in order of importance:

1. **Symmetry with enforce.** In enforce mode, blocked requests don't reach
   Redis (fast-path 429). The GCRA bucket only sees *allowed* traffic. If
   monitor mode behaved differently — every request reaches Redis — the
   bucket diverges and monitor becomes a poor predictor of enforce. They
   must share the cache to share GCRA semantics.
2. **Performance parity.** Without the cache, monitor mode pays one Redis
   round-trip per attack request. That makes monitor too expensive to leave
   on, defeating its purpose as a safe-rollout mode.
3. **Audit volume.** With the cache, audit is "one entry per block episode
   per IP" in both modes. Without it, monitor would write thousands of
   duplicate rows during a single attack.

The cached *value* is the mode that decided the block (`enforce` /
`monitor`), not a boolean. A mode flip mid-window therefore does not
retroactively change cached entries — they keep behaving as their original
mode said until the TTL expires.

### Why response-phase scoring runs in a timer

`log_by_lua` does not allow socket I/O — the request is finished. We
schedule a 0-delay timer because timer contexts *do* allow sockets. The
charge is applied via the same GCRA path as a normal request, so it
participates in the same bucket arithmetic.

Response-phase scoring is fully data-driven via `firewall:rules` entries
with `phase: "res"` (see "Rule schema" above). For example:

```json
[
  {"name":"res-404","phase":"res","cost":50,"match":{"status":404}},
  {"name":"res-499","phase":"res","cost":25,"match":{"status":499}}
]
```

| Status | Suggested cost | Rationale |
|---|---|---|
| 404 | 50 | Probing for vulnerable paths that nothing legitimate requests |
| 499 | 25 | Client closed connection — real users rarely abort, scanners fire-and-forget |

Adding a new status is one rule entry in `firewall:rules`; no application
logic changes.

<<<<<<< HEAD
### Fail-open everywhere

If Redis is unreachable, `redis.connect()` returns `nil` and every caller
returns early. The site stays up; the firewall is effectively off until
Redis returns. This is preferred over fail-closed because a Redis outage
should not be a site outage.
=======
### Why Redis for the page cache, not nginx's fastcgi_cache

`fastcgi_cache` is per-pod: each of N pods builds its own copy, each
misses independently after a deploy, and there is no way for WordPress to
purge a URL across all pods on publish. A Redis-backed cache is filled
once cluster-wide, and the purge mu-plugin's single `DEL` invalidates
everywhere at once. The cost — one Redis round-trip on the HIT path
instead of a local disk read — buys correct multi-pod invalidation.

### Why the page cache write is deferred to a timer

Same constraint as the firewall's response-phase scoring: the body is
captured in `body_filter_by_lua` and the write scheduled from
`log_by_lua`, and neither phase allows cosocket (Redis) I/O. A 0-delay
timer does. The bonus is that the client never waits on the cache write —
it happens after the response is fully sent. The price is the
purge/write race, which the fence key closes (see
[The purge/write race](#the-purgewrite-race-fence-keys)).

### Why separate Redis databases (firewall db0, page cache db1)

Blast-radius isolation on a shared instance. A page-cache `FLUSHDB` (a
legitimate ops action) can never wipe firewall rules, bans, or audit
history; a firewall test run pointed at db1 can't collide with live data.
Each wrapper gets its own keepalive pool name (`firewall_db0`,
`pagecache_db1`) so a pooled socket `SELECT`ed on one db is never handed
to a caller expecting the other, and `redis_pool` re-`SELECT`s on every
checkout regardless. The index is env-tunable per subsystem
(`FIREWALL_DB`, `PAGECACHE_DB`); the page cache's value must match the WP
purge plugin's (same env var, same default).

### Fail-open everywhere

If Redis is unreachable, `connect()` returns `nil` and every caller
returns early. The site stays up: the firewall is effectively off and the
page cache falls through to PHP until Redis returns. This is preferred
over fail-closed because a Redis outage should not be a site outage.
>>>>>>> prototype-cache-lua-implementation

### Per-pod rules cache + Redis-backed version counter

Each nginx pod runs a single background timer (in worker 0) that polls
`firewall:cache_version` and `firewall:penalties_version` from Redis once
per second (one `MGET`) and mirrors the values into a per-pod shared dict
(`firewall_rc_cache`). Every worker compares `cache_version` to its own
in-memory copy on each request and re-reads
`firewall:rules`/`:config`/`:allowlist`/`:blocklist` from Redis when they
differ. When `penalties_version` advances, worker 0 calls
`blocked_cache:flush_all()` immediately — because `ngx.shared` dicts are
cross-worker, this single call clears stale auto-ban decisions for every
worker in the pod.

Writers bump the counters:
- `INCR firewall:cache_version` — PHP admin save, ops scripts, after writing rules/config.
- `INCR firewall:penalties_version` — `clear_penalties()` after deleting auto-ban keys.

Total cost: one Redis `MGET` (two keys) per pod per second, regardless of
worker count or traffic. Propagation latency: ~1 s cluster-wide.

### Schema validation lives in Lua, exposed over HTTP

The schema for `firewall:rules` and `firewall:config` is defined once in
[firewall/schema.lua](firewall/schema.lua). The WordPress admin form
posts the operator's input to `POST /firewall/admin/validate?kind=rules`
(or `kind=config`) and uses the JSON response (`ok`, `errors`,
`normalised`) to decide whether to write to Redis.

Why an HTTP endpoint instead of a duplicated PHP validator:

- **Single source of truth.** A type or default added in Lua is picked
  up by the admin form on the next request — no parallel PHP validator
  to keep in sync, no schema-drift class of bug.
- **Same parser as the runtime.** The endpoint runs the exact functions
  that read from Redis at request time, wrapped to fail hard instead of
  fail soft. If the runtime would warn-and-skip a rule, the admin sees
  it as an error before save.
- **Read-only and cheap.** No Redis writes, no side effects; restricted
  to loopback in production by the same nginx ACL as the other
  `/firewall/*` admin endpoints.

What this design intentionally does *not* do (yet):

- It does not move Redis writes into nginx. PHP still owns the `SET` and
  the follow-up `INCR firewall:cache_version`. A future phase could
  fold validate + write + bump into a single atomic admin endpoint, but
  that change has more surface area for less marginal value than killing
  the duplicated validator does.
- It does not move runtime reads off PHP. The PHP class still talks
  directly to Redis for the admin "current value" display. Same reason:
  removing the duplicated *validation* code is the high-value change;
  removing the duplicated *read* path is a larger refactor for a
  smaller win.

### Admin endpoint routing is dispatched in Lua, not in nginx locations

All `/firewall/*` admin endpoints are served by a single nginx block:

```nginx
location ^~ /firewall/ {
    allow 127.0.0.1; allow ::1; deny all;  # prod only
    content_by_lua_block { require("firewall.admin").handle_route() }
}
```

`handle_route()` in [firewall/admin.lua](firewall/admin.lua) inspects `ngx.var.uri` and dispatches
to `stats()`, `clear_penalties()`, or `validate()`. An
unrecognised path gets a 404 JSON response.

Why not a separate `location =` block per endpoint:

- **Access control in one place.** The loopback `allow`/`deny` is
  declared once on the parent block and inherited by every endpoint. A
  new endpoint can't be added without the ACL; it's structurally
  impossible to accidentally leave one unrestricted.
- **nginx config stays minimal.** Adding or renaming an endpoint is a
  Lua change only — no nginx config edit, no rebuild required in local
  dev (Lua files are volume-mounted).
- **Testable.** The route table in `handle_route()` is plain Lua data;
  the routing logic can be exercised in the e2e test suite by hitting
  each path, without needing to inspect nginx internals.

### PCRE pattern validation lives in the HTTP endpoint, not the schema module

`schema.lua` validates rule structure (types, required fields, known
keys) but does not call the PCRE engine. This is deliberate: `schema.lua`
is a pure Lua module with no `ngx` dependency, which keeps it fully
unit-testable with plain busted outside an OpenResty worker.

`ngx.re.match` — the PCRE engine — is only available inside a running
nginx worker. Rather than inject it as a parameter (which would make
`validate_rules_strict`'s behaviour conditional and harder to reason
about), the compile-check lives in [firewall/admin.lua](firewall/admin.lua)'s
`compile_check_patterns()` helper, called from `validate()` immediately
after the structural check passes:

```
-- firewall/admin.lua validate()
result = schema.validate_rules_strict(decoded)  -- structure only

if result.ok and result.normalised then
    -- second pass: compile each PCRE pattern with the real engine
    local regex_errors = compile_check_patterns(result.normalised)
    if #regex_errors > 0 then
        result = { ok = false, errors = regex_errors, normalised = nil }
    end
end
```

The layers are honest about their responsibilities: `schema.lua` owns
the schema, `firewall/admin.lua` owns the nginx layer. The compile-check
loop is small enough that the absence of a busted unit test for it is
acceptable — it calls a single well-understood API with no branching
logic of its own.
