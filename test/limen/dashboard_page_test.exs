defmodule Limen.DashboardPageTest do
  use Limen.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Limen.Test.DashboardApp
  alias Limen.Test.DashboardApp.Endpoint

  @endpoint Endpoint
  @secret String.duplicate("dashboard", 4)

  setup_all do
    # LiveDashboard's tables render their page size forms without ids.
    Application.put_env(:phoenix_live_view, :test_warnings, missing_form_id: :ignore)

    Application.put_env(:limen, Endpoint,
      secret_key_base: String.duplicate("limen-dashboard-test", 4),
      live_view: [signing_salt: "limen-dashboard-test"],
      server: false
    )

    start_supervised!(Endpoint)
    :ok
  end

  setup do
    start_supervised!({Limen, name: DashboardApp.instance(), config: [secret_key: @secret]})
    :ok
  end

  test "the Limen page renders and refreshes" do
    name = DashboardApp.instance()
    Limen.ban(name, "198.51.100.3", 60, reason: :dashboard_test)
    Limen.Plug.call(conn(:get, "/"), Limen.Plug.init(instance: name))

    {:ok, view, html} = live(build_conn(), "/dashboard/limen")

    assert html =~ "Decisions per second"
    assert html =~ "Busiest prefixes, this minute"
    assert html =~ "198.51.100.3/32"
    assert render(view) =~ "Recent sampled decisions"
  end
end
