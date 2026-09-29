defmodule Limen.TestHelpersTest do
  # One shared instance and endpoint, as in an application's tests: the
  # tests below only change it per request.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias Limen.Decision
  alias Limen.Test.LiveApp
  alias Limen.Test.LiveApp.Endpoint

  @endpoint Endpoint
  @browser "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  setup_all do
    Application.put_env(:limen, Endpoint,
      secret_key_base: String.duplicate("limen-live-test", 5),
      live_view: [signing_salt: "limen-live-test"],
      server: false
    )

    config = [
      secret_key: String.duplicate("live", 8),
      mode: :dry_run,
      trap: [min_fill_time: 0],
      decision_log: [non_allow_sample_rate: 0.0]
    ]

    start_supervised!({Limen, name: LiveApp.instance(), config: config})
    start_supervised!(Endpoint)
    :ok
  end

  setup do
    %{conn: build_conn() |> Limen.Test.put_client_ip(Limen.Test.unique_ip())}
  end

  defp browser(conn), do: put_req_header(conn, "user-agent", @browser)

  test "unique addresses are distinct clients" do
    ips = for _n <- 1..100, do: Limen.Test.unique_ip()
    prefixes = for {a, b, c, d, _e, _f, _g, _h} <- ips, do: {a, b, c, d}
    assert length(Enum.uniq(prefixes)) == 100
  end

  test "put_mode/2 enforces one request while the instance stays in dry-run", %{conn: conn} do
    dry_run = get(conn, "/signup")
    assert %Decision{action: :challenge, enforced: false} = Limen.decision(dry_run)
    assert dry_run.status == 200

    enforced = get(Limen.Test.put_mode(conn, :enforce), "/signup")

    assert %Decision{action: :challenge, enforced: true, mode: :enforce} =
             Limen.decision(enforced)

    assert html_response(enforced, 403) =~ "Checking your browser"
  end

  test "trusted clients pass the router's gate, and the endpoint serves Limen", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{"signed_in" => true})
      |> Limen.Test.put_mode(:enforce)
      |> get("/signup")

    assert %Decision{action: :allow, stage: :trust, facts: %{signed_in: true}} =
             Limen.decision(conn)

    assert get(build_conn(), "/__limen/solver.js").status == 200
  end

  test "LiveView sockets see the client the HTTP gate saw", %{conn: conn} do
    conn =
      conn
      |> browser()
      |> Limen.Test.put_mode(:enforce)
      |> Limen.Test.put_socket_token(instance: LiveApp.instance())

    {:ok, view, _html} = live(conn, "/signup")

    submitted = render_submit(form(view, "#signup", %{"email" => "a@example.com"}))
    assert submitted =~ "saved"
  end

  test "without a token, enforcing sockets send the client back through the gate", %{conn: conn} do
    conn = Limen.Test.put_mode(browser(conn), :enforce)
    assert {:error, {:redirect, %{to: "/signup"}}} = live(conn, "/signup")

    # In dry-run, the same connection is let through.
    assert {:ok, _view, _html} = live(browser(build_conn()), "/signup")
  end

  test "form traps in a LiveView record the page and flag the client", %{conn: conn} do
    ip = conn.remote_ip
    capture = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:limen, :decision],
      fn _event, _measurements, %{decision: decision}, _config ->
        if decision.stage == :trap and decision.identity.client_ip == ip,
          do: send(capture, {:trap, decision})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    conn =
      conn
      |> browser()
      |> Limen.Test.put_mode(:enforce)
      |> Limen.Test.put_socket_token(instance: LiveApp.instance())

    {:ok, view, _html} = live(conn, "/signup")

    submitted =
      view
      |> form("#signup", %{"email" => "a@example.com", "website" => "http://spam.example"})
      |> render_submit()

    assert submitted =~ "saved, pretending"
    assert_receive {:trap, %Decision{action: :maze, enforced: true, path: "/signup"}}
    assert %{action: :maze, origin: :trap} = Limen.banned(LiveApp.instance(), ip)
  end
end
