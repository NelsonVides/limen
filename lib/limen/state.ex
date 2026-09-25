defmodule Limen.State do
  @moduledoc """
  An instance's shared, lock-free state.

  `new/1` creates every ETS table and `:atomics` array an instance needs; the
  instance's `Limen.Owner` calls it when the instance starts, owns the tables,
  and publishes them in its `Limen.Instance`. Requests read and write the
  tables directly; they never message a process. Background work (rotating
  time windows, sweeping expired entries) lives in `Limen.State.Rotator` and
  `Limen.State.Sweeper`, one of each per instance.

  ## Tables

    * Time windows (`Limen.State.Window`): for each of `:second`, `:minute`
      and `:hour`, three epoch slots of exact counters plus a Count-Min Sketch
      per slot for keys that arrive once the slot is full.
    * GCRA (`Limen.State.Gcra`): theoretical arrival times for hard limits.
    * Bans (`Limen.State.BanList`): banned prefixes with their expiry.

  ## Memory bounds

  Every table has a hard cap on the number of keys (see the `:state` options
  in `Limen.Config`), counted with `:atomics` so the request path never has to
  ask ETS for a table size. Sketches are allocated once and never grow. Once a
  table is full:

    * windows count new keys in the slot's sketch instead (estimates may
      overcount, never undercount);
    * GCRA stops tracking new keys, which are then not limited;
    * the ban list refuses new bans.

  Each case increments the `:saturated` counter in `Limen.Stats`.
  """

  use Boundary,
    type: :strict,
    deps: [Limen.Config, Limen.Instance, Limen.IP, Limen.Sketch, Limen.Stats, Limen.Telemetry],
    exports: [BanList, Gcra, Rotator, Sweeper, Window]

  alias Limen.Instance
  alias Limen.Sketch.CountMin

  @windows [second: 1_000, minute: 60_000, hour: 3_600_000]
  @slots 3

  @type window :: :second | :minute | :hour
  @type t :: %{
          windows: %{
            window() => %{tables: tuple(), counts: :atomics.atomics_ref(), sketches: tuple()}
          },
          gcra: %{table: :ets.tid(), size: :atomics.atomics_ref()},
          bans: %{table: :ets.tid(), size: :atomics.atomics_ref()}
        }

  @doc """
  Window names and their durations in milliseconds.
  """
  @spec windows() :: keyword(pos_integer())
  def windows, do: @windows

  @doc """
  Number of epoch slots per window.
  """
  @spec slots() :: pos_integer()
  def slots, do: @slots

  @doc """
  Duration of `window` in milliseconds.
  """
  @spec duration(window()) :: pos_integer()
  for {window, ms} <- @windows do
    def duration(unquote(window)), do: unquote(ms)
  end

  @doc false
  @spec new(Limen.Config.t()) :: t()
  def new(%{state: config}) do
    windows =
      Map.new(@windows, fn {window, _duration} ->
        tables = for _slot <- 1..@slots, do: new_table(:limen_window)

        sketches =
          for _slot <- 1..@slots, do: CountMin.new(config.sketch_width, config.sketch_depth)

        {window,
         %{
           tables: List.to_tuple(tables),
           counts: :atomics.new(@slots, []),
           sketches: List.to_tuple(sketches)
         }}
      end)

    %{
      windows: windows,
      gcra: %{table: new_table(:limen_gcra), size: :atomics.new(1, [])},
      bans: %{table: new_table(:limen_bans), size: :atomics.new(1, [])}
    }
  end

  @doc false
  @spec table(Instance.t(), window(), 0..2) :: :ets.tid()
  def table(%Instance{state: %{windows: windows}}, window, slot) do
    elem(Map.fetch!(windows, window).tables, slot)
  end

  @doc """
  Memory used by an instance's state, in bytes, by table.
  """
  @spec memory(atom() | Instance.t()) :: %{term() => non_neg_integer()}
  def memory(instance) do
    %Instance{state: state} = Instance.fetch!(instance)
    word = :erlang.system_info(:wordsize)

    windows =
      for {window, %{tables: tables}} <- state.windows,
          {table, slot} <- Enum.with_index(Tuple.to_list(tables)) do
        {{:window, window, slot}, :ets.info(table, :memory) * word}
      end

    sketches =
      state.windows
      |> Enum.flat_map(fn {_window, %{sketches: sketches}} -> Tuple.to_list(sketches) end)
      |> Enum.map(&CountMin.memory/1)
      |> Enum.sum()

    Map.new(
      windows ++
        [
          gcra: :ets.info(state.gcra.table, :memory) * word,
          bans: :ets.info(state.bans.table, :memory) * word,
          sketches: sketches
        ]
    )
  end

  @doc """
  Clears every table and counter of an instance. Meant for tests.
  """
  @spec reset(atom() | Instance.t()) :: :ok
  def reset(instance) do
    %Instance{state: state} = Instance.fetch!(instance)

    for {_window, %{tables: tables, counts: counts, sketches: sketches}} <- state.windows,
        slot <- 1..@slots do
      :ets.delete_all_objects(elem(tables, slot - 1))
      :atomics.put(counts, slot, 0)
      CountMin.reset(elem(sketches, slot - 1))
    end

    for %{table: table, size: size} <- [state.gcra, state.bans] do
      :ets.delete_all_objects(table)
      :atomics.put(size, 1, 0)
    end

    :ok
  end

  defp new_table(name) do
    :ets.new(name, [
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: :auto,
      decentralized_counters: true
    ])
  end
end
