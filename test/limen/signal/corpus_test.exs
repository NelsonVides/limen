defmodule Limen.Signal.CorpusTest do
  use Limen.Case, async: true

  alias Limen.{Corpus, IP}

  @moduletag config: [trusted_proxies: ["10.0.0.0/8"], client_ip_header: "x-forwarded-for"]

  @chrome_ja4 "t13d1516h2_8daaf6152771_02713d6af862"

  # Expected identity and signals per recorded request. Only the listed keys
  # are compared.
  @expected %{
    "chrome_windows_navigation" => %{
      client_ip: "203.0.113.7",
      prefix: "203.0.113.7/32",
      ja4: @chrome_ja4,
      ua_family: :chrome,
      ua_version: 128,
      shape_flags: [],
      pages_per_minute: 1
    },
    "chrome_stylesheet" => %{
      client_ip: "203.0.113.7",
      ua_family: :chrome,
      shape_flags: [],
      assets_per_minute: 1,
      pages_per_minute: 0,
      asset_ratio: nil
    },
    "firefox_macos_navigation" => %{
      client_ip: "198.51.100.23",
      ja4: "t13d1715h2_5b57614c22b0_3d5424432f57",
      ua_family: :firefox,
      ua_version: 130,
      shape_flags: []
    },
    "safari_iphone_navigation" => %{
      client_ip: "2001:db8:1234:5678:abcd::1",
      prefix: "2001:db8:1234:5678::/64",
      ua_family: :safari,
      ua_version: 17,
      shape_flags: []
    },
    "curl" => %{
      client_ip: "192.0.2.99",
      ua_family: :tool,
      shape_flags: [:no_accept_language, :no_accept_encoding]
    },
    "curl_direct_spoofing" => %{
      client_ip: "198.51.100.200",
      via_proxy: false,
      ja4: nil,
      ua_family: :tool,
      evidence: %{client_ip: :peer, ja4: :untrusted_peer}
    },
    "python_requests" => %{
      client_ip: "192.0.2.100",
      ua_family: :tool,
      shape_flags: [:no_accept_language]
    },
    "scraper_chrome_user_agent" => %{
      ua_family: :chrome,
      ua_version: 127,
      shape_flags: [:no_accept_language, :generic_accept, :no_sec_fetch, :no_client_hints]
    },
    "headless_chrome" => %{ua_family: :headless, shape_flags: [:headless]},
    "firefox_with_client_hints" => %{
      ua_family: :firefox,
      shape_flags: [:unexpected_client_hints]
    },
    "chrome_platform_mismatch" => %{
      ua_family: :chrome,
      shape_flags: [:client_hint_platform_mismatch, :client_hint_mobile_mismatch]
    },
    "googlebot" => %{
      client_ip: "66.249.66.1",
      ua_family: :crawler,
      shape_flags: [:no_accept_language]
    },
    "forwarded_chain" => %{
      client_ip: "203.0.113.60",
      ja4: nil,
      evidence: %{client_ip: {:header, "x-forwarded-for"}, ja4: :malformed}
    },
    "rfc7239_forwarded" => %{
      client_ip: "2001:db8:cafe::17",
      prefix: "2001:db8:cafe::/64",
      evidence: %{client_ip: {:header, "forwarded"}}
    },
    "no_headers" => %{
      ua_family: :none,
      shape_flags: [:no_user_agent, :no_accept, :no_accept_language, :no_accept_encoding]
    }
  }

  test "every fixture has expectations and every expectation a fixture" do
    assert Enum.sort(Map.keys(@expected)) == Corpus.names()
  end

  for name <- Corpus.names() do
    test "populates the context for #{name}", %{limen: limen} do
      decision = evaluate(limen, unquote(name))
      expected = Map.fetch!(@expected, unquote(name))

      for {key, value} <- expected do
        assert {key, observed(decision, key)} == {key, value}
      end
    end
  end

  test "clients on the same HTTP stack share a shape", %{limen: limen} do
    assert shape(limen, "curl") == shape(limen, "curl_direct_spoofing")
    refute shape(limen, "curl") == shape(limen, "python_requests")
  end

  test "names the crawler for DNS verification", %{limen: limen} do
    decision = evaluate(limen, "googlebot")
    assert %{ua_family: :crawler, ua_name: "googlebot"} = decision.signals
    assert %{crawler: "googlebot"} = decision.evidence.fcrdns
  end

  defp evaluate(limen, name) do
    %{conn: conn, meta: meta} = Corpus.load(name)

    Limen.update_config(
      limen,
      :client_ip_header,
      meta["client_ip_header"] || "x-forwarded-for"
    )

    Limen.decision(Limen.Plug.call(conn, Limen.Plug.init(instance: limen)))
  end

  defp shape(limen, name), do: evaluate(limen, name).signals.shape

  defp observed(decision, :client_ip), do: to_string(:inet.ntoa(decision.identity.client_ip))

  defp observed(decision, :prefix), do: IP.prefix_to_string(decision.identity.prefix)
  defp observed(decision, :ja4), do: decision.identity.ja4
  defp observed(decision, :via_proxy), do: decision.identity.via_proxy

  defp observed(decision, :evidence) do
    Map.take(decision.evidence, [:client_ip, :ja4])
  end

  defp observed(decision, key), do: Map.fetch!(decision.signals, key)
end
