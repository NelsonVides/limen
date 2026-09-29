# Concepts

Every request Limen sees ends in one *decision*. To reach it, Limen works out
*who* the client is, collects *facts* about the request, judges them with a
*policy*, and carries out an *action*. Everything else is either the shared
memory these steps use or the tooling that observes them.

```
request ─▶ identity ─▶ signals ─▶ policy ─▶ decision ─▶ action
            (who)      (facts)  (judgement) (verdict) (what happens)
                 ╲         │          │           │         ╱
                  ╲────────┴── state ─┴───────────┴────────╱
                      (shared memory: counters, bans, sketches)
```

All of it runs inside an *instance*, and observability watches every
decision from the side.

## Containers

| Term | Meaning |
|---|---|
| Instance | A running, named Limen with its own configuration, tables and background processes (`Limen.Instance`). An application can run several, such as `:public` and `:admin`. Each request reads its instance once, from `:persistent_term`. |
| Config | The instance's validated options (`Limen.Config`). |
| Context | Everything known about one request while it is evaluated (`Limen.Context`). Signals write to it and policies read from it. |

## Identity: who is this?

| Term | Meaning |
|---|---|
| Client IP | The client's address, read from forwarding headers only when they come from a trusted proxy (`Limen.Signal.ClientIP`). |
| Prefix | The client IP aggregated to a network, `/32` for IPv4 and `/64` for IPv6 by default. It is the unit Limen counts and bans, since a single IPv6 user holds a whole `/64`. |
| JA4 | A fingerprint of the client's TLS handshake, computed by the TLS terminator and passed in a header (`Limen.Signal.JA4`). |

Identity is resolved for every request, before anything else, because pass
cookies and bans are bound to it.

## Facts: signals

| Term | Meaning |
|---|---|
| Signal | A module that computes named facts about a request: `provides/0` lists their names and `collect/1` computes them (`Limen.Signal`). The built-in ones are `Limen.Signal.HttpShape`, `Limen.Signal.Behaviour`, `Limen.Signal.Asn` and `Limen.Signal.Fcrdns`. |
| Signal value | One named fact, such as `:ua_family`, `:asn_kind` or `:not_found_ratio`. Policies refer to values, not modules. |
| Evidence | Details attached to a value that explain it, such as the parsed user agent or the host a crawler's address resolved to. |
| Shape and shape flags | The hash of a request's header order, and the inconsistencies between its headers and its user agent, from `Limen.Signal.HttpShape`. |
| Behaviour | What a prefix did over the last minute: requests, pages, assets, `404`s and new paths (`Limen.Signal.Behaviour`). These are counts kept in the state, not properties of the current request. |

Signals only observe: they never decide or block anything.

## Judgement: policies

| Term | Meaning |
|---|---|
| Policy | A module written with `Limen.Policy`: the signals it needs, its rules and a `decide` block. `Limen.Policy.Default` is the built-in one. |
| Rule | One named line of a policy: `trust`, `allow`, `deny`, `maze`, `score` or `limit`, with its condition in `when:`. |
| Fact | Something the application knows about a request and Limen cannot, such as whether the client is signed in, stated with `Limen.put_facts/2` and read with `fact(:signed_in)`. |
| Trust | A `trust` rule allows a client before anything else happens, bans and limits included: for clients the application vouches for, usually with a fact. |
| Score | The sum of the weights of the matching `score` rules, so that many weak facts add up to one number. |
| `decide` | The block that turns the score into an action, such as `score >= 150 -> :deny`. |
| Limit | A hard cap per client, such as 100 requests a second, enforced with [GCRA] (`Limen.State.Gcra`). Limits are checked before any rule; exceeding one throttles. |
| Rate | A soft count over a sliding window, such as `rate(:prefix, per: :minute)`, usually feeding a `score` rule (`Limen.State.Window`). |
| List | A named set, such as allowed addresses or bad JA4 fingerprints, tested with `value in list(name)` (`Limen.Lists`). |
| Route | A path prefix mapped to a policy, or to `:off` or `:track`, in the options of `Limen.Plug`, so `/login` can use a stricter policy than the rest of the site. |

A limit is exact and blocks; a rate is approximate and only scores.

## Verdict: the decision

| Term | Meaning |
|---|---|
| Decision | The record of one verdict (`Limen.Decision`): the action, the stage, the score, the matching rules, every signal value with its evidence, and the time it took. `Limen.Decision.explain/1` renders it. |
| Action | What should happen: `:allow`, `:challenge`, `:throttle`, `:deny`, `:tarpit` or `:maze`. |
| Stage | Where the decision was reached, and so which mechanism made it: `:trust`, `:ban`, `:limit`, `:pass`, `:rule`, `:decide`, `:trap`, `:socket`, `:endpoint` or `:off`. |
| Mode | `:dry_run` or `:enforce`. In dry-run mode everything is computed and recorded as in enforce mode, and only the final action is skipped. See [Rolling out with dry-run](dry-run-rollout.md). |
| Enforced | Whether the decision's action was actually carried out. |

## Actions: what happens to the client

