# Limen

*Limen* (Latin): threshold. The point every request crosses before it enters.

Limen is native Elixir L7 bot protection. It is a Plug that classifies
requests, rate-limits, challenges and blocks automated traffic entirely inside
the BEAM: no sidecar, no external service, all state in ETS, `:atomics` and
`:persistent_term`.

> Limen is under active development. See [PLAN.md](PLAN.md) for the roadmap.

## Installation

```elixir
def deps do
  [
    {:limen, "~> 0.1"}
  ]
end
```

Configure an instance in your application, start it, and add the plug to
your endpoint, before the router:

```elixir
# config/config.exs
config :my_app, Limen, mode: :dry_run

# lib/my_app/application.ex
children = [{Limen, otp_app: :my_app}, MyAppWeb.Endpoint]

# lib/my_app_web/endpoint.ex
plug Limen.Plug, otp_app: :my_app
```

Limen starts in dry-run mode: every decision is computed, emitted as
telemetry and sampled into the decision log, but nothing is blocked.

## License

Apache-2.0. See [LICENSE](LICENSE).
