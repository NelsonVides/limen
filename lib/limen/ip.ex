defmodule Limen.IP do
  @moduledoc """
  IP address helpers: parsing, prefix aggregation and CIDR matching.

  A *prefix* is the unit Limen keys state on. IPv4 addresses are aggregated to
  `/32` by default and IPv6 addresses to `/64`, since a single IPv6 subscriber
  usually controls at least a `/64`. IPv4-mapped IPv6 addresses
  (`::ffff:a.b.c.d`) are treated as IPv4.

  Prefixes are represented as `{version, masked_integer, length}` tuples, which
  are cheap to hash, compare and use as ETS keys.
  """

  use Boundary, type: :strict, deps: []

  import Bitwise

  @type version :: 4 | 6
  @type prefix :: {version(), non_neg_integer(), 0..128}
  @type cidr_set :: %{
          lengths: %{optional(version()) => [0..128]},
          members: %{optional({version(), 0..128}) => %{optional(non_neg_integer()) => true}}
        }

  @doc """
  Parses a textual IP address.

      iex> Limen.IP.parse("192.0.2.1")
      {:ok, {192, 0, 2, 1}}

      iex> Limen.IP.parse("not an ip")
      :error
  """
  @spec parse(String.t()) :: {:ok, :inet.ip_address()} | :error
  def parse(string) when is_binary(string) do
    with :error <- parse_ipv4(string),
         {:error, _reason} <- :inet.parse_strict_address(String.to_charlist(String.trim(string))) do
      :error
    end
  end

  # Canonical dotted quads, the common case, parsed without a charlist.
  # Anything else, leading zeros and surrounding space included, takes the
  # general path, so the accepted forms are those of `:inet`.
  defp parse_ipv4(string) do
    with {a, "." <> rest} <- octet(string),
         {b, "." <> rest} <- octet(rest),
         {c, "." <> rest} <- octet(rest),
         {d, ""} <- octet(rest) do
      {:ok, {a, b, c, d}}
    else
      _other -> :error
    end
  end

  defp octet(<<?0, rest::binary>>), do: {0, rest}

  defp octet(<<a, b, c, rest::binary>>) when a in ?1..?9 and b in ?0..?9 and c in ?0..?9 do
    case (a - ?0) * 100 + (b - ?0) * 10 + c - ?0 do
      n when n <= 255 -> {n, rest}
      _n -> :error
    end
  end

  defp octet(<<a, b, rest::binary>>) when a in ?1..?9 and b in ?0..?9,
    do: {(a - ?0) * 10 + b - ?0, rest}

  defp octet(<<a, rest::binary>>) when a in ?1..?9, do: {a - ?0, rest}
  defp octet(_other), do: :error

  @doc """
  Converts an address tuple to `{version, integer}`.

  IPv4-mapped IPv6 addresses are converted to their IPv4 form.
  """
  @spec to_integer(:inet.ip_address()) :: {version(), non_neg_integer()}
  def to_integer({a, b, c, d}), do: {4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  def to_integer({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {4, hi <<< 16 ||| lo}

  def to_integer({a, b, c, d, e, f, g, h}) do
    {6,
     a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 ||| g <<< 16 |||
       h}
  end

  @doc """
  Converts `{version, integer}` back to an address tuple.
  """
  @spec from_integer({version(), non_neg_integer()}) :: :inet.ip_address()
  def from_integer({4, n}),
    do: {n >>> 24 &&& 0xFF, n >>> 16 &&& 0xFF, n >>> 8 &&& 0xFF, n &&& 0xFF}

  def from_integer({6, n}) do
    List.to_tuple(for shift <- 112..0//-16, do: n >>> shift &&& 0xFFFF)
  end

  @doc """
  Aggregates an address into its prefix.

      iex> Limen.IP.prefix({192, 0, 2, 77}, 24, 64)
      {4, 3221225984, 24}

      iex> Limen.IP.prefix({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}, 32, 48)
      {6, 42540766411283801782723599580828532736, 48}
  """
  @spec prefix(:inet.ip_address(), 0..32, 0..128) :: prefix()
  def prefix(ip, v4_length, v6_length) do
    case to_integer(ip) do
      {4, n} -> {4, mask(n, 32, v4_length), v4_length}
      {6, n} -> {6, mask(n, 128, v6_length), v6_length}
    end
  end

  @doc """
  Renders a prefix in CIDR notation.

      iex> Limen.IP.prefix_to_string({4, 3221225984, 24})
      "192.0.2.0/24"
  """
  @spec prefix_to_string(prefix()) :: String.t()
  def prefix_to_string({version, n, length}) do
    "#{:inet.ntoa(from_integer({version, n}))}/#{length}"
  end

  @doc """
  A compact binary encoding of a prefix, used when binding tokens to a client.
  """
  @spec prefix_to_binary(prefix() | nil) :: binary()
  def prefix_to_binary({version, n, length}), do: <<version, length, n::128>>
  def prefix_to_binary(nil), do: <<0>>

  @doc """
  Parses CIDR notation. A bare address is a host prefix.

      iex> Limen.IP.parse_cidr("10.0.0.0/8")
      {:ok, {4, 167772160, 8}}

      iex> Limen.IP.parse_cidr("10.0.0.0/33")
      :error
  """
  @spec parse_cidr(String.t()) :: {:ok, prefix()} | :error
  def parse_cidr(string) when is_binary(string) do
    with [address | rest] <- String.split(String.trim(string), "/", parts: 2),
         {:ok, ip} <- parse(address),
         {version, n} = to_integer(ip),
         bits = if(version == 4, do: 32, else: 128),
         {:ok, length} <- parse_length(rest, bits) do
      {:ok, {version, mask(n, bits, length), length}}
    else
      _invalid -> :error
    end
  end

  defp parse_length([], bits), do: {:ok, bits}

  defp parse_length([string], bits) do
    case Integer.parse(string) do
      {length, ""} when length >= 0 and length <= bits -> {:ok, length}
      _invalid -> :error
    end
  end

  @doc """
  Builds a set of CIDR ranges for fast membership checks.

  Lookups cost one map probe per distinct prefix length in the set, so they
  stay cheap for the handful of lengths real allow- and deny-lists contain.
  Raises `ArgumentError` on an invalid range.
  """
  @spec cidr_set([String.t() | prefix()]) :: cidr_set()
  def cidr_set(ranges) do
    Enum.reduce(ranges, %{lengths: %{}, members: %{}}, fn range, acc ->
      {version, n, length} = to_prefix!(range)

      acc
      |> update_in([:lengths], fn lengths ->
        Map.update(lengths, version, [length], &Enum.sort(Enum.uniq([length | &1]), :desc))
      end)
      |> update_in([:members], fn members ->
        Map.update(members, {version, length}, %{n => true}, &Map.put(&1, n, true))
      end)
    end)
  end

  defp to_prefix!({version, n, length} = prefix)
       when version in [4, 6] and is_integer(n) and is_integer(length),
       do: prefix

  defp to_prefix!(string) when is_binary(string) do
    case parse_cidr(string) do
      {:ok, prefix} -> prefix
      :error -> raise ArgumentError, "invalid CIDR range: #{inspect(string)}"
    end
  end

  @doc """
  Returns whether `ip` falls within any range of a `cidr_set/1`.
  """
  @spec member?(cidr_set(), :inet.ip_address() | nil) :: boolean()
  def member?(_set, nil), do: false

  def member?(%{lengths: lengths, members: members}, ip) do
    {version, n} = to_integer(ip)
    bits = if version == 4, do: 32, else: 128

    lengths
    |> Map.get(version, [])
    |> Enum.any?(fn length ->
      Map.has_key?(Map.fetch!(members, {version, length}), mask(n, bits, length))
    end)
  end

  @doc """
  Whether a value looks like an address tuple.
  """
  defguard is_ip(ip) when is_tuple(ip) and (tuple_size(ip) == 4 or tuple_size(ip) == 8)

  defp mask(n, bits, length) do
    shift = bits - length
    (n >>> shift) <<< shift
  end
end
