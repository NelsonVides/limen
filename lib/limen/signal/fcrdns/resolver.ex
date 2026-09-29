defmodule Limen.Signal.Fcrdns.Resolver do
  @moduledoc """
  Verifies an instance's queued crawler addresses in the background.

  Every `:interval` milliseconds it takes the addresses `Limen.Signal.Fcrdns`
  queued, verifies them concurrently (at most `:concurrency` lookups, each
  bounded by `:timeout`), and caches the results for `:verified_ttl`,
  `:failed_ttl` or, after a transient DNS error, `:error_ttl` seconds.
  """

  use GenServer

  alias Limen.Instance
  alias Limen.Signal.Fcrdns

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name)

  @doc """
  Resolves everything `instance` queued now and waits until it is done.
  """
  @spec run(atom()) :: :ok
  def run(instance), do: GenServer.call(Instance.whereis(instance, __MODULE__), :run, :infinity)

  @impl true
  def init(name) do
    schedule(name)
    {:ok, %{name: name, runs: 0}}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, :ok, resolve(state)}

  @impl true
  def handle_info(:run, state) do
    state = resolve(state)
    schedule(state.name)
    {:noreply, state}
  end

  defp resolve(%{name: name, runs: runs} = state) do
    %Instance{config: %{fcrdns: config}, state: %{fcrdns: tables}} = Instance.fetch!(name)

    case Enum.map(:ets.tab2list(tables.pending), fn {key} -> key end) do
      [] -> :ok
      keys -> resolve(name, keys, tables, config)
    end

    # Expired results are swept every few hundred runs.
    _swept = if rem(runs, 200) == 0, do: sweep(tables.cache), else: 0
    %{state | runs: runs + 1}
  end

  defp resolve(name, keys, tables, config) do
    keys
    |> Task.async_stream(&verify(name, &1, config),
      max_concurrency: config.concurrency,
      timeout: config.timeout * 3,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.each(&cache(tables.cache, &1, config))

    # Subtracted, not reset to the queue's size, which would lose the keys
    # queued meanwhile: every queued key adds one.
    removed = Enum.count(keys, &(:ets.take(tables.pending, &1) != []))
    :atomics.sub(tables.size, 1, removed)
  end

  defp verify(name, {ip, crawler} = key, config) do
    started = System.monotonic_time()
    result = Fcrdns.verify(ip, Map.fetch!(config.crawlers, crawler), config.dns, config.timeout)

    Limen.Telemetry.execute(
      name,
      [:fcrdns, :resolved],
      %{duration: System.monotonic_time() - started},
      %{
        ip: ip,
        crawler: crawler,
        result: result
      }
    )

    {key, result}
  end

  defp cache(table, {:ok, {key, result}}, config) do
    now = System.system_time(:millisecond)

    if :ets.info(table, :size) < config.max_cache do
      entry =
        case result do
          {:verified, host} -> {key, :verified, host, now + config.verified_ttl * 1_000}
          {:failed, reason} -> {key, :failed, reason, now + config.failed_ttl * 1_000}
          {:error, reason} -> {key, :error, reason, now + config.error_ttl * 1_000}
        end

      :ets.insert(table, entry)
    end
  end

  defp cache(_table, {:exit, {_key, _reason}}, _config), do: true

  defp sweep(table) do
    now = System.system_time(:millisecond)

    :ets.select_delete(table, [
      {{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}
    ])
  end

  defp schedule(name),
    do: Process.send_after(self(), :run, Instance.fetch!(name).config.fcrdns.interval)
end
