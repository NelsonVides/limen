defmodule Limen.InstanceTest do
  # Sets application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Limen.Instance

  # Instances started here have no secret key and warn about it.
  @moduletag :capture_log

  setup do
    on_exit(fn -> Application.delete_env(:limen_test_app, Limen) end)
  end

  test "starts one instance named after the application" do
    Application.put_env(:limen_test_app, Limen, mode: :enforce)
    start_supervised!({Limen, otp_app: :limen_test_app})

    assert %Instance{name: :limen_test_app, config: %{mode: :enforce}} =
             Instance.fetch!(:limen_test_app)
  end

  test "starts every configured instance, sharing top-level options" do
    Application.put_env(:limen_test_app, Limen,
      ipv6_prefix: 56,
      instances: [limen_test_public: [], limen_test_admin: [mode: :enforce]]
    )

    start_supervised!({Limen, otp_app: :limen_test_app})

    assert %{config: %{mode: :dry_run, ipv6_prefix: 56}} = Instance.fetch!(:limen_test_public)
    assert %{config: %{mode: :enforce, ipv6_prefix: 56}} = Instance.fetch!(:limen_test_admin)
    refute Instance.get(:limen_test_app)
  end

  test "instance names are unique" do
    start_supervised!({Limen, name: :limen_test_unique})

    assert {:error, {{:shutdown, {:failed_to_start_child, Limen.Owner, reason}}, _spec}} =
             start_supervised({Limen, name: :limen_test_unique}, id: :second)

    assert reason == {:already_started, :limen_test_unique}
  end

  test "stopping an instance unpublishes it" do
    start_supervised!({Limen, name: :limen_test_stopped})
    assert Instance.get(:limen_test_stopped)

    stop_supervised!({Limen, :limen_test_stopped})
    refute Instance.get(:limen_test_stopped)

    assert_raise ArgumentError, ~r/is not running/, fn -> Instance.fetch!(:limen_test_stopped) end
  end

  test "warns when it has to generate a secret key" do
    log = capture_log(fn -> start_supervised!({Limen, name: :limen_test_generated}) end)
    assert log =~ "Limen instance :limen_test_generated has no :secret_key"
    assert Instance.fetch!(:limen_test_generated).config.keys.generated

    secret = String.duplicate("s", 32)
    config = [secret_key: secret]

    assert capture_log(fn ->
             start_supervised!({Limen, name: :limen_test_configured, config: config})
           end) == ""
  end

  test "invalid options fail at startup" do
    assert_raise ArgumentError, ~r/unknown option :nope/, fn ->
      Limen.Config.build(nope: true)
    end

    assert_raise ArgumentError, ~r/invalid Limen mode option/, fn ->
      Limen.Config.build(mode: :sometimes)
    end
  end

  describe "update_config/3" do
    setup do
      name = :limen_test_updated

      config = [
        secret_key: String.duplicate("s", 32),
        trap: [paths: ["/archive"], min_fill_time: 3_000],
        asn: [refresh: [every: 3_600_000, jitter: 0.5]],
        lists: [office: ["a"]]
      ]

      start_supervised!({Limen, name: name, config: config})
      %{name: name}
    end

    test "merges keyword options into their current values", %{name: name} do
      :ok = Limen.update_config(name, :trap, min_fill_time: 0)
      assert %{paths: ["/archive"], min_fill_time: 0} = Instance.fetch!(name).config.trap

      # Nested keyword options merge too.
      :ok = Limen.update_config(name, :fcrdns, interval: 10)
      :ok = Limen.update_config(name, :fcrdns, timeout: 500)
      assert %{interval: 10, timeout: 500} = Instance.fetch!(name).config.fcrdns

      # Other values replace the current ones.
      :ok = Limen.update_config(name, :trap, paths: ["/elsewhere"])
      assert %{paths: ["/elsewhere"], min_fill_time: 0} = Instance.fetch!(name).config.trap
      assert Instance.fetch!(name).config.trap.routes == [{["elsewhere"], "/elsewhere"}]

      :ok = Limen.set_mode(name, :enforce)
      assert Instance.fetch!(name).config.mode == :enforce
    end

    test "validates like at startup and changes nothing on error", %{name: name} do
      before = Instance.fetch!(name).config

      assert_raise ArgumentError, ~r/invalid Limen trap option/, fn ->
        Limen.update_config(name, :trap, min_fill_time: -1)
      end

      assert_raise ArgumentError, ~r/is under the challenge path/, fn ->
        Limen.update_config(name, :challenge, path: "/archive")
      end

      assert Instance.fetch!(name).config == before
    end

    test "refuses options only read at startup", %{name: name} do
      assert_raise ArgumentError, ~r/:state option :max_keys is read at startup/, fn ->
        Limen.update_config(name, :state, max_keys: 10)
      end

      assert_raise ArgumentError, ~r/:asn option :refresh is read at startup/, fn ->
        Limen.update_config(name, :asn, refresh: [jitter: 0.1])
      end

      assert_raise ArgumentError, ~r/with Limen.Lists/, fn ->
        Limen.update_config(name, :lists, office: ["b"])
      end

      # Unchanged, or changing what is read at runtime, is fine.
      :ok = Limen.update_config(name, :asn, refresh: [jitter: 0.5], hosting: [64_496])
      :ok = Limen.update_config(name, :state, max_bans: 10)
      assert Instance.fetch!(name).config.state.max_bans == 10
    end
  end
end