| Term | Meaning | Built from |
|---|---|---|
| Challenge | A proof-of-work page: the browser finds a hash with a number of leading zero bits (the *difficulty*) before going on (`Limen.Challenge`). | A signed token, a JavaScript solver and a replay guard |
| Pass | The cookie a solved challenge earns, bound to the client's prefix and JA4. While it is valid, requests take the *fast path*, skipping signals and rules (`Limen.Challenge.Pass`). | An HMAC over an expiry and the identity |
| Throttle | `429 Too Many Requests` with `Retry-After`. | A limit |
| Deny | `403 Forbidden`, optionally with a ban. | |
| Ban | A prefix refused until an expiry, in the ban list (`Limen.State.BanList`). A ban whose action is `:maze` is a *flag*. | An ETS table, a sweeper and cluster propagation |
| Tarpit | Silence, then `403`: refused clients pay for asking in time (`Limen.Tarpit`). | A bounded sleep |
| Maze | Endless, slowly served pages that link ever deeper, to waste a scraper's time and crawl budget (`Limen.Maze`). | A Markov chain, weighted dice and seeded randomness |
| Trap | A honeypot: a hidden link, or a decoy form field, that no person uses. Using one is a *confession*: the prefix is flagged and sent to the maze (`Limen.Trap`). | Hidden links, decoy fields and signed timestamps |

*Honeypots* covers traps and the maze together; see [Honeypots and the
maze](honeypots-and-maze.md).

## Shared memory: the state

The state is a set of data structures, not features: the features above are
built on them. Each is lock-free and bounded (`Limen.State`).

| Term | Meaning | Used by |
|---|---|---|
| Window | Sliding-window counters in three rotating slots, a key holding one count or a row of several (`Limen.State.Window`). | Rates, behaviour, the dashboard |
| GCRA | One timestamp per key: when its next request is due (`Limen.State.Gcra`). | Limits |
| Ban list | Prefix to expiry, reason and action (`Limen.State.BanList`). | Bans, flags, the cluster |
| Sketches | Fixed-size approximate structures: a Count-Min Sketch for how many times (`Limen.Sketch.CountMin`), Bloom filters for whether something was seen (`Limen.Sketch.Bloom`, `Limen.Sketch.RotatingBloom`), and a HyperLogLog for how many distinct (`Limen.Sketch.HyperLogLog`). | Full window slots, challenge replays, distinct paths, active prefixes |
| Caps | Every table has a maximum size. Past it, new keys go to a sketch or are refused, and the `:saturated` counter rises. See [Tuning](tuning.md). | |

## Background work

Processes do the slow work, away from requests; requests only read what
they produce. Nothing on the request path calls a process or sends a
message.

| Process | Job |
|---|---|
| `Limen.State.Rotator` | Clears old window slots, estimates active prefixes |
| `Limen.State.Sweeper` | Removes expired bans and idle limits |
| `Limen.Signal.Fcrdns.Resolver` | Verifies crawlers with DNS |
| `Limen.Signal.Asn.Loader` | Loads and refreshes the IP-to-ASN data |
| `Limen.Challenge.Replay.Rotator` | Ages out solved challenges |
| `Limen.Cluster` | Broadcasts bans to other nodes |
| `Limen.DecisionLog.Flusher` | Logs sampled decisions |

## Observability

| Term | Meaning |
|---|---|
| Stats | Counters per action and event (`Limen.Stats`). |
| Telemetry | A `[:limen, :decision]` event per decision, and events for the maze and challenges (`Limen.Telemetry`). |
| Decision log | A sampled ring buffer of whole decisions (`Limen.DecisionLog`). |
| Dashboard | A LiveDashboard page built on all of the above (`Limen.Dashboard`). |

## Sockets

Phoenix sockets bypass plugs. Pages embed a signed token proving that the
client passed `Limen.Plug` recently, and the socket checks it when it
connects (`Limen.Socket`, `Limen.LiveView`).

## How the layers interact

1. Identity keys everything: state, passes, bans and socket tokens.
2. Signals read the state but never decide.
3. Policies read signal values and lists, and write only their own counters:
   rates in the window, limits in GCRA.
4. Decisions are records. `Limen.Plug` turns one into an action, and only
   in enforce mode.
5. Actions write state that later decisions read: a deny can add a ban, a
   trap adds a flag, a solved challenge issues a pass. The next request
   checks bans and passes before collecting any signal, which is why they
   are stages of their own.
6. Background processes keep the state bounded and current, and
   observability reads decisions and state without touching the request
   path.

Within one request, the stages that can end the evaluation run in this
order: a trusted client (`:trust`); a trap route (`:trap`); a ban or flag
(`:ban`); an exceeded limit (`:limit`); a valid pass (`:pass`). Otherwise the policy's signals are
collected, and a hard rule decides (`:rule`) or the score does (`:decide`).
Behaviour and rates are counted before any of these, so they include every
request. Last, the decision is recorded and emitted, and its action is
carried out in enforce mode.

[GCRA]: https://www.itu.int/rec/T-REC-I.371
