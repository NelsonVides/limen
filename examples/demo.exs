# A tiny "hello, <name>" site with Limen in front of it: a LiveView form,
# a lab to trigger every kind of decision, a live feed of Limen's telemetry,
# and LiveDashboard with Limen's page and charts.
#
#     elixir examples/demo.exs
#     LIMEN_MODE=dry_run PORT=4001 elixir examples/demo.exs
#
# Then open:
#
#   http://localhost:4000                           the site
#   http://localhost:4000/lab                       trigger decisions, watch them live
#   http://localhost:4000/dashboard/limen           Limen's LiveDashboard page
#   http://localhost:4000/dashboard/metrics?nav=limen   charts of Limen's telemetry
#
# The site follows the instance's mode: enforce, unless LIMEN_MODE=dry_run,
# and the lab can switch it. The lab's /try routes always enforce. The lab
# and the dashboard are `:off` routes, so they keep working while your own
# address is banned or in the maze.

Mix.install(
  [
    {:limen, path: Path.expand("..", __DIR__)},
    {:phoenix, "~> 1.8"},
    {:phoenix_live_view, "~> 1.1"},
    {:phoenix_live_dashboard, "~> 0.8"},
    {:telemetry_metrics, "~> 1.0"},
    {:bandit, "~> 1.6"}
  ],
  # Phoenix sockets encode with Elixir's own JSON module.
  config: [phoenix: [json_library: JSON]]
)

port = String.to_integer(System.get_env("PORT", "4000"))
mode = if System.get_env("LIMEN_MODE") == "dry_run", do: :dry_run, else: :enforce

Application.put_env(:demo, Limen,
  mode: mode,
  secret_key: String.duplicate("limen-demo-secret", 2),
  decision_log: [sample_rate: 0.0, non_allow_sample_rate: 1.0, flush_interval: 500],
  # The name form has a single field, which a person can fill in well under
  # the default three seconds.
  trap: [paths: ["/archive/directory"], ban: 60, min_fill_time: 1_000],
  # Quicker than the defaults, to watch it happen.
  maze: [delay: {200, 1_000}, max_duration: 15_000]
)

# Endpoint configuration is read when the endpoint module compiles.
Application.put_env(:demo, Demo.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  debug_errors: true,
  pubsub_server: Demo.PubSub,
  live_view: [signing_salt: "limen-demo-live-view"],
  secret_key_base: String.duplicate("demo", 16)
)

# Policies for the lab: each /try path gets the decision it is named after.
defmodule Demo.LabPolicy do
  use Limen.Policy

  deny :lab_deny, when: path() == "/try/deny"
  deny :lab_ban, when: path() == "/try/ban", ban: 30
  maze :lab_maze, when: path() == "/try/maze"

  score :lab_challenge, 100, when: path() == "/try/challenge"
  score :lab_tarpit, 200, when: path() == "/try/tarpit"

  decide do
    score >= 200 -> {:tarpit, delay: 3_000}
    score >= 100 -> {:challenge, difficulty: 16}
    true -> :allow
  end
end

defmodule Demo.ThrottlePolicy do
  use Limen.Policy

  limit :three_a_minute, key: :prefix, rate: 3, per: :minute, burst: 2
end

