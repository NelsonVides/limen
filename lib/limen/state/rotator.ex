defmodule Limen.State.Rotator do
  @moduledoc """
  Clears an instance's expired time-window slots shortly after each epoch
  boundary.

  For each window, a timer fires just after every epoch starts and clears the
  slot the *next* epoch will use (see `Limen.State.Window.rotate/3`). A whole
  slot is dropped at once, so no per-entry expiry scan ever runs.

  Every minute it also starts new distinct-counting generations, and every
  second it publishes a fresh estimate of active client prefixes, so the
  request path never has to scan a HyperLogLog.
  """

  use GenServer

  alias Limen.Instance
  alias Limen.State
  alias Limen.State.Window

  # Fire slightly after the boundary so the new epoch has certainly started.
  @delay 5

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @impl true
  def init(name) do
    instance = Instance.fetch!(name)
    now = System.system_time(:millisecond)

    for {window, _duration} <- State.windows() do
      _cleared = Window.rotate(instance, window, now)
      schedule(window, now)
    end

    {:ok, name}
  end

  @impl true
  def handle_info({:rotate, window}, name) do
    now = System.system_time(:millisecond)
    instance = Instance.fetch!(name)
    cleared = Window.rotate(instance, window, now)
    epoch = div(now, State.duration(window))
    :ok = distinct(instance, window, now)

    Limen.Telemetry.execute(name, [:state, :rotated], %{cleared: cleared}, %{
      window: window,
      epoch: epoch
    })

    schedule(window, now)
    {:noreply, name}
  end

  defp distinct(instance, :second, now) do
    _estimate = State.estimate_active_prefixes(instance, now)
    :ok
  end

  defp distinct(instance, :minute, now), do: State.rotate_distinct(instance, now)
  defp distinct(_instance, :hour, _now), do: :ok

  defp schedule(window, now) do
    duration = State.duration(window)
    Process.send_after(self(), {:rotate, window}, duration - rem(now, duration) + @delay)
  end
end
