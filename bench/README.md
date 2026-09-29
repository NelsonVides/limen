# Benchmarks

Benchmarks cover the operations on the request path. Each sample runs an
operation 100 times so that sub-microsecond operations stay well above timer
resolution; all figures below are per operation.

```sh
mix bench                                   # print results
mix bench --output bench/output/head.json   # also write them as JSON
mix run bench/compare.exs --base a.json --head b.json [--threshold 0.10]
MIX_ENV=bench mix run bench/stages.exs      # the full path, stage by stage
```

`bench/stages.exs` runs the full path cumulatively, one more stage of
`Limen.Plug` per job, and prints what each stage adds. Differences between
neighbouring jobs carry some noise, about ±0.2 µs; it attributes cost, and the
scenarios above measure it.

## Regression gate

On every pull request, CI benchmarks the base branch and the pull request on
the same runner, alternating two runs of each, and compares the fastest median
of every scenario. Any scenario more than 10% slower fails the build. The
comparison table is written to the job summary, and raw results are uploaded
as the `benchmarks` artifact on every run.

## Baselines

Apple M4 Pro (14 cores), Elixir 1.20.4, OTP 29.1.1, 2 s per scenario. The
plug scenarios resolve a Chrome client behind a trusted proxy with a JA4
header; the full path rotates through 20,000 clients so none of them hits a
limit, and evaluates `Limen.Policy.Default` with its default signals.

### 0.1.0

| Scenario | Median | p99 |
|---|---|---|
| state: ban lookup, miss | 54 ns | 95 ns |
| state: gcra check | 127 ns | 167 ns |
| state: window count | 130 ns | 185 ns |
| state: window incr, hot key | 141 ns | 182 ns |
| state: window incr, flood of unique keys | 384 ns | 589 ns |
| policy: evaluate default, chrome | 604 ns | 725 ns |
| signals: identity via proxy | 1.01 µs | 1.42 µs |
| challenge: verify pass cookie | 1.17 µs | 1.44 µs |
| challenge: verify token | 1.22 µs | 1.47 µs |
| signals: http shape, chrome | 1.95 µs | 2.27 µs |
| plug: pass fast path, chrome via proxy | 4.07 µs | 5.24 µs |
| plug: dry-run, default policy, chrome via proxy | 9.03 µs | 16.54 µs |

The flood scenario counts a new key on every call with the exact tables
capped at 1,000 keys, so almost every call takes the saturated path: a
membership check plus a Count-Min Sketch update.

The HTTP shape scenario ran on a request without identity, so its user agent
was never parsed. It was replaced by `signals: http shape, chrome via proxy`,
on an identified request, which took 3.3 µs at 0.1.0.

The pass fast path scenario sent the same client on every call, which
exceeds the default policy's flood limit after 200 requests. Limits are
checked before passes, so it mostly measured throttled requests. It was
replaced by `plug: pass holders, chrome via proxy`, in which each of 20,000
clients holds a pass of its own.

### M8: honeypots and the maze

Trap paths and ban actions leave the request path unchanged (every scenario
above within noise of 0.1.0). Rendering a maze page happens once per maze
response, which then spends seconds asleep:

| Scenario | Median | p99 |
|---|---|---|
| maze: render page | 141 µs | 161 µs |

### IP-to-ASN data in `:persistent_term`

Lookups in a synthetic table as dense as the iptoasn.com data (450,000 IPv4
and 120,000 IPv6 ranges), each picking the next of 10,000 addresses. Every
other scenario stayed within noise.

| Scenario | Median | p99 |
|---|---|---|
| signals: asn lookup, ipv4 | 181 ns | 334 ns |
| signals: asn lookup, ipv6 | 345 ns | 579 ns |

Against the ETS tables they replace, on the real data (580,830 ranges) and
random addresses inside routed ranges. With 14 processes looking up at once,
times are wall time per lookup: the ETS tables serve about twice as many
lookups per second as with one process, the packed table about seven times
as many.

| | ETS | Packed |
|---|---|---|
| memory | 85 MB | 9.7 MB |
| IPv4 lookup, one process | 876 ns | 255 ns |
| IPv6 lookup, one process | 1,070 ns | 325 ns |
| IPv4 lookup, 14 processes | 453 ns | 37 ns |
| IPv6 lookup, 14 processes | 451 ns | 54 ns |

### M1: state layer

| Scenario | Median | p99 |
|---|---|---|
| state: ban lookup, miss | 53 ns | 93 ns |
| state: gcra check | 118 ns | 163 ns |
| state: window incr, hot key | 138 ns | 208 ns |
| state: window count | 141 ns | 198 ns |
| state: window incr, flood of unique keys | 373 ns | 478 ns |
| plug: dry-run, no signals | 390 ns | 528 ns |
