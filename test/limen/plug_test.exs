defmodule Limen.PlugTest do
  use Limen.Case, async: true

  alias Limen.Decision

  describe "dry-run" do
    test "records a decision and lets the request through", %{limen: limen} do
      capture_events([[:limen, :decision]], limen)

      conn = conn(:get, "/hello") |> Limen.Plug.call(Limen.Plug.init(instance: limen))

      refute conn.halted

      assert %Decision{instance: ^limen, mode: :dry_run, enforced: false} = Limen.decision(conn)

      assert_receive {:event, [:limen, :decision], %{duration: duration}, %{decision: decision}}
      assert duration >= 0
      assert decision.identity.prefix == {4, 0x7F000001, 32}
      assert decision.path == "/hello"
    end

    test "the plug option overrides the configured mode", %{limen: limen} do
      conn = conn(:get, "/") |> Limen.Plug.call(Limen.Plug.init(instance: limen, mode: :enforce))
      assert Limen.decision(conn).mode == :enforce
    end
  end

  describe "bans" do
    test "an enforced ban denies the request", %{limen: limen} do
      Limen.ban(limen, {127, 0, 0, 1}, 60, reason: :manual)
      conn = conn(:get, "/") |> Limen.Plug.call(Limen.Plug.init(instance: limen, mode: :enforce))

      assert conn.halted
      assert conn.status == 403
      assert %Decision{action: :deny, stage: :ban, enforced: true} = Limen.decision(conn)
      assert Decision.explain(Limen.decision(conn)) =~ "ban banned when prefix is banned"
    end

    test "a ban created in dry-run mode is reported but not enforced", %{limen: limen} do
      Limen.ban(limen, {127, 0, 0, 1}, 60, mode: :dry_run)
      conn = conn(:get, "/") |> Limen.Plug.call(Limen.Plug.init(instance: limen, mode: :enforce))

      refute conn.halted
      assert %Decision{action: :deny, stage: :ban, enforced: false} = Limen.decision(conn)
    end

    test "dry-run routes do not enforce bans", %{limen: limen} do
      Limen.ban(limen, {127, 0, 0, 1}, 60)
      conn = conn(:get, "/") |> Limen.Plug.call(Limen.Plug.init(instance: limen))

      refute conn.halted
      assert %Decision{action: :deny, mode: :dry_run, enforced: false} = Limen.decision(conn)
    end

    # The other instance warns that it has no secret key.
    @tag :capture_log
    test "bans are per instance", %{limen: limen} do
      start_supervised!({Limen, name: :limen_plug_other_instance})
      Limen.ban(limen, {127, 0, 0, 1}, 60)

      refute Limen.banned(:limen_plug_other_instance, {127, 0, 0, 1})
      assert Limen.banned(limen, {127, 0, 0, 1})
    end
  end

  test "the mode can be changed at runtime", %{limen: limen} do
    Limen.set_mode(limen, :enforce)
    conn = conn(:get, "/") |> Limen.Plug.call(Limen.Plug.init(instance: limen))
    assert Limen.decision(conn).mode == :enforce
  end

  test "rejects invalid options" do
    assert_raise ArgumentError, fn -> Limen.Plug.init(instance: :x, mode: :sometimes) end
    assert_raise ArgumentError, ~r/:instance or an :otp_app/, fn -> Limen.Plug.init([]) end
  end
end
