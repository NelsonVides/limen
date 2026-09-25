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

### M1: state layer

Apple M4 Pro (14 cores), Elixir 1.20.4, OTP 29.1.1, 2 s per scenario.

| Scenario | Median | p99 |
|---|---|---|
| state: ban lookup, miss | 53 ns | 93 ns |
| state: gcra check | 118 ns | 163 ns |
| state: window incr, hot key | 138 ns | 208 ns |
| state: window count | 141 ns | 198 ns |
| state: window incr, flood of unique keys | 373 ns | 478 ns |
| plug: dry-run, no signals | 390 ns | 528 ns |

The flood scenario counts a new key on every call with the exact tables
capped at 1,000 keys, so almost every call takes the saturated path: a
membership check plus a Count-Min Sketch update.
