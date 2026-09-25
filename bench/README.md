# Benchmarks

Benchmarks cover the operations on the request path. Each sample runs an
operation 100 times so that sub-microsecond operations stay well above timer
resolution; all figures below are per operation.

```sh
mix bench                                   # print results
mix bench --output bench/output/head.json   # also write them as JSON
mix run bench/compare.exs --base a.json --head b.json [--threshold 0.10]
```

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

### M1: state layer

| Scenario | Median | p99 |
|---|---|---|
| state: ban lookup, miss | 53 ns | 93 ns |
| state: gcra check | 118 ns | 163 ns |
| state: window incr, hot key | 138 ns | 208 ns |
| state: window count | 141 ns | 198 ns |
| state: window incr, flood of unique keys | 373 ns | 478 ns |
| plug: dry-run, no signals | 390 ns | 528 ns |
