defmodule Limen.Signal.Asn.TableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Limen.Signal.Asn.Table

  @top4 (1 <<< 32) - 1
  @top6 (1 <<< 128) - 1

  describe "lookups" do
    property "agree with the greatest range start at or below the address" do
      check all rows <- list_of(row(), max_length: 60), max_runs: 200 do
        {:ok, table} = Table.from_rows(rows)
        reference = reference(rows)

        for ip <- probes(rows) do
          assert Table.lookup(table, ip) == lookup(reference, ip),
                 "#{inspect(ip)} in #{inspect(rows)}"
        end
      end
    end

    test "cover the whole address space, from the first address to the last" do
      {:ok, table} =
        Table.from_rows([
          {"0.0.0.0", "255.255.255.255", 1, "AA", "all of IPv4"},
          {"::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 2, "BB", "all of IPv6"}
        ])

      assert %{asn: 1} = Table.lookup(table, {0, 0, 0, 0})
      assert %{asn: 1} = Table.lookup(table, {255, 255, 255, 255})
      assert %{asn: 2} = Table.lookup(table, {0, 0, 0, 0, 0, 0, 0, 0})

      assert %{asn: 2} =
               Table.lookup(
                 table,
                 {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
               )
    end

    test "treat IPv4-mapped IPv6 addresses as IPv4" do
      {:ok, table} = Table.from_rows([{"192.0.2.0", "192.0.2.255", 64_500, "ZZ", "TEST-NET"}])
      assert %{asn: 64_500} = Table.lookup(table, {0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201})
    end

    test "find nothing in an empty table" do
      {:ok, table} = Table.from_rows([])
      assert table.ranges == 0
      assert Table.lookup(table, {1, 2, 3, 4}) == nil
      assert Table.lookup(table, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == nil
    end

    test "copy what they return out of the table" do
      {:ok, table} =
        Table.from_rows([{"8.8.8.0", "8.8.8.255", 15_169, "US", String.duplicate("G", 100)}])

      %{name: name, country: country} = Table.lookup(table, {8, 8, 8, 8})

      assert :binary.referenced_byte_size(name) == byte_size(name)
      assert :binary.referenced_byte_size(country) == byte_size(country)
    end
  end

  describe "building" do
    test "skips unrouted space and invalid rows" do
      {:ok, table} =
        Table.from_rows([
          {"1.0.0.0", "1.0.0.255", 0, "None", "Not routed"},
          {"not an address", "1.0.1.255", 13_335, "US", "CLOUDFLARENET"},
          {"1.0.2.255", "1.0.2.0", 13_335, "US", "CLOUDFLARENET"},
          {"1.0.3.0", "::1", 13_335, "US", "CLOUDFLARENET"},
          {"1.0.4.0", "1.0.4.255", 13_335, "US", "CLOUDFLARENET"}
        ])

      assert table.ranges == 1
      assert Table.lookup(table, {1, 0, 0, 1}) == nil
      assert %{asn: 13_335} = Table.lookup(table, {1, 0, 4, 1})
    end

    test "takes an ASN's name from its first row, and keeps each country" do
      {:ok, table} =
        Table.from_rows([
          {"10.0.0.0", "10.0.0.255", 64_512, "US", "FIRST"},
          {"10.0.1.0", "10.0.1.255", 64_512, "Unknown", "SECOND"}
        ])

      assert %{name: "FIRST", country: "US"} = Table.lookup(table, {10, 0, 0, 1})
      assert %{name: "FIRST", country: "Unknown"} = Table.lookup(table, {10, 0, 1, 1})
    end

    test "sizes the table by its binaries" do
      {:ok, table} = Table.from_rows([{"8.8.8.0", "8.8.8.255", 15_169, "US", "GOOGLE"}])
      # Two 65,537-entry indexes dominate a small table.
      assert table.bytes > 2 * 65_537 * 4
    end
  end

  # Rows in a small address space, so overlaps, duplicate starts, adjacent
  # ranges and unsorted input are common; plus the very top of each space.
  defp row do
    gen all version <- member_of([4, 6]),
            first <- one_of([integer(0..400), constant(top(version) - 5)]),
            length <- integer(0..60),
            asn <- integer(0..4),
            country <- member_of(["US", "DE", "Unknown"]),
            name <- member_of(["A", "B", "C"]) do
      to_row(version, first, length, asn, country, name)
    end
  end

  defp to_row(version, first, length, asn, country, name) do
    last = min(first + length, top(version))
    {format(version, first), format(version, last), asn, country, name}
  end

  defp top(4), do: @top4
  defp top(6), do: @top6

  defp format(4, n), do: to_string(:inet.ntoa(ip(4, n)))
  defp format(6, n), do: to_string(:inet.ntoa(ip(6, n)))

  defp ip(4, n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
  defp ip(6, n), do: List.to_tuple(for shift <- 112..0//-16, do: n >>> shift &&& 0xFFFF)

  # The semantics Limen had with an ETS ordered_set: later rows replace
  # earlier ones with the same start, and an ASN keeps its first name.
  defp reference(rows) do
    Enum.reduce(rows, {%{}, %{}}, fn {first, last, asn, country, name}, {ranges, names} ->
      {:ok, first} = Limen.IP.parse(first)
      {:ok, last} = Limen.IP.parse(last)
      {version, first} = Limen.IP.to_integer(first)
      {_version, last} = Limen.IP.to_integer(last)

      if asn == 0,
        do: {ranges, names},
        else:
          {Map.put(ranges, {version, first}, {last, asn, country}), Map.put_new(names, asn, name)}
    end)
  end

  defp lookup({ranges, names}, ip) do
    {version, n} = Limen.IP.to_integer(ip)

    below =
      for {{^version, first}, range} <- ranges, first <= n, do: {first, range}

    case Enum.max_by(below, &elem(&1, 0), fn -> nil end) do
      {_start, {last, asn, country}} when n <= last ->
        %{asn: asn, country: country, name: names[asn]}

      _none ->
        nil
    end
  end

  defp probes(rows) do
    edges =
      for {first, last, _asn, _country, _name} <- rows,
          address <- [first, last],
          {:ok, ip} = Limen.IP.parse(address),
          {version, n} = Limen.IP.to_integer(ip),
          probe <- [n - 1, n, n + 1],
          probe >= 0 and probe <= top(version),
          do: ip(version, probe)

    Enum.uniq(edges ++ [ip(4, 0), ip(4, @top4), ip(6, 0), ip(6, @top6), ip(4, 1000), ip(6, 1000)])
  end
end
