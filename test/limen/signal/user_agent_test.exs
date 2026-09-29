defmodule Limen.Signal.UserAgentTest do
  use ExUnit.Case, async: true

  alias Limen.Signal.UserAgent

  @cases [
    {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0",
     %{family: :edge, engine: :chromium, version: 128, platform: :windows}},
    {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 OPR/113.0.0.0",
     %{family: :opera, engine: :chromium, version: 113}},
    {"Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36",
     %{family: :chrome, platform: :android, mobile: true}},
    {"Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/128.0.6613.98 Mobile/15E148 Safari/604.1",
     %{family: :chrome, engine: :webkit, platform: :ios}},
    {"Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0",
     %{family: :firefox, engine: :gecko, version: 130, platform: :linux}},
    {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
     %{family: :safari, engine: :webkit, version: 17, platform: :macos}},
    {"Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.119 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
     %{family: :crawler, name: "googlebot", engine: nil}},
    {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm) Chrome/116.0.1938.76 Safari/537.36",
     %{family: :crawler, name: "bingbot"}},
    {"Mozilla/5.0 (compatible; SomeNewBot/1.0; +https://example.com/bot)",
     %{family: :crawler, name: nil}},
    {"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/128.0.0.0 Safari/537.36",
     %{family: :headless}},
    {"Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/128.0.0.0 Mobile Safari/537.36",
     %{family: :chrome, version: 128, platform: :android, mobile: true}},
    # Platform names can overlap markers, so they are found in a pass of
    # their own: here "Windows" only appears within "WindowsPowerShell/".
    {"WindowsPowerShell/5.1.19041.4648",
     %{family: :tool, name: "powershell", platform: :windows}},
    {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)",
     %{family: :ai_crawler, name: "gptbot", engine: nil}},
    {"Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
     %{family: :ai_crawler, name: "claudebot"}},
    {"CCBot/2.0 (https://commoncrawl.org/faq/)", %{family: :ai_crawler, name: "ccbot"}},
    {"meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)",
     %{family: :ai_crawler, name: "meta-externalagent"}},
    {"Mozilla/5.0 (compatible; omgilibot/0.3 +http://omgili.com)",
     %{family: :ai_crawler, name: "omgili"}},
    # A longer token wins over a shorter one starting at the same place.
    {"Mozilla/5.0 (compatible; SemrushBot-OCOB/1; +https://www.semrush.com/bot/)",
     %{family: :ai_crawler, name: "semrushbot-ocob"}},
    {"Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)",
     %{family: :crawler, name: "semrushbot"}},
    {"Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)",
     %{family: :ai_crawler, name: "bytespider"}},
    {"facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
     %{family: :link_preview, name: "facebookexternalhit"}},
    {"Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
     %{family: :link_preview, name: "slackbot"}},
    {"Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
     %{family: :link_preview, name: "discordbot"}},
    {"WhatsApp/2.23.20.0 A", %{family: :link_preview, name: "whatsapp"}},
    {"TelegramBot (like TwitterBot)", %{family: :link_preview, name: "telegrambot"}},
    {"http.rb/5.1.1 (Mastodon/4.2.10; +https://mastodon.social/)",
     %{family: :link_preview, name: "mastodon"}},
    {"Go-http-client/2.0", %{family: :tool, name: "go"}},
    {"Wget/1.21.4", %{family: :tool, name: "wget"}},
    {"Mozilla/5.0", %{family: :other, engine: nil}},
    {nil, %{family: :none}}
  ]

  for {ua, expected} <- @cases do
    test "classifies #{inspect(ua)}" do
      parsed = UserAgent.parse(unquote(ua))

      assert Map.take(parsed, Map.keys(unquote(Macro.escape(expected)))) ==
               unquote(Macro.escape(expected))
    end
  end

  describe "an instance's own tokens" do
    defp custom(opts), do: Limen.Config.build(user_agents: opts).user_agents

    test "extend the built-in lists" do
      custom = custom(ai_crawler: ["NewAIBot"], tool: [{"MyMonitor/", "monitor"}])

      assert %{family: :ai_crawler, name: "newaibot"} =
               UserAgent.parse("Mozilla/5.0 (compatible; NewAIBot/1.0)", custom)

      assert %{family: :tool, name: "monitor"} = UserAgent.parse("MyMonitor/2.0", custom)

      # The built-in lists still apply, and so does the leftmost marker rule.
      assert %{family: :crawler, name: "googlebot"} =
               UserAgent.parse("Googlebot/2.1 NewAIBot/1.0", custom)

      assert %{family: :chrome, version: 128} =
               UserAgent.parse("Mozilla/5.0 Chrome/128.0.0.0 Safari/537.36", custom)
    end

    test "move and remove built-in tokens" do
      custom = custom(crawler: ["Amazonbot"], ignore: ["Mastodon/"])

      assert %{family: :crawler, name: "amazonbot"} =
               UserAgent.parse("Mozilla/5.0 (compatible; Amazonbot/0.1)", custom)

      assert %{family: :ai_crawler} = UserAgent.parse("Mozilla/5.0 (compatible; Amazonbot/0.1)")

      assert %{family: :other, name: nil} =
               UserAgent.parse("http.rb/5.1.1 (Mastodon/4.2.10)", custom)

      # Ignoring alone needs no pattern of its own.
      assert %{family: :other} = UserAgent.parse("WhatsApp/2.23", custom(ignore: ["WhatsApp/"]))
    end

    test "are validated" do
      for invalid <- [[robot: ["X"]], [tool: [""]], [tool: "X"], [ignore: [{"X", "x"}]]] do
        assert_raise ArgumentError, ~r/invalid Limen user_agents option/, fn ->
          custom(invalid)
        end
      end
    end
  end
end
