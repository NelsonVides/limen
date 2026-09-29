defmodule Limen.State.BanListTest do
  use Limen.Case, async: true

  alias Limen.State.BanList

  @prefix {4, 0xC0000201, 32}

  # Tests pass explicit times; start a day ahead so the background sweeper,
  # which uses the real clock, never sees these bans as expired.
  setup do
    %{now: System.system_time(:millisecond) + 86_400_000}
  end

  test "a ban is active until it expires", %{instance: instance, now: now} do
    capture_events([[:limen, :ban, :added]], instance.name)
    assert BanList.ban(instance, @prefix, 60, reason: :abuse, now: now) == :ok

    assert %{reason: :abuse, mode: :enforce, origin: :admin} =
             BanList.lookup(instance, @prefix, now)

    assert BanList.lookup(instance, @prefix, now + 59_999)
    refute BanList.lookup(instance, @prefix, now + 60_000)
    assert_receive {:event, [:limen, :ban, :added], %{ttl: 60}, %{prefix: @prefix}}
  end

  test "banning again extends and escalates, never shortens", %{instance: instance, now: now} do
    BanList.ban(instance, @prefix, 60, mode: :dry_run, now: now)
    BanList.ban(instance, @prefix, 10, mode: :dry_run, now: now)
    assert BanList.lookup(instance, @prefix, now).expires_at == now + 60_000

    BanList.ban(instance, @prefix, 10, mode: :enforce, now: now)
    assert %{mode: :enforce, expires_at: expires_at} = BanList.lookup(instance, @prefix, now)
    assert expires_at == now + 60_000

    BanList.ban(instance, @prefix, 120, mode: :dry_run, now: now)
    assert %{mode: :enforce, expires_at: expires_at} = BanList.lookup(instance, @prefix, now)
    assert expires_at == now + 120_000
  end

  test "bans deny unless they send to the maze, which sticks", %{instance: instance, now: now} do
    BanList.ban(instance, @prefix, 60, now: now)
    assert %{action: :deny} = BanList.lookup(instance, @prefix, now)

    BanList.ban(instance, @prefix, 10, action: :maze, origin: :trap, now: now)
    assert %{action: :maze, expires_at: expires_at} = BanList.lookup(instance, @prefix, now)
    assert expires_at == now + 60_000

    BanList.ban(instance, @prefix, 600, action: :deny, now: now)
    assert %{action: :maze, expires_at: expires_at} = BanList.lookup(instance, @prefix, now)
    assert expires_at == now + 600_000
    assert [%{action: :maze}] = BanList.list(instance, now)
  end

  test "sweep removes expired bans", %{instance: instance, now: now} do
    BanList.ban(instance, @prefix, 1, now: now)
    BanList.ban(instance, {4, 1, 32}, 100, now: now)

    assert BanList.sweep(instance, now + 1_000) == 1
    assert [%{prefix: {4, 1, 32}}] = BanList.list(instance, now + 1_000)
  end

  @tag config: [state: [max_bans: 2]]
  test "refuses new bans when full", %{instance: instance} do
    assert BanList.ban(instance, {4, 1, 32}, 60) == :ok
    assert BanList.ban(instance, {4, 2, 32}, 60) == :ok
    assert BanList.ban(instance, {4, 3, 32}, 60) == {:error, :full}
    assert BanList.ban(instance, {4, 1, 32}, 120) == :ok

    BanList.unban(instance, {4, 1, 32})
    assert BanList.ban(instance, {4, 3, 32}, 60) == :ok
  end

  @tag config: [state: [max_bans: 1_000]]
  test "sweeping while bans are added keeps the list within its cap", %{
    instance: instance,
    now: now
  } do
    # Sweeps look at time 0, so none of these bans has expired, but every
    # sweep races the new bans.
    banners = 8
    sweeper = Task.async(fn -> sweep_until_stopped(instance) end)

    1..banners
    |> Enum.map(fn banner ->
      Task.async(fn ->
        for n <- 1..5_000, do: BanList.ban(instance, {4, banner * 100_000 + n, 32}, 60, now: now)
      end)
    end)
    |> Task.await_many(30_000)

    send(sweeper.pid, :stop)
    Task.await(sweeper)

    assert :ets.info(instance.state.bans.table, :size) <= 1_000 + banners
  end

  defp sweep_until_stopped(instance) do
    receive do
      :stop -> :ok
    after
      0 ->
        BanList.sweep(instance, 0)
        sweep_until_stopped(instance)
    end
  end

  test "concurrent bans of one prefix all take effect", %{instance: instance, now: now} do
    # Banners wait to start together, and each extends the ban to a different
    # expiry, one of them enforcing it and one sending it to the maze: the
    # result must have the longest expiry and both escalations.
    banners = 16

    for n <- 1..300 do
      prefix = {4, n, 32}
      BanList.ban(instance, prefix, 1, mode: :dry_run, now: now)

      tasks =
        for ttl <- 2..(banners + 1) do
          opts = [mode: if(ttl == 2, do: :enforce, else: :dry_run), now: now]
          opts = if ttl == 3, do: [action: :maze] ++ opts, else: opts

          Task.async(fn ->
            receive do
              :go -> BanList.ban(instance, prefix, ttl, opts)
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      Task.await_many(tasks)

      assert %{expires_at: expires_at, mode: :enforce, action: :maze} =
               BanList.lookup(instance, prefix, now)

      assert expires_at == now + (banners + 1) * 1_000
    end
  end

  describe "Limen.ban/4" do
    test "aggregates addresses to their prefix", %{instance: instance} do
      assert Limen.ban(instance, "192.0.2.1", 60) == :ok
      assert Limen.banned(instance, {192, 0, 2, 1})
      refute Limen.banned(instance, {192, 0, 2, 2})

      Limen.unban(instance, "192.0.2.1")
      refute Limen.banned(instance, "192.0.2.1")
    end

    @tag config: [ipv6_prefix: 56]
    test "accepts prefixes of the configured length only", %{instance: instance} do
      assert Limen.ban(instance, "2001:db8:0:100::/56", 60) == :ok
      assert Limen.banned(instance, "2001:db8:0:1ff::1")

      assert_raise ArgumentError, ~r"/56 prefixes", fn ->
        Limen.ban(instance, "2001:db8::/48", 60)
      end

      assert_raise ArgumentError, fn -> Limen.ban(instance, "nope", 60) end
    end
  end
end
