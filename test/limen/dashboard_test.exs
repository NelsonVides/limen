defmodule Limen.DashboardTest do
  use Limen.Case, async: true

  alias Limen.Dashboard.Data

  @tag config: [decision_log: [sample_rate: 1.0], trusted_proxies: ["192.0.2.2/32"]]
  test "reports the busiest prefixes and fingerprints, bans and recent decisions", %{
    limen: limen
  } do
    opts = Limen.Plug.init(instance: limen, policy: Limen.Test.Policies.Limited)
    ja4 = "t13d1516h2_8daaf6152771_02713d6af862"

    # Only the trusted peer's JA4 header is read.
    for {ip, count} <- [{{192, 0, 2, 1}, 5}, {{192, 0, 2, 2}, 2}], _request <- 1..count do
      Limen.Plug.call(%{put_req_header(conn(:get, "/"), "x-ja4", ja4) | remote_ip: ip}, opts)
    end

    Limen.ban(limen, "198.51.100.1", 60, reason: :manual)

    assert [%{prefix: "192.0.2.1/32", requests: 5}, %{prefix: "192.0.2.2/32", requests: 2}] =
             Data.top_prefixes(limen, 10)

    assert [%{prefix: "198.51.100.1/32", reason: ":manual", origin: :admin, action: :deny}] =
             Data.bans(limen, 10)

    assert [%{stage: :decide} | _rest] = Data.recent(limen, 3)
    assert Data.top_ja4(limen, 10) == [%{ja4: ja4, requests: 2}]
  end

  test "computes rates between snapshots", %{limen: limen} do
    first = Data.snapshot(limen)
    Limen.Stats.incr(instance(limen), :deny)
    second = %{Data.snapshot(limen) | at: first.at + 500}

    assert Data.rates(first, second).deny == 2.0
    assert Data.rates(nil, second).deny == 0.0
    assert second.memory > 0
  end

  test "the LiveDashboard page shows one instance" do
    assert {:ok, session} = Limen.Dashboard.init(otp_app: :my_app)
    assert {:ok, "Limen (my_app)"} = Limen.Dashboard.menu_link(session, %{})
    assert_raise ArgumentError, fn -> Limen.Dashboard.init([]) end
  end
end
