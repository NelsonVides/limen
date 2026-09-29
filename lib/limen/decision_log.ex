defmodule Limen.DecisionLog do
  @moduledoc """
  A sampled, structured decision log.

  Writing to `Logger` from the request path would send a message to a logger
  handler for every request, so decisions are instead sampled into a
  fixed-size ring buffer: an ETS table indexed by an `:atomics` cursor, one
  per instance. `Limen.DecisionLog.Flusher` drains the buffer periodically and
  emits each entry as a structured `Logger` report. When the buffer wraps
  faster than it is drained, the oldest entries are overwritten and the
  flusher logs how many were lost.

  The same buffer backs `recent/2`, which the LiveDashboard page uses to show
  the latest decisions.

  Sampling is configured with the `:decision_log` option, see `Limen.Config`.
  """

  use Limen.Boundary,
    type: :strict,
    deps: [Limen.Config, Limen.Decision, Limen.Instance, Limen.IP, Logger],
    exports: [Flusher]

  alias Limen.{Decision, Instance}

  @type buffer :: %{table: :ets.tid(), cursor: :atomics.atomics_ref()}

  @doc false
  @spec new(Limen.Config.t()) :: buffer()
  def new(_config) do
    %{
      table: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
      cursor: :atomics.new(1, signed: false)
    }
  end

  @doc """
  Samples `decision` into the instance's buffer according to the configured
  rates.

  Called on the request path. Costs a random number and, when sampled, one
  atomic increment and one ETS insert.
  """
  @spec record(Instance.t(), Decision.t()) :: :ok
  def record(%Instance{config: %{decision_log: log}, log: buffer}, %Decision{} = decision) do
    rate = if decision.action == :allow, do: log.sample_rate, else: log.non_allow_sample_rate

    if rate > 0 and (rate >= 1 or :rand.uniform() < rate) do
      seq = :atomics.add_get(buffer.cursor, 1, 1)
      :ets.insert(buffer.table, {rem(seq, log.size), seq, decision})
    end

    :ok
  end

  @doc """
  Returns up to `limit` of the most recent sampled decisions, newest first.
  """
  @spec recent(atom() | Instance.t(), pos_integer()) :: [Decision.t()]
  def recent(instance, limit \\ 50) do
    %Instance{config: %{decision_log: %{size: size}}, log: buffer} = Instance.fetch!(instance)
    last = :atomics.get(buffer.cursor, 1)
    first = max(last - min(limit, size) + 1, 1)
    if last < first, do: [], else: collect(buffer, last..first//-1, size)
  end

  @doc """
  Converts a decision into a structured report map.
  """
  @spec report(Decision.t()) :: map()
  def report(%Decision{identity: identity} = decision) do
    %{
      event: "limen.decision",
      instance: decision.instance,
      action: decision.action,
      params: decision.params,
      enforced: decision.enforced,
      mode: decision.mode,
      stage: decision.stage,
      policy: decision.policy && inspect(decision.policy),
      route: decision.route,
      score: decision.score,
      method: decision.method,
      path: decision.path,
      client_ip: format_ip(identity[:client_ip]),
      prefix: format_prefix(identity[:prefix]),
      ja4: identity[:ja4],
      rules: Enum.map(decision.matches, &"#{&1.kind}:#{&1.name}"),
      clause: decision.clause,
      signals: decision.signals,
      errors: decision.errors
    }
  end

  @doc false
  @spec since(Instance.t(), non_neg_integer()) ::
          {[Decision.t()], dropped :: non_neg_integer(), last :: non_neg_integer()}
  def since(%Instance{config: %{decision_log: %{size: size}}, log: buffer}, flushed) do
    last = :atomics.get(buffer.cursor, 1)
    first = max(flushed + 1, last - size + 1)
    entries = if last >= first, do: Enum.reverse(collect(buffer, last..first//-1, size)), else: []
    {entries, first - flushed - 1, last}
  end

  defp collect(%{table: table}, range, size) do
    Enum.flat_map(range, fn seq ->
      case :ets.lookup(table, rem(seq, size)) do
        [{_slot, ^seq, decision}] -> [decision]
        _overwritten -> []
      end
    end)
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: to_string(:inet.ntoa(ip))

  defp format_prefix(nil), do: nil
  defp format_prefix(prefix), do: Limen.IP.prefix_to_string(prefix)
end
