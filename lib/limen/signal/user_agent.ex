defmodule Limen.Signal.UserAgent do
  @moduledoc """
  A deliberately small user agent classifier.

  It answers the questions bot scoring needs, not the ones analytics does:
  does the agent claim to be a browser, which engine (and therefore which
  headers it must send), a crawler (and which one, for DNS verification), an
  automation tool or a headless browser?

  Non-browser markers are found with a single pass of a precompiled
  [Aho-Corasick] pattern, which matches many strings at once; the leftmost
  marker wins, so a crawler that embeds a Chrome token in its user agent is
  still a crawler.

  [Aho-Corasick]: https://doi.org/10.1145/360825.360855
  """

  @pattern_key {__MODULE__, :pattern}

  @type family ::
          :chrome
          | :edge
          | :opera
          | :samsung
          | :firefox
          | :safari
          | :crawler
          | :headless
          | :tool
          | :other
          | :none

  @type t :: %{
          family: family(),
          name: String.t() | nil,
          version: non_neg_integer() | nil,
          engine: :chromium | :gecko | :webkit | nil,
          platform: :windows | :macos | :linux | :android | :ios | :chromeos | nil,
          mobile: boolean()
        }

  @markers [
    # Search engines and other crawlers.
    {"Googlebot", :crawler, "googlebot"},
    {"Google-InspectionTool", :crawler, "googlebot"},
    {"bingbot", :crawler, "bingbot"},
    {"Applebot", :crawler, "applebot"},
    {"YandexBot", :crawler, "yandexbot"},
    {"Baiduspider", :crawler, "baiduspider"},
    {"DuckDuckBot", :crawler, "duckduckbot"},
    {"Yahoo! Slurp", :crawler, "slurp"},
    {"facebookexternalhit", :crawler, "facebook"},
    {"Twitterbot", :crawler, "twitterbot"},
    {"LinkedInBot", :crawler, "linkedinbot"},
    {"GPTBot", :crawler, "gptbot"},
    {"ClaudeBot", :crawler, "claudebot"},
    {"CCBot", :crawler, "ccbot"},
    {"Bytespider", :crawler, "bytespider"},
    {"Amazonbot", :crawler, "amazonbot"},
    {"PerplexityBot", :crawler, "perplexitybot"},
    {"AhrefsBot", :crawler, "ahrefsbot"},
    {"SemrushBot", :crawler, "semrushbot"},
    {"MJ12bot", :crawler, "mj12bot"},
    {"PetalBot", :crawler, "petalbot"},
    {"DotBot", :crawler, "dotbot"},
    {"crawler", :crawler, nil},
    {"Crawler", :crawler, nil},
    {"spider", :crawler, nil},
    {"Spider", :crawler, nil},
    {"bot/", :crawler, nil},
    {"Bot/", :crawler, nil},
    # Browsers driven by automation.
    {"HeadlessChrome", :headless, "headless-chrome"},
    {"PhantomJS", :headless, "phantomjs"},
    # HTTP libraries and command line tools.
    {"curl/", :tool, "curl"},
    {"Wget/", :tool, "wget"},
    {"python-requests/", :tool, "python-requests"},
    {"Python-urllib/", :tool, "python-urllib"},
    {"python-httpx/", :tool, "httpx"},
    {"aiohttp/", :tool, "aiohttp"},
    {"Go-http-client/", :tool, "go"},
    {"okhttp/", :tool, "okhttp"},
    {"Java/", :tool, "java"},
    {"Apache-HttpClient/", :tool, "apache-httpclient"},
    {"libwww-perl/", :tool, "libwww-perl"},
    {"Scrapy/", :tool, "scrapy"},
    {"node-fetch", :tool, "node-fetch"},
    {"axios/", :tool, "axios"},
    {"undici", :tool, "undici"},
    {"HTTPie/", :tool, "httpie"},
    {"PostmanRuntime/", :tool, "postman"},
    {"insomnia/", :tool, "insomnia"},
    {"hackney/", :tool, "hackney"},
    {"GuzzleHttp/", :tool, "guzzle"},
    {"Faraday v", :tool, "faraday"},
    {"WindowsPowerShell/", :tool, "powershell"},
    {"Dart/", :tool, "dart"},
    {"reqwest/", :tool, "reqwest"},
    {"Deno/", :tool, "deno"},
    {"Bun/", :tool, "bun"}
  ]

  # Browser tokens, most specific first: Edge and Opera also carry Chrome's.
  @browsers [
    {"EdgiOS/", :edge, :webkit},
    {"EdgA/", :edge, :chromium},
    {"Edg/", :edge, :chromium},
    {"OPR/", :opera, :chromium},
    {"SamsungBrowser/", :samsung, :chromium},
    {"CriOS/", :chrome, :webkit},
    {"FxiOS/", :firefox, :webkit},
    {"Firefox/", :firefox, :gecko},
    {"Chrome/", :chrome, :chromium},
    {"Version/", :safari, :webkit}
  ]

  @platforms [
    {"Windows", :windows},
    {"iPhone", :ios},
    {"iPad", :ios},
    {"Android", :android},
    {"CrOS", :chromeos},
    {"Macintosh", :macos},
    {"Linux", :linux}
  ]

  for {marker, family, name} <- @markers do
    defp marker(unquote(marker)), do: {unquote(family), unquote(name)}
  end

  # Shared by every instance: the patterns are pure. Only installed when
  # missing, since replacing a persistent term triggers a global GC.
  @doc false
  @spec setup() :: :ok
  def setup do
    if :persistent_term.get(@pattern_key, nil) == nil do
      :persistent_term.put(@pattern_key, compile())
    end

    :ok
  end

  @doc """
  Classifies a user agent string.

      iex> Limen.Signal.UserAgent.parse("curl/8.5.0")
      %{family: :tool, name: "curl", version: nil, engine: nil, platform: nil, mobile: false}

      iex> ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
      ...>   "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
      iex> Limen.Signal.UserAgent.parse(ua)
      %{family: :chrome, name: nil, version: 128, engine: :chromium, platform: :windows, mobile: false}
  """
  @spec parse(String.t() | nil) :: t()
  def parse(nil), do: empty(:none)
  def parse(""), do: empty(:none)

  def parse(ua) when is_binary(ua) do
    patterns = patterns()
    environment = tokens(ua, patterns.platforms)

    base = %{
      empty(:other)
      | platform: Enum.find_value(@platforms, fn {token, p} -> if environment[token], do: p end),
        mobile: Map.has_key?(environment, "Mobile")
    }

    case :binary.match(ua, patterns.markers) do
      {start, length} ->
        {family, name} = marker(binary_part(ua, start, length))
        %{base | family: family, name: name}

      :nomatch ->
        browser(ua, tokens(ua, patterns.browsers), base)
    end
  end

  # Every token found in `ua`, with the offset right after its first
  # occurrence, in a single pass over the string.
  defp tokens(ua, pattern) do
    ua
    |> :binary.matches(pattern)
    |> Enum.reduce(%{}, fn {start, length}, found ->
      Map.put_new(found, binary_part(ua, start, length), start + length)
    end)
  end

  # "Version/" also appears in Android WebView user agents, which carry a
  # Chrome token that takes precedence; only Safari pairs it with "Safari/".
  defp browser(ua, found, base) do
    Enum.find_value(@browsers, base, fn {token, family, engine} ->
      case found do
        %{"Version/" => _offset, "Safari/" => _safari} when token == "Version/" ->
          %{base | family: family, engine: engine, version: version(ua, found[token])}

        %{^token => offset} when token != "Version/" ->
          %{base | family: family, engine: engine, version: version(ua, offset)}

        _missing ->
          nil
      end
    end)
  end

  defp version(ua, offset) do
    rest = binary_part(ua, offset, byte_size(ua) - offset)

    case Integer.parse(rest) do
      {version, _rest} when version >= 0 -> version
      :error -> nil
    end
  end

  defp empty(family) do
    %{family: family, name: nil, version: nil, engine: nil, platform: nil, mobile: false}
  end

  defp patterns do
    case :persistent_term.get(@pattern_key, nil) do
      nil -> compile()
      patterns -> patterns
    end
  end

  defp compile do
    %{
      markers: :binary.compile_pattern(Enum.map(@markers, &elem(&1, 0))),
      browsers: :binary.compile_pattern(["Safari/" | Enum.map(@browsers, &elem(&1, 0))]),
      platforms: :binary.compile_pattern(["Mobile" | Enum.map(@platforms, &elem(&1, 0))])
    }
  end
end
