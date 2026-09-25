# A single-file Phoenix app with Limen in front of the router.
#
#     elixir examples/demo.exs
#     LIMEN_MODE=enforce elixir examples/demo.exs
#
# Then browse to http://localhost:4000 (a LiveView page gated by Limen) and
# http://localhost:4000/dashboard/limen (the LiveDashboard page), or try
# `curl -i localhost:4000`. Every decision is logged. In dry-run mode (the
# default) nothing is blocked; in enforce mode automated clients get the
# proof-of-work challenge, which a browser solves in a fraction of a second.
#
# The page hides a link to a trap, and its form carries a form trap. In
# enforce mode, follow the hidden link (see /robots.txt for the trap path)
# with `curl -N localhost:4000/archive/directory/x` to watch a maze page
# drip in; every later request from your address gets the maze too, until
# you restart the demo.

Mix.install([
  {:limen, path: Path.expand("..", __DIR__)},
  {:phoenix, "~> 1.8"},
  {:phoenix_live_view, "~> 1.1"},
  {:phoenix_live_dashboard, "~> 0.8"},
  {:bandit, "~> 1.6"}
])

port = String.to_integer(System.get_env("PORT", "4000"))
mode = if System.get_env("LIMEN_MODE") == "enforce", do: :enforce, else: :dry_run

Application.put_env(:demo, Limen,
  mode: mode,
  secret_key: String.duplicate("limen-demo-secret", 2),
  decision_log: [sample_rate: 1.0, flush_interval: 500],
  trap: [paths: ["/archive/directory"], ban: 600],
  # Quicker than the defaults, to watch it happen.
  maze: [delay: {200, 1_000}, max_duration: 15_000]
)

# Endpoint configuration is read when the endpoint module compiles.
Application.put_env(:demo, Demo.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  debug_errors: true,
  live_view: [signing_salt: "limen-demo-live-view"],
  secret_key_base: String.duplicate("demo", 16)
)

defmodule Demo.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <meta name="limen-socket" content={Limen.LiveView.token(@conn)} />
        <title>Limen demo</title>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          const csrf = document.querySelector("meta[name='csrf-token']").content
          const limen = document.querySelector("meta[name='limen-socket']")?.content
          const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
            params: {_csrf_token: csrf, _limen: limen}
          })
          liveSocket.connect()
        </script>
      </head>
      <body style="font-family: system-ui; max-width: 48rem; margin: 2rem auto">
        {@inner_content}
        <footer>{Limen.Trap.link(:demo)}</footer>
      </body>
    </html>
    """
  end
end

defmodule Demo.HomeLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1_000, :tick)
    stats = Limen.Stats.snapshot(:demo)
    {:ok, assign(socket, stats: stats, connected: connected?(socket), subscribed: nil)}
  end

  # Trapped submissions get the same answer as real ones.
  def handle_event("subscribe", params, socket) do
    result =
      case Limen.LiveView.check_form(socket, params, otp_app: :demo) do
        {:ok, _decision} -> "subscribed"
        {:trapped, _decision} -> "trapped"
      end

    IO.puts("Newsletter form: #{result}")
    {:noreply, assign(socket, subscribed: "Thanks, check your inbox.")}
  end

  def handle_info(:tick, socket),
    do: {:noreply, assign(socket, stats: Limen.Stats.snapshot(:demo))}

  def render(assigns) do
    ~H"""
    <h1>Limen demo</h1>
    <p>
      This LiveView {if @connected, do: "passed the socket gate", else: "is rendering"}.
      See <a href="/dashboard/limen">the dashboard</a>.
    </p>
    <form phx-submit="subscribe">
      {Limen.Trap.form_fields(:demo)}
      <input type="email" name="email" placeholder="you@example.com" />
      <button>Subscribe</button>
    </form>
    <p :if={@subscribed}>{@subscribed}</p>
    <pre>{inspect(@stats, pretty: true)}</pre>
    """
  end
end

defmodule Demo.RobotsController do
  use Phoenix.Controller, formats: [:text]

  def show(conn, _params), do: text(conn, "User-agent: *\n" <> Limen.Trap.robots(:demo))
end

defmodule Demo.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Demo.Layouts, :root}
  end

  get "/robots.txt", Demo.RobotsController, :show

  scope "/" do
    pipe_through(:browser)

    live_session :default, on_mount: {Limen.LiveView, otp_app: :demo} do
      live "/", Demo.HomeLive
    end

    live_dashboard "/dashboard", additional_pages: [limen: {Limen.Dashboard, otp_app: :demo}]
  end
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :demo

  @session [store: :cookie, key: "_demo", signing_salt: "limen-demo"]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, :user_agent, :uri, session: @session]]

  plug Limen.Plug,
    otp_app: :demo,
    routes: [
      # A real application protects its dashboard with authentication instead.
      {"/dashboard", :off},
      {"/assets", :track}
    ]

  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Session, @session
  plug Demo.Router
end

{:ok, _} = Supervisor.start_link([{Limen, otp_app: :demo}, Demo.Endpoint], strategy: :one_for_one)
IO.puts("Limen demo (#{mode}) listening on http://localhost:#{port}")
Process.sleep(:infinity)
