defmodule Limen.Signal.FcrdnsTest do
  # FakeDNS records are global, but only this module uses them.
  use Limen.Case, async: true

  alias Limen.Context
  alias Limen.Signal.Fcrdns
  alias Limen.Signal.Fcrdns.Resolver
  alias Limen.Test.FakeDNS

  @moduletag config: [fcrdns: [dns: FakeDNS, interval: 60_000]]

  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @real {66, 249, 66, 1}
  @spoofer {203, 0, 113, 9}

  setup do
    FakeDNS.put(%{
      {:ptr, @real} => ["crawl-66-249-66-1.googlebot.com."],
      {:a, "crawl-66-249-66-1.googlebot.com"} => [@real],
      {:ptr, @spoofer} => ["host.attacker.example"],
      {:ptr, {203, 0, 113, 10}} => ["fake.googlebot.com.attacker.example"],
      {:ptr, {203, 0, 113, 11}} => ["crawl-1.googlebot.com"],
      {:a, "crawl-1.googlebot.com"} => [@real],
      {:ptr, {203, 0, 113, 12}} => {:error, :transient}
    })

    on_exit(fn -> FakeDNS.put(%{}) end)
  end

  defp signal(limen, ip, user_agent \\ @googlebot) do
    ctx =
      Fcrdns.collect(%Context{
        instance: instance(limen),
        client_ip: ip,
        user_agent: user_agent,
        now: System.system_time(:millisecond)
      })

    {ctx.signals.fcrdns, Map.get(ctx.evidence, :fcrdns)}
  end

  test "requests not claiming to be a crawler are left alone", %{limen: limen} do
    assert {:not_claimed, nil} = signal(limen, @real, "curl/8.5.0")
    assert pending(limen) == 0
  end

  test "verifies a real crawler in the background", %{limen: limen} do
    assert {:pending, %{crawler: "googlebot"}} = signal(limen, @real)
    assert {:pending, _evidence} = signal(limen, @real)
    assert pending(limen) == 1

    Resolver.run(limen)

    assert {:verified, %{host: "crawl-66-249-66-1.googlebot.com"}} = signal(limen, @real)
    assert pending(limen) == 0
  end

  test "reports every verification as telemetry", %{limen: limen} do
    capture_events([[:limen, :fcrdns, :resolved]], limen)
    for ip <- [@real, @spoofer, {203, 0, 113, 12}], do: signal(limen, ip)
    Resolver.run(limen)

    events =
      for _n <- 1..3 do
        assert_receive {:event, [:limen, :fcrdns, :resolved], %{duration: duration}, metadata}
        assert is_integer(duration)
        {metadata.ip, Map.delete(metadata, :ip)}
      end

    assert Map.new(events) == %{
             @real => %{
               instance: limen,
               crawler: "googlebot",
               result: :verified,
               host: "crawl-66-249-66-1.googlebot.com",
               reason: nil
             },
             @spoofer => %{
               instance: limen,
               crawler: "googlebot",
               result: :failed,
               host: nil,
               reason: {:unexpected_host, "host.attacker.example"}
             },
             {203, 0, 113, 12} => %{
               instance: limen,
               crawler: "googlebot",
               result: :error,
               host: nil,
               reason: :transient
             }
           }
  end

  test "exposes spoofed crawlers", %{limen: limen} do
    for ip <- [@spoofer, {203, 0, 113, 10}, {203, 0, 113, 11}], do: signal(limen, ip)
    Resolver.run(limen)

    assert {:failed, %{reason: {:unexpected_host, "host.attacker.example"}}} =
             signal(limen, @spoofer)

    assert {:failed, _suffix_is_not_enough} = signal(limen, {203, 0, 113, 10})

    assert {:failed, %{reason: {:forward_mismatch, "crawl-1.googlebot.com"}}} =
             signal(limen, {203, 0, 113, 11})
  end

  test "transient DNS errors keep the claim pending without retrying on every request", %{
    limen: limen
  } do
    signal(limen, {203, 0, 113, 12})
    Resolver.run(limen)

    assert {:pending, %{reason: :transient}} = signal(limen, {203, 0, 113, 12})
    assert pending(limen) == 0
  end

  test "unknown crawlers cannot be verified", %{limen: limen} do
    assert {:unverifiable, %{crawler: "claudebot"}} =
             signal(
               limen,
               @real,
               "Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"
             )
  end

  @tag config: [fcrdns: [dns: FakeDNS, interval: 60_000, max_pending: 2]]
  test "the verification queue is bounded", %{limen: limen} do
    for n <- 1..10, do: signal(limen, {198, 51, 100, n})
    assert pending(limen) == 2
  end

  test "the default policy allows verified crawlers and scores spoofed ones", %{limen: limen} do
    signal(limen, @real)
    signal(limen, @spoofer)
    Resolver.run(limen)

    decide = fn ip ->
      conn(:get, "/")
      |> Map.put(:remote_ip, ip)
      |> put_req_header("user-agent", @googlebot)
      |> Limen.Plug.call(Limen.Plug.init(instance: limen))
      |> Limen.decision()
    end

    assert %{action: :allow, stage: :rule, matches: [%{name: :verified_crawler}]} = decide.(@real)
    assert %{matches: matches} = decide.(@spoofer)
    assert Enum.any?(matches, &(&1.name == :spoofed_crawler))
  end

  defp pending(limen), do: :ets.info(instance(limen).state.fcrdns.pending, :size)
end
