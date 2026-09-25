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
end
