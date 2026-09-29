defmodule Limen.Signal.UserAgent do
  @moduledoc """
  A deliberately small user agent classifier.

  It answers the questions bot scoring needs, not the ones analytics does:
  does the agent claim to be a browser, which engine (and therefore which
  headers it must send), or which kind of automated client, and which one
  (for DNS verification, and for rules about a particular one)?

  ## Families

  Browsers are `:chrome`, `:edge`, `:opera`, `:samsung`, `:firefox` and
  `:safari`. Automated clients that name themselves are:

    * `:crawler` - search engines, SEO tools, and anything else calling
      itself a bot, crawler or spider;
    * `:ai_crawler` - crawlers and fetchers of AI companies, gathering
      training data or answering their users' questions, such as `GPTBot`,
      `ClaudeBot`, `CCBot` or `Bytespider`, after the community list at
      [ai.robots.txt];
    * `:link_preview` - services fetching a shared link to show a preview,
      such as `facebookexternalhit`, `Slackbot`, `Discordbot` or
      `WhatsApp`;
    * `:headless` - browsers driven by automation;
    * `:tool` - HTTP libraries and command line tools.

  Anything else is `:other`, and a missing or empty user agent is `:none`.
  Known automated clients also get a `name`, such as `"googlebot"` or
  `"gptbot"`. Anyone can claim any of these; `Limen.Signal.Fcrdns` verifies
  the claims that can be verified.

  The lists are built in and kept current with Limen's releases. The
  `:user_agents` option of `Limen.Config` extends and overrides them per
  instance, by family, with the tokens to look for, matched exactly as they
  appear in user agents (case matters):

      config :my_app, Limen,
        user_agents: [
          ai_crawler: ["NewAIBot"],
          link_preview: [{"ChatUnfurler/", "chat-unfurler"}],
          crawler: ["Amazonbot"],
          ignore: ["Mastodon/"]
        ]

  A token given as a string is named after itself, in lowercase and without
  a trailing `/`; `{token, name}` names it explicitly. Listing a built-in
  token under another family moves it there, and `:ignore` removes built-in
  tokens altogether.

  ## How it works

  Non-browser markers and browser tokens are found with a single pass of a
  precompiled [Aho-Corasick] pattern, which matches many strings at once, and
  platforms with a second one: a pass reports matches that do not overlap,
  and platform names can overlap markers, as `Windows` does
  `WindowsPowerShell/`. The leftmost marker wins, so a crawler that embeds a
  Chrome token in its user agent is still a crawler. An instance with tokens
  of its own looks for them in a third pass.

  [Aho-Corasick]: https://doi.org/10.1145/360825.360855
  [ai.robots.txt]: https://github.com/ai-robots-txt/ai.robots.txt
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
          | :ai_crawler
          | :link_preview
          | :headless
          | :tool
          | :other
          | :none

  @typedoc """
  An instance's own tokens (see the `:user_agents` option), as
  `Limen.Config` prepares them.
  """
  @type custom :: %{
          markers: %{String.t() => {:marker, family(), String.t() | nil} | :ignore},
          pattern: :binary.cp() | nil
        }

  @type t :: %{
          family: family(),
          name: String.t() | nil,
          version: non_neg_integer() | nil,
          engine: :chromium | :gecko | :webkit | nil,
          platform: :windows | :macos | :linux | :android | :ios | :chromeos | nil,
          mobile: boolean()
        }

  # Well-behaved automated clients name themselves in their user agents. The
  # AI crawlers follow the community list at
  # https://github.com/ai-robots-txt/ai.robots.txt (2026-09): agents that
  # fetch pages for training or answering, not tokens that only appear in
  # robots.txt, such as Google-Extended.
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
    # Crawlers and fetchers of AI companies.
    {"GPTBot", :ai_crawler, "gptbot"},
    {"ChatGPT-User", :ai_crawler, "chatgpt-user"},
    {"OAI-SearchBot", :ai_crawler, "oai-searchbot"},
    {"ClaudeBot", :ai_crawler, "claudebot"},
    {"Claude-Web", :ai_crawler, "claude-web"},
    {"Claude-User", :ai_crawler, "claude-user"},
    {"Claude-SearchBot", :ai_crawler, "claude-searchbot"},
    {"anthropic-ai", :ai_crawler, "anthropic-ai"},
    {"CCBot", :ai_crawler, "ccbot"},
    {"PerplexityBot", :ai_crawler, "perplexitybot"},
    {"Perplexity-User", :ai_crawler, "perplexity-user"},
    {"Bytespider", :ai_crawler, "bytespider"},
    {"Amazonbot", :ai_crawler, "amazonbot"},
    {"GoogleOther", :ai_crawler, "googleother"},
    {"Google-CloudVertexBot", :ai_crawler, "google-cloudvertexbot"},
    {"meta-externalagent", :ai_crawler, "meta-externalagent"},
    {"meta-externalfetcher", :ai_crawler, "meta-externalfetcher"},
    {"FacebookBot", :ai_crawler, "facebookbot"},
    {"Diffbot", :ai_crawler, "diffbot"},
    {"ImagesiftBot", :ai_crawler, "imagesiftbot"},
    {"omgili", :ai_crawler, "omgili"},
    {"cohere-ai", :ai_crawler, "cohere-ai"},
    {"cohere-training-data-crawler", :ai_crawler, "cohere-training-data-crawler"},
    {"AI2Bot", :ai_crawler, "ai2bot"},
    {"Ai2Bot-Dolma", :ai_crawler, "ai2bot-dolma"},
    {"Timpibot", :ai_crawler, "timpibot"},
    {"YouBot", :ai_crawler, "youbot"},
    {"DuckAssistBot", :ai_crawler, "duckassistbot"},
    {"MistralAI-User", :ai_crawler, "mistralai-user"},
    {"PanguBot", :ai_crawler, "pangubot"},
    {"iaskspider", :ai_crawler, "iaskspider"},
    {"ICC-Crawler", :ai_crawler, "icc-crawler"},
    {"img2dataset", :ai_crawler, "img2dataset"},
    {"Kangaroo Bot", :ai_crawler, "kangaroo-bot"},
    {"Webzio-Extended", :ai_crawler, "webzio-extended"},
    {"TikTokSpider", :ai_crawler, "tiktokspider"},
    {"SemrushBot-OCOB", :ai_crawler, "semrushbot-ocob"},
    {"FirecrawlAgent", :ai_crawler, "firecrawlagent"},
    # Link previews: chat, social and publishing services fetching a shared
    # link to show its title and image.
    {"facebookexternalhit", :link_preview, "facebookexternalhit"},
    {"Twitterbot", :link_preview, "twitterbot"},
    {"LinkedInBot", :link_preview, "linkedinbot"},
    {"Slackbot", :link_preview, "slackbot"},
    {"Slack-ImgProxy", :link_preview, "slack-imgproxy"},
    {"Discordbot", :link_preview, "discordbot"},
    {"WhatsApp/", :link_preview, "whatsapp"},
    {"TelegramBot", :link_preview, "telegrambot"},
    {"redditbot", :link_preview, "redditbot"},
    {"Pinterestbot", :link_preview, "pinterestbot"},
    {"Pinterest/", :link_preview, "pinterestbot"},
    {"Embedly", :link_preview, "embedly"},
    {"Iframely", :link_preview, "iframely"},
    {"Quora Link Preview", :link_preview, "quora-link-preview"},
    {"SkypeUriPreview", :link_preview, "skypeuripreview"},
    {"vkShare", :link_preview, "vkshare"},
    {"bitlybot", :link_preview, "bitlybot"},
    {"Mastodon/", :link_preview, "mastodon"},
    {"Cardyb", :link_preview, "bluesky"},
    {"Snap URL Preview", :link_preview, "snap"},
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
  Classifies a user agent string with the built-in lists only.

      iex> Limen.Signal.UserAgent.parse("curl/8.5.0")
      %{family: :tool, name: "curl", version: nil, engine: nil, platform: nil, mobile: false}

      iex> ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
      ...>   "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
      iex> Limen.Signal.UserAgent.parse(ua)
      %{family: :chrome, name: nil, version: 128, engine: :chromium, platform: :windows, mobile: false}
  """
  @spec parse(String.t() | nil) :: t()
  def parse(ua), do: parse(ua, nil)

  @doc """
  Classifies a user agent string with the built-in lists and an instance's
  own tokens (its `config.user_agents`).

      iex> custom = Limen.Config.build(user_agents: [tool: ["MyMonitor/"]]).user_agents
      iex> Limen.Signal.UserAgent.parse("MyMonitor/2.0", custom).family
      :tool
  """
  @spec parse(String.t() | nil, custom() | nil) :: t()
  def parse(nil, _custom), do: empty(:none)
  def parse("", _custom), do: empty(:none)

  def parse(ua, custom) when is_binary(ua) do
    patterns = patterns()
    {platform, mobile} = environment(:binary.matches(ua, patterns.platforms), ua, @no_platform)
    base = %{empty(:other) | platform: platform, mobile: mobile}

    case custom do
      %{markers: markers, pattern: pattern} when map_size(markers) > 0 ->
        matches = :binary.matches(ua, patterns.agents)
        matches = if pattern, do: merge(matches, :binary.matches(ua, pattern)), else: matches
        agent(matches, ua, base, nil, false, markers)

      _built_in_only ->
        agent(:binary.matches(ua, patterns.agents), ua, base, nil, false, %{})
    end
  end

  # Both lists are in order of position; so is the result.
  defp merge([{a, _length} = first | rest], [{b, _other_length} | _others] = others) when a <= b,
    do: [first | merge(rest, others)]

  defp merge(ones, [other | others]), do: [other | merge(ones, others)]
  defp merge(ones, []), do: ones

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
  defp agent([{start, length} | matches], ua, base, browser, safari?, markers) do
    case token(binary_part(ua, start, length), markers) do
      {:marker, family, name} ->
        %{base | family: family, name: name}

      :safari ->
        agent(matches, ua, base, browser, true, markers)

      {:browser, rank, family, engine} ->
        browser =
          if better?(rank, browser), do: {rank, family, engine, start + length}, else: browser

        agent(matches, ua, base, browser, safari?, markers)

      :ignore ->
        agent(matches, ua, base, browser, safari?, markers)
    end
  end

  defp agent([], ua, base, {rank, family, engine, offset}, safari?, _markers)
       when rank != @version_rank or safari? do
    %{base | family: family, engine: engine, version: version(ua, offset)}
  end

  defp agent([], _ua, base, _browser, _safari?, _markers), do: base

  # An instance's own tokens override the built-in ones.
  defp token(token, markers) when map_size(markers) == 0, do: agent(token)

  defp token(token, markers) do
    case markers do
      %{^token => found} -> found
      _built_in -> agent(token)
    end
  end

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
