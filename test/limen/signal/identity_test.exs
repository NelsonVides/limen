defmodule Limen.Signal.IdentityTest do
  use Limen.Case, async: true
  use ExUnitProperties

  alias Limen.{Context, Signal}
  alias Limen.Signal.{ClientIP, JA4}

  doctest Limen.Signal.JA4
  doctest Limen.Signal.UserAgent

  @proxy {10, 0, 0, 2}

  defp config(overrides) do
    Limen.Config.build([trusted_proxies: ["10.0.0.0/8"]] ++ overrides)
  end

  defp resolve(headers, overrides \\ [client_ip_header: "x-forwarded-for"], peer \\ @proxy) do
    ClientIP.resolve(
      %Context{peer_ip: peer, client_ip: peer, headers: headers},
      config(overrides)
    )
  end

  defp ipv4 do
    gen all parts <- list_of(integer(0..255), length: 4), hd(parts) != 10 do
      to_string(:inet.ntoa(List.to_tuple(parts)))
    end
  end

  property "addresses a client prepends to X-Forwarded-For are ignored" do
    check all spoofed <- list_of(ipv4(), max_length: 5), client <- ipv4() do
      chain = Enum.join(spoofed ++ [client, "10.0.0.7"], ", ")
      ctx = resolve([{"x-forwarded-for", chain}])
      assert ctx.client_ip == elem(Limen.IP.parse(client), 1)
    end
  end

  test "untrusted peers are the client whatever they claim" do
    ctx =
      resolve(
        [{"x-forwarded-for", "192.0.2.1"}],
        [client_ip_header: "x-forwarded-for"],
        {192, 0, 2, 9}
      )

    assert ctx.client_ip == {192, 0, 2, 9}
    refute ctx.via_proxy
    assert ctx.evidence.client_ip == :peer
  end

  test "falls back to the peer on a malformed chain" do
    ctx = resolve([{"x-forwarded-for", "192.0.2.1, unknown"}])
    assert ctx.client_ip == @proxy
    assert ctx.evidence.client_ip == {:invalid, "x-forwarded-for"}
  end

  test "a chain of trusted proxies resolves to the leftmost one" do
    assert resolve([{"x-forwarded-for", "10.1.1.1, 10.2.2.2"}]).client_ip == {10, 1, 1, 1}
  end

  test "reads X-Real-IP" do
    ctx = resolve([{"x-real-ip", "2001:db8::1"}], client_ip_header: "x-real-ip")
    assert ctx.client_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    assert ctx.prefix == {6, 0x20010DB8000000000000000000000000, 64}

    assert resolve([{"x-real-ip", "junk"}], client_ip_header: "x-real-ip").evidence.client_ip ==
             {:invalid, "x-real-ip"}
  end

  test "reads RFC 7239 Forwarded elements" do
    ctx =
      resolve([{"forwarded", ~s(for=192.0.2.60;proto=http;by=203.0.113.43)}],
        client_ip_header: "forwarded"
      )

    assert ctx.client_ip == {192, 0, 2, 60}

    ctx = resolve([{"forwarded", ~s(for="_hidden", for=10.0.0.3)}], client_ip_header: "forwarded")
    assert ctx.evidence.client_ip == {:invalid, "forwarded"}
  end

  test "JA4 is only read from trusted proxies" do
    ja4 = "t13d1516h2_8daaf6152771_02713d6af862"
    trusted = %Context{via_proxy: true, headers: [{"x-ja4", ja4}]}
    untrusted = %Context{via_proxy: false, headers: [{"x-ja4", ja4}]}

    assert JA4.resolve(trusted, config([])).ja4 == ja4
    assert JA4.resolve(untrusted, config([])).ja4 == nil
    assert JA4.resolve(%Context{via_proxy: true, headers: []}, config([])).evidence == %{}

    assert JA4.resolve(
             %Context{via_proxy: true, headers: [{"x-tls-fp", ja4}]},
             config(ja4_header: "X-TLS-FP")
           ).ja4 == ja4
  end

  property "identify reads each header as resolving it on its own would" do
    ja4 = "t13d1516h2_8daaf6152771_02713d6af862"

    header =
      one_of([
        tuple(
          {member_of(~w(x-forwarded-for forwarded x-real-ip)),
           member_of(["192.0.2.1", "10.1.1.1, 192.0.2.2", "for=192.0.2.3", "junk"])}
        ),
        tuple({constant("x-ja4"), member_of([ja4, "junk"])}),
        tuple(
          {member_of(~w(user-agent sec-fetch-dest cookie x-other)),
           string(:alphanumeric, max_length: 4)}
        )
      ])

    check all headers <- list_of(header, max_length: 8),
              client_ip_header <- member_of([nil, "x-forwarded-for", "forwarded", "x-real-ip"]),
              peer <- member_of([@proxy, {192, 0, 2, 9}]) do
      config = config(client_ip_header: client_ip_header)
      ctx = %Context{peer_ip: peer, client_ip: peer, headers: headers}

      expected =
        ctx
        |> ClientIP.resolve(config)
        |> JA4.resolve(config)
        |> Map.merge(%{
          user_agent: Context.header(ctx, "user-agent"),
          fetch_dest: Context.header(ctx, "sec-fetch-dest"),
          cookie_headers: for({"cookie", value} <- headers, do: value)
        })

      assert Signal.identify(ctx, config) == expected
    end
  end
end
