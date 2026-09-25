defmodule Limen.PlugTest do
  use Limen.Case, async: true

  alias Limen.Decision

  describe "dry-run" do
    test "records a decision and lets the request through", %{limen: limen} do
      capture_events([[:limen, :decision]], limen)

      conn = conn(:get, "/hello") |> Limen.Plug.call(Limen.Plug.init(instance: limen))

      refute conn.halted

      assert %Decision{instance: ^limen, action: :allow, mode: :dry_run, enforced: false} =
               Limen.decision(conn)

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
