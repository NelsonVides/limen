defmodule Limen.InstanceTest do
  # Sets application environment.
  use ExUnit.Case, async: false

  alias Limen.Instance

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

    assert {:error, {{:shutdown, {:failed_to_start_child, Limen.Instance.Owner, reason}}, _spec}} =
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

  test "invalid options fail at startup" do
    assert_raise ArgumentError, ~r/unknown option :nope/, fn ->
      Limen.Config.build(nope: true)
    end

    assert_raise ArgumentError, ~r/invalid Limen mode option/, fn ->
      Limen.Config.build(mode: :sometimes)
    end
  end
end
