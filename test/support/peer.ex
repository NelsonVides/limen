defmodule Limen.Test.Peer do
  @moduledoc """
  Helpers the distributed tests call on peer nodes.
  """

  @doc """
  Starts a `Limen` instance that outlives the calling process, as a remote
  call's process exits as soon as it returns.
  """
  def start_instance(name, config) do
    {:ok, pid} =
      Supervisor.start_link([{Limen, name: name, config: config}], strategy: :one_for_one)

    Process.unlink(pid)
    {:ok, pid}
  end
end
