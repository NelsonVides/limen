defmodule Limen.Challenge.Replay.Rotator do
  @moduledoc """
  Rotates an instance's replay filter every challenge `:ttl`.
  """

  use GenServer

  alias Limen.Challenge.Replay
  alias Limen.Instance

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @impl true
  def init(name) do
    schedule(name)
    {:ok, name}
  end

  @impl true
  def handle_info(:rotate, name) do
    Replay.rotate(Instance.fetch!(name))
    schedule(name)
    {:noreply, name}
  end

  defp schedule(name) do
    Process.send_after(self(), :rotate, Instance.fetch!(name).config.challenge.ttl * 1_000)
  end
end
