defmodule Limen.Stats do
  @moduledoc """
  Lock-free, node-local counters for dashboards and health checks.

  Each instance has a single `:counters` array, created when it starts.
  Updating a counter is one `:counters.add/3` call; reading them all is a
  snapshot that callers can diff over time to compute rates.
  """

  use Boundary, type: :strict, deps: [Limen.Instance]

  alias Limen.Instance

  @names [
    :allow,
    :challenge,
    :throttle,
    :deny,
    :tarpit,
    :maze,
    :enforced,
    :pass,
    :challenge_issued,
    :challenge_solved,
    :challenge_failed,
    :ban_added,
    :trap_hit,
    :maze_served,
    :maze_refused,
    :saturated
  ]

  @type name ::
          :allow
          | :challenge
          | :throttle
          | :deny
          | :tarpit
          | :maze
          | :enforced
          | :pass
          | :challenge_issued
          | :challenge_solved
          | :challenge_failed
          | :ban_added
          | :trap_hit
          | :maze_served
          | :maze_refused
          | :saturated

  @doc false
  @spec new() :: :counters.counters_ref()
  def new, do: :counters.new(length(@names), [:write_concurrency])

  @doc """
  Increments counter `name` of an instance by one.
  """
  @spec incr(Instance.t(), name()) :: :ok
  def incr(%Instance{stats: ref}, name), do: :counters.add(ref, index(name), 1)

  @doc """
  Returns the current value of every counter of an instance.
  """
  @spec snapshot(atom() | Instance.t()) :: %{name() => non_neg_integer()}
  def snapshot(instance) do
    %Instance{stats: ref} = Instance.fetch!(instance)
    Map.new(@names, fn name -> {name, :counters.get(ref, index(name))} end)
  end

  for {name, index} <- Enum.with_index(@names, 1) do
    defp index(unquote(name)), do: unquote(index)
  end
end
