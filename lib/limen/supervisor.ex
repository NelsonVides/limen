defmodule Limen.Supervisor do
  @moduledoc """
  Supervises one Limen instance.

  The first child owns the instance's tables and publishes its
  `Limen.Instance`; the others are background workers that read and maintain
  that state. Workers restart with the owner, since they work on its tables.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Limen.Config.build(Keyword.get(opts, :config, []))
    Supervisor.start_link(__MODULE__, {name, config})
  end

  @impl true
  def init({name, config}) do
    children = [
      {Limen.Owner, {name, config, self()}},
      {Limen.DecisionLog.Flusher, name},
      {Limen.State.Rotator, name},
      {Limen.State.Sweeper, name}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