# Relays Limen's telemetry events to the lab. Handlers run in the request
# process, so this one only builds a small map and broadcasts it.
defmodule Demo.Feed do
  @events [
    [:limen, :decision],
    [:limen, :ban, :added],
    [:limen, :maze, :served],
    [:limen, :challenge, :issued],
    [:limen, :challenge, :verified]
  ]

  def attach, do: :telemetry.attach_many("demo-feed", @events, &__MODULE__.handle/4, nil)

  def subscribe, do: Phoenix.PubSub.subscribe(Demo.PubSub, "limen")

  def handle(event, measurements, %{instance: :demo} = metadata, _config) do
    entry =
      Map.merge(
        %{id: System.unique_integer([:positive, :monotonic]), at: now()},
        entry(event, measurements, metadata)
      )

    Phoenix.PubSub.broadcast(Demo.PubSub, "limen", {:limen, entry})
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok

  defp entry([:limen, :decision], _measurements, %{decision: decision, conn: conn}) do
    %{
      kind: :decision,
      action: decision.action,
      request: if(conn, do: "#{conn.method} #{conn.request_path}", else: "LiveView socket"),
      stage: decision.stage,
      # Only an action dry-run held back is "dry"; an allowed request has
      # nothing to enforce.
      dry: not decision.enforced and decision.action != :allow,
      score: decision.score,
      rules: Enum.map(decision.matches, & &1.name),
      explain: Limen.Decision.explain(decision)
    }
  end

  defp entry([:limen, :ban, :added], %{ttl: ttl}, metadata) do
    what = if metadata.action == :maze, do: "flagged for the maze", else: "banned"

    note(
      "#{Limen.IP.prefix_to_string(metadata.prefix)} #{what} for #{ttl} s (#{metadata.origin}, #{inspect(metadata.reason)})"
    )
  end

  defp entry([:limen, :maze, :served], measurements, metadata) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    note(
      "maze page #{metadata.path}: #{measurements.bytes} bytes in #{measurements.chunks} chunks over #{ms} ms (#{metadata.result})"
    )
  end

  defp entry([:limen, :challenge, :issued], %{difficulty: difficulty}, _metadata),
    do: note("challenge issued, #{difficulty} bits")

  defp entry([:limen, :challenge, :verified], _measurements, metadata),
    do: note("challenge answer checked (#{metadata.method}): #{inspect(metadata.result)}")

  defp note(text), do: %{kind: :note, text: text}

  defp now, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
end

# Charts on LiveDashboard's metrics page. The decision's fields are nested in
# the event's metadata, so tags are picked out with `tag_values`.
defmodule Demo.Telemetry do
  import Telemetry.Metrics

  def metrics do
    decision = fn %{decision: decision} -> %{action: decision.action, stage: decision.stage} end
    result = fn %{result: result} -> %{result: if(result == :ok, do: "ok", else: "failed")} end

    [
      counter("limen.decision.count", tags: [:action], tag_values: decision),
      summary("limen.decision.duration",
        unit: {:native, :microsecond},
        tags: [:stage],
        tag_values: decision
      ),
      summary("limen.decision.score", tags: [:action], tag_values: decision),
      counter("limen.ban.added.count", tags: [:action, :origin]),
      counter("limen.challenge.issued.count"),
      counter("limen.challenge.verified.count", tags: [:result], tag_values: result),
      sum("limen.maze.served.bytes", tags: [:result]),
      summary("limen.maze.served.duration", unit: {:native, :second}, tags: [:result])
    ]
  end
end

defmodule Demo.Greetings do
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def add(name) do
    Agent.update(__MODULE__, &Enum.take([name | &1], 5))
    Phoenix.PubSub.broadcast(Demo.PubSub, "greetings", :greeted)
  end

  def recent, do: Agent.get(__MODULE__, & &1)
end

