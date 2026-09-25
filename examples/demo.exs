# A single-file Phoenix app with Limen in front of the router.
#
#     elixir examples/demo.exs
#
# Then browse to http://localhost:4000 or `curl -i localhost:4000`. Every
# request is logged as a structured Limen decision; the demo runs in dry-run
# mode, so nothing is blocked.

Mix.install([
  {:limen, path: Path.expand("..", __DIR__)},
  {:phoenix, "~> 1.8"},
  {:bandit, "~> 1.6"}
])

Application.put_env(:demo, Limen,
  mode: :dry_run,
  decision_log: [sample_rate: 1.0, flush_interval: 500]
)

defmodule Demo.PageController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    decision = Limen.decision(conn)

    html(conn, """
    <!doctype html>
    <title>Limen demo</title>
    <h1>Limen demo</h1>
    <p>Limen decided <strong>#{decision.action}</strong> for this request
       (#{if decision.enforced, do: "enforced", else: "not enforced"}).</p>
    <pre>#{Plug.HTML.html_escape(Limen.Decision.explain(decision))}</pre>
    """)
  end
end

defmodule Demo.Router do
  use Phoenix.Router

  get "/", Demo.PageController, :index
  get "/*path", Demo.PageController, :index
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :demo

  plug Limen.Plug, otp_app: :demo
  plug Demo.Router
end

port = String.to_integer(System.get_env("PORT", "4000"))

Application.put_env(:demo, Demo.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  secret_key_base: String.duplicate("demo", 16)
)

{:ok, _} = Supervisor.start_link([{Limen, otp_app: :demo}, Demo.Endpoint], strategy: :one_for_one)
IO.puts("Limen demo listening on http://localhost:#{port}")
Process.sleep(:infinity)
