defmodule Limen.State.Sweeper do
  @moduledoc """
  Periodically removes an instance's expired bans and idle GCRA keys.

  Runs every `:sweep_interval` milliseconds (see `Limen.Config`), entirely off
  the request path. Sweeping also resynchronises the `:atomics` size counters
  the request path uses to enforce table caps.
  """

  use GenServer

  alias Limen.Instance
  alias Limen.State.{BanList, Gcra}

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @doc """
  Sweeps `instance` now and waits until it is done.
  """
  @spec sweep(atom()) :: :ok
  def sweep(instance), do: GenServer.call(Instance.whereis(instance, __MODULE__), :sweep)

  @impl true
  def init(name) do
    schedule(name)
    {:ok, name}
  end

  @impl true
  def handle_call(:sweep, _from, name) do
    run(name)
    {:reply, :ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    run(name)
    schedule(name)
    {:noreply, name}
  end

  defp run(name) do
    instance = Instance.fetch!(name)
    _bans = BanList.sweep(instance)
    _limits = Gcra.sweep(instance)
    :ok
  end

  defp schedule(name) do
    interval = Instance.fetch!(name).config.state.sweep_interval
    Process.send_after(self(), :sweep, interval)
  end
end
