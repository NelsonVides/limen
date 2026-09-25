defmodule Limen.Bench.Scenarios do
  @moduledoc """
  The request-path operations CI tracks for performance regressions.

  Scenario names are the keys results are compared by, so renaming one starts
  a new series.

  Every sample runs its operation `batch/0` times: single operations take a
  few hundred nanoseconds, too close to timer resolution and scheduling noise
  for a 10% regression threshold to be meaningful. Reported figures are
  divided back to a single operation.

  Every scenario runs against a fresh `Limen` instance with its own
  configuration, so results do not depend on scenario order. Operations
  receive the instance, as the request path does after its single lookup.
  """

  import Plug.Test

  alias Limen.State.{BanList, Gcra, Window}

  @batch 100
  @instance :limen_bench

  @doc """
  Operations per benchmark sample.
  """
  @spec batch() :: pos_integer()
  def batch, do: @batch

  @doc """
  Starts the supervisor scenario instances run under.
  """
  @spec setup() :: :ok
  def setup do
    {:ok, _pid} = DynamicSupervisor.start_link(name: __MODULE__, strategy: :one_for_one)
    :ok
  end

  @doc """
  Returns every scenario as a Benchee job map.
  """
  @spec all() :: %{String.t() => {(Limen.Instance.t() -> term()), keyword()}}
  def all do
    state()
    |> Map.merge(plug())
    |> Map.new(fn {name, {fun, config}} ->
      {name,
       {fn instance -> repeat(fun, instance, @batch) end,
        before_scenario: fn _input -> restart(config) end}}
    end)
  end

  @doc """
  Starts a fresh instance with `config` and returns it.
  """
  @spec restart(keyword()) :: Limen.Instance.t()
  def restart(config) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(__MODULE__) do
      :ok = DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    {:ok, _pid} =
      DynamicSupervisor.start_child(__MODULE__, {Limen, name: @instance, config: config})

    Limen.Instance.fetch!(@instance)
  end

  defp repeat(_fun, _instance, 0), do: :ok

  defp repeat(fun, instance, n) do
    fun.(instance)
    repeat(fun, instance, n - 1)
  end

  defp state do
    now = fn -> System.system_time(:millisecond) end
    counter = :counters.new(1, [:write_concurrency])

    unique = fn ->
      :counters.add(counter, 1, 1)
      {:bench, {6, :counters.get(counter, 1), 64}}
    end

    %{
      "state: window incr, hot key" =>
        {fn instance -> Window.incr(instance, :second, :bench_hot, now.()) end, []},
      "state: window incr, flood of unique keys" =>
        {fn instance -> Window.incr(instance, :minute, unique.(), now.()) end,
         [state: [max_keys: 1_000]]},
      "state: window count" =>
        {fn instance -> Window.count(instance, :second, :bench_hot, now.()) end, []},
      "state: gcra check" =>
        {fn instance -> Gcra.check(instance, :bench_gcra, 1_000_000, 1_000, 1_000) end, []},
      "state: ban lookup, miss" =>
        {fn instance -> BanList.lookup(instance, {4, 1, 32}, now.()) end, []}
    }
  end

  defp plug do
    opts = Limen.Plug.init(instance: @instance)
    conn = conn(:get, "/articles/42") |> Plug.Conn.put_req_header("user-agent", "bench")

    %{
      "plug: dry-run, no signals" => {fn _instance -> Limen.Plug.call(conn, opts) end, []}
    }
  end
end
