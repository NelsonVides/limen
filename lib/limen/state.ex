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
      (`Limen.Sketch.CountMin`) per slot for keys that arrive once the slot
      is full.
    * GCRA (`Limen.State.Gcra`): theoretical arrival times for hard limits.
    * Bans (`Limen.State.BanList`): banned prefixes with their expiry, and
      an outbox of local ban changes `Limen.Cluster` broadcasts.
    * Distinct counting: a HyperLogLog (`Limen.Sketch.HyperLogLog`) of client
      prefixes per minute epoch, whose estimate a background tick publishes
      as `active_prefixes/1`, and a rotating Bloom filter
      (`Limen.Sketch.RotatingBloom`) of (prefix, path) pairs so each client's
      distinct paths can be counted in its time window.
    * Crawler verification (`Limen.Signal.Fcrdns`): a cache of results and a
      bounded queue of addresses to verify.

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
  alias Limen.Sketch.{Bloom, CountMin, HyperLogLog, RotatingBloom}

  @windows [second: 1_000, minute: 60_000, hour: 3_600_000]
  @slots 3

  @type window :: :second | :minute | :hour
  @type t :: %{
          windows: %{
            window() => %{
              tables: tuple(),
              counts: :atomics.atomics_ref(),
              sketches: tuple(),
              max_keys: pos_integer()
            }
          },
          gcra: %{table: :ets.tid(), size: :atomics.atomics_ref()},
          bans: %{
            table: :ets.tid(),
            size: :atomics.atomics_ref(),
            outbox: :ets.tid(),
            outbox_size: :atomics.atomics_ref()
          },
          distinct: %{
            prefixes: tuple(),
            paths: RotatingBloom.t(),
            estimate: :atomics.atomics_ref()
          },
          fcrdns: %{cache: :ets.tid(), pending: :ets.tid(), size: :atomics.atomics_ref()}
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
           sketches: List.to_tuple(sketches),
           max_keys: config.max_keys
         }}
      end)

    prefixes = for _slot <- 1..@slots, do: HyperLogLog.new(config.hll_precision)

    %{
      windows: windows,
      gcra: %{table: new_table(:limen_gcra), size: :atomics.new(1, [])},
      bans: %{
        table: new_table(:limen_bans),
        size: :atomics.new(1, []),
        outbox: new_table(:limen_ban_outbox),
        outbox_size: :atomics.new(1, [])
      },
      distinct: %{
        prefixes: List.to_tuple(prefixes),
        paths: RotatingBloom.new(config.path_filter_capacity, 0.02),
        estimate: :atomics.new(1, [])
      },
      fcrdns: %{
        cache: new_table(:limen_fcrdns_cache),
        pending: new_table(:limen_fcrdns_pending),
        size: :atomics.new(1, [])
      }
    }
  end

  @doc false
  @spec table(Instance.t(), window(), 0..2) :: :ets.tid()
  def table(%Instance{state: %{windows: windows}}, window, slot) do
    elem(Map.fetch!(windows, window).tables, slot)
  end

  @doc """
  Distinct client prefixes `instance` saw over the last one to two minutes,
  as last estimated in the background.
  """
  @spec active_prefixes(Instance.t()) :: non_neg_integer()
  def active_prefixes(%Instance{state: %{distinct: %{estimate: estimate}}}),
    do: :atomics.get(estimate, 1)

  @doc """
  Adds a client prefix to the active prefix count, and returns whether it had
  not requested `path` recently.
  """
  @spec observe_client(Instance.t(), Limen.IP.prefix(), String.t(), integer()) :: boolean()
  def observe_client(%Instance{state: %{distinct: distinct}}, prefix, path, now) do
    %{prefixes: prefixes, paths: paths} = distinct
    HyperLogLog.add(elem(prefixes, rem(div(now, duration(:minute)), @slots)), prefix)
    RotatingBloom.put_new(paths, {prefix, path})
  end

  @doc false
  @spec estimate_active_prefixes(Instance.t(), integer()) :: non_neg_integer()
  def estimate_active_prefixes(%Instance{state: %{distinct: distinct}}, now) do
    %{prefixes: prefixes, estimate: estimate} = distinct
    epoch = div(now, duration(:minute))
    current = elem(prefixes, rem(epoch, @slots))
    previous = elem(prefixes, rem(epoch - 1 + @slots, @slots))
    count = HyperLogLog.cardinality([current, previous])
    :atomics.put(estimate, 1, count)
    count
  end

  @doc false
  @spec rotate_distinct(Instance.t(), integer()) :: :ok
  def rotate_distinct(%Instance{state: %{distinct: distinct}}, now) do
    %{prefixes: prefixes, paths: paths} = distinct
    HyperLogLog.reset(elem(prefixes, rem(div(now, duration(:minute)) + 1, @slots)))
    RotatingBloom.rotate(paths)
  end

  @doc """
  Memory used by an instance's state, in bytes, by table.
  """
  @spec memory(atom() | Instance.t()) :: %{term() => non_neg_integer()}
  def memory(instance) do
    %Instance{state: state} = Instance.fetch!(instance)
    Map.new(windows_memory(state.windows) ++ tables_memory(state) ++ sketches_memory(state))
  end

  defp windows_memory(windows) do
    for {window, %{tables: tables}} <- windows,
        {table, slot} <- Enum.with_index(Tuple.to_list(tables)) do
      {{:window, window, slot}, table_memory(table)}
    end
  end

  defp tables_memory(%{gcra: gcra, bans: bans, fcrdns: fcrdns}) do
    [
      gcra: table_memory(gcra.table),
      bans: table_memory(bans.table),
      ban_outbox: table_memory(bans.outbox),
      fcrdns_cache: table_memory(fcrdns.cache),
      fcrdns_pending: table_memory(fcrdns.pending)
    ]
  end

  defp sketches_memory(%{windows: windows, distinct: distinct}) do
    %{prefixes: prefixes, paths: %RotatingBloom{generations: {a, b}}} = distinct

    sketches =
      windows
      |> Enum.flat_map(fn {_window, %{sketches: sketches}} -> Tuple.to_list(sketches) end)
      |> Enum.map(&CountMin.memory/1)

    [
      sketches: Enum.sum(sketches),
      distinct_prefixes: Enum.sum(Enum.map(Tuple.to_list(prefixes), &HyperLogLog.memory/1)),
      path_filter: Bloom.memory(a) + Bloom.memory(b)
    ]
  end

  defp table_memory(table), do: :ets.info(table, :memory) * :erlang.system_info(:wordsize)

  @doc """
  Clears every table and counter of an instance. Meant for tests.
  """
  @spec reset(atom() | Instance.t()) :: :ok
  def reset(instance) do
    %Instance{state: %{gcra: gcra, bans: bans, fcrdns: fcrdns} = state} =
      Instance.fetch!(instance)

    Enum.each(state.windows, fn {_window, slots} -> reset_window(slots) end)
    reset_tables([gcra.table], gcra.size)
    reset_tables([bans.table], bans.size)
    reset_tables([bans.outbox], bans.outbox_size)
    reset_tables([fcrdns.cache, fcrdns.pending], fcrdns.size)
    reset_distinct(state.distinct)
  end

  defp reset_window(%{tables: tables, counts: counts, sketches: sketches}) do
    for slot <- 1..@slots do
      :ets.delete_all_objects(elem(tables, slot - 1))
      :atomics.put(counts, slot, 0)
      CountMin.reset(elem(sketches, slot - 1))
    end
  end

  defp reset_tables(tables, size) do
    Enum.each(tables, &:ets.delete_all_objects/1)
    :atomics.put(size, 1, 0)
  end

  defp reset_distinct(%{prefixes: prefixes, paths: paths, estimate: estimate}) do
    for sketch <- Tuple.to_list(prefixes), do: HyperLogLog.reset(sketch)
    RotatingBloom.rotate(paths)
    RotatingBloom.rotate(paths)
    :atomics.put(estimate, 1, 0)
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
