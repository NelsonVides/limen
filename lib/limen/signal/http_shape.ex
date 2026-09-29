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

  Browsers only send [`sec-fetch-*`][Fetch Metadata] headers (what a request
  is for, such as a page or an image) and [client hints][UA Client Hints]
  (`sec-ch-ua*`, in which Chromium browsers describe themselves) to secure
  origins, so those checks only apply to HTTPS requests. Behind a TLS
  terminator, make sure `conn.scheme` reflects the original scheme (for
  example with `Plug.RewriteOn`) before `Limen.Plug` runs.

  This is an independent design, not [JA4H] (FoxIO's HTTP fingerprint).

  ## Shape

  `:shape` is a stable hash of the request's header *names* in the order
  they were received, leaving out headers added by proxies. Clients built on
  the same HTTP stack share a shape, so it works well in lists and rate keys.
  Header order is only meaningful when the web server preserves it: Bandit
  does, Cowboy does not.

  Provides `:ua_family`, `:ua_version`, `:shape` and `:shape_flags`, with the
  parsed user agent as evidence for `:ua_family`.

  [Fetch Metadata]: https://www.w3.org/TR/fetch-metadata/
  [UA Client Hints]: https://wicg.github.io/ua-client-hints/
  [JA4H]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4H.md
  """

  @behaviour Limen.Signal

  import Bitwise

  alias Limen.Context
  alias Limen.Signal.UserAgent

  @proxy_headers ~w(x-forwarded-for x-forwarded-proto x-forwarded-host x-forwarded-port
                   x-real-ip forwarded via x-request-id cdn-loop)

  # The headers flags look at.
  @flag_headers ~w(accept accept-language accept-encoding sec-ch-ua sec-ch-ua-mobile
                   sec-ch-ua-platform sec-fetch-dest sec-fetch-mode sec-fetch-site)

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

  @pattern_key {__MODULE__, :patterns}

  @impl true
  def provides, do: [:ua_family, :ua_version, :shape, :shape_flags]

  # Shared by every instance, like the user agent patterns: searching with a
  # precompiled pattern is about ten times faster than `String.contains?/2`,
  # which compiles one per call. Only installed when missing, since replacing
  # a persistent term triggers a global GC.
  @doc false
  @spec setup() :: :ok
  def setup do
    if :persistent_term.get(@pattern_key, nil) == nil do
      :persistent_term.put(@pattern_key, compile())
    end

    :ok
  end

  @impl true
  def collect(%Context{} = ctx) do
    ua = UserAgent.parse(ctx.user_agent)

    Context.put_signals(
      ctx,
      %{
        ua_family: ua.family,
        ua_version: ua.version,
        shape: shape(ctx),
        shape_flags: flags(ctx, ua)
      },
      %{ua_family: Map.delete(ua, :family)}
    )
  end

  @doc """
  The header-order shape of a request.
  """
  @spec shape(Context.t()) :: String.t()
  def shape(%Context{headers: headers, instance: %{config: config}}) do
    %{shape: %{ignore_headers: ignored}, ja4_header: ja4_header} = config

    names =
      for {name, _value} <- headers,
          not proxy_header?(name) and name != ja4_header and not is_map_key(ignored, name),
          do: name

    Base.encode16(<<:erlang.phash2(names, 1 <<< 32)::32>>, case: :lower)
  end

  for name <- @proxy_headers, do: defp(proxy_header?(unquote(name)), do: true)
  defp proxy_header?(_name), do: false

  @doc """
  The inconsistencies between a request's headers and its user agent.
  """
  @spec flags(Context.t(), UserAgent.t()) :: [atom()]
  def flags(%Context{} = ctx, ua) do
    headers =
      :maps.from_list(for {name, _value} = header <- ctx.headers, flag_header?(name), do: header)

    flags =
      missing_headers(ua, headers) ++
        browser_flags(ua, headers, ctx.scheme == :https, patterns())

    for {flag, true} <- flags, do: flag
  end

  for name <- @flag_headers, do: defp(flag_header?(unquote(name)), do: true)
  defp flag_header?(_name), do: false

  defp missing_headers(ua, headers) do
    [
      {:no_user_agent, ua.family == :none},
      {:no_accept, not Map.has_key?(headers, "accept")},
      {:no_accept_language, not Map.has_key?(headers, "accept-language")},
      {:no_accept_encoding, not Map.has_key?(headers, "accept-encoding")}
    ]
  end

  defp browser_flags(%{engine: nil} = ua, headers, _secure?, patterns) do
    [{:headless, ua.family == :headless or headless_hints?(headers, patterns)}]
  end

  defp browser_flags(ua, headers, secure?, patterns) do
    hints? = Map.has_key?(headers, "sec-ch-ua")

    [
      {:generic_accept, generic_navigation?(headers)},
      {:no_sec_fetch, secure? and sends_sec_fetch?(ua) and not sec_fetch?(headers)},
      {:no_client_hints, secure? and sends_client_hints?(ua) and not hints?},
      {:unexpected_client_hints, ua.engine != :chromium and hints?},
      {:client_hint_brand_mismatch, brand_mismatch?(ua, headers, patterns)},
      {:client_hint_platform_mismatch, platform_mismatch?(ua, headers)},
      {:client_hint_mobile_mismatch, mobile_mismatch?(ua, headers)},
      {:headless, headless_hints?(headers, patterns)}
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

  defp brand_mismatch?(%{engine: :chromium, family: family}, %{"sec-ch-ua" => brands}, patterns) do
    case patterns.brands do
      %{^family => pattern} -> :binary.match(brands, pattern) == :nomatch
      _unknown -> true
    end
  end

  defp brand_mismatch?(_ua, _headers, _patterns), do: false

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

  defp headless_hints?(%{"sec-ch-ua" => brands}, patterns),
    do: :binary.match(brands, patterns.headless) != :nomatch

  defp headless_hints?(_headers, _patterns), do: false

  defp patterns do
    case :persistent_term.get(@pattern_key, nil) do
      nil -> compile()
      patterns -> patterns
    end
  end

  defp compile do
    %{
      brands:
        Map.new(@brands, fn {family, names} -> {family, :binary.compile_pattern(names)} end),
      headless: :binary.compile_pattern("HeadlessChrome")
    }
  end
end
