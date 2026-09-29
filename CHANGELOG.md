# Changelog

## 0.2.0

Changes that came from running Limen in front of a real application.
Several are breaking; "Upgrading from 0.1" below says what to change.

### Added

- Facts: `Limen.put_facts/2` (and `Limen.LiveView.put_facts/2` and the
  `:facts` option of `Limen.Socket.check/3` and `Limen.Trap.check_form/3`
  for sockets) state what the application knows about a request, such as
  whether the client is signed in. Policies read them with `fact(:name)`,
  and every decision records them in its new `:facts` field.
- `trust` rules: `trust :signed_in, when: fact(:signed_in)` allows a client
  before bans, limits, passes and every other rule, at the new `:trust`
  stage. `Limen.Plug` checks them for trap paths too, and
  `Limen.Socket.check/3` and the `Limen.LiveView` hook take a `:policy`
  whose trust rules they check, so sockets agree with the HTTP gate.
- `Limen.Plug`'s `:policy` also takes `:off` or `:track`. The guides
  describe gating in a router pipeline, after the facts, with an endpoint
  plug (`policy: :off`) that only serves Limen's endpoints and trap paths.
- Policy parameters: `use Limen.Policy, params: [name: default]` and
  `param(:name)` in conditions, score weights and `decide`, overridden per
  instance with the new `:params` option and at runtime. Decisions record
  the values used, including those of the matching `decide` clause in the
  new `:clause_observed` field.
- `Limen.update_config/3` changes an option of a running instance, merging
  keyword options into their current values.
- User agents: the new `:ai_crawler` and `:link_preview` families, built-in
  lists of AI crawlers (after ai.robots.txt) and link preview services, a
  `:ua_name` signal with the name of a known automated client, and a
  `:user_agents` option extending, moving and removing tokens per instance.
- Substring lists: `Limen.Lists.put_substrings/3` and
  `{:substrings, [...]}` in `:lists`, matching strings containing a member.
- `Limen.Signal.Asn.Source`: the `:asn` `:source` option looks addresses up
  somewhere else than the iptoasn.com data, such as MaxMind databases the
  application already has.
- The `:challenge` `:bind` option: what pass cookies and socket tokens are
  bound to, any of `:prefix`, `:ja4` and `:user_agent` (all three by
  default), for instance to keep passes across networks.
- The `:challenge` `:page` option and the `Limen.Challenge.Page` behaviour:
  the challenge page's texts per request, in the visitor's language, and
  its markup.
- The maze's `:admit` option, `{module, function, args}`, refuses clients
  while the application is under load; `Limen.Maze.held/1` reads how many
  it holds; `[:limen, :maze, :refused]` telemetry reports refusals.
- `Limen.DecisionLog.Sink`: the `:decision_log` `:sink` option writes
  sampled decisions somewhere else than `Logger`, in batches, from the
  flusher's process.
- `Limen.Test`: `put_mode/2` (enforce one request in an otherwise dry-run
  test instance), `put_client_ip/2` (the same client for the HTTP gate and
  LiveViewTest sockets), `unique_ip/0`, `socket_params/2` and
  `put_socket_token/2`, and a testing guide.

### Changed

- `boundary` is no longer a dependency of applications: Limen's modules
  only declare their boundaries when its own build runs the boundary
  compiler.
- `via_proxy` in contexts and decisions is only `true` when the client
  address came from a forwarding header, not whenever the peer is a
  trusted proxy. Trusted peers are still trusted with the JA4 header.
- `[:limen, :fcrdns, :resolved]` metadata is flat: `:result` is
  `:verified`, `:failed` or `:error`, with `:host` and `:reason` alongside.
- Several user agent markers moved from `:crawler` to the new families,
  and `facebookexternalhit` is named `"facebookexternalhit"`, not
  `"facebook"`.
