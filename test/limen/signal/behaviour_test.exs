defmodule Limen.Signal.BehaviourTest do
  use Limen.Case, async: true

  alias Limen.{Context, Signal, State}
  alias Limen.Signal.Behaviour

  # The start of a minute centuries ahead, so the rotator never clears it.
  @now 3_600_000 * 5_000_000

  defp track(instance, path, headers \\ [], ip \\ {127, 0, 0, 1}) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, conn -> put_req_header(conn, k, v) end)

    conn = %{conn | remote_ip: ip}

    ctx = Signal.identify(Context.from_conn(conn, instance), instance.config)
    Behaviour.track(conn, %{ctx | now: @now})
  end

  test "counts a client's requests, pages, assets, 404s and new paths", %{instance: instance} do
    page = [{"sec-fetch-dest", "document"}]

    track(instance, "/a", page)
    track(instance, "/a", page)
    track(instance, "/app.js")
    {conn, _ctx} = track(instance, "/missing", page)
    send_resp(conn, 404, "")
    {_conn, ctx} = track(instance, "/b", page)

    assert %{
             requests_per_minute: 5,
             pages_per_minute: 4,
             assets_per_minute: 1,
             asset_ratio: 0.25,
             not_found_ratio: 0.2,
             distinct_paths_per_minute: 4
           } = Behaviour.collect(ctx).signals

    # Read back from the table when the request was not tracked.
    assert Behaviour.collect(%{ctx | rates: %{}}).signals == Behaviour.collect(ctx).signals
  end

  test "keeps a client's counts in one key of the minute window", %{instance: instance} do
    track(instance, "/a", [{"sec-fetch-dest", "document"}])
    {conn, _ctx} = track(instance, "/app.js")
    send_resp(conn, 404, "")

    table = State.table(instance, :minute, rem(div(@now, 60_000), 3))
    key = {Behaviour.key({4, 0x7F000001, 32}), div(@now, 60_000)}

    assert [{^key, 2, 1, 1, 1, 2}] = :ets.lookup(table, key)
  end

  test "counts each active prefix once, however many requests it makes", %{instance: instance} do
    for ip <- [{192, 0, 2, 1}, {198, 51, 100, 1}, {203, 0, 113, 1}], path <- ["/a", "/b", "/c"] do
      track(instance, path, [], ip)
    end

    assert State.estimate_active_prefixes(instance, @now) == 3
  end
end
