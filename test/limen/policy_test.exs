defmodule Limen.PolicyTest do
  use Limen.Case, async: true

  alias Limen.{Context, Decision, Policy}
  alias Limen.Test.Policies.{Limited, Scoring}

  doctest Limen.Policy.Runtime
  doctest Limen.Policy.Default

  setup %{limen: limen} do
    Limen.Lists.put(limen, :test_bad_ja4, ["t13d1812h1_85036bcba153_375ca2c5e164"])
    Limen.Lists.put_cidrs(limen, :test_office, ["198.51.100.0/24"])
  end

  defp request(headers \\ [], opts \\ []) do
    conn(:get, Keyword.get(opts, :path, "/"))
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, {192, 0, 2, 1}))
    |> Map.put(:req_headers, headers)
    |> put_private(:limen_now, Keyword.get_lazy(opts, :now, &future_now/0))
    |> put_private(:limen_monotonic, Keyword.get(opts, :monotonic, 1_000_000_000))
  end

  defp decide(limen, policy, conn, mode \\ :dry_run) do
    opts = Limen.Plug.init(instance: limen, policy: policy, mode: mode)
    Limen.decision(Limen.Plug.call(conn, opts))
  end

  describe "rules" do
    test "scores matching rules and explains what they observed", %{limen: limen} do
      decision = decide(limen, Scoring, request([{"user-agent", "curl/8.5.0"}]))

      assert %Decision{action: :challenge, params: %{difficulty: 16}, score: 50} = decision
      assert decision.clause == "score >= 40 -> {:challenge, difficulty: difficulty_for(score)}"
      assert Enum.map(decision.matches, & &1.name) == [:curl, :no_accept_language]

      [curl, _language] = decision.matches
      assert curl.condition == "signal(:ua_family) == :tool"
      assert curl.observed == [{"signal(:ua_family)", :tool}]
      assert Decision.explain(decision) =~ "score curl +30 when signal(:ua_family) == :tool"
    end

    test "negative weights lower the score", %{limen: limen} do
      decision =
        decide(limen, Scoring, request([{"user-agent", "curl/8.5.0"}, {"x-test-trust", "yes"}]))

      assert decision.score == 0
      assert decision.action == :allow
      assert decision.clause == nil
    end

    test "a rule that raises does not match and is recorded", %{limen: limen} do
      decision = decide(limen, Scoring, request([{"accept-language", "en"}]))

      refute Enum.any?(decision.matches, &(&1.name == :broken))
      assert [{:rule, :broken, _message}] = decision.errors
    end

    test "allow rules short-circuit, CIDR lists match addresses", %{limen: limen} do
      decision =
        decide(limen, Scoring, request([{"user-agent", "curl/8.5.0"}], ip: {198, 51, 100, 9}))

      assert %Decision{action: :allow, stage: :rule, score: 0} = decision
      assert [%{name: :trusted_office, kind: :allow, observed: observed}] = decision.matches
      assert {"signal(:client_ip) in list(:test_office)", true} in observed
    end

    @tag config: [trusted_proxies: ["10.0.0.0/8"]]
    test "deny rules short-circuit and ban", %{limen: limen} do
      conn =
        request([{"x-ja4", "t13d1812h1_85036bcba153_375ca2c5e164"}], ip: {10, 0, 0, 1})

      assert %Decision{action: :deny, stage: :rule, params: %{ban: 60}} =
               decide(limen, Scoring, conn)

      assert %Decision{action: :deny, stage: :ban} = decide(limen, Scoring, conn)

      assert %{mode: :dry_run, reason: :bad_ja4, origin: :policy} =
               Limen.banned(limen, {10, 0, 0, 1})
    end

    test "decide bans too", %{limen: limen} do
      headers = [{"user-agent", "curl/8.5.0"}]
      conn = request(headers, path: "/api/items")

      for _request <- 1..3, do: decide(limen, Scoring, conn)
      decision = decide(limen, Scoring, conn)

      assert decision.score == 85
      assert decision.params == %{ban: 30}
      assert Limen.banned(limen, {192, 0, 2, 1}).reason == :curl
    end

    test "rates count every request the policy sees", %{limen: limen} do
      conn = request([{"accept-language", "en"}])
      decisions = for _request <- 1..5, do: decide(limen, Scoring, conn)

      assert Enum.map(decisions, &Enum.any?(&1.matches, fn m -> m.name == :burst end)) ==
               [false, false, false, true, true]

      [burst] = Enum.filter(List.last(decisions).matches, &(&1.name == :burst))
      assert burst.observed == [{"rate(:prefix, per: :second)", 5}]
    end
  end

  describe "limits" do
    test "throttle once the GCRA limit is exceeded, before any rule runs", %{limen: limen} do
      conns = for n <- 0..3, do: request([], monotonic: 1_000_000_000 + n)
      [first, second, third, fourth] = Enum.map(conns, &decide(limen, Limited, &1, :enforce))

      assert first.action == :allow
      assert second.action == :allow
      assert %Decision{action: :throttle, stage: :limit, enforced: true} = third
      assert third.params.retry_after == 1
      assert [%{kind: :limit, name: :per_client, condition: condition}] = third.matches
      assert condition == "2 per second by prefix, burst 1"
      assert fourth.action == :throttle
    end

    test "respond with 429 and Retry-After", %{limen: limen} do
      for _request <- 1..2,
          do: Limen.Plug.call(request(), Limen.Plug.init(instance: limen, policy: Limited))

      conn =
        Limen.Plug.call(
          request(),
          Limen.Plug.init(instance: limen, policy: Limited, mode: :enforce)
        )

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["1"]
    end
  end

  describe "compile-time validation" do
    defp compile(body) do
      Code.compile_string("""
      defmodule Limen.PolicyTest.Compiled#{System.unique_integer([:positive])} do
        use Limen.Policy
        #{body}
      end
      """)
    end

    test "unknown signal keys" do
      assert_raise CompileError, ~r/no signal of this policy provides :fcrdns/, fn ->
        compile("allow :crawler, when: signal(:fcrdns) == :verified")
      end
    end

    test "invalid rate windows and dimensions" do
      assert_raise CompileError, ~r/rate\/2 expects/, fn ->
        compile("score :x, 1, when: rate(:prefix, per: :day) > 1")
      end

      assert_raise CompileError, ~r/rate\/2 expects/, fn ->
        compile("score :x, 1, when: rate(:user, per: :second) > 1")
      end
    end

    test "duplicate names, missing conditions, bad weights and limits" do
      assert_raise CompileError, ~r/duplicate rule names: \[:x\]/, fn ->
        compile("score :x, 1, when: true\nscore :x, 2, when: false")
      end

      assert_raise CompileError, ~r/expects a rule name and `when: condition`/, fn ->
        compile("allow :x, if: true")
      end

      assert_raise CompileError, ~r/integer weight/, fn ->
        compile("score :x, 1.5, when: true")
      end

      assert_raise CompileError, ~r/limit expects/, fn -> compile("limit :x, key: :prefix") end

      assert_raise CompileError, ~r/unknown options/, fn ->
        compile("allow :x, when: true, ban: 1")
      end
    end

    test "signal modules must implement the behaviour" do
      assert_raise CompileError, ~r/does not implement the Limen.Signal behaviour/, fn ->
        Code.compile_string("""
        defmodule Limen.PolicyTest.BadSignals do
          use Limen.Policy, signals: [String]
        end
        """)
      end
    end
  end

  test "describe/1 renders the policy" do
    text = Policy.describe(Scoring)

    assert text =~ "Limen.Test.Policies.Scoring (signals: Limen.Signal.HttpShape"
    assert text =~ "deny bad_ja4 when signal(:ja4) in list(:test_bad_ja4), ban 60s"
    assert text =~ "score -50 trusted_header when header(\"x-test-trust\") == \"yes\""
    assert text =~ "    score >= 70 -> {:deny, ban: 30}"
    assert Policy.describe(Limited) =~ "limit per_client: 2 per second by prefix, burst 1"
  end

  defmodule Ordering do
    use Limen.Policy

    score :few_assets, 10, when: signal(:asset_ratio) < 0.2
    score :many_assets, 20, when: signal(:asset_ratio) > 0.8
    score :between, 40, when: 0.1 <= signal(:asset_ratio) and signal(:asset_ratio) <= 0.9
    score :fewer_pages, 80, when: signal(:pages_per_minute) < signal(:assets_per_minute)

    decide do
      true -> :allow
    end
  end

  test "ordering comparisons with a missing value are false" do
    assert Policy.evaluate(Ordering, %Context{}).score == 0

    ctx = %Context{signals: %{asset_ratio: 0.5, pages_per_minute: 1, assets_per_minute: 2}}
    assert Policy.evaluate(Ordering, ctx).score == 120

    ctx = %Context{signals: %{asset_ratio: 0.95}}

    assert %{score: 20, matches: [%{observed: [{"signal(:asset_ratio)", 0.95}]}]} =
             Policy.evaluate(Ordering, ctx)
  end

  test "evaluate/2 works on a bare context" do
    result = Policy.evaluate(Scoring, %Context{headers: [{"accept-language", "en"}]})
    assert %{action: :allow, stage: :decide, score: 0} = result
  end
end
