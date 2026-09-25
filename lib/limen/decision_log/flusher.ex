defmodule Limen.DecisionLog.Flusher do
  @moduledoc """
  Drains an instance's decision log buffer to `Logger` periodically.
  """

  use GenServer

  alias Limen.{DecisionLog, Instance}

  require Logger

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @doc """
  Drains the buffer of `instance` now and waits until it is done.
  """
  @spec flush(atom()) :: :ok
  def flush(instance), do: GenServer.call(Instance.whereis(instance, __MODULE__), :flush)

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    schedule(name)
    {:ok, %{name: name, flushed: 0}}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_now(state)}

  @impl true
  def handle_info(:flush, state) do
    state = flush_now(state)
    schedule(state.name)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: flush_now(state)

  defp flush_now(%{name: name, flushed: flushed} = state) do
    case Instance.get(name) do
      nil ->
        state

      instance ->
        {entries, dropped, last} = DecisionLog.since(instance, flushed)
        level = instance.config.decision_log.level

        if dropped > 0 do
          Logger.warning(
            "Limen decision log of #{inspect(name)} overflowed, #{dropped} entries dropped"
          )
        end

        Enum.each(entries, fn decision ->
          Logger.log(level, fn -> DecisionLog.report(decision) end)
        end)

        %{state | flushed: last}
    end
  end

  defp schedule(name) do
    interval = Instance.fetch!(name).config.decision_log.flush_interval
    Process.send_after(self(), :flush, interval)
  end
end
