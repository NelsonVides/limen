defmodule Limen.ListsTest do
  use Limen.Case, async: true

  alias Limen.Lists

  doctest Limen.Lists

  defmodule ScraperPolicy do
    use Limen.Policy, signals: []

    deny :scraper, when: signal(:user_agent) in list(:scrapers)
  end

  @tag config: [lists: [scrapers: {:substrings, ["HTTrack", "SiteSucker"]}]]
  test "substring lists match strings containing a member", %{limen: limen} do
    assert Lists.member?(limen, :scrapers, "Mozilla/4.5 (compatible; HTTrack 3.0x; Windows 98)")
    assert Lists.member?(limen, :scrapers, "SiteSucker/3.2")
    refute Lists.member?(limen, :scrapers, "sitesucker/3.2")
    refute Lists.member?(limen, :scrapers, nil)
    assert Lists.get(limen, :scrapers) == ["HTTrack", "SiteSucker"]

    conn =
      conn(:get, "/")
      |> put_req_header("user-agent", "SiteSucker/3.2")
      |> Limen.Plug.call(Limen.Plug.init(instance: limen, policy: ScraperPolicy))

    assert %Limen.Decision{action: :deny, matches: [%{name: :scraper}]} = Limen.decision(conn)

    Lists.put_substrings(limen, :scrapers, [])
    refute Lists.member?(limen, :scrapers, "SiteSucker/3.2")
  end

  test "substring members must be non-empty strings", %{limen: limen} do
    assert_raise ArgumentError, fn -> Lists.put_substrings(limen, :bad, [""]) end

    assert_raise ArgumentError, ~r/invalid Limen lists option/, fn ->
      Limen.Config.build(lists: [bad: {:substrings, [:atom]}])
    end
  end
end
