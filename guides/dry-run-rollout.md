# Rolling out with dry-run

Blocking real people is worse than letting some bots through. Limen is built
to be rolled out gradually: run it in dry-run mode, read what it would have
done, tune, then enforce one route at a time.

## What dry-run means

In dry-run mode the whole pipeline runs exactly as it would when enforcing:
signals are collected, rates and limits are counted, rules are evaluated,
bans are recorded, telemetry is emitted and decisions are logged. Only the
final action is skipped, and the request continues to your application.
`decision.enforced` is `false`, `decision.mode` is `:dry_run`.

Bans a dry-run policy creates are remembered with their mode and never
enforced, not even on routes that do enforce, so dry-run can never block
anyone indirectly.

The mode is resolved per request, from the most specific setting:

1. a route's `mode:` in `Limen.Plug`'s `:routes`;
2. the plug's `mode:` option;
3. the policy's `use Limen.Policy, mode: ...`;
4. the instance's `:mode` (`:dry_run` by default), which `Limen.set_mode/2`
   changes at runtime.

## 1. Deploy in dry-run

Deploy with the default mode and, ideally, sample every non-allow decision:

```elixir
config :my_app, Limen, decision_log: [sample_rate: 0.001, non_allow_sample_rate: 1.0]
```

## 2. Read the decisions

For a few days, look at what would have been challenged or denied:

- the Limen page of LiveDashboard shows rates, the busiest prefixes, the
  [JA4] fingerprints (hashes of each client's TLS handshake) with the most
  clients, and recent sampled decisions;
- the decision log has one structured report per sampled decision, with the
  matched rules and every signal;
- your telemetry handler can count `[:limen, :decision]` events by action and
  by matched rule.

For any decision, `Limen.Decision.explain/1` shows why: which rules matched,
the values their conditions observed, and the `decide` clause that picked the
action.

## 3. Look for false positives

Typical causes, and what to do:

- **Office or partner networks behind one address**: allow-list them with
  `Limen.Lists.put_cidrs(:my_app, :allow, [...])` or the `:lists` option,
  which `Limen.Policy.Default` honours.
- **Monitoring and uptime checks**: `{"/health", :off}` or an allow rule on
  their user agent and address.
- **Your own API clients**: route API paths to a policy that uses limits and
  keys, not browser heuristics, or turn them off.
- **Mobile networks with [carrier-grade NAT][CGNAT] (IPv4)**: many users can
  share an address. Keep rate thresholds generous for IPv4, or aggregate IPv4
  to `/32` (the default) and rely on JA4 and shape more than on rates.
- **Crawlers you want**: verified search engine crawlers are allowed by the
  default policy once [FCrDNS] verification completes (forward-confirmed
  reverse DNS: the address's DNS name must belong to the crawler and resolve
  back to it); add others by name and DNS suffix in the `:fcrdns`
  configuration.

### Trap hits

Honeypots (see [Honeypots and the maze](honeypots-and-maze.md)) follow the
same rules: in dry-run a trap hit is recorded, the client's flag is stored as
a dry-run ban, and the request continues to your application; nobody is sent
to the maze. Before enforcing, look at who fell in: decisions at the `:trap`
stage should be scrapers, security scanners and the odd link-prefetching
browser extension, never your users' normal browsing.

## 4. Enforce one route first

Login and signup pages are the usual first targets: little legitimate
automation, a lot of abuse.

```elixir
plug Limen.Plug,
  otp_app: :my_app,
  routes: [
    {"/users/log_in", MyApp.LoginPolicy, mode: :enforce},
    {"/assets", :track}
  ]
```

Watch the challenge solve rate on the dashboard: challenges that are issued
but never solved are either automation giving up (good) or people failing
(check browser support, and consider the no-JavaScript wait).

## 5. Enforce everywhere

Switch the instance's mode when the numbers look right:

```elixir
config :my_app, Limen, mode: :enforce
```

## Emergency switch

If Limen blocks legitimate traffic in production, switch back without a
deploy:

```elixir
Limen.set_mode(:my_app, :dry_run)
```

Routes with an explicit `mode: :enforce` keep enforcing; remove those with a
deploy, or lift individual bans with `Limen.unban/2`.

## Accessibility

The challenge needs JavaScript and costs some CPU time. With the default
`no_js: {:meta_refresh, 5}`, clients without JavaScript, including some
assistive technologies and text browsers, get through after a five second
wait instead of being blocked; that costs automated clients time rather than
CPU. `no_js: :deny` is stricter and shuts those users out: prefer allow-lists
for the clients you know.

[JA4]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md
[CGNAT]: https://www.rfc-editor.org/rfc/rfc6888
[FCrDNS]: https://developers.google.com/search/docs/crawling-indexing/verifying-googlebot
