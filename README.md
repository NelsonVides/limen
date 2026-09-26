# Limen

*Limen* (Latin): threshold. The point every request crosses before it enters.

Limen is native Elixir L7 bot protection: a Plug that classifies requests,
rate-limits, challenges and blocks automated traffic entirely inside the BEAM.
No sidecar, no external service: all state lives in ETS, `:atomics` and
`:persistent_term`, and nothing on the request path calls a process or sends
a message.

- **Fingerprints and behaviour**: client prefixes (IPv6 aggregated to /64),
  [JA4] TLS fingerprints from your TLS terminator (a hash of what the client's
  TLS library offers in the handshake), HTTP header shape against the claimed
  user agent, per-client request, 404 and asset patterns, hosting [ASNs][ASN]
  (the numbered networks addresses belong to, such as a cloud provider's), and
  search engine crawlers verified with [forward-confirmed reverse DNS][FCrDNS]
  (the address's DNS name must belong to the crawler and resolve back to it).
- **A compiled policy DSL**: rules become plain functions at compile time, and
  every decision records which rules matched and the values they saw.
- **Proof-of-work challenges** modelled on the [Anubis] proxy: the browser
  searches for a hash with enough leading zero bits, a fraction of a second
  for a visitor but a cost a scraper pays again for every identity it uses.
  Stateless [HMAC]-signed tokens (a hash only holders of the secret can
  compute), a vendored solver on the browser's [Web Crypto API], single-use
  tokens, and a pass cookie checked on a fast path of a few microseconds.
- **Honeypots and a maze**: hidden links and form fields catch clients that
  act unlike people, and send them to endless, slow, plausible pages written
  by a [Markov chain] (each word drawn from those that followed the previous
  two in real text), the same for your site on every visit and unpredictable
  anywhere else.
- **Dry-run first**: every policy can observe without acting, producing exactly
  the decisions it would enforce.
- **Built for Phoenix**: per-route policies and instances, a LiveView socket
  gate, cluster ban propagation over [`:pg`][pg] (Erlang's distributed process
  groups), and a LiveDashboard page.

## Quick start

```elixir
def deps do
  [
    {:limen, "~> 0.1"}
  ]
end
```

Configure Limen in your application's environment, start an instance in
your supervision tree, and add the plug to your endpoint, before the router:

```elixir
# config/runtime.exs
config :my_app, Limen,
  secret_key: System.fetch_env!("LIMEN_SECRET_KEY"),
  trusted_proxies: ["10.0.0.0/8"],
  client_ip_header: "x-forwarded-for"
```

```elixir
# lib/my_app/application.ex, before the endpoint
children = [{Limen, otp_app: :my_app}, MyAppWeb.Endpoint]
```

```elixir
# lib/my_app_web/endpoint.ex, before Plug.Static and the router
plug Limen.Plug,
  otp_app: :my_app,
  routes: [
    {"/health", :off},
    {"/assets", :track}
  ]
```

Limen starts in dry-run mode with `Limen.Policy.Default`: every decision is
computed, emitted as telemetry and sampled into the decision log, but nothing
is blocked until you switch to `:enforce`. See the
[getting started guide](guides/getting-started.md) and the
[dry-run rollout guide](guides/dry-run-rollout.md).

Each application configures and starts its own instances, so several can run
side by side: one per endpoint, a stricter one for some routes, or one per
test. The request path finds its instance with a single `:persistent_term`
read.

## A policy

```elixir
defmodule MyApp.BotPolicy do
  use Limen.Policy

  limit :flood, key: :prefix, rate: 50, per: :second, burst: 100

  allow :verified_crawler, when: signal(:fcrdns) == :verified
  deny :known_bad_ja4, when: signal(:ja4) in list(:bad_ja4), ban: 3_600

  score :no_accept_language, 20, when: missing_header("accept-language")
  score :datacenter_asn, 30, when: signal(:asn_kind) == :hosting
  score :spoofed_browser, 40, when: shape_flag(:no_client_hints)
  score :burst, 40, when: rate(:prefix, per: :second) > 20

  decide do
    score >= 80 -> :deny
    score >= 40 -> {:challenge, difficulty: difficulty_for(score)}
    true -> :allow
  end
end
```

Referencing a signal no configured signal module provides is a compile error.
Every decision explains itself:

```
challenge(difficulty: 16) (enforced) at stage decide by MyApp.BotPolicy, score 70
  prefix: 203.0.113.0/24
  score datacenter_asn +30 when signal(:asn_kind) == :hosting [signal(:asn_kind) = :hosting]
  score burst +40 when rate(:prefix, per: :second) > 20 [rate(:prefix, per: :second) = 35]
  decided by: score >= 40 -> {:challenge, difficulty: difficulty_for(score)}
  signal asn = 16509 ...
```

## How a request is handled

```
request
  │
  ▼
Limen.Plug
  ├── Identify   client address behind trusted proxies, prefix, JA4
  ├── Trap?      trap path → flag the prefix, maze
  ├── Ban?       banned prefix → deny, or maze
  ├── Limit      GCRA hard limits → throttle
  ├── Pass?      valid pass cookie → allow (fast path)
  ├── Collect    signals → %Limen.Context{}
  ├── Score      policy rules → score + matched rules
  ├── Decide     allow | challenge(difficulty) | throttle | deny | tarpit | maze
  └── Act        respond or continue, emit telemetry
```

Hard limits use [GCRA], the generic cell rate algorithm: a leaky bucket that
stores a single timestamp per key.

## Performance

Median cost per request on an Apple M4 Pro (see [bench/README.md](bench/README.md)):

| Path | Median |
|---|---|
| Valid pass cookie (fast path) | 4.1 µs |
| Full evaluation with the default policy and signals | 9.0 µs |

Benchmarks run in CI on every pull request, against the base branch on the
same runner, and fail the build on a regression over 10%. State is bounded:
a flood of a million unique IPv6 /64 prefixes leaves memory where it was
after a hundred thousand.

## Guides

- [Getting started](guides/getting-started.md)
- [Concepts](guides/concepts.md)
- [Rolling out with dry-run](guides/dry-run-rollout.md)
- [Honeypots and the maze](guides/honeypots-and-maze.md)
- [JA4 behind nginx](guides/nginx-ja4.md)
- [Tuning](guides/tuning.md)

## Verification

`mix precommit` runs every check CI runs, in one command.

Besides unit, property and doctest suites, CI runs the vendored solver under
Node.js against the server, floods the state layer with a million unique
prefixes, and propagates bans between two nodes. A real-browser test
(`mix test --only browser`) drives Chrome or Firefox through the challenge.
Static checks include `credo --strict` with most opt-in checks, a custom
check that forbids process messaging outside background processes,
`boundary` layering, dialyzer and docs built with warnings as errors.

## Licensing

Limen is Apache-2.0 licensed. JA4 (the TLS client fingerprint) is
[BSD-3-Clause][JA4 license]; other JA4+ methods have been published under the
more restrictive [FoxIO License], and Limen implements none of them. The HTTP
shape signal is an independent design.

## License

Apache-2.0. See [LICENSE](LICENSE).

[JA4]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md
[ASN]: https://www.rfc-editor.org/rfc/rfc1930
[FCrDNS]: https://developers.google.com/search/docs/crawling-indexing/verifying-googlebot
[Anubis]: https://anubis.techaro.lol/
[HMAC]: https://www.rfc-editor.org/rfc/rfc2104
[Web Crypto API]: https://www.w3.org/TR/WebCryptoAPI/
[Markov chain]: https://en.wikipedia.org/wiki/Markov_chain
[pg]: https://www.erlang.org/doc/apps/kernel/pg.html
[GCRA]: https://www.itu.int/rec/T-REC-I.371
[JA4 license]: https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE-JA4
[FoxIO License]: https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE
