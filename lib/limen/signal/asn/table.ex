defmodule Limen.Signal.Asn.Table do
  @moduledoc """
  IP-to-ASN data packed into a handful of binaries, for one
  `:persistent_term` entry.

  The ranges of each IP version are stored as a step function: every range
  start maps to the value of the range, a gap after a range maps to a miss,
  and consecutive starts with the same value are merged, so no range ends
  are stored. Looking an address up finds the greatest start at or below it:

    * `index` - 65,537 big-endian `u32`, the position of the greatest start
      at or below each value of the address's top 16 bits, narrowing the
      search to a slice;
    * `starts` - the sorted starts, `u32` for IPv4 and `u128` for IPv6;
    * `values` - a `u32` per start: `0` for a miss, otherwise a 1-based
      index into the records.

  Each distinct `{asn, country}` has a 10-byte record (`asn::32`,
  `country::16`, name offset `::32`); names and countries live in two blobs,
  and a lookup copies them out. Everything is a binary larger than 64 bytes,
  so reading the table copies nothing, results never point into it, and
  replacing it only leaves a few words behind in the literal area.

  The full iptoasn.com dataset (about 580,000 routed ranges) takes about
  10 MB. A lookup is a `:persistent_term` read and about ten binary matches.
  """

  import Bitwise

  alias Limen.IP

  @enforce_keys [:v4, :v6, :records, :country_offsets, :countries, :names, :ranges, :bytes]
  defstruct @enforce_keys ++ [loaded_at: nil, source: nil]

  @type version :: {index :: binary(), starts :: binary(), values :: binary()}
  @type t :: %__MODULE__{
          v4: version(),
          v6: version(),
          records: binary(),
          country_offsets: binary(),
          countries: binary(),
          names: binary(),
          ranges: non_neg_integer(),
          bytes: non_neg_integer(),
          loaded_at: integer() | nil,
          source: term()
        }

  @type entry :: %{asn: pos_integer(), country: String.t(), name: String.t()}

  @typedoc """
  A range as found in the iptoasn.com data: first and last address, ASN,
  country and name. ASN `0` marks unrouted space and is skipped.
  """
  @type row ::
          {first :: String.t(), last :: String.t(), asn :: non_neg_integer(),
           country :: String.t(), name :: String.t()}

  @record 10

  ## Lookup

  @doc """
  Returns the entry covering `ip`, or `nil`.
  """
  @spec lookup(t(), :inet.ip_address()) :: entry() | nil
  def lookup(%__MODULE__{v4: v4} = table, {a, b, c, d}),
    do: lookup4(table, v4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d)

  def lookup(%__MODULE__{v4: v4} = table, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: lookup4(table, v4, hi <<< 16 ||| lo)

  # The 128-bit address is compared as 48, 48 and 32-bit words, all small
  # integers, so a lookup creates no bignums.
  def lookup(%__MODULE__{v6: {index, starts, values}} = table, {a, b, c, d, e, f, g, h}) do
    {lo, hi} = slice(index, a)

    position =
      search6(
        starts,
        a <<< 32 ||| b <<< 16 ||| c,
        d <<< 32 ||| e <<< 16 ||| f,
        g <<< 16 ||| h,
        lo,
        hi + 1
      )

    entry(table, values, position)
  end

  defp lookup4(table, {index, starts, values}, n) do
    {lo, hi} = slice(index, n >>> 16)
    entry(table, values, search4(starts, n, lo, hi + 1))
  end

  defp slice(index, prefix) do
    offset = prefix * 4
    <<_skip::binary-size(^offset), lo::32, hi::32, _rest::binary>> = index
    {lo, hi}
  end

  # The start at `lo` is at or below the key; the answer is in `lo..hi - 1`.
  defp search4(starts, key, lo, hi) when hi - lo > 1 do
    mid = (lo + hi) >>> 1
    offset = mid * 4
    <<_skip::binary-size(^offset), start::32, _rest::binary>> = starts
    if start <= key, do: search4(starts, key, mid, hi), else: search4(starts, key, lo, mid)
  end

  defp search4(_starts, _key, lo, _hi), do: lo

  defp search6(starts, k1, k2, k3, lo, hi) when hi - lo > 1 do
    mid = (lo + hi) >>> 1
    offset = mid * 16
    <<_skip::binary-size(^offset), s1::48, s2::48, s3::32, _rest::binary>> = starts

    if s1 < k1 or (s1 == k1 and (s2 < k2 or (s2 == k2 and s3 <= k3))),
      do: search6(starts, k1, k2, k3, mid, hi),
      else: search6(starts, k1, k2, k3, lo, mid)
  end

  defp search6(_starts, _k1, _k2, _k3, lo, _hi), do: lo

  defp entry(table, values, position) do
    offset = position * 4

    case values do
      <<_skip::binary-size(^offset), 0::32, _rest::binary>> -> nil
      <<_skip::binary-size(^offset), id::32, _rest::binary>> -> record(table, id)
    end
  end

  defp record(%__MODULE__{} = table, id) do
    offset = (id - 1) * @record

    <<_skip::binary-size(^offset), asn::32, country::16, from::32, _next::48, to::32,
      _rest::binary>> = table.records

    %{asn: asn, country: country(table, country), name: copy(table.names, from, to - from)}
  end

  defp country(%__MODULE__{country_offsets: offsets, countries: countries}, id) do
    offset = id * 4
    <<_skip::binary-size(^offset), from::32, to::32, _rest::binary>> = offsets
    copy(countries, from, to - from)
  end

  # Copied, so results never point into the table and never keep it alive.
  defp copy(blob, from, length) do
    <<_skip::binary-size(^from), part::binary-size(^length), _rest::binary>> = blob
    :binary.copy(part)
  end

  ## Build

  @doc """
  Builds a table from rows (see `t:row/0`).

  Rows are streamed once when each IP version's ranges come sorted by their
  first address, as in the iptoasn.com data; otherwise they are sorted
  first. Where ranges overlap, the later start wins from there on, and of
  two ranges with the same start, the later row wins. An ASN takes the name
  of its first row.
  """
  @spec from_rows(Enumerable.t(row())) :: {:ok, t()} | {:error, String.t()}
  def from_rows(rows) do
    ranges = Stream.flat_map(rows, &parse_row/1)

    table =
      try do
        pack(ranges, %{})
      catch
        :unsorted -> pack_unsorted(ranges)
      end

    {:ok, table}
  rescue
    e in [ArgumentError] -> {:error, Exception.message(e)}
  end

  # Sorted by start, but each ASN still takes the name of its first row in
  # the input's order.
  defp pack_unsorted(ranges) do
    names =
      Enum.reduce(ranges, %{}, fn {_version, _first, _last, asn, _country, name}, names ->
        Map.put_new_lazy(names, asn, fn -> :binary.copy(name) end)
      end)

    ranges
    |> Enum.with_index()
    |> Enum.sort_by(&order/1)
    |> Stream.map(&elem(&1, 0))
    |> pack(names)
  end

  defp order({{version, first, _last, _asn, _country, _name}, position}),
    do: {version, first, position}

  defp parse_row({first, last, asn, country, name})
       when is_integer(asn) and asn > 0 and is_binary(country) and is_binary(name) do
    with {:ok, first} <- IP.parse(first),
         {:ok, last} <- IP.parse(last),
         {version, first} = IP.to_integer(first),
         {^version, last} when last >= first <- IP.to_integer(last) do
      [{version, first, last, asn, :binary.copy(country), name}]
    else
      _invalid -> []
    end
  end

  defp parse_row(_unrouted_or_invalid), do: []

  defp pack(ranges, names) do
    state =
      Enum.reduce(ranges, %{new_state() | asn_names: names}, fn {version, first, last, asn,
                                                                 country, name},
                                                                state ->
        {id, state} = value_id(state, asn, country, name)
        versions = Map.update!(state.versions, version, &add_range(&1, first, last, id))
        %{state | versions: versions, ranges: state.ranges + 1}
      end)

    {offsets, countries} = pack_countries(state.countries)
    records = <<state.records::binary, 0::32, 0::16, byte_size(state.names)::32>>

    table = %__MODULE__{
      v4: finish(state.versions[4]),
      v6: finish(state.versions[6]),
      records: records,
      country_offsets: offsets,
      countries: countries,
      names: state.names,
      ranges: state.ranges,
      bytes: 0
    }

    %{table | bytes: bytes(table)}
  end

  defp new_state do
    %{
      versions: %{4 => new_version(32), 6 => new_version(128)},
      ids: %{},
      asn_names: %{},
      countries: %{},
      records: <<>>,
      names: <<>>,
      ranges: 0
    }
  end

  defp new_version(bits) do
    %{
      bits: bits,
      shift: bits - 16,
      index: <<>>,
      starts: <<>>,
      values: <<>>,
      count: 0,
      next_prefix: 0,
      pending: nil,
      last_start: -1,
      last_end: -1
    }
  end

  defp value_id(state, asn, country, name) do
    case state.ids do
      %{{^asn, ^country} => id} ->
        {id, state}

      ids ->
        id = map_size(ids) + 1
        {country_id, countries} = intern(state.countries, country)
        {name, asn_names} = first_name(state.asn_names, asn, name)
        record = <<asn::32, country_id::16, byte_size(state.names)::32>>

        {id,
         %{
           state
           | ids: Map.put(ids, {asn, country}, id),
             countries: countries,
             asn_names: asn_names,
             records: <<state.records::binary, record::binary>>,
             names: <<state.names::binary, name::binary>>
         }}
    end
  end

  defp intern(countries, country) do
    case countries do
      %{^country => id} ->
        {id, countries}

      _new when map_size(countries) < 65_536 ->
        {map_size(countries), Map.put(countries, country, map_size(countries))}

      _full ->
        raise ArgumentError, "more than 65,536 distinct countries"
    end
  end

  defp first_name(names, asn, name) do
    case names do
      %{^asn => first} ->
        {first, names}

      _new ->
        name = :binary.copy(name)
        {name, Map.put(names, asn, name)}
    end
  end

  defp pack_countries(countries) do
    sorted =
      countries
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {ends, _size} = Enum.map_reduce(sorted, 0, &{&2 + byte_size(&1), &2 + byte_size(&1)})
    offsets = for offset <- [0 | ends], into: <<>>, do: <<offset::32>>
    {offsets, IO.iodata_to_binary(sorted)}
  end

  # A range adds a miss for the gap before it, if any, then its own step.
  defp add_range(%{last_start: last_start}, first, _last, _id) when first < last_start,
    do: throw(:unsorted)

  defp add_range(version, first, last, id) do
    version =
      cond do
        version.last_end < 0 and first > 0 ->
          step(version, 0, 0)

        version.last_end >= 0 and first > version.last_end + 1 ->
          step(version, version.last_end + 1, 0)

        true ->
          version
      end

    %{step(version, first, id) | last_start: first, last_end: last}
  end

  # The newest step waits in `pending`: a later step with the same start
  # replaces it, and one with the same value merges into it.
  defp step(%{pending: {start, _value}} = version, start, value),
    do: %{version | pending: {start, value}}

  defp step(%{pending: {_start, value}} = version, _new_start, value), do: version
  defp step(%{pending: nil} = version, start, value), do: %{version | pending: {start, value}}

  defp step(%{pending: {pending_start, pending_value}} = version, start, value),
    do: %{emit(version, pending_start, pending_value) | pending: {start, value}}

  defp emit(version, start, value) do
    bits = version.bits
    version = fill_index(version, start)

    %{
      version
      | starts: <<version.starts::binary, start::size(bits)>>,
        values: <<version.values::binary, value::32>>,
        count: version.count + 1
    }
  end

  # Prefixes wholly below `start` point at the last step emitted before it.
  defp fill_index(%{next_prefix: prefix, shift: shift} = version, start)
       when prefix <= 65_535 and prefix <<< shift < start do
    index = <<version.index::binary, version.count - 1::32>>
    fill_index(%{version | index: index, next_prefix: prefix + 1}, start)
  end

  defp fill_index(version, _start), do: version

  defp finish(version) do
    version =
      cond do
        version.last_end < 0 -> step(version, 0, 0)
        version.last_end + 1 < 1 <<< version.bits -> step(version, version.last_end + 1, 0)
        true -> version
      end

    {start, value} = version.pending
    version = fill_index(emit(version, start, value), 1 <<< version.bits)
    {<<version.index::binary, version.count - 1::32>>, version.starts, version.values}
  end

  defp bytes(%__MODULE__{v4: {i4, s4, v4}, v6: {i6, s6, v6}} = table) do
    [i4, s4, v4, i6, s6, v6, table.records, table.country_offsets, table.countries, table.names]
    |> Enum.map(&byte_size/1)
    |> Enum.sum()
  end
end
