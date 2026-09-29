# Getting started

This guide adds Limen to a Phoenix application in dry-run mode. Nothing is
blocked until you decide to enforce; see [Rolling out with
dry-run](dry-run-rollout.md) for that.

## Install

```elixir
def deps do
  [
    {:limen, "~> 0.1"}
  ]
end
```

## Configure

Limen runs as an *instance* your application configures and starts. Its
configuration lives in your application's environment, under the `Limen`
key, so each application sets up its own and several instances can run side
by side.

Limen signs challenge tokens and pass cookies with a secret that every node
serving your site must share. Generate one:

```sh
mix phx.gen.secret 48
```

and configure it at runtime, together with the proxies in front of your
application as [CIDR] ranges (an address and how many of its leading bits
must match):

```elixir
# config/runtime.exs
config :my_app, Limen,
  secret_key: System.fetch_env!("LIMEN_SECRET_KEY"),
  trusted_proxies: ["10.0.0.0/8", "fd00::/8"],
  client_ip_header: "x-forwarded-for"
```

`trusted_proxies` matters: forwarding headers (such as
[`X-Forwarded-For`][X-Forwarded-For], to which each proxy appends the address
it got the request from) and the JA4 header (a fingerprint of the client's TLS
handshake, see [JA4 behind nginx](nginx-ja4.md)) are only read from those
peers, and forwarding chains are walked from the right, so clients cannot
choose their own address. Without a load balancer, leave both options out and
Limen uses the connection's peer address.

Every option is documented in `Limen.Config`.

## Start the instance

Add Limen to your application's children, before the endpoint:

```elixir
children = [
  {Limen, otp_app: :my_app},
  MyAppWeb.Endpoint
]
```

This starts one instance, named after your application, with its own tables
and background processes. To run several (say, a stricter one for an admin
area), list them under `:instances`; top-level options are shared:

```elixir
config :my_app, Limen,
  secret_key: System.fetch_env!("LIMEN_SECRET_KEY"),
  instances: [public: [], admin: [mode: :enforce]]
```

Each one is then referred to by its name, as in `Limen.ban(:admin, ...)`.

## Add the plug

Put `Limen.Plug` in your endpoint, before `Plug.Static` (so asset requests count
towards client behaviour) and before the router:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # Behind a TLS terminator, make conn.scheme reflect the client's scheme:
  # browsers only send some headers Limen checks over HTTPS.
  plug Plug.RewriteOn, [:x_forwarded_proto]

  plug Limen.Plug,
    otp_app: :my_app,
    routes: [
      {"/health", :off},
      {"/assets", :track}
    ]

  plug Plug.Static, ...
  plug MyAppWeb.Router
end
```

Routes pick what Limen does per path prefix: `:off` does nothing, `:track`
only counts behaviour and enforces bans, and a policy module evaluates that
policy (optionally with its own `mode:`, and `instance:` to use another
instance for that path). Everything else uses `Limen.Policy.Default` unless
you pass `policy: MyApp.BotPolicy`. With several instances, pass
`instance: :public` instead of `otp_app:`.

Limen serves its challenge endpoints under `/__limen`. If a
[Content-Security-Policy][CSP] (a header restricting what a page may load and
run) applies to your whole site, the challenge page sets its own; it loads
nothing from other origins.

## Watch decisions

Every evaluated request emits a `[:limen, :decision]` telemetry event whose
metadata carries the `Limen.Decision`. `Limen.Decision.explain/1` renders it:

```elixir
:telemetry.attach(
  "limen-log-challenges",
  [:limen, :decision],
  fn _event, _measurements, %{decision: decision}, _config ->
    if decision.action != :allow do
      MyApp.Metrics.increment("limen.#{decision.action}")
    end
  end,
  nil
)
```

Handlers run in the request process: keep them cheap. For logs, configure the
sampled decision log instead, which writes structured `Logger` reports from a
background process:

```elixir
config :my_app, Limen, decision_log: [sample_rate: 0.01, non_allow_sample_rate: 1.0]
```

To keep sampled decisions somewhere else, such as a database table, write a
`Limen.DecisionLog.Sink`: it gets them in batches, away from the request
path.

`Limen.decision(conn)` returns the decision for the current request anywhere
downstream of the plug.

## Gate LiveView sockets

Phoenix dispatches sockets before any endpoint plug runs, so LiveView
connections need their own check. See `Limen.LiveView`; in short:

```elixir
# endpoint
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:peer_data, :x_headers, :user_agent, :uri, session: @session_options]]

# root layout
<meta name="limen-socket" content={Limen.LiveView.token(@conn)} />

# app.js
const limen = document.querySelector("meta[name='limen-socket']")?.content
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken, _limen: limen}})

# router
live_session :default, on_mount: {Limen.LiveView, otp_app: :my_app} do
  ...
end
```

For plain channel sockets, call `Limen.Socket.check/3` from `connect/3`.
Tokens are checked by the instance that issued them.

## Add the dashboard page

```elixir
live_dashboard "/dashboard", additional_pages: [limen: {Limen.Dashboard, otp_app: :my_app}]
```

## More than one node

Counters and limits are per node, which works well behind a load balancer.
Bans should apply everywhere:

```elixir
config :my_app, Limen, cluster: [enabled: true]
```

Instances of the same name on different nodes share their bans. See
`Limen.Cluster`.

## Next steps

- Write your own policy: `Limen.Policy`.
- Load IP-to-[ASN] data (which network, such as a cloud provider's, each
  address belongs to), and keep it current, so hosting providers can be
  scored: `Limen.Signal.Asn`.
- Catch scrapers with hidden links and form fields, and send them to the
  maze: [Honeypots and the maze](honeypots-and-maze.md).
- Forward JA4 fingerprints from your TLS terminator: [JA4 behind nginx](nginx-ja4.md).
- Size and tune: [Tuning](tuning.md).

## Testing

Tests can start isolated instances from options, without touching the
application environment, and run concurrently:

```elixir
setup do
  start_supervised!({Limen, name: :my_test, config: [mode: :enforce]})
  :ok
end
```

[CIDR]: https://www.rfc-editor.org/rfc/rfc4632
[X-Forwarded-For]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For
[CSP]: https://www.w3.org/TR/CSP3/
[ASN]: https://www.rfc-editor.org/rfc/rfc1930
