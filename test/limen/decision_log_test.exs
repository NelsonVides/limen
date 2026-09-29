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
        pid -> send(pid, {:written, Enum.map(decisions, & &1.path)})
      end
    end
  end

  test "writes batches to the configured sink, oldest first", %{limen: limen} do
    Limen.update_config(limen, :decision_log, sink: {Sink, test: self()})
    for n <- 1..3, do: DecisionLog.record(instance(limen), %Decision{path: "/#{n}"})

    Flusher.flush(limen)
    assert_received {:written, ["/1", "/2", "/3"]}

    # Nothing sampled, nothing written.
    Flusher.flush(limen)
    refute_received {:written, _paths}

    DecisionLog.record(instance(limen), %Decision{path: "/4"})
    Flusher.flush(limen)
    assert_received {:written, ["/4"]}
  end

  test "a failing sink loses its batch, not the flusher", %{limen: limen} do
    Limen.update_config(limen, :decision_log, sink: {Sink, test: :raise})
    DecisionLog.record(instance(limen), %Decision{path: "/lost"})

    assert capture_log(fn -> Flusher.flush(limen) end) =~ "the database is down"

    Limen.update_config(limen, :decision_log, sink: {Sink, test: self()})
    DecisionLog.record(instance(limen), %Decision{path: "/kept"})
    Flusher.flush(limen)
    assert_received {:written, ["/kept"]}
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
