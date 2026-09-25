Code.require_file("../../credo/checks/no_messaging.ex", __DIR__)

defmodule Limen.Credo.NoMessagingTest do
  use Credo.Test.Case, async: true

  alias Limen.Credo.NoMessaging

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  test "allows ETS, atomics and telemetry" do
    """
    defmodule Hot do
      def call(key) do
        :ets.update_counter(:t, key, 1, {key, 0})
        :atomics.add(:persistent_term.get(:ref), 1, 1)
        :telemetry.execute([:x], %{}, %{})
        IO.iodata_to_binary(["a", "b"])
      end
    end
    """
    |> to_source_file()
    |> run_check(NoMessaging)
    |> refute_issues()
  end

  test "reports sends, calls, spawns, logging and IO" do
    """
    defmodule Hot do
      require Logger

      def call(pid) do
        send(pid, :hello)
        Process.send_after(pid, :later, 10)
        GenServer.call(pid, :sync)
        :gen_server.cast(pid, :async)
        Task.start(fn -> :ok end)
        spawn(fn -> :ok end)
        Logger.info("hi")
        IO.puts("hi")
      end
    end
    """
    |> to_source_file()
    |> run_check(NoMessaging)
    |> assert_issues(fn issues ->
      triggers = Enum.map(issues, & &1.trigger)

      expected =
        ~w(send Process.send_after GenServer.call :gen_server.cast Task.start spawn Logger.info IO.puts)

      assert Enum.sort(triggers) == Enum.sort(expected)
    end)
  end
end
