defmodule Limen.Dashboard.Data do
  @moduledoc """
  Node-local figures of an instance for dashboards: counters, the busiest
  clients, bans and recent decisions.

  Everything here scans tables or copies buffers, so it belongs in dashboards
  and health checks, not on the request path.
  """

  alias Limen.{DecisionLog, Instance, IP, State, Stats, Tarpit}
  alias Limen.Signal.Asn
  alias Limen.State.{BanList, Window}

  @doc """
  A snapshot of the counters and gauges, with the time it was taken.
  """
  @spec snapshot(atom()) :: map()
  def snapshot(name) do
    instance = Instance.fetch!(name)

    %{
      at: System.monotonic_time(:millisecond),
      mode: instance.config.mode,
      stats: Stats.snapshot(instance),
      active_prefixes: State.active_prefixes(instance),
      bans: length(BanList.list(instance)),
      tarpitted: Tarpit.held(instance),
      in_maze: :atomics.get(instance.maze, 1),
      memory: Enum.sum(Map.values(State.memory(instance))),
      asn: asn(name)
    }
  end

  # The loader may be busy downloading or building a table for a while;
  # the loaded table's own description is always at hand.
  defp asn(name) do
    Asn.Loader.status(name, 500)
  catch
    :exit, _busy ->
      table = Asn.published(name) || %{ranges: nil, bytes: nil, loaded_at: nil, source: nil}
      Map.put(Map.take(table, [:ranges, :bytes, :loaded_at, :source]), :busy, true)
  end

  @doc """
  Per-second rates of every counter between two snapshots.
  """
  @spec rates(map() | nil, map()) :: map()
  def rates(nil, current), do: Map.new(current.stats, fn {name, _count} -> {name, 0.0} end)

  def rates(previous, current) do
    seconds = max(current.at - previous.at, 1) / 1_000

    Map.new(current.stats, fn {name, count} ->
      {name, Float.round((count - Map.get(previous.stats, name, 0)) / seconds, 1)}
    end)
  end

  @doc """
  The prefixes with the most requests in the current minute epoch.
  """
  @spec top_prefixes(atom(), pos_integer()) :: [%{prefix: String.t(), requests: pos_integer()}]
  def top_prefixes(name, limit) do
    # A prefix's behaviour row starts with its request count.
    for {{:limen_behaviour, prefix}, count} <- top(name, :limen_behaviour, limit) do
      %{prefix: IP.prefix_to_string(prefix), requests: count}
    end
  end

  @doc """
  The JA4 fingerprints with the most clients (prefixes) in the current minute
  epoch. A prefix counts for the fingerprint of its first request of the
  minute.
  """
  @spec top_ja4(atom(), pos_integer()) :: [%{ja4: String.t(), clients: pos_integer()}]
  def top_ja4(name, limit) do
    for {{:limen_ja4, ja4}, count} <- top(name, :limen_ja4, limit) do
      %{ja4: ja4, clients: count}
    end
  end

  defp top(name, tag, limit) do
    filter = &match?({^tag, _subject}, &1)
    Window.top(Instance.fetch!(name), :minute, filter, limit, System.system_time(:millisecond))
  end

  @doc """
  Active bans, soonest to expire first.
  """
  @spec bans(atom(), pos_integer()) :: [map()]
  def bans(name, limit) do
    now = System.system_time(:millisecond)

    for ban <- Enum.take(BanList.list(Instance.fetch!(name), now), limit) do
      %{
        prefix: IP.prefix_to_string(ban.prefix),
        reason: inspect(ban.reason),
        origin: ban.origin,
        action: ban.action,
        mode: ban.mode,
        expires_in: div(ban.expires_at - now, 1_000)
      }
    end
  end

  @doc """
  The most recent sampled decisions.
  """
  @spec recent(atom(), pos_integer()) :: [map()]
  def recent(name, limit) do
    for decision <- DecisionLog.recent(name, limit) do
      report = DecisionLog.report(decision)

      %{
        action: report.action,
        enforced: report.enforced,
        stage: report.stage,
        score: report.score,
        path: report.path,
        prefix: report.prefix,
        rules: Enum.join(report.rules, ", ")
      }
    end
  end
end
