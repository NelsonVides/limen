defmodule Limen.DryRunTest do
  @moduledoc """
  Dry-run mode must behave identically to enforce mode except for the final
  action: the same requests produce the same decisions and the same state.
  """

  use Limen.Case, async: true
  use ExUnitProperties

  alias Limen.State.BanList
  alias Limen.Test.Policies.Scoring

  @agents [
    "curl/8.5.0",
    "python-requests/2.32.3",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
      "Chrome/128.0.0.0 Safari/537.36",
    nil
  ]

  defp requests do
    list_of(
      tuple({
        member_of([{192, 0, 2, 1}, {192, 0, 2, 2}, {198, 51, 100, 9}]),
        member_of(@agents),
        member_of(["/", "/api/items", "/about"]),
        boolean(),
        integer(0..700)
      }),
      max_length: 40
    )
  end

  defp run(limen, requests, mode, start) do
    Limen.State.reset(limen)
    opts = Limen.Plug.init(instance: limen, policy: Scoring, mode: mode)

    {decisions, _time} =
      Enum.map_reduce(requests, 0, fn {ip, agent, path, language?, gap}, time ->
        time = time + gap

        headers =
          [{"user-agent", agent}, {"accept-language", if(language?, do: "en")}]
          |> Enum.reject(fn {_name, value} -> is_nil(value) end)

        conn =
          conn(:get, path)
          |> Map.put(:remote_ip, ip)
          |> Map.put(:req_headers, headers)
          |> put_private(:limen_now, start + time)
          |> put_private(:limen_monotonic, 1_000_000_000 + time * 1_000)
          |> Limen.Plug.call(opts)

        {{conn.halted, comparable(Limen.decision(conn))}, time}
      end)

    bans = Enum.map(BanList.list(instance(limen), start), &Map.drop(&1, [:mode, :expires_at]))
    {decisions, bans}
  end

  # A background process refreshes the active prefix estimate every second,
  # so it may change between the two runs.
  defp comparable(decision) do
    %{
      decision
      | mode: nil,
        enforced: nil,
        duration: nil,
        at: nil,
        matches: strip(decision.matches),
        signals: Map.delete(decision.signals, :active_prefixes)
    }
  end

  # Ban observations carry the absolute expiry, which differs between runs.
  defp strip(matches) do
    Enum.map(matches, fn match ->
      %{match | observed: Enum.reject(match.observed, &match?({"expires_at", _at}, &1))}
    end)
  end

  setup %{limen: limen} do
    Limen.Lists.put_cidrs(limen, :test_office, ["198.51.100.0/24"])
  end

  property "dry-run and enforce reach the same decisions and state", %{limen: limen} do
    check all requests <- requests() do
      # Both runs see the same clock, so time windows line up.
      start = future_now()
      {dry_run, dry_run_bans} = run(limen, requests, :dry_run, start)
      {enforce, enforce_bans} = run(limen, requests, :enforce, start)

      assert Enum.map(dry_run, &elem(&1, 1)) == Enum.map(enforce, &elem(&1, 1))
      assert dry_run_bans == enforce_bans
      refute Enum.any?(dry_run, &elem(&1, 0))
    end
  end
end
