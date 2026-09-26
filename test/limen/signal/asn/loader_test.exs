defmodule Limen.Signal.Asn.LoaderTest do
  use ExUnit.Case, async: true

  import Limen.Case, only: [capture_events: 2]

  alias Limen.Signal.Asn
  alias Limen.Signal.Asn.Loader

  @moduletag :capture_log

  @fixture Path.expand("../../../fixtures/ip2asn-sample.tsv", __DIR__)
  @day 86_400_000

  defmodule Server do
    @moduledoc false
    # Serves the data the test sets. Unless it `changed`, a conditional
    # request gets a 304.
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      since = get_req_header(conn, "if-modified-since")

      state =
        Agent.get_and_update(agent, &{&1, Map.update!(&1, :requests, fn r -> [since | r] end)})

      cond do
        state.status != 200 -> send_resp(conn, state.status, "")
        since != [] and not state.changed -> send_resp(conn, 304, "")
        true -> send_resp(conn, 200, state.body)
      end
    end
  end

  setup do
    agent =
      start_supervised!(
        {Agent, fn -> %{body: File.read!(@fixture), changed: true, status: 200, requests: []} end}
      )

    server =
      start_supervised!(
        {Bandit, plug: {Server, agent}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    dir = Path.join(System.tmp_dir!(), "limen-asn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{
      agent: agent,
      url: "http://127.0.0.1:#{port}/ip2asn.tsv",
      path: Path.join(dir, "ip2asn.tsv")
    }
  end

  defp start(context, refresh \\ [], opts \\ []) do
    name = :"limen_asn_#{System.unique_integer([:positive])}"

    if Keyword.get(opts, :capture, false),
      do: capture_events([[:limen, :asn, :loaded], [:limen, :asn, :checked]], name)

    refresh = Keyword.merge([jitter: 0.0, max_utilization: nil, retry: 60_000], refresh)

    config = [
      secret_key: String.duplicate("limen-test-secret", 2),
      decision_log: [non_allow_sample_rate: 0.0],
      asn: [file: context.path, url: context.url, refresh: refresh]
    ]

    start_supervised!({Limen, name: name, config: config}, id: name)
    name
  end

  defp eventually(fun, tries \\ 250) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  defp checked(name), do: eventually(fn -> Loader.status(name).last_check end)
  defp server(agent, changes), do: Agent.update(agent, &Map.merge(&1, Map.new(changes)))
  defp requests(agent), do: Agent.get(agent, &Enum.reverse(&1.requests))

  test "downloads the data at startup when there is none yet", context do
    name = start(context, [], capture: true)

    assert %{result: :updated} = checked(name)
    assert %{asn: 16_509, name: "AMAZON-02"} = Asn.lookup(name, {3, 5, 140, 2})
    assert File.read!(context.path) == File.read!(@fixture)
    assert requests(context.agent) == [[]]

    assert %{source: {:url, url}, ranges: 4, failures: 0} = status = Loader.status(name)
    assert url == context.url
    assert (status.next_check - status.last_check.at) in @day..(@day + 50)

    assert_receive {:event, [:limen, :asn, :loaded], %{ranges: 4, bytes: _bytes},
                    %{source: {:url, _url}}}

    assert_receive {:event, [:limen, :asn, :checked], %{duration: _duration},
                    %{result: :updated, reason: nil}}
  end

  test "asks only for newer data, and loads it when there is some", context do
    name = start(context)
    checked(name)

    server(context.agent, changed: false)
    assert Loader.refresh(name) == :unchanged
    assert [[], [since]] = requests(context.agent)

    assert {{_year, _month, _day}, _time} =
             :httpd_util.convert_request_date(String.to_charlist(since))

    server(context.agent,
      changed: true,
      body: "8.8.8.0\t8.8.8.255\t15169\tUS\tGOOGLE\n" <> File.read!(@fixture)
    )

    assert Loader.refresh(name) == :updated
    assert %{asn: 15_169} = Asn.lookup(name, {8, 8, 8, 8})
    assert Loader.status(name).ranges == 5
  end

  test "keeps its data and backs off when a check fails", context do
    name = start(context)
    checked(name)

    server(context.agent, status: 500)
    assert Loader.refresh(name) == {:error, {:http_status, 500}}
    assert %{asn: 16_509} = Asn.lookup(name, {3, 5, 140, 2})

    assert %{failures: 1, last_check: %{at: at}, next_check: next} = Loader.status(name)
    assert (next - at) in 60_000..60_050
    refute File.exists?(context.path <> ".download")
  end

  test "rejects downloads that lose most of the data, or all of it", context do
    name = start(context)
    checked(name)

    server(context.agent, body: "1.0.0.0\t1.0.0.255\t13335\tUS\tCLOUDFLARENET\n")
    assert Loader.refresh(name) == {:error, {:too_few_ranges, 1, 4}}

    server(context.agent, body: "<html>Service unavailable</html>")
    assert Loader.refresh(name) == {:error, :no_ranges}

    assert Loader.status(name).ranges == 4
    assert File.read!(context.path) == File.read!(@fixture)
  end

  test "postpones scheduled checks while the node is busy", context do
    name = start(context, max_memory: 1)

    assert %{result: {:postponed, {:memory, memory}}} = checked(name)
    assert memory > 1
    assert requests(context.agent) == []
    assert Asn.lookup(name, {3, 5, 140, 2}) == nil
  end

  test "loads the file it has at startup, and checks it when due", context do
    File.cp!(@fixture, context.path)
    two_days_ago = System.os_time(:second) - 2 * 86_400
    File.touch!(context.path, two_days_ago)

    server(context.agent, changed: false)
    name = start(context)

    assert %{result: :unchanged} = checked(name)
    assert %{source: {:file, file}} = Loader.status(name)
    assert file == context.path
    assert [[_since]] = requests(context.agent)
    assert File.stat!(context.path, time: :posix).mtime > two_days_ago
  end

  test "waits for the next check when the file is current", context do
    File.cp!(@fixture, context.path)
    name = start(context)

    assert %{ranges: 4, last_check: nil, next_check: next} =
             eventually(fn -> Loader.status(name) end)

    assert next > System.system_time(:millisecond) + @day - 5_000
    assert requests(context.agent) == []
  end

  describe "configuration" do
    test "needs a file to keep downloads in" do
      assert_raise ArgumentError, ~r/needs a :file/, fn ->
        Limen.Config.build(asn: [url: "https://iptoasn.com/data/ip2asn-combined.tsv.gz"])
      end
    end

    test "rejects invalid refresh options and URLs" do
      invalid = [
        [every: 1_000],
        [jitter: 2],
        [window: {~T[01:00:00], ~T[01:00:00]}],
        [window: [:nightly]],
        [max_utilization: 0],
        [max_memory: -1],
        [retry: 10],
        [daily: true]
      ]

      for refresh <- invalid do
        assert_raise ArgumentError, ~r/invalid Limen asn option/, fn ->
          Limen.Config.build(
            asn: [file: "asn.tsv", url: "https://example.com/asn", refresh: refresh]
          )
        end
      end

      assert_raise ArgumentError, ~r/invalid Limen asn option/, fn ->
        Limen.Config.build(asn: [file: "asn.tsv", url: "ftp://example.com/asn"])
      end
    end

    test "takes one window or several, and defaults the rest" do
      window = {~T[01:00:00], ~T[05:00:00]}

      refresh =
        Limen.Config.build(
          asn: [file: "asn.tsv", url: "https://example.com/asn", refresh: [window: window]]
        ).asn.refresh

      assert refresh.window == [window]
      assert %{every: 86_400_000, jitter: 0.1, max_utilization: 0.9, max_memory: nil} = refresh
    end
  end

  test "measures how busy the schedulers are" do
    assert Loader.utilization(20) >= 0.0
    assert Loader.utilization(20) <= 1.0
  end
end
