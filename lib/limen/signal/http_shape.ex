defmodule Limen.Signal.HttpShape do
  @moduledoc """
  Checks whether a request looks like what its user agent claims to be.

  Browsers send a predictable set of headers. Automation that borrows a
  browser's user agent string rarely reproduces all of them, and never
  reproduces them consistently. This signal classifies the user agent (see
  `Limen.Signal.UserAgent`) and reports inconsistencies as flags:

  | Flag | Meaning |
  |---|---|
  | `:no_user_agent` | no `user-agent` header |
  | `:no_accept` | no `accept` header |
  | `:no_accept_language` | no `accept-language` header |
  | `:no_accept_encoding` | no `accept-encoding` header |
  | `:generic_accept` | a browser navigation with `accept: */*` |
  | `:no_sec_fetch` | a browser recent enough to send `sec-fetch-*` headers did not |
  | `:no_client_hints` | a Chromium browser recent enough to send `sec-ch-ua` did not |
  | `:unexpected_client_hints` | a non-Chromium browser sent `sec-ch-ua` |
  | `:client_hint_brand_mismatch` | `sec-ch-ua` does not name the claimed browser |
  | `:client_hint_platform_mismatch` | `sec-ch-ua-platform` disagrees with the user agent |
  | `:client_hint_mobile_mismatch` | `sec-ch-ua-mobile` disagrees with the user agent |
  | `:headless` | the user agent or client hints name a headless browser |

  Browsers only send `sec-fetch-*` and client hints to secure origins, so
  those checks only apply to HTTPS requests. Behind a TLS terminator, make
  sure `conn.scheme` reflects the original scheme (for example with
  `Plug.RewriteOn`) before `Limen.Plug` runs.

  This is an independent design, not JA4H.

  ## Shape

  `:shape` is a stable hash of the request's header *names* in the order
  they were received, leaving out headers added by proxies. Clients built on
  the same HTTP stack share a shape, so it works well in lists and rate keys.
  Header order is only meaningful when the web server preserves it: Bandit
  does, Cowboy does not.

  Provides `:ua_family`, `:ua_version`, `:shape` and `:shape_flags`, with the
  parsed user agent as evidence for `:ua_family`.
  """

  @behaviour Limen.Signal

  import Bitwise

  alias Limen.Context
  alias Limen.Signal.UserAgent

  @proxy_headers Map.new(
                   ~w(x-forwarded-for x-forwarded-proto x-forwarded-host x-forwarded-port
                      x-real-ip forwarded via x-request-id cdn-loop),
                   &{&1, true}
                 )

  # First versions sending sec-fetch-* to secure origins by default. Safari
  # started with 16.4; only major versions are parsed, so 17 avoids flagging
  # 16.0 to 16.3.
  @sec_fetch_since %{chromium: 76, gecko: 90, webkit: 17}
  # First Chromium version sending sec-ch-ua by default.
  @client_hints_since 89

  @client_hint_platforms %{
    "\"Windows\"" => :windows,
    "\"macOS\"" => :macos,
    "\"Linux\"" => :linux,
    "\"Android\"" => :android,
    "\"Chrome OS\"" => :chromeos,
    "\"iOS\"" => :ios
  }

  @brands %{
    chrome: ["Google Chrome", "Chromium"],
    edge: ["Microsoft Edge"],
    opera: ["Opera"],
    samsung: ["Samsung Internet"]
  }

  @impl true
  def provides, do: [:ua_family, :ua_version, :shape, :shape_flags]

  @impl true
  def collect(%Context{} = ctx) do
    ua = UserAgent.parse(ctx.user_agent)

    ctx
    |> Context.put_signal(:ua_family, ua.family, Map.delete(ua, :family))
    |> Context.put_signal(:ua_version, ua.version)
    |> Context.put_signal(:shape, shape(ctx))
    |> Context.put_signal(:shape_flags, flags(ctx, ua))
  end

  @doc """
  The header-order shape of a request.
  """
  @spec shape(Context.t()) :: String.t()
  def shape(%Context{headers: headers, instance: %{config: config}}) do
    ignored = Map.put(config.shape.ignore_headers, config.ja4_header, true)

    names =
      for {name, _value} <- headers,
          not is_map_key(@proxy_headers, name) and not is_map_key(ignored, name),
          do: name

    Base.encode16(<<:erlang.phash2(names, 1 <<< 32)::32>>, case: :lower)
  end

  @doc """
  The inconsistencies between a request's headers and its user agent.
  """
  @spec flags(Context.t(), UserAgent.t()) :: [atom()]
  def flags(%Context{} = ctx, ua) do
    headers = Map.new(ctx.headers)

    (missing_headers(ua, headers) ++ browser_flags(ua, headers, ctx.scheme == :https))
    |> Enum.filter(fn {_flag, set?} -> set? end)
    |> Enum.map(fn {flag, _set?} -> flag end)
  end

  defp missing_headers(ua, headers) do
    [
      {:no_user_agent, ua.family == :none},
      {:no_accept, not Map.has_key?(headers, "accept")},
      {:no_accept_language, not Map.has_key?(headers, "accept-language")},
      {:no_accept_encoding, not Map.has_key?(headers, "accept-encoding")}
    ]
  end

  defp browser_flags(%{engine: nil} = ua, headers, _secure?) do
    [{:headless, ua.family == :headless or headless_hints?(headers)}]
  end

  defp browser_flags(ua, headers, secure?) do
    hints? = Map.has_key?(headers, "sec-ch-ua")

    [
      {:generic_accept, generic_navigation?(headers)},
      {:no_sec_fetch, secure? and sends_sec_fetch?(ua) and not sec_fetch?(headers)},
      {:no_client_hints, secure? and sends_client_hints?(ua) and not hints?},
      {:unexpected_client_hints, ua.engine != :chromium and hints?},
      {:client_hint_brand_mismatch, brand_mismatch?(ua, headers)},
      {:client_hint_platform_mismatch, platform_mismatch?(ua, headers)},
      {:client_hint_mobile_mismatch, mobile_mismatch?(ua, headers)},
      {:headless, headless_hints?(headers)}
    ]
  end

  defp generic_navigation?(headers) do
    headers["accept"] == "*/*" and headers["sec-fetch-dest"] in [nil, "document"]
  end

  defp sec_fetch?(headers) do
    Map.has_key?(headers, "sec-fetch-mode") or Map.has_key?(headers, "sec-fetch-site")
  end

  defp sends_sec_fetch?(%{engine: engine, version: version}) when is_integer(version),
    do: version >= Map.fetch!(@sec_fetch_since, engine)

  defp sends_sec_fetch?(_ua), do: false

  defp sends_client_hints?(%{engine: :chromium, version: version}) when is_integer(version),
    do: version >= @client_hints_since

  defp sends_client_hints?(_ua), do: false

  defp brand_mismatch?(%{engine: :chromium, family: family}, %{"sec-ch-ua" => brands}) do
    not Enum.any?(Map.get(@brands, family, []), &String.contains?(brands, &1))
  end

  defp brand_mismatch?(_ua, _headers), do: false

  defp platform_mismatch?(%{platform: platform}, %{"sec-ch-ua-platform" => claimed})
       when platform != nil do
    case Map.fetch(@client_hint_platforms, claimed) do
      {:ok, hinted} -> hinted != platform and not (hinted == :android and platform == :linux)
      :error -> false
    end
  end

  defp platform_mismatch?(_ua, _headers), do: false

  defp mobile_mismatch?(%{mobile: mobile}, %{"sec-ch-ua-mobile" => "?1"}), do: not mobile
  defp mobile_mismatch?(%{mobile: mobile}, %{"sec-ch-ua-mobile" => "?0"}), do: mobile
  defp mobile_mismatch?(_ua, _headers), do: false

  defp headless_hints?(%{"sec-ch-ua" => brands}), do: String.contains?(brands, "HeadlessChrome")
  defp headless_hints?(_headers), do: false
end