- `Limen.Instance.put_config` is replaced by `Limen.update_config/3`
  (and `Limen.Instance.update_config/3`), which merges instead of resetting
  a group to its defaults, and refuses options only read at startup.
- The decision log's `:level` option moved to its default sink.
- `Limen.Decision.explain/1` shows negative weights as `-20`, not `+-20`.

### Fixed

- `Limen.Plug` could reject a valid policy, depending on compilation order,
  when initialised while the application compiled; it now waits for the
  policy to compile.
- `Limen.LiveView.check_form/3` recorded the socket's path
  (`/live/websocket`) instead of the page's.
- `Limen.Telemetry` documented `[:limen, :fcrdns, :resolved]` metadata the
  resolver did not send.

### Upgrading from 0.1

- **Runtime configuration.** Replace `Limen.Instance.put_config(name, key,
  value)` with `Limen.update_config(name, key, value)`. Only the keys you
  pass change now: drop code that read the other keys back to pass them
  again. Changing an option read only at startup (see `Limen.Config`) now
  raises instead of doing nothing.
- **Decision log level.** Replace `decision_log: [level: :debug]` with
  `decision_log: [sink: {Limen.DecisionLog.Logger, level: :debug}]`.
- **User agent families.** Rules comparing `signal(:ua_family)` with
  `:crawler` no longer match AI crawlers (`GPTBot`, `ClaudeBot`, `CCBot`,
  `Bytespider`, `Amazonbot` and others) or link previews
  (`facebookexternalhit`, `Twitterbot`, `LinkedInBot` and others); use
  `in [:crawler, :ai_crawler, :link_preview]` for all of them, or the new
  families on their own. To keep a token in its old family, list it under
  `:crawler` in the `:user_agents` option. A custom `:fcrdns` crawler keyed
  `"facebook"` needs the key `"facebookexternalhit"`.
- **Crawler verification telemetry.** Handlers matching
  `%{result: {:verified, host}}` should match `%{result: :verified, host:
  host}`.
- **`via_proxy`.** Code reading `decision.identity.via_proxy` to learn
  whether the peer was a proxy gets `false` for a proxy's own requests and
  for unusable forwarding headers; `evidence.client_ip` still tells how the
  address was found.
- **`boundary`.** An application that only had `boundary` for Limen can
  drop the dependency.
- **Custom challenge pages.** `Limen.Challenge.Page.render`, with four
  arguments, is gone; see `Limen.Challenge.Page` for pages of your own.
- **Skipping Limen for signed-in users.** A plug that skips `Limen.Plug`,
  or a wrapper around the `Limen.LiveView` hook, can become a facts plug or
  hook and a `trust` rule, which leaves a decision behind; see the getting
  started guide.

## 0.1.0

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
  `decide`, compile-time validation and per-rule explanations. Only the
  signals a policy refers to are collected.
- Proof-of-work challenges with stateless tokens, a vendored solver,
  single-use tokens, pass cookies and a no-JavaScript fallback.
- IP-to-ASN data packed into a single `:persistent_term` entry, about 10 MB
  for the full iptoasn.com data, and optionally downloaded and kept current
  from a URL on a configurable schedule: frequency, jitter, UTC time windows,
  and postponement while the node is busy.
- Lock-free state: sliding windows, GCRA limits, bans, Count-Min Sketch,
  Bloom filters and HyperLogLog, all with bounded memory.
- LiveView and socket gating, cluster ban propagation and a LiveDashboard
  page.
- Honeypots (`Limen.Trap`): trap paths behind hidden links and `robots.txt`,
  and form traps with a decoy field and a signed timestamp, flagging the
  clients that fall in.
- The maze (`Limen.Maze`): endless pages written by a Markov chain model of a
  bundled corpus and, optionally, the site's own text, seeded per site from
  the instance secret and dripped slowly with random chunks and pauses. Bans
  carry an action (`:deny` or `:maze`), and policies can send clients to the
  maze with `maze` rules or `{:maze, ban: seconds}`.
