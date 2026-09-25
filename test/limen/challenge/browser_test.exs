defmodule Limen.Challenge.BrowserTest do
  @moduledoc """
  End to end: a real browser solves the challenge, a plain HTTP client does
  not get through.

  Excluded by default. Run with `mix test --only browser`; set
  `LIMEN_BROWSER` to a Firefox or Chrome binary if it is not found.
  """

  use ExUnit.Case, async: false

  import Limen.Case

  alias Limen.Decision
  alias Limen.Test.Policies.Challenging

  @moduletag :browser
  @moduletag timeout: 120_000

  @instance :limen_browser_test

  defmodule App do
    @moduledoc false
    use Plug.Builder

    plug Limen.Plug, instance: :limen_browser_test, policy: Challenging
    plug :welcome

    def welcome(conn, _opts) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<h1>Welcome</h1>")
    end
  end

  setup do
    config = [
      secret_key: String.duplicate("browser", 5),
      decision_log: [non_allow_sample_rate: 0.0]
    ]

    start_supervised!({Limen, name: @instance, config: config})
    {:ok, server} = Bandit.start_link(plug: App, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    %{url: "http://localhost:#{port}/articles?page=2"}
  end

  test "a plain HTTP client only ever gets the challenge page", %{url: url} do
    :inets.start()

    for _attempt <- 1..3 do
      {:ok, {{_version, status, _reason}, _headers, body}} =
        :httpc.request(:get, {String.to_charlist(url), [{~c"accept", ~c"text/html"}]}, [], [])

      assert status == 403
      assert to_string(body) =~ "Checking your browser"
      refute to_string(body) =~ "Welcome"
    end
  end

  test "a real browser solves the challenge and comes back with a pass", %{url: url} do
    browser = browser!()
    capture_events([[:limen, :decision]], @instance)
    profile = Path.join(System.tmp_dir!(), "limen-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(profile)

    port =
      Port.open({:spawn_executable, browser}, [
        :binary,
        :stderr_to_stdout,
        args: browser_args(browser, profile, url)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      File.rm_rf(profile)
    end)

    assert_receive {:event, [:limen, :decision], _m, %{decision: %Decision{action: :challenge}}},
                   30_000

    assert_receive {:event, [:limen, :decision], _m,
                    %{decision: %Decision{stage: :endpoint, action: :allow} = solved}},
                   60_000

    assert [%{name: :challenge_solved, condition: "proof of work"}] = solved.matches

    assert_receive {:event, [:limen, :decision], _m,
                    %{decision: %Decision{stage: :pass, path: "/articles"}}},
                   30_000
  end

  defp browser! do
    candidates = [
      System.get_env("LIMEN_BROWSER"),
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Firefox.app/Contents/MacOS/firefox",
      System.find_executable("google-chrome"),
      System.find_executable("chromium"),
      System.find_executable("firefox")
    ]

    Enum.find(candidates, &(&1 && File.exists?(&1))) ||
      flunk("no browser found, set LIMEN_BROWSER")
  end

  defp browser_args(browser, profile, url) do
    if String.contains?(String.downcase(browser), "firefox") do
      ["-headless", "-no-remote", "-profile", profile, url]
    else
      ["--headless=new", "--no-first-run", "--user-data-dir=#{profile}", url]
    end
  end
end
