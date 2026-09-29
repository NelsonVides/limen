defmodule Limen.DecisionLogTest do
  # Captures Logger output, which is global.
  use Limen.Case, async: false

  import ExUnit.CaptureLog

  alias Limen.{Decision, DecisionLog}
  alias Limen.DecisionLog.Flusher

  @moduletag config: [
               decision_log: [
                 sample_rate: 1.0,
                 non_allow_sample_rate: 1.0,
                 size: 8,
                 flush_interval: 60_000
               ]
             ]

  test "keeps the most recent sampled decisions, newest first", %{limen: limen} do
    for n <- 1..20, do: DecisionLog.record(instance(limen), %Decision{path: "/#{n}"})

    paths = Enum.map(DecisionLog.recent(limen, 3), & &1.path)
    assert paths == ["/20", "/19", "/18"]
    assert length(DecisionLog.recent(limen, 100)) == 8

    # The overflow is reported when the buffer is drained.
    assert capture_log(fn -> Flusher.flush(limen) end) =~ "12 entries dropped"
  end

  @tag config: [decision_log: [sample_rate: 0.0, non_allow_sample_rate: 1.0, size: 8]]
  test "samples allow and non-allow decisions separately", %{limen: limen} do
    DecisionLog.record(instance(limen), %Decision{action: :allow, path: "/allowed"})
    DecisionLog.record(instance(limen), %Decision{action: :deny, path: "/denied"})

    assert [%Decision{path: "/denied"} | _older] = DecisionLog.recent(limen, 1)
    refute Enum.any?(DecisionLog.recent(limen, 8), &(&1.path == "/allowed"))
  end

  test "flushes sampled decisions to Logger as structured reports", %{limen: limen} do
    decision = %Decision{
      instance: limen,
      action: :deny,
      path: "/flushed",
      identity: %{prefix: {4, 1, 32}}
    }

    DecisionLog.record(instance(limen), decision)

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log(fn -> Flusher.flush(limen) end)

    assert log =~ "limen.decision"
    assert log =~ "/flushed"
  end

  defmodule Sink do
    @behaviour Limen.DecisionLog.Sink

    @impl true
    def write(decisions, opts) do
      case Keyword.fetch!(opts, :test) do
        :raise -> raise "the database is down"
        pid -> send(pid, {:written, Enum.map(decisions, & &1.path), self()})
      end
    end
  end

  test "writes batches to the configured sink, oldest first", %{limen: limen} do
    Limen.update_config(limen, :decision_log, sink: {Sink, test: self()})
    for n <- 1..3, do: DecisionLog.record(instance(limen), %Decision{path: "/#{n}"})

    Flusher.flush(limen)
    assert_received {:written, ["/1", "/2", "/3"], _flusher}

    # Nothing sampled, nothing written.
    Flusher.flush(limen)
    refute_received {:written, _paths, _flusher}

    DecisionLog.record(instance(limen), %Decision{path: "/4"})
    Flusher.flush(limen)
    assert_received {:written, ["/4"], _flusher}
  end

  test "a failing sink loses its batch, not the flusher", %{limen: limen} do
    Limen.update_config(limen, :decision_log, sink: {Sink, test: :raise})
    DecisionLog.record(instance(limen), %Decision{path: "/lost"})

    assert capture_log(fn -> Flusher.flush(limen) end) =~ "the database is down"

    Limen.update_config(limen, :decision_log, sink: {Sink, test: self()})
    DecisionLog.record(instance(limen), %Decision{path: "/kept"})
    Flusher.flush(limen)
    assert_received {:written, ["/kept"], _flusher}
  end

  describe "inline delivery" do
    setup %{limen: limen} do
      Limen.update_config(limen, :decision_log, sink: {Sink, test: self()}, delivery: :inline)
    end

    test "writes each sampled decision at once, in the process that made it",
         %{limen: limen} do
      test = self()
      DecisionLog.record(instance(limen), %Decision{path: "/now"})
      assert_received {:written, ["/now"], ^test}

      # The buffer still has it for the dashboard, and the flusher doesn't
      # write it again.
      assert [%Decision{path: "/now"} | _older] = DecisionLog.recent(limen, 1)
      Flusher.flush(limen)
      refute_received {:written, _paths, _process}
    end

    test "writes the decisions of requests through the plug", %{limen: limen} do
      opts = Limen.Plug.init(instance: limen)
      test = self()

      Plug.Test.conn(:get, "/through-the-plug")
      |> Limen.Test.put_client_ip(Limen.Test.unique_ip())
      |> Limen.Plug.call(opts)

      assert_received {:written, ["/through-the-plug"], ^test}
    end

    test "switching back to batches neither repeats nor loses decisions", %{limen: limen} do
      DecisionLog.record(instance(limen), %Decision{path: "/inline"})
      assert_received {:written, ["/inline"], _process}

      Limen.update_config(limen, :decision_log, delivery: :batched)
      DecisionLog.record(instance(limen), %Decision{path: "/batched"})
      Flusher.flush(limen)
      assert_received {:written, ["/batched"], _flusher}
    end

    test "a failing sink raises in the caller, so its test fails", %{limen: limen} do
      Limen.update_config(limen, :decision_log, sink: {Sink, test: :raise})

      assert_raise RuntimeError, "the database is down", fn ->
        DecisionLog.record(instance(limen), %Decision{path: "/broken"})
      end
    end

    test "overwritten entries aren't reported as dropped", %{limen: limen} do
      for n <- 1..20, do: DecisionLog.record(instance(limen), %Decision{path: "/#{n}"})
      refute capture_log(fn -> Flusher.flush(limen) end) =~ "dropped"
    end
  end

  test "delivery is :batched or :inline" do
    assert_raise ArgumentError, ~r/invalid value for :delivery/, fn ->
      Limen.Config.build(decision_log: [delivery: :sync])
    end
  end

  test "the Logger sink logs at its level", %{limen: limen} do
    Limen.update_config(limen, :decision_log, sink: {Limen.DecisionLog.Logger, level: :error})
    DecisionLog.record(instance(limen), %Decision{path: "/loud"})

    assert capture_log([level: :error], fn -> Flusher.flush(limen) end) =~ "/loud"
  end

  test "sinks must implement the behaviour" do
    assert_raise ArgumentError, ~r/invalid value for :sink/, fn ->
      Limen.Config.build(decision_log: [sink: Enum])
    end
  end
end
