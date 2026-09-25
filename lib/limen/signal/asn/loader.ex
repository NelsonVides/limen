defmodule Limen.Signal.Asn.Loader do
  @moduledoc """
  Loads IP-to-ASN tables for `Limen.Signal.Asn`, off the request path.

  A new table is built completely before it is published, so lookups see
  either the old table or the new one, never a partial load. The previous
  table is deleted a few seconds later, once in-flight lookups are done.
  """

  use GenServer

  alias Limen.{Instance, IP}
  alias Limen.Signal.Asn

  require Logger

  @retire_after 5_000

  @type row ::
          {start :: String.t(), last :: String.t(), asn :: non_neg_integer(),
           country :: String.t(), name :: String.t()}

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
  Loads ranges given as `{start, last, asn, country, name}` tuples into
  `instance`. Meant for tests and small custom tables.
  """
  @spec load_rows(atom(), [row()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_rows(instance, rows), do: call(instance, {:load, {:rows, rows}})

  defp call(instance, request) do
    GenServer.call(Instance.whereis(instance, __MODULE__), request, :infinity)
  end

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)

    case Instance.fetch!(name).config.asn.file do
      nil -> {:ok, name}
      path -> {:ok, name, {:continue, {:load, path}}}
    end
  end

  @impl true
  def handle_continue({:load, path}, name) do
    case build(name, {:file, path}) do
      {:ok, count} ->
        Logger.info("Limen loaded #{count} ASN ranges from #{path}")

      {:error, reason} ->
        Logger.error("Limen could not load ASN data from #{path}: #{inspect(reason)}")
    end

    {:noreply, name}
  end

  @impl true
  def handle_call({:load, source}, _from, name), do: {:reply, build(name, source), name}

  @impl true
  def handle_info({:retire, tables}, name) do
    Enum.each(tables, &:ets.delete/1)
    {:noreply, name}
  end

  @impl true
  def terminate(_reason, name), do: Asn.unpublish(name)

  defp build(name, source) do
    ranges = :ets.new(:limen_asn_ranges, [:ordered_set, :protected, read_concurrency: true])
    names = :ets.new(:limen_asn_names, [:set, :protected, read_concurrency: true])

    try do
      count = Enum.reduce(rows(source), 0, &insert(ranges, names, &1, &2))
      previous = Asn.published(name)
      Asn.publish(name, {ranges, names})

      retire_later(previous)

      {:ok, count}
    rescue
      e in [File.Error, ArgumentError, ErlangError] ->
        :ets.delete(ranges)
        :ets.delete(names)
        {:error, Exception.message(e)}
    end
  end

  defp retire_later(nil), do: :ok

  defp retire_later(tables) do
    _timer = Process.send_after(self(), {:retire, Tuple.to_list(tables)}, @retire_after)
    :ok
  end

  defp rows({:rows, rows}), do: rows

  defp rows({:file, path}) do
    modes = if String.ends_with?(path, ".gz"), do: [:compressed], else: []

    path
    |> File.stream!(:line, modes)
    |> Stream.map(&String.split(String.trim_trailing(&1, "\n"), "\t"))
    |> Stream.flat_map(fn
      [start, last, asn, country, name] -> [{start, last, String.to_integer(asn), country, name}]
      _malformed -> []
    end)
  end

  # ASN 0 marks unrouted space in the iptoasn data.
  defp insert(_ranges, _names, {_start, _last, 0, _country, _name}, count), do: count

  defp insert(ranges, names, {start, last, asn, country, name}, count) do
    with {:ok, first} <- IP.parse(start),
         {:ok, last} <- IP.parse(last),
         {version, first} = IP.to_integer(first),
         {^version, last} <- IP.to_integer(last) do
      :ets.insert(ranges, {{version, first}, last, asn, country})
      :ets.insert_new(names, {asn, name})
      count + 1
    else
      _invalid -> count
    end
  end
end
