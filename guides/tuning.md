# Tuning

## Client prefixes

Limen keys all state on a client *prefix*: IPv4 addresses aggregated to `/32`
and IPv6 addresses to `/64` by default. One IPv6 subscriber usually controls
at least a `/64` ([RFC 6177] asks ISPs for significantly more, and many assign
a `/56` or `/48`), so aggregating less would let a single client look like
billions.

- `ipv6_prefix: 56` or `48` counts larger allocations as one client. Use it
  when you see floods rotating through a `/56` or `/48`; it also groups more
  unrelated users together.
- `ipv4_prefix: 24` groups neighbouring IPv4 addresses.
  [Carrier-grade NAT][CGNAT], where an ISP shares one address between many
  customers, already puts many users behind one IPv4 address; aggregating
  further makes that worse, so only do it against floods from hosting ranges.

## Memory

Each instance has its own state, bounded by caps in its `:state`
configuration:

| Table | Default cap | Cost per entry |
|---|---|---|
| each time-window slot (9: 3 windows × 3 slots) | `max_keys: 50_000` | about 180 bytes |
| GCRA limits | `gcra_max_keys: 100_000` | about 160 bytes |
| bans | `max_bans: 100_000` | about 146 bytes |

plus about 4.5 MB allocated when the instance starts: a [Count-Min Sketch]
(fixed-size counters that may overcount but never undercount) per window
slot (`sketch_width × sketch_depth × 8` bytes), the rotating [Bloom filter]
of client paths (`path_filter_capacity`) and the prefix
[HyperLogLogs][HyperLogLog] (distinct counters, `hll_precision`).

The worst case at the defaults is around 120 MB per instance, reached only if
every table fills at once. Instances that serve little traffic can use much
smaller caps. In practice the second and minute windows fill first, since
behaviour tracking and most rate rules use them; the hour window only holds
keys for policies that use `per: :hour`.

