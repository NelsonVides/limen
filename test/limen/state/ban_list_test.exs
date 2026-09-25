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

  describe "Limen.ban/3" do
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
