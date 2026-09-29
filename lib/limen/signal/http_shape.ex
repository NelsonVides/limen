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

  Provides `:ua_family` (see `Limen.Signal.UserAgent` for the families),
  `:ua_name` (the name of a known automated client, such as `"googlebot"`,
  `"gptbot"` or `"curl"`, else `nil`), `:ua_version`, `:shape` and
  `:shape_flags`, with the parsed user agent as evidence for `:ua_family`.

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
  def provides, do: [:ua_family, :ua_name, :ua_version, :shape, :shape_flags]

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
    %{shape: %{ignore_headers: ignored}, ja4_header: ja4_header, user_agents: custom} =
      ctx.instance.config

    ua = UserAgent.parse(ctx.user_agent, custom)
    {names, seen} = read(ctx.headers, ja4_header, ignored)

    Context.put_signals(
      ctx,
      %{
        ua_family: ua.family,
        ua_name: ua.name,
        ua_version: ua.version,
        shape: hash(names),
        shape_flags: raised(ua, seen, ctx.scheme == :https, patterns())
      },
      %{ua_family: Map.delete(ua, :family)}
    )
  end

  @doc """
  The header-order shape of a request.
  """
  @spec shape(Context.t()) :: String.t()
  def shape(%Context{instance: %{config: config}} = ctx) do
    %{shape: %{ignore_headers: ignored}, ja4_header: ja4_header} = config
    {names, _seen} = read(ctx.headers, ja4_header, ignored)
    hash(names)
  end

  @doc """
  The inconsistencies between a request's headers and its user agent.
  """
  @spec flags(Context.t(), UserAgent.t()) :: [atom()]
  def flags(%Context{} = ctx, ua) do
    # Names are left aside, so none need skipping.
    {_names, seen} = read(ctx.headers, nil, %{})
    raised(ua, seen, ctx.scheme == :https, patterns())
  end

  defp hash(names) do
    hash = :erlang.phash2(:lists.reverse(names), 1 <<< 32)
    Base.encode16(<<hash::32>>, case: :lower)
  end

  # One pass over the headers collects the names that make up the shape,
  # last first, and the values of the headers flags look at. Their values
  # stay in the arguments `@seen`, in the order of `@flag_headers`, until the
  # end: the pass allocates nothing but the list of names. As in a map, a
  # repeated header's last value wins.
  @seen Macro.generate_arguments(length(@flag_headers), __MODULE__)
  @seen_keys Enum.map(@flag_headers, &String.to_atom(String.replace(&1, "-", "_")))

  defp read(headers, ja4_header, ignored),
    do:
      read(headers, ja4_header, ignored, [], unquote_splicing(List.duplicate(nil, length(@seen))))

  defp read([{name, value} | rest], ja4_header, ignored, names, unquote_splicing(@seen)) do
    header(
      byte_size(name),
      name,
      value,
      rest,
      ja4_header,
      ignored,
      names,
      unquote_splicing(@seen)
    )
  end

  defp read([], _ja4_header, _ignored, names, unquote_splicing(@seen)),
    do: {names, %{unquote_splicing(Enum.zip(@seen_keys, @seen))}}

  # A clause per flag header, selected by the length of the name and then
  # compared, so that each name is compared with few others. Matching the
  # name against a literal instead would start a binary match, which
  # allocates a match context for every header.
  for {flag_header, index} <- Enum.with_index(@flag_headers) do
    defp header(
           unquote(byte_size(flag_header)),
           name,
           value,
           rest,
           ja4_header,
           ignored,
           names,
           unquote_splicing(List.replace_at(@seen, index, Macro.var(:_, nil)))
         )
         when name === unquote(flag_header) do
      names = if is_map_key(ignored, name), do: names, else: [name | names]

      read(
        rest,
        ja4_header,
        ignored,
        names,
        unquote_splicing(List.replace_at(@seen, index, Macro.var(:value, nil)))
      )
    end
  end

  defp header(size, name, _value, rest, ja4_header, ignored, names, unquote_splicing(@seen)) do
    names =
      if proxy_header?(size, name) or name == ja4_header or is_map_key(ignored, name),
        do: names,
        else: [name | names]

    read(rest, ja4_header, ignored, names, unquote_splicing(@seen))
  end

  for header <- @proxy_headers do
    defp proxy_header?(unquote(byte_size(header)), name) when name === unquote(header), do: true
  end

  defp proxy_header?(_size, _name), do: false

  # Only raised flags are allocated: the list is built from the last flag to
  # the first.
  defp raised(%{engine: nil} = ua, seen, _secure?, patterns) do
    []
    |> flag(:headless, ua.family == :headless or headless_hints?(seen, patterns))
    |> missing(ua, seen)
  end

  defp raised(ua, seen, secure?, patterns) do
    hints? = seen.sec_ch_ua != nil

    []
    |> flag(:headless, headless_hints?(seen, patterns))
    |> flag(:client_hint_mobile_mismatch, mobile_mismatch?(ua, seen))
    |> flag(:client_hint_platform_mismatch, platform_mismatch?(ua, seen))
    |> flag(:client_hint_brand_mismatch, brand_mismatch?(ua, seen, patterns))
    |> flag(:unexpected_client_hints, ua.engine != :chromium and hints?)
    |> flag(:no_client_hints, secure? and sends_client_hints?(ua) and not hints?)
    |> flag(:no_sec_fetch, secure? and sends_sec_fetch?(ua) and not sec_fetch?(seen))
    |> flag(:generic_accept, generic_navigation?(seen))
    |> missing(ua, seen)
  end

  defp missing(flags, ua, seen) do
    flags
    |> flag(:no_accept_encoding, seen.accept_encoding == nil)
    |> flag(:no_accept_language, seen.accept_language == nil)
    |> flag(:no_accept, seen.accept == nil)
    |> flag(:no_user_agent, ua.family == :none)
  end

  defp flag(flags, name, true), do: [name | flags]
  defp flag(flags, _name, false), do: flags

  defp generic_navigation?(seen) do
    seen.accept == "*/*" and seen.sec_fetch_dest in [nil, "document"]
  end

  defp sec_fetch?(seen), do: seen.sec_fetch_mode != nil or seen.sec_fetch_site != nil

  defp sends_sec_fetch?(%{engine: engine, version: version}) when is_integer(version),
    do: version >= Map.fetch!(@sec_fetch_since, engine)

  defp sends_sec_fetch?(_ua), do: false

  defp sends_client_hints?(%{engine: :chromium, version: version}) when is_integer(version),
    do: version >= @client_hints_since

  defp sends_client_hints?(_ua), do: false

  defp brand_mismatch?(%{engine: :chromium, family: family}, %{sec_ch_ua: brands}, patterns)
       when brands != nil do
    case patterns.brands do
      %{^family => pattern} -> :binary.match(brands, pattern) == :nomatch
      _unknown -> true
    end
  end

  defp brand_mismatch?(_ua, _seen, _patterns), do: false

  defp platform_mismatch?(%{platform: platform}, %{sec_ch_ua_platform: claimed})
       when platform != nil do
    case Map.fetch(@client_hint_platforms, claimed) do
      {:ok, hinted} -> hinted != platform and not (hinted == :android and platform == :linux)
      :error -> false
    end
  end

  defp platform_mismatch?(_ua, _seen), do: false

  defp mobile_mismatch?(%{mobile: mobile}, %{sec_ch_ua_mobile: "?1"}), do: not mobile
  defp mobile_mismatch?(%{mobile: mobile}, %{sec_ch_ua_mobile: "?0"}), do: mobile
  defp mobile_mismatch?(_ua, _seen), do: false

  defp headless_hints?(%{sec_ch_ua: brands}, patterns) when brands != nil,
    do: :binary.match(brands, patterns.headless) != :nomatch

  defp headless_hints?(_seen, _patterns), do: false

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
