# Changelog

## Unreleased

First release.

- Instances: configured in the host application's environment
  (`config :my_app, Limen`) and started in its supervision tree, several
  per node if needed, each with its own state and selectable per plug and
  per route.
- `Limen.Plug`: the request gate, with per-route policies, `:off` and
  `:track` routes, dry-run and enforce modes, and an explainable
  `Limen.Decision` for every evaluated request.
- Signals: client address behind trusted proxies, prefix aggregation, JA4
  from the TLS terminator, HTTP shape against the claimed user agent,
  per-prefix behaviour, IP-to-ASN classification and FCrDNS crawler
  verification.
- `Limen.Policy`: a compiled DSL with `limit`, `allow`, `deny`, `score` and
  `decide`, compile-time validation and per-rule explanations.
- Proof-of-work challenges with stateless tokens, a vendored solver,
  single-use tokens, pass cookies and a no-JavaScript fallback.
- Lock-free state: sliding windows, GCRA limits, bans, Count-Min Sketch,
  Bloom filters and HyperLogLog, all with bounded memory.
- LiveView and socket gating, cluster ban propagation and a LiveDashboard
  page.