When a window slot is full, new keys are counted in the slot's Count-Min
Sketch instead: estimates may then overcount (by at most
`e / sketch_width` of the slot's overflow traffic), never undercount. When
the GCRA table is full, new keys are not limited. When the ban list is full,
new bans are refused. Each case increments the `:saturated` counter shown on
the dashboard; if it keeps rising outside attacks, raise the caps.

## IP-to-ASN data

The full [iptoasn.com][iptoasn] data, about 580,000 routed ranges, takes
about 10 MB in each instance that loads it, in a single `:persistent_term`
entry of binaries. A lookup takes a few hundred nanoseconds and copies
nothing. Loading or refreshing the data takes a few seconds of one scheduler
and about 90 MB more memory for that time, in a process of its own.

With a `:url`, each node keeps the data current by itself: the file is where
downloads are kept, so a node that restarts loads what it had and does not
wait for the network. iptoasn.com updates its data every hour, but ranges
change slowly, so the default daily check is plenty. A check that finds
nothing new costs one small request.

```elixir
config :my_app, Limen,
  asn: [
    file: "/var/lib/my_app/ip2asn-combined.tsv.gz",
    url: "https://iptoasn.com/data/ip2asn-combined.tsv.gz",
    refresh: [
      every: :timer.hours(24),
      jitter: 0.25,
      window: {~T[02:00:00], ~T[05:00:00]},
      max_utilization: 0.75,
      max_memory: 6 * 1024 ** 3
    ]
  ]
```

- `:jitter` spreads nodes out: each waits up to that share of `:every` more,
  at random.
- `:window` keeps checks to quiet hours (UTC); a check due outside it moves
  to a random time inside the next one. Several windows can be given as a
  list.
- `:max_utilization` (0.9 by default) and `:max_memory` postpone a
  scheduled check while the node is busy, by `:retry` at a time. The
  scheduler utilization is sampled for a second before each check.
- A failed or implausible download (less than half the ranges already
  loaded) keeps the current data and is retried after `:retry`, doubling up
  to `:every`.

`Limen.Signal.Asn.Loader.refresh/1` checks at once, and the dashboard shows
what is loaded, the last check and the next one. The `[:limen, :asn, :loaded]`
and `[:limen, :asn, :checked]` telemetry events report every load and check.

If your application already keeps IP data current, such as MaxMind's
GeoLite2 databases, point the signal at it with `asn: [source: MyApp.GeoAsn]`
(see `Limen.Signal.Asn.Source`) and Limen loads nothing of its own.

## Rates and limits

`rate(dimension, per: window)` in a policy is a sliding-window estimate over
the last second, minute or hour, counted for every request the policy sees,
including clients holding a pass. It is cheap and approximate.

`limit` rules are hard [GCRA] limits (the generic cell rate algorithm, a
leaky bucket that stores one timestamp per key), checked before anything
else, even for clients holding a pass. `rate: 50, per: :second, burst: 100`
admits a steady 50 requests per second and bursts of up to 101 at once. Over
any interval of length `Δ`, at most `Δ × rate / period + burst + 1` requests
get through. `Limen.State.Gcra` explains how it works, with an example.

Limits and rates are per node. Behind a load balancer spreading each client
over `n` nodes, a client gets up to `n` times the limit.

## Challenge difficulty

Difficulty is the number of leading zero bits the [SHA-256] hash of the token
and nonce must have. The expected work doubles with every bit. Times below are
the vendored worker measured under Node.js on an Apple M4 Pro with a single
worker; browsers split the search over up to eight workers, while phones are
several times slower per core, so treat them as an order of magnitude:

| Bits | Expected hashes | One worker, M4 Pro |
|---|---|---|
| 14 | 16 thousand | 0.03 s |
| 16 | 65 thousand | 0.17 s |
| 18 | 262 thousand | 0.35 s |
| 20 | 1 million | 2.9 s |
| 22 | 4 million | around 12 s |

Solving time varies a lot between attempts: it is a geometric distribution, so
some clients get lucky and some take several times the average.

`difficulty_for(score)` maps scores to difficulty: 16 bits up to a score of 40,
plus a bit every 20 points, up to 22. Pass options to change the curve:
`difficulty_for(score, base: 14, from: 50, step: 25, max: 20)`.

The point is not that a bot cannot pay: it is that paying for every identity
it rotates through is expensive, while a person pays once per pass.

## Pass lifetime

`challenge: [pass_ttl: 3_600]` is how long a solved challenge is honoured. A
pass is bound to the client prefix, JA4 and user agent, so it also ends when
any of those change (a phone switching from Wi-Fi to mobile data, a browser
update). Longer passes mean fewer interruptions for people and more reuse by
anyone who can keep the identity stable.

`challenge: [bind: [:ja4, :user_agent]]` stops binding passes (and socket
tokens) to the address: a pass then survives network changes, which suits
mobile visitors and [carrier-grade NAT][CGNAT], where addresses change or
are shared. The price is that a copied pass works from any address with the
same JA4 and user agent, and a scraper can share one solved challenge across
its whole pool of addresses. Pair it with a shorter `:pass_ttl`, and keep
limits, which apply to pass holders too, per prefix.

## Tarpit

`{:tarpit, delay: ms}` holds a request before denying it: cheap for the BEAM,
costly for a scraper waiting on the connection. `tarpit: [max_concurrent:
1_000, max_delay: 30_000]` bounds how many requests are held at once and for
how long, since each still holds a connection on your side. A tarpit judges
each request on its own and bans nobody; see
[Maze or tarpit?](honeypots-and-maze.md#maze-or-tarpit) to choose between the
two.

## The maze

Rendering a maze page takes around 150 microseconds; the rest of a maze
response is spent asleep, so its cost is the connection and process it holds
(a few kilobytes) for up to `:max_duration`. `maze: [max_concurrent: 200]`
bounds how many are held at once; beyond that, clients get an immediate
`429`. Raise it if the dashboard shows many refused maze requests and you have
connections to spare, lower it if your proxy or server limits connections
tightly. Keep `:max_duration` under your proxy's read timeout. An `:admit`
function (see `Limen.Maze`) turns clients away while your application is
busy, and `Limen.Maze.held/1` tells how many responses are held.

Longer `:delay`s waste more of a scraper's time per byte; longer pages
(`:paragraphs`) and more links (`:links`) give it more to crawl. A client in
the maze only costs you what it holds, so err on the slow side.

`trap: [ban: 86_400]` is how long a trapped prefix stays in the maze. Keep it
moderate where many people share IPv4 addresses (carrier-grade NAT, offices),
since a ban covers the whole prefix.

## The default policy

`Limen.Policy.Default` is deliberately conservative: it challenges at a score
of 50, denies at 150 and never bans. `Limen.Policy.describe/1` prints its
rules. To change it, copy it into your application and edit the weights and
thresholds; a policy is just a module.

Weights and thresholds you expect to adjust as you learn your traffic can be
parameters (see `Limen.Policy`): declared with defaults in the policy, set
per instance with the `:params` option, and changed at runtime with
`Limen.update_config/3`, without a deploy. Every value a decision used is
recorded in it.

## Decision log sampling

`decision_log: [sample_rate: 0.0, non_allow_sample_rate: 1.0]` logs every
non-allow decision and no allowed ones. Under attack, non-allow decisions can
be most of your traffic: the log's ring buffer (`size: 1024`) then drops the
oldest entries between flushes and says so, rather than slowing requests down.
Lower `non_allow_sample_rate` if the log gets too loud.

## Measuring

`mix bench` measures the request path on your hardware; see
[bench/README.md](https://github.com/NelsonVides/limen/blob/main/bench/README.md).
In production, `[:limen, :decision]` events carry the evaluation time in
native time units as `duration`.

[RFC 6177]: https://www.rfc-editor.org/rfc/rfc6177
[CGNAT]: https://www.rfc-editor.org/rfc/rfc6888
[Count-Min Sketch]: https://doi.org/10.1016/j.jalgor.2003.12.001
[Bloom filter]: https://doi.org/10.1145/362686.362692
[HyperLogLog]: https://doi.org/10.46298/dmtcs.3545
[GCRA]: https://www.itu.int/rec/T-REC-I.371
[SHA-256]: https://csrc.nist.gov/pubs/fips/180-4/upd1/final
[iptoasn]: https://iptoasn.com/