defmodule Demo.Layouts do
  use Phoenix.Component

  attr(:assets, :string, required: true)
  attr(:socket_token, :string, default: nil)

  def head(assigns) do
    ~H"""
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
    <meta :if={@socket_token} name="limen-socket" content={@socket_token} />
    <title>Limen demo</title>
    <style>
      :root { color-scheme: light dark; --muted: #6b7280; --line: #d1d5db55; }
      body { font: 16px/1.5 system-ui, sans-serif; max-width: 64rem; margin: 2rem auto; padding: 0 1rem; }
      a { color: #2563eb; }
      input, button { font: inherit; padding: .4rem .7rem; border-radius: .4rem; border: 1px solid #9ca3af; }
      button { cursor: pointer; background: #2563eb; color: white; border-color: #2563eb; }
      .muted { color: var(--muted); font-size: .9rem; }
      .site { max-width: 30rem; margin: 6rem auto; text-align: center; }
      .site h1 { font-size: 2.5rem; margin-bottom: .5rem; }
      nav a { margin-right: 1rem; }
      section { margin: 2rem 0; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: .75rem; }
      .card { border: 1px solid var(--line); border-radius: .6rem; padding: .75rem; }
      .card a { font-weight: 600; }
      .card p { margin: .3rem 0 0; font-size: .9rem; color: var(--muted); }
      .badge { display: inline-block; min-width: 5.5rem; text-align: center; border-radius: 1rem; padding: 0 .5rem; font-size: .8rem; color: white; background: #6b7280; }
      .allow { background: #16a34a; } .challenge { background: #d97706; } .throttle { background: #ea580c; }
      .deny { background: #dc2626; } .tarpit { background: #7c3aed; } .maze { background: #0891b2; }
      .dry { background: transparent; color: var(--muted); border: 1px dashed var(--muted); }
      .bars div { display: flex; align-items: center; gap: .5rem; margin: .2rem 0; }
      .bars span.bar { height: .8rem; border-radius: .2rem; min-width: 2px; }
      .feed details { border-bottom: 1px solid var(--line); padding: .3rem 0; }
      .feed summary { cursor: pointer; list-style: none; display: flex; gap: .75rem; align-items: baseline; }
      .feed .note { color: var(--muted); font-size: .9rem; padding: .3rem 0; border-bottom: 1px solid var(--line); }
      pre { background: #6b728018; padding: .75rem; border-radius: .4rem; overflow-x: auto; font-size: .85rem; }
      code { font-size: .9em; }
    </style>
    <script src={"#{@assets}/phoenix/phoenix.min.js"}></script>
    <script src={"#{@assets}/phoenix_live_view/phoenix_live_view.min.js"}></script>
    <script>
      const csrf = document.querySelector("meta[name='csrf-token']").content
      const limen = document.querySelector("meta[name='limen-socket']")?.content
      const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
        params: {_csrf_token: csrf, _limen: limen}
      })
      liveSocket.connect()
    </script>
    """
  end

  def site(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head><.head assets="/assets" socket_token={Limen.LiveView.token(@conn)} /></head>
      <body>
        {@inner_content}
        <footer>{Limen.Trap.link(:demo)}</footer>
      </body>
    </html>
    """
  end

  # The lab loads its scripts under /lab, an `:off` route, so it keeps
  # working when your address is banned or in the maze. It has no socket
  # gate, so it needs no socket token.
  def lab(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head><.head assets="/lab/assets" /></head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule Demo.HomeLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, error: nil)}

  def handle_event("greet", %{"name" => name} = params, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, error: "Tell me your name first.")}
    else
      # A trapped submission gets the same answer, so a script learns
      # nothing; only real ones are remembered.
      with {:ok, _decision} <- Limen.LiveView.check_form(socket, params, otp_app: :demo) do
        Demo.Greetings.add(name)
      end

      path = "/hello/" <> URI.encode(name, &URI.char_unreserved?/1)
      {:noreply, push_navigate(socket, to: path)}
    end
  end

  def render(assigns) do
    ~H"""
    <main class="site">
      <h1>Hello!</h1>
      <p>What's your name?</p>
      <form phx-submit="greet">
        {Limen.Trap.form_fields(:demo)}
        <input name="name" maxlength="40" placeholder="Ada" autofocus autocomplete="given-name" />
        <button>Say hello</button>
      </form>
      <p :if={@error}>{@error}</p>
      <p class="muted">
        This page is a LiveView behind Limen. <a href="/lab">Open the lab</a>
        to see what Limen makes of your visit.
      </p>
    </main>
    """
  end
end

defmodule Demo.HelloLive do
  use Phoenix.LiveView

  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Demo.PubSub, "greetings")
    {:ok, assign(socket, name: name, recent: Demo.Greetings.recent())}
  end

  def handle_info(:greeted, socket),
    do: {:noreply, assign(socket, recent: Demo.Greetings.recent())}

  def render(assigns) do
    ~H"""
    <main class="site">
      <h1>Hello, {@name}!</h1>
      <p :if={@recent != []} class="muted">Recently greeted: {Enum.join(@recent, ", ")}</p>
      <p><a href="/">Say hello again</a> · <a href="/lab">Open the lab</a></p>
    </main>
    """
  end
end

defmodule Demo.LabLive do
  use Phoenix.LiveView

  @actions [:allow, :challenge, :throttle, :deny, :tarpit, :maze]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Demo.Feed.subscribe()
      :timer.send_interval(1_000, :tick)
    end

    {:ok, socket |> assign(actions: @actions) |> refresh() |> stream(:feed, [], limit: 60)}
  end

  def handle_event("mode", %{"to" => mode}, socket) do
    :ok = Limen.set_mode(:demo, String.to_existing_atom(mode))
    {:noreply, refresh(socket)}
  end

  def handle_event("unban", %{"prefix" => prefix}, socket) do
    :ok = Limen.unban(:demo, prefix)
    {:noreply, refresh(socket)}
  end

  def handle_info({:limen, entry}, socket),
    do: {:noreply, socket |> stream_insert(:feed, entry, at: 0, limit: 60) |> refresh()}

  def handle_info(:tick, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    assign(socket,
      mode: Limen.Instance.fetch!(:demo).config.mode,
      stats: Limen.Stats.snapshot(:demo),
      bans: Limen.State.BanList.list(Limen.Instance.fetch!(:demo)),
      trap: Limen.Trap.href(:demo)
    )
  end

  attr(:href, :string, required: true)
  attr(:action, :atom, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp trigger(assigns) do
    ~H"""
    <div class="card">
      <span class={["badge", to_string(@action)]}>{@action}</span>
      <a href={@href} target="_blank">{@title}</a>
      <p>{render_slot(@inner_block)}</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <nav><a href="/">Site</a><a href="/dashboard/limen">Dashboard</a><a href="/dashboard/metrics?nav=limen">Charts</a></nav>
    <h1>Limen lab</h1>

    <section>
      <p>
        The site is in <strong>{mode_name(@mode)}</strong> mode.
        <button phx-click="mode" phx-value-to={if @mode == :enforce, do: "dry_run", else: "enforce"}>
          Switch to {mode_name(if @mode == :enforce, do: :dry_run, else: :enforce)}
        </button>
      </p>
      <p class="muted">
        In dry-run, Limen decides and records everything, then lets every request through.
        The links below always enforce, so you can see each response. They open in a new tab;
        this page shows what Limen decided.
      </p>
    </section>

    <section>
      <h2>Trigger a decision</h2>
      <div class="grid">
        <.trigger href="/hello/Ada" action={:allow} title="A page view">
          An ordinary request from your browser, scored by the default policy.
        </.trigger>
        <.trigger href="/try/challenge" action={:challenge} title="Challenge">
          The proof-of-work page. Your browser solves it and gets a pass.
        </.trigger>
        <.trigger href="/try/throttle" action={:throttle} title="Throttle">
          Three a minute are allowed: open it four times.
        </.trigger>
        <.trigger href="/try/deny" action={:deny} title="Deny">
          A plain 403.
        </.trigger>
        <.trigger href="/try/ban" action={:deny} title="Deny and ban">
          A 403, and your address is banned for 30 s: the site answers 403 until then.
        </.trigger>
        <.trigger href="/try/tarpit" action={:tarpit} title="Tarpit">
          Nothing for 3 s, then a 403.
        </.trigger>
        <.trigger href="/try/maze" action={:maze} title="Maze">
          One maze page, sent slowly. Every link in it leads deeper.
        </.trigger>
        <.trigger href={@trap} action={:maze} title="Hidden trap link">
          The link every page hides. Your address is flagged for the maze for 60 s.
          {if @mode == :dry_run, do: "In dry-run, that is only reported."}
        </.trigger>
      </div>

      <h3>Form traps</h3>
      <p class="muted">What a script filling in the site's form would look like. Each flags your address for the maze{if @mode == :dry_run, do: ", which in dry-run the site only reports"}.</p>
      <div class="grid">
        <form class="card" action="/try/form" method="post" target="_blank">
          {Limen.Trap.form_fields(:demo)}
          <input type="hidden" name="website" value="https://spam.example" />
          <input type="hidden" name="name" value="bot" />
          <button>Fill in the hidden field</button>
        </form>
        <form class="card" action="/try/form" method="post" target="_blank">
          <input type="hidden" name="name" value="bot" />
          <button>Leave out the signed timestamp</button>
        </form>
        <div class="card">
          <a href="/try/form-fast" target="_blank">Submit within a second</a>
          <p>A page that submits its form as soon as it loads.</p>
        </div>
      </div>

      <h3>From a terminal</h3>
      <pre>{commands(@trap)}</pre>
      <p class="muted">Your terminal and your browser share an address, so what one triggers applies to both.</p>
    </section>

    <section>
      <h2>Your address</h2>
      <p :if={@bans == []} class="muted">No bans. <a href="/lab/forget-pass">Forget my pass</a> (so challenges show again).</p>
      <div :for={ban <- @bans} class="card">
        <span class={["badge", to_string(ban.action)]}>{ban.action}</span>
        {Limen.IP.prefix_to_string(ban.prefix)} for {div(ban.expires_at - System.system_time(:millisecond), 1000)} s more
        ({ban.origin}, {inspect(ban.reason)}{if ban.mode == :dry_run, do: ", dry-run: reported only"})
        <button phx-click="unban" phx-value-prefix={Limen.IP.prefix_to_string(ban.prefix)}>Unban</button>
      </div>
    </section>

    <section>
      <h2>Decisions so far</h2>
      <div class="bars">
        <div :for={action <- @actions}>
          <span class={["badge", to_string(action)]}>{action}</span>
          <span class={["bar", to_string(action)]} style={"width: #{bar(@stats, action)}%"}></span>
          {Map.get(@stats, action, 0)}
        </div>
      </div>
      <p class="muted">
        Enforced {@stats.enforced}, passes {@stats.pass}, challenges solved {@stats.challenge_solved},
        trap hits {@stats.trap_hit}, maze pages {@stats.maze_served}.
      </p>
    </section>

    <section class="feed">
      <h2>Live feed</h2>
      <p class="muted">Every <code>[:limen, ...]</code> telemetry event, newest first. Click a decision for its explanation.</p>
      <div id="feed" phx-update="stream">
        <div :for={{dom_id, entry} <- @streams.feed} id={dom_id}>
          <details :if={entry.kind == :decision}>
            <summary>
              <span class="muted">{entry.at}</span>
              <span class={["badge", to_string(entry.action), entry.dry && "dry"]}>{entry.action}{if entry.dry, do: " (dry)"}</span>
              <code>{entry.request}</code>
              <span class="muted">stage {entry.stage}, score {entry.score}{if entry.rules != [], do: ", " <> Enum.map_join(entry.rules, ", ", &to_string/1)}</span>
            </summary>
            <pre>{entry.explain}</pre>
          </details>
          <div :if={entry.kind == :note} class="note">{entry.at} · {entry.text}</div>
        </div>
      </div>
    </section>
    """
  end

  defp mode_name(:enforce), do: "enforce"
  defp mode_name(:dry_run), do: "dry-run"

  defp bar(stats, action) do
    max = @actions |> Enum.map(&Map.get(stats, &1, 0)) |> Enum.max()
    if max == 0, do: 0, else: Map.get(stats, action, 0) * 100 / max
  end

  defp commands(trap) do
    base = "localhost:#{Application.get_env(:demo, Demo.Endpoint)[:http][:port]}"

    """
    curl -i #{base}/hello/curl      # scored by the default policy
    curl -N #{base}#{trap}   # a trap: watch the maze drip in
    for i in 1 2 3 4; do curl -s -o /dev/null -w '%{http_code} ' #{base}/try/throttle; done\
    """
  end
end

defmodule Demo.TryHTML do
  use Phoenix.Component

  def result(assigns) do
    ~H"""
    <nav><a href="/lab">Back to the lab</a></nav>
    <h1>{@title}</h1>
    <p :if={@decision && @decision.stage == :pass}>
      Your pass let this request through before any rule ran.
      <a href="/lab/forget-pass">Forget the pass</a> to see what this link does without one.
    </p>
    <p :if={@note}>{@note}</p>
    <pre :if={@decision}>{Limen.Decision.explain(@decision)}</pre>
    """
  end

  def fast_form(assigns) do
    ~H"""
    <p>Submitting at once…</p>
    <form id="fast" action="/try/form" method="post">
      {Limen.Trap.form_fields(:demo)}
      <input type="hidden" name="name" value="bot" />
    </form>
    <script>document.getElementById("fast").submit()</script>
    """
  end
end

defmodule Demo.TryController do
  use Phoenix.Controller, formats: [:html]

  plug :put_view, html: Demo.TryHTML

  # Only reached when Limen lets the request through.
  def show(conn, _params) do
    render(conn, :result,
      title: "Limen let this through",
      note: nil,
      decision: Limen.decision(conn)
    )
  end

  def fast_form(conn, _params), do: render(conn, :fast_form)

  def form(conn, params) do
    case Limen.Trap.check_form(conn, params, otp_app: :demo, mode: :enforce) do
      {:ok, decision} ->
        render(conn, :result, title: "The form went through", note: nil, decision: decision)

      {:trapped, decision} ->
        note =
          "A real application would answer as if it had worked. Your address is now in the maze for 60 s: open any page of the site."

        render(conn, :result, title: "Trapped", note: note, decision: decision)
    end
  end
end

defmodule Demo.LabController do
  use Phoenix.Controller, formats: [:html]

  def forget_pass(conn, _params) do
    conn
    |> delete_resp_cookie("_limen_pass", path: "/")
    |> redirect(to: "/lab")
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

  pipeline :site do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Demo.Layouts, :site}
  end

  pipeline :lab do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Demo.Layouts, :lab}
  end

  # The form traps stand in for scripts, which send no CSRF token.
  pipeline :bot_forms do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {Demo.Layouts, :lab}
  end

  get "/robots.txt", Demo.RobotsController, :show

  scope "/" do
    pipe_through(:site)

    live_session :site, on_mount: {Limen.LiveView, otp_app: :demo} do
      live "/", Demo.HomeLive
      live "/hello/:name", Demo.HelloLive
    end
  end

  scope "/" do
    pipe_through(:lab)

    live_session :lab do
      live "/lab", Demo.LabLive
    end

    get "/lab/forget-pass", Demo.LabController, :forget_pass
    get "/try/form-fast", Demo.TryController, :fast_form
    get "/try/:what", Demo.TryController, :show

    # A real application protects its dashboard with authentication.
    live_dashboard "/dashboard",
      metrics: Demo.Telemetry,
      additional_pages: [limen: {Limen.Dashboard, otp_app: :demo}]
  end

  scope "/" do
    pipe_through(:bot_forms)
    post "/try/form", Demo.TryController, :form
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
      {"/lab", :off},
      {"/dashboard", :off},
      {"/try/throttle", Demo.ThrottlePolicy, mode: :enforce},
      {"/try", Demo.LabPolicy, mode: :enforce},
      {"/assets", :track}
    ]

  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Static, at: "/lab/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/lab/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Parsers, parsers: [:urlencoded]
  plug Plug.Session, @session
  plug Demo.Router
end

Demo.Feed.attach()

children = [
  {Phoenix.PubSub, name: Demo.PubSub},
  Demo.Greetings,
  {Limen, otp_app: :demo},
  Demo.Endpoint
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("""
Limen demo (#{mode}) on http://localhost:#{port}
  site       http://localhost:#{port}/
  lab        http://localhost:#{port}/lab
  dashboard  http://localhost:#{port}/dashboard/limen
  charts     http://localhost:#{port}/dashboard/metrics?nav=limen
""")

Process.sleep(:infinity)
