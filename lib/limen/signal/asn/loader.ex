defmodule Limen.Signal.Asn.Loader do
  @moduledoc """
  Loads IP-to-ASN data for `Limen.Signal.Asn` and keeps it current, off the
  request path.

  ## Loading

  At startup the loader reads the `:file` of the `:asn` configuration, if it
  exists. Each table (see `Limen.Signal.Asn.Table`) is built in a
  short-lived process, so the memory building takes goes with it, and is
  complete before it replaces the published one: lookups see the old table
  or the new one, never a partial load. `load/2` and `load_rows/2` load other
  data by hand.

  ## Refreshing

  With a `:url`, the loader downloads the data into `:file` and checks it
  for changes on the schedule of the `:refresh` options (see
  `Limen.Signal.Asn.Schedule` and `Limen.Config`):

    * a check downloads the data only if it changed since the file was last
      confirmed current, which restarting does not reset;
    * a scheduled check is postponed while the BEAM's schedulers are busier
      than `:max_utilization` (sampled for a second) or its memory is above
      `:max_memory`: building a table takes a few seconds of one scheduler
      and, for the full iptoasn.com data, about 100 MB for that time;
    * new data with less than half the ranges of the loaded table is
      rejected as a broken download, and so is data with no range at all;
    * a failed check keeps the current data and is retried with backoff.

  `refresh/1` checks at once, whatever the schedule and the load, and
  `status/1` reports what the loader did and plans to do. Every load and
  check emits telemetry, see `Limen.Telemetry`.
  """

  use GenServer

  alias Limen.Instance
  alias Limen.Signal.Asn
  alias Limen.Signal.Asn.{Download, Schedule, Table}

  require Logger

  @typedoc """
  The outcome of a check for new data.
  """
  @type result :: :updated | :unchanged | {:postponed, term()} | {:error, term()}

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @doc """
  Loads an iptoasn.com TSV file (optionally gzipped) into `instance`.

  Returns the number of ranges loaded.
  """
  @spec load(atom(), Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(instance, path), do: call(instance, {:load, {:file, path}})

  @doc """
  Loads ranges given as `{first, last, asn, country, name}` tuples into
  `instance`. Meant for tests and small custom tables.
  """
  @spec load_rows(atom(), [Table.row()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_rows(instance, rows), do: call(instance, {:load, {:rows, rows}})

  @doc """
  Checks the `:url` for new data now, whatever the schedule and the load,
  and reschedules the next check from there.
  """
  @spec refresh(atom()) :: result()
  def refresh(instance), do: call(instance, :refresh)

  @doc """
  What `instance` has loaded and when it checks next.

    * `:ranges`, `:bytes`, `:loaded_at` and `:source` describe the loaded
      table, or are `nil` when none is;
    * `:next_check` is when the next check is due, in milliseconds since the
      epoch, or `nil` without a `:url`;
    * `:last_check` is `%{at: milliseconds, result: result}`, or `nil`;
    * `:failures` counts consecutive failed checks.

  The loader answers once it finishes what it is doing, which can be a
  download; pass a `timeout` in milliseconds to wait less.
  """
  @spec status(atom(), timeout()) :: map()
  def status(instance, timeout \\ :infinity), do: call(instance, :status, timeout)

  defp call(instance, request, timeout \\ :infinity) do
    GenServer.call(Instance.whereis(instance, __MODULE__), request, timeout)
  end

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    state = %{name: name, asn: Instance.fetch!(name).config.asn, failures: 0, check: nil}
    {:ok, Map.merge(state, %{next_check: nil, last_check: nil}), {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, %{asn: %{file: file, url: url}} = state) do
    cond do
      is_nil(file) -> :ok
      # The first check downloads it.
      url && not File.regular?(file) -> :ok
      true -> boot_load(state.name, file)
    end

    {:noreply, schedule_first(state)}
  end

  @impl true
  def handle_call({:load, source}, _from, state),
    do: {:reply, load_table(state.name, source), state}

  def handle_call(:refresh, _from, %{asn: %{url: nil}} = state),
    do: {:reply, {:error, :no_url}, state}

  def handle_call(:refresh, _from, state) do
    {result, state} = check(state, true)
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    table = Asn.published(state.name) || %{ranges: nil, bytes: nil, loaded_at: nil, source: nil}

    status =
      table
      |> Map.take([:ranges, :bytes, :loaded_at, :source])
      |> Map.merge(Map.take(state, [:next_check, :last_check, :failures]))

    {:reply, status, state}
  end

  @impl true
  def handle_info({:check, ref}, %{check: {ref, _timer}} = state) do
    {_result, state} = check(state, false)
    {:noreply, state}
  end

  # A check that was rescheduled before its timer fired.
  def handle_info({:check, _stale}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Asn.unpublish(state.name)

  ## Loading

  defp boot_load(name, file) do
    case load_table(name, {:file, file}) do
      {:ok, _ranges} ->
        :ok

      {:error, reason} ->
        Logger.error("Limen could not load ASN data from #{file}: #{inspect(reason)}")
    end
  end

  defp load_table(name, source) do
    started = System.monotonic_time()

    case isolated(source) do
      {:ok, table} ->
        publish(name, table, source, started)
        {:ok, table.ranges}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish(name, table, source, started) do
    source = describe(source)
    Asn.publish(name, %{table | loaded_at: System.system_time(:millisecond), source: source})

    measurements = %{
      duration: System.monotonic_time() - started,
      ranges: table.ranges,
      bytes: table.bytes
    }

    Limen.Telemetry.execute(name, [:asn, :loaded], measurements, %{source: source})
    Logger.info("Limen loaded #{table.ranges} ASN ranges from #{format_source(source)}")
  end

  defp describe({:rows, _rows}), do: :rows
  defp describe(source), do: source

  defp format_source({_kind, location}), do: location
  defp format_source(:rows), do: "rows"

  # Building allocates far more than the table it returns; doing it in its
  # own process frees all of that at once when it exits.
  defp isolated({:rows, rows}), do: isolated(fn -> Table.from_rows(rows) end)
  defp isolated({:file, path}), do: isolated(fn -> read(path) end)

  defp isolated(build) when is_function(build, 0) do
    loader = self()
    {pid, ref} = spawn_monitor(fn -> send(loader, {self(), build.()}) end)

    receive do
      {^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:build_failed, reason}}
    end
  end

  # A file in the iptoasn.com `ip2asn-combined.tsv` format, gzipped or not.
  defp read(path) do
    with {:ok, modes} <- modes(path) do
      path
      |> File.stream!(:line, modes)
      |> Stream.flat_map(&parse_line/1)
      |> Table.from_rows()
    end
  rescue
    e in [File.Error, IO.StreamError, ErlangError] -> {:error, Exception.message(e)}
  end

  # Gzip is recognised by its magic bytes, not by the file name: downloads
  # land in a temporary file first.
  defp modes(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, <<0x1F, 0x8B>>} -> {:ok, [:compressed]}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_line(line) do
    case :binary.split(String.trim_trailing(line, "\n"), "\t", [:global]) do
      [first, last, asn, country, name] ->
        case Integer.parse(asn) do
          {asn, ""} -> [{first, last, asn, country, name}]
          _invalid -> []
        end

      _malformed ->
        []
    end
  end

  ## Refreshing

  defp schedule_first(%{asn: %{url: nil}} = state), do: state

  defp schedule_first(%{asn: asn} = state) do
    # Without a loaded table, whatever the file holds is no reason to wait.
    checked_at = if Asn.published(state.name), do: modified_at(asn.file)
    now = System.system_time(:millisecond)
    schedule(state, Schedule.next_check(now, checked_at, asn.refresh, :rand.uniform()))
  end

  defp check(state, forced?) do
    started = System.monotonic_time()

    result = if forced?, do: fetch(state), else: fetch_unless_busy(state)

    {outcome, reason} =
      case result do
        {kind, reason} -> {kind, reason}
        outcome -> {outcome, nil}
      end

    metadata = %{url: state.asn.url, result: outcome, reason: reason}
    measurements = %{duration: System.monotonic_time() - started}
    Limen.Telemetry.execute(state.name, [:asn, :checked], measurements, metadata)
    log_check(state.asn.url, result)

    {result, reschedule(state, result)}
  end

  defp log_check(url, {:error, reason}),
    do: Logger.warning("Limen could not refresh ASN data from #{url}: #{inspect(reason)}")

  defp log_check(_url, _result), do: :ok

  defp fetch_unless_busy(state) do
    case busy(state.asn.refresh) do
      nil -> fetch(state)
      reason -> {:postponed, reason}
    end
  end

  defp busy(refresh) do
    memory = :erlang.memory(:total)

    cond do
      refresh.max_memory && memory > refresh.max_memory ->
        {:memory, memory}

      refresh.max_utilization ->
        utilization = utilization(1_000)
        if utilization > refresh.max_utilization, do: {:utilization, utilization}

      true ->
        nil
    end
  end

  @doc """
  The share of time the BEAM's schedulers were busy over the next `ms`
  milliseconds, between `0.0` and `1.0`.
  """
  @spec utilization(pos_integer()) :: float()
  def utilization(ms) do
    _previous = :erlang.system_flag(:scheduler_wall_time, true)
    first = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(ms)
    second = :erlang.statistics(:scheduler_wall_time)
    _previous = :erlang.system_flag(:scheduler_wall_time, false)
    schedulers = :erlang.system_info(:schedulers)

    {active, total} =
      Enum.zip(Enum.sort(first), Enum.sort(second))
      |> Enum.filter(fn {{id, _active, _total}, _second} -> id <= schedulers end)
      |> Enum.reduce({0, 0}, fn {{_id, a1, t1}, {_id2, a2, t2}}, {active, total} ->
        {active + a2 - a1, total + t2 - t1}
      end)

    if total > 0, do: active / total, else: 0.0
  end

  defp fetch(%{asn: asn} = state) do
    download = asn.file <> ".download"
    # Without a loaded table, download whatever the server has.
    since = if Asn.published(state.name), do: modified_at(asn.file)

    case Download.fetch(asn.url, download, since, asn.refresh.timeout) do
      :unchanged ->
        # The file is confirmed current as of now.
        _touched = File.touch(asn.file)
        :unchanged

      :updated ->
        install(state, download)

      {:error, reason} ->
        _removed = File.rm(download)
        {:error, reason}
    end
  end

  defp install(%{name: name, asn: asn}, download) do
    started = System.monotonic_time()

    with {:ok, table} <- isolated({:file, download}),
         :ok <- plausible(table, Asn.published(name)),
         :ok <- File.rename(download, asn.file) do
      _touched = File.touch(asn.file)
      publish(name, table, {:url, asn.url}, started)
      :updated
    else
      {:error, reason} ->
        _removed = File.rm(download)
        {:error, reason}
    end
  end

  defp plausible(%{ranges: 0}, _current), do: {:error, :no_ranges}

  defp plausible(%{ranges: ranges}, %{ranges: current}) when ranges * 2 < current,
    do: {:error, {:too_few_ranges, ranges, current}}

  defp plausible(_table, _current), do: :ok

  defp reschedule(state, result) do
    now = System.system_time(:millisecond)
    refresh = state.asn.refresh
    random = :rand.uniform()

    {failures, at} =
      case result do
        {:error, _reason} ->
          {state.failures + 1, Schedule.retry_failed(now, state.failures + 1, refresh, random)}

        {:postponed, _reason} ->
          {state.failures, Schedule.retry_postponed(now, refresh, random)}

        _loaded_or_current ->
          {0, Schedule.next_check(now, now, refresh, random)}
      end

    schedule(%{state | failures: failures, last_check: %{at: now, result: result}}, at)
  end

  defp schedule(state, at) do
    with {_ref, timer} <- state.check, do: Process.cancel_timer(timer)
    ref = make_ref()
    delay = max(at - System.system_time(:millisecond), 0)
    timer = Process.send_after(self(), {:check, ref}, delay)
    %{state | check: {ref, timer}, next_check: at}
  end

  defp modified_at(nil), do: nil

  defp modified_at(file) do
    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime * 1_000
      {:error, _reason} -> nil
    end
  end
end
