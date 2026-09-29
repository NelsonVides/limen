defmodule Limen.Signal.UserAgent do
  @moduledoc """
  A deliberately small user agent classifier.

  It answers the questions bot scoring needs, not the ones analytics does:
  does the agent claim to be a browser, which engine (and therefore which
  headers it must send), a crawler (and which one, for DNS verification), an
  automation tool or a headless browser?

  Non-browser markers and browser tokens are found with a single pass of a
  precompiled [Aho-Corasick] pattern, which matches many strings at once, and
  platforms with a second one: a pass reports matches that do not overlap,
  and platform names can overlap markers, as `Windows` does
  `WindowsPowerShell/`. The leftmost marker wins, so a crawler that embeds a
  Chrome token in its user agent is still a crawler.

  [Aho-Corasick]: https://doi.org/10.1145/360825.360855
  """

  @pattern_key {__MODULE__, :patterns}

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
    defp agent(unquote(marker)), do: {:marker, unquote(family), unquote(name)}
  end

  # A browser's rank is its position in @browsers: the lowest found wins.
  for {{token, family, engine}, rank} <- Enum.with_index(@browsers) do
    defp agent(unquote(token)), do: {:browser, unquote(rank), unquote(family), unquote(engine)}
  end

  defp agent("Safari/"), do: :safari

  @version_rank Enum.find_index(@browsers, &(elem(&1, 0) == "Version/"))

  for {{token, platform}, rank} <- Enum.with_index(@platforms) do
    defp platform(unquote(token)), do: {unquote(rank), unquote(platform)}
  end

  defp platform("Mobile"), do: :mobile

  @no_platform {length(@platforms), nil}

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
    {platform, mobile} = environment(:binary.matches(ua, patterns.platforms), ua, @no_platform)

    base = %{empty(:other) | platform: platform, mobile: mobile}
    agent(:binary.matches(ua, patterns.agents), ua, base, nil, false)
  end

  # The platform listed first in @platforms wins, wherever it appears.
  defp environment(matches, ua, best, mobile \\ false)

  defp environment([{start, length} | matches], ua, {rank, _platform} = best, mobile) do
    case platform(binary_part(ua, start, length)) do
      :mobile ->
        environment(matches, ua, best, true)

      {found, _platform} = platform when found < rank ->
        environment(matches, ua, platform, mobile)

      _ranked_lower ->
        environment(matches, ua, best, mobile)
    end
  end

  defp environment([], _ua, {_rank, platform}, mobile), do: {platform, mobile}

  # The leftmost marker settles the family. Otherwise the best ranked browser
  # token does, at its first occurrence. "Version/" also appears in Android
  # WebView user agents, which carry a Chrome token that ranks higher; it
  # only counts next to "Safari/".
  defp agent([{start, length} | matches], ua, base, browser, safari?) do
    case agent(binary_part(ua, start, length)) do
      {:marker, family, name} ->
        %{base | family: family, name: name}

      :safari ->
        agent(matches, ua, base, browser, true)

      {:browser, rank, family, engine} ->
        browser =
          if better?(rank, browser), do: {rank, family, engine, start + length}, else: browser

        agent(matches, ua, base, browser, safari?)
    end
  end

  defp agent([], ua, base, {rank, family, engine, offset}, safari?)
       when rank != @version_rank or safari? do
    %{base | family: family, engine: engine, version: version(ua, offset)}
  end

  defp agent([], _ua, base, _browser, _safari?), do: base

  defp better?(_rank, nil), do: true
  defp better?(rank, {best, _family, _engine, _offset}), do: rank < best

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
    browsers = ["Safari/" | Enum.map(@browsers, &elem(&1, 0))]

    %{
      agents: :binary.compile_pattern(browsers ++ Enum.map(@markers, &elem(&1, 0))),
      platforms: :binary.compile_pattern(["Mobile" | Enum.map(@platforms, &elem(&1, 0))])
    }
  end
end
