defmodule Limen.ClusterTest do
  @moduledoc """
  Bans propagate between nodes.

  Tagged `:distributed` and excluded by default: it starts a second node
  with `:peer`, which needs `epmd`. Run with `mix test --only distributed`.
  """

  use ExUnit.Case, async: false

  alias Limen.Test.Peer

  @moduletag :distributed
  @moduletag timeout: 120_000

  @instance :limen_cluster
  @config [
    secret_key: String.duplicate("cluster", 5),
    cluster: [enabled: true, interval: 20],
    decision_log: [non_allow_sample_rate: 0.0]
  ]

  setup_all do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])
      {:ok, _pid} = :net_kernel.start([:"limen_primary@127.0.0.1", :longnames])
    end

    start_supervised!({Limen, name: @instance, config: @config})
    start_supervised!({Limen, name: :limen_cluster_other, config: @config}, id: :other)

    # Not linked: setup_all runs in a process that exits before the tests.
    {:ok, peer, node} =
      :peer.start(%{
        name: :limen_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:limen])
    {:ok, _pid} = :erpc.call(node, Peer, :start_instance, [@instance, @config])

    on_exit(fn -> :peer.stop(peer) end)
    %{node: node}
  end

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and attempts > 0 ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  test "instances of the same name find each other", %{node: node} do
    assert eventually(fn -> Limen.Cluster.peers(@instance) == [node] end)
    assert Limen.Cluster.peers(:limen_cluster_other) == []
  end

  test "bans and unbans propagate both ways", %{node: node} do
    eventually(fn -> Limen.Cluster.peers(@instance) == [node] end)

    :ok = Limen.ban(@instance, "192.0.2.77", 60, reason: :abuse)

    assert %{origin: :remote, reason: :abuse, mode: :enforce} =
             eventually(fn -> :erpc.call(node, Limen, :banned, [@instance, "192.0.2.77"]) end)

    :ok = :erpc.call(node, Limen, :ban, [@instance, "198.51.100.5", 60])
    assert %{origin: :remote} = eventually(fn -> Limen.banned(@instance, "198.51.100.5") end)

    :ok = Limen.unban(@instance, "192.0.2.77")

    assert eventually(fn ->
             :erpc.call(node, Limen, :banned, [@instance, "192.0.2.77"]) == nil
           end)

    # Other instances never see them.
    refute Limen.banned(:limen_cluster_other, "198.51.100.5")
  end
end
