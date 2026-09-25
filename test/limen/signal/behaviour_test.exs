defmodule Limen.Signal.BehaviourTest do
  use Limen.Case, async: true

  alias Limen.{Context, Signal, State}
  alias Limen.Signal.Behaviour

  # The start of a minute centuries ahead, so the rotator never clears it.
  @now 3_600_000 * 5_000_000

  defp track(instance, path, headers \\ []) do
    conn =
      Enum.reduce(headers, conn(:get, path), fn {k, v}, conn -> put_req_header(conn, k, v) end)

    ctx = Signal.identify(Context.from_conn(conn, instance), instance.config)
    Behaviour.track(conn, %{ctx | now: @now})
  end

  test "counts a client's requests, pages, assets and 404s", %{instance: instance} do
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
             not_found_ratio: 0.2
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

    assert [{^key, 2, 1, 1, 1}] = :ets.lookup(table, key)
  end
end
