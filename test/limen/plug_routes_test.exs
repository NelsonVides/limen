defmodule Limen.PlugRoutesTest do
  use Limen.Case, async: true

  alias Limen.Decision
  alias Limen.Test.Policies.{Login, Tarpit, TarpitAll}

  @routes [
    {"/health", :off},
    {"/assets", :track},
    {"/login", Login},
    {"/login/admin", Login, mode: :enforce},
    {"/tarpit", Tarpit}
  ]

  defp call(limen, path) do
    Limen.Plug.call(conn(:get, path), Limen.Plug.init(instance: limen, routes: @routes))
  end

  test ":off routes are left alone", %{limen: limen} do
    conn = call(limen, "/health")
    assert Limen.decision(conn) == nil
    refute Map.has_key?(conn.private, :before_send)
  end

  @tag config: [trap: [paths: ["/archive"]], maze: [delay: {0, 0}], mode: :enforce]
  test "policy: :off serves Limen's endpoints and traps, and nothing else", %{limen: limen} do
    opts = Limen.Plug.init(instance: limen, policy: :off)

    page = Limen.Plug.call(conn(:get, "/articles"), opts)
    refute page.halted
    assert Limen.decision(page) == nil

    solver = Limen.Plug.call(conn(:get, "/__limen/solver.js"), opts)
    assert solver.halted and solver.status == 200

    trap = Limen.Plug.call(conn(:get, "/archive/x"), opts)
    assert %Decision{stage: :trap, action: :maze, enforced: true} = Limen.decision(trap)

    tracked =
      Limen.Plug.call(conn(:get, "/articles"), Limen.Plug.init(instance: limen, policy: :track))

    assert %Decision{stage: :ban} = Limen.decision(tracked)
  end

  test ":track routes count behaviour and enforce bans only", %{limen: limen} do
    conn = call(limen, "/assets/app.css")
    assert Limen.decision(conn) == nil
    assert [_count_not_found] = conn.private.before_send

    Limen.ban(limen, {127, 0, 0, 1}, 60)
    Limen.set_mode(limen, :enforce)

    assert %Decision{action: :deny, stage: :ban, enforced: true} =
             Limen.decision(call(limen, "/assets/x.js"))
  end

  test "paths match whole segments and the most specific route wins", %{limen: limen} do
    assert %Decision{policy: Login, route: "/login", mode: :dry_run} =
             Limen.decision(call(limen, "/login"))

    assert %Decision{route: "/login"} = Limen.decision(call(limen, "/login/otp"))

    assert %Decision{route: "/login/admin", mode: :enforce} =
             Limen.decision(call(limen, "/login/admin/x"))

    assert %Decision{policy: Limen.Policy.Default, route: nil} =
             Limen.decision(call(limen, "/loginx"))
  end

  test "a policy's own mode applies unless the route sets one", %{limen: limen} do
    conn = call(limen, "/tarpit")
    assert %Decision{action: :deny, mode: :enforce, enforced: true} = Limen.decision(conn)
    assert conn.status == 403
  end

  test "tarpits hold the request before denying it", %{limen: limen} do
    opts = Limen.Plug.init(instance: limen, policy: TarpitAll)
    {elapsed, conn} = :timer.tc(fn -> Limen.Plug.call(conn(:get, "/"), opts) end, :millisecond)

    assert conn.status == 403
    assert elapsed >= 20
    assert %Decision{action: :tarpit, params: %{delay: 20}} = Limen.decision(conn)
  end

  @tag config: [tarpit: [max_concurrent: 0]]
  test "tarpits deny immediately once too many requests are held", %{limen: limen} do
    assert Limen.Tarpit.hold(instance(limen), 10_000) == 0
  end

  test "invalid routes are rejected", %{limen: limen} do
    assert_raise ArgumentError, ~r/invalid Limen route/, fn ->
      Limen.Plug.init(instance: limen, routes: [{"/x", "nope"}])
    end

    assert_raise ArgumentError, ~r/is not a Limen.Policy/, fn ->
      Limen.Plug.init(instance: limen, policy: String)
    end
  end
end
