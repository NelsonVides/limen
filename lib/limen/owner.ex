defmodule Limen.Owner do
  @moduledoc """
  Owns an instance's tables and publishes its `Limen.Instance`.

  This process creates every ETS table and `:atomics` array the instance
  needs, publishes the struct holding them, and then does nothing but own
  them. Requests read and write the tables directly; they never message this
  process. When it stops, the instance is unpublished and its tables go with
  it.
  """

  use GenServer

  alias Limen.Challenge.Replay
  alias Limen.{DecisionLog, Instance, Lists, State, Stats, Tarpit}
  alias Limen.Signal.{HttpShape, UserAgent}

  require Logger

  @doc false
  @spec start_link({atom(), Limen.Config.t(), pid()}) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({name, config, supervisor}) do
    Process.flag(:trap_exit, true)

    if taken?(name, supervisor) do
      {:stop, {:already_started, name}}
    else
      UserAgent.setup()
      HttpShape.setup()

      Instance.publish(%Instance{
        name: name,
        config: config,
        supervisor: supervisor,
        stats: Stats.new(),
        log: DecisionLog.new(config),
        state: State.new(config),
        tarpit: Tarpit.new(),
        maze: :atomics.new(1, []),
        replay: Replay.new(config)
      })

      :ok = Limen.Maze.setup(name, config)

      if config.keys.generated do
        Logger.warning(
          "Limen instance #{inspect(name)} has no :secret_key and generated one: challenge " <>
            "passes will not survive restarts or work across nodes"
        )
      end

      Lists.load(name, config.lists)

      {:ok, name}
    end
  end

  # A published instance may be a previous incarnation of this one that died
  # without cleaning up; only another live instance takes the name.
  defp taken?(name, supervisor) do
    case Instance.get(name) do
      %Instance{supervisor: other} when is_pid(other) and other != supervisor ->
        Process.alive?(other)

      _free_or_ours ->
        false
    end
  end

  @impl true
  def terminate(_reason, name) do
    Lists.clear(name)
    Limen.Maze.teardown(name)
    Instance.unpublish(name)
  end
end
