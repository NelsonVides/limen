defmodule Limen.DecisionTest do
  use ExUnit.Case, async: true

  alias Limen.Decision
  alias Limen.Decision.Match

  describe "normalize/1" do
    test "fills in default parameters" do
      assert Decision.normalize(:allow) == {:allow, %{}}
      assert Decision.normalize(:throttle) == {:throttle, %{retry_after: 1}}
      assert Decision.normalize({:challenge, difficulty: 20}) == {:challenge, %{difficulty: 20}}
      assert Decision.normalize({:challenge, 40}) == {:challenge, %{difficulty: 32}}
      assert Decision.normalize({:deny, ban: 60}) == {:deny, %{ban: 60}}
      assert Decision.normalize({:tarpit, 250}) == {:tarpit, %{delay: 250}}
    end

    test "rejects unknown actions" do
      assert_raise ArgumentError, fn -> Decision.normalize(:maybe) end
    end
  end

  test "explain/1 lists identity, rules, clause and signals" do
    decision = %Decision{
      action: :challenge,
      params: %{difficulty: 18},
      mode: :enforce,
      enforced: true,
      stage: :decide,
      policy: MyPolicy,
      score: 50,
      identity: %{client_ip: {192, 0, 2, 1}, prefix: {4, 3_221_225_985, 32}, ja4: nil},
      matches: [
        %Match{
          name: :datacenter_asn,
          kind: :score,
          weight: 30,
          condition: "signal(:asn_kind) == :hosting",
          observed: [{"signal(:asn_kind)", :hosting}]
        }
      ],
      clause: "score >= 40",
      signals: %{asn_kind: :hosting},
      evidence: %{asn_kind: 16_509}
    }

    text = Decision.explain(decision)

    assert text =~ "challenge(difficulty: 18) (enforced) at stage decide by MyPolicy, score 50"
    assert text =~ "prefix: 192.0.2.1/32"
    assert text =~ "score datacenter_asn +30 when signal(:asn_kind) == :hosting"
    assert text =~ "[signal(:asn_kind) = :hosting]"
    assert text =~ "decided by: score >= 40"
    assert text =~ "signal asn_kind = :hosting (16509)"
    refute text =~ "ja4"
  end

  test "explain shows only the mode of allowed requests, which have nothing to enforce" do
    header = fn decision -> hd(String.split(Decision.explain(decision), "\n")) end

    assert header.(%Decision{action: :allow, mode: :enforce, stage: :pass}) ==
             "allow (enforce mode) at stage pass, score 0"

    assert header.(%Decision{action: :deny, mode: :dry_run, stage: :rule}) ==
             "deny (not enforced, dry_run) at stage rule, score 0"
  end
end
