defmodule Limen.IPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.IP

  doctest Limen.IP

  describe "prefix/3" do
    test "aggregates IPv6 to the configured length" do
      ip = {0x2001, 0xDB8, 0xAAAA, 0xBBBB, 1, 2, 3, 4}
      assert IP.prefix_to_string(IP.prefix(ip, 32, 64)) == "2001:db8:aaaa:bbbb::/64"
      assert IP.prefix_to_string(IP.prefix(ip, 32, 56)) == "2001:db8:aaaa:bb00::/56"
      assert IP.prefix_to_string(IP.prefix(ip, 32, 48)) == "2001:db8:aaaa::/48"
    end

    test "treats IPv4-mapped IPv6 addresses as IPv4" do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}
      assert IP.prefix(mapped, 32, 64) == IP.prefix({192, 0, 2, 1}, 32, 64)
    end

    property "every address in a prefix aggregates to the same key" do
      check all(
              a <- integer(0..255),
              b <- integer(0..255),
              c <- integer(0..255),
              d1 <- integer(0..255),
              d2 <- integer(0..255)
            ) do
        assert IP.prefix({a, b, c, d1}, 24, 64) == IP.prefix({a, b, c, d2}, 24, 64)
      end
    end

    property "IPv6 addresses sharing the first 64 bits share a /64" do
      check all(
              head <- list_of(integer(0..0xFFFF), length: 4),
              tail1 <- list_of(integer(0..0xFFFF), length: 4),
              tail2 <- list_of(integer(0..0xFFFF), length: 4)
            ) do
        ip1 = List.to_tuple(head ++ tail1)
        ip2 = List.to_tuple(head ++ tail2)
        assert IP.prefix(ip1, 32, 64) == IP.prefix(ip2, 32, 64)
      end
    end

    property "integer conversion round-trips" do
      check all(parts <- list_of(integer(0..0xFFFF), length: 8), parts != [0, 0, 0, 0, 0, 0xFFFF]) do
        ip = List.to_tuple(parts)

        case IP.to_integer(ip) do
          {6, _} = n -> assert IP.from_integer(n) == ip
          {4, _} -> assert match?([0, 0, 0, 0, 0, 0xFFFF | _], parts)
        end
      end
    end
  end

  describe "cidr_set/1" do
    test "matches addresses inside any range" do
      set = IP.cidr_set(["10.0.0.0/8", "192.0.2.0/24", "2001:db8::/32", "198.51.100.7"])

      assert IP.member?(set, {10, 1, 2, 3})
      assert IP.member?(set, {192, 0, 2, 200})
      assert IP.member?(set, {198, 51, 100, 7})
      assert IP.member?(set, {0x2001, 0xDB8, 5, 0, 0, 0, 0, 1})
      refute IP.member?(set, {198, 51, 100, 8})
      refute IP.member?(set, {11, 0, 0, 1})
      refute IP.member?(set, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
      refute IP.member?(set, nil)
    end

    test "rejects invalid ranges" do
      assert_raise ArgumentError, fn -> IP.cidr_set(["10.0.0.0/40"]) end
      assert_raise ArgumentError, fn -> IP.cidr_set(["nope"]) end
    end

    property "an address is a member of its own prefix" do
      check all(parts <- list_of(integer(0..255), length: 4), length <- integer(8..32)) do
        ip = List.to_tuple(parts)
        set = IP.cidr_set([IP.prefix(ip, length, 64)])
        assert IP.member?(set, ip)
      end
    end
  end
end
