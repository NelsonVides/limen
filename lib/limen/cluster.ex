defmodule Limen.Cluster do
  @moduledoc """
  Propagates an instance's bans across a cluster of nodes.

  By default all of an instance's state is per node, which works well behind
  a load balancer: rates and limits are approximate per node anyway. Bans are
  different: a client banned on one node should be banned everywhere. With

      config :my_app, Limen, cluster: [enabled: true]

  the instance runs this process in a dedicated [`:pg`][pg] scope (Erlang's
  distributed process groups), named after the instance unless `:scope` says
  otherwise, so instances of the same name on
  different nodes share their bans and other instances never see them. Bans
  and unbans made on a node (by policies or with `Limen.ban/4`) are queued in
  an ETS outbox on the request path, and this process broadcasts the queue to
  the other nodes every `:interval` milliseconds. Received bans keep their
  absolute expiry, so node clocks should be roughly in sync ([NTP]). Counters
  stay local.

  Nothing on the request path talks to this process; it only reads and
  writes ETS.

  [pg]: https://www.erlang.org/doc/apps/kernel/pg.html
  [NTP]: https://www.rfc-editor.org/rfc/rfc5905
  """

  use GenServer

  alias Limen.Instance
  alias Limen.State.BanList

  require Logger

  @group :bans

  @doc false
  @spec child_specs(atom(), Limen.Config.t()) :: [Supervisor.child_spec()]
  def child_specs(name, %{cluster: %{enabled: true} = config}) do
    scope = scope(name, config)
    [%{id: :pg, start: {:pg, :start_link, [scope]}}, {__MODULE__, {name, scope}}]
  end

  def child_specs(_name, _config), do: []

  # Instance names are atoms fixed at startup, so this creates one atom per
  # clustered instance.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp scope(name, %{scope: nil}), do: :"limen_cluster_#{name}"
  defp scope(_name, %{scope: scope}), do: scope

  @doc false
  @spec start_link({atom(), atom()}) :: GenServer.on_start()
  def start_link({name, scope}), do: GenServer.start_link(__MODULE__, {name, scope})

  @doc """
  The other nodes currently receiving the bans of `instance`.
  """
  @spec peers(atom()) :: [node()]
  def peers(instance) do
    scope = scope(instance, Instance.fetch!(instance).config.cluster)
    for pid <- :pg.get_members(scope, @group), node(pid) != node(), uniq: true, do: node(pid)
  end

  @doc """
  Broadcasts the queued bans of `instance` now and waits until it is done.
  """
  @spec flush(atom()) :: :ok
  def flush(instance), do: GenServer.call(Instance.whereis(instance, __MODULE__), :flush)

  @impl true
  def init({name, scope}) do
    :ok = :pg.join(scope, @group, self())
    interval = Instance.fetch!(name).config.cluster.interval
    Process.send_after(self(), :flush, interval)
    {:ok, %{name: name, scope: scope, interval: interval}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:flush, state) do
    broadcast(state)
    Process.send_after(self(), :flush, state.interval)
    {:noreply, state}
  end

  def handle_info({:limen_bans, from, changes}, %{name: name} = state) do
    instance = Instance.fetch!(name)
    now = System.system_time(:millisecond)
    Enum.each(changes, &BanList.apply_remote(instance, &1, now))

    Logger.debug(
      "Limen instance #{inspect(name)} applied #{length(changes)} ban changes from #{from}"
    )

    {:noreply, state}
  end

  defp broadcast(%{name: name, scope: scope}) do
    case BanList.drain_outbox(Instance.fetch!(name)) do
      [] ->
        :ok

      changes ->
        for pid <- :pg.get_members(scope, @group), node(pid) != node() do
          send(pid, {:limen_bans, node(), changes})
        end

        :ok
    end
  end
end
