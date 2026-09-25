defmodule Limen.FloodTest do
  @moduledoc """
  A flood of 10^6 unique IPv6 /64 prefixes must stay within the memory cap.

  Tagged `:flood` and excluded from the default run; CI runs it separately.
  """

  use Limen.Case, async: true

  alias Limen.State

  @moduletag :flood
  @moduletag timeout: 600_000
  @max_keys 20_000
  @moduletag config: [state: [max_keys: @max_keys, gcra_max_keys: @max_keys]]

  defp flood(opts, range, now) do
    range
    |> Task.async_stream(
      fn n ->
        conn(:get, "/p/#{rem(n, 50)}")
        |> Map.put(:remote_ip, {0x2001, 0xDB8, div(n, 65_536), rem(n, 65_536), 0, 0, 0, 1})
        |> put_req_header("user-agent", "python-requests/2.32.3")
        |> put_private(:limen_now, now)
        |> Limen.Plug.call(opts)

        :ok
      end,
      ordered: false,
      max_concurrency: System.schedulers_online()
    )
    |> Stream.run()
  end

  defp total(memory), do: Enum.sum(Map.values(memory))

  test "10^6 unique /64s stay within the memory cap", %{instance: instance} do
    opts = Limen.Plug.init(instance: instance.name, policy: Limen.Policy.Default)
    now = future_now()

    flood(opts, 1..100_000, now)
    after_100k = State.memory(instance)

    flood(opts, 100_001..1_000_000, now)
    after_1m = State.memory(instance)

    # Every capped table holds at most its cap (plus the few insertions racing
    # the cap check on other schedulers).
    slack = System.schedulers_online()

    for {window, _duration} <- State.windows(), slot <- 0..2 do
      assert :ets.info(State.table(instance, window, slot), :size) <= @max_keys + slack
    end

    assert :ets.info(instance.state.gcra.table, :size) <= @max_keys + slack

    # Memory plateaus once the caps are reached: sketches and filters are
    # preallocated and the exact tables are full.
    assert total(after_1m) <= total(after_100k) * 1.05

    Mix.shell().info(
      "\nMemory after 10^5 unique prefixes: #{div(total(after_100k), 1_048_576)} MiB, " <>
        "after 10^6: #{div(total(after_1m), 1_048_576)} MiB"
    )
  end
end
