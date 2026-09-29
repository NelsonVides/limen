defmodule Limen.ParamsTest do
  use Limen.Case, async: true

  alias Limen.{Context, Decision, Policy}

  defmodule Tunable do
    use Limen.Policy,
      signals: [Limen.Signal.HttpShape],
      params: [
        tool_weight: 30,
        lenient_weight: -10,
        challenge_at: 40,
        difficulty: 12,
        tools: [:tool]
      ]

    score :tool_user_agent, param(:tool_weight), when: signal(:ua_family) in param(:tools)
    score :lenient, param(:lenient_weight), when: header("x-lenient") == "yes"

    decide do
      score >= param(:challenge_at) -> {:challenge, difficulty: param(:difficulty)}
      true -> :allow
    end
  end

  defp decide(limen, headers \\ [{"user-agent", "curl/8.5.0"}]) do
    conn = %{conn(:get, "/") | req_headers: headers}
    Limen.decision(Limen.Plug.call(conn, Limen.Plug.init(instance: limen, policy: Tunable)))
  end

  test "parameters take their defaults", %{limen: limen} do
    decision = decide(limen)

    assert %Decision{action: :allow, score: 30} = decision
    assert [%{name: :tool_user_agent, weight: 30} = match] = decision.matches

    assert match.observed == [
             {"signal(:ua_family)", :tool},
             {"param(:tools)", [:tool]},
             {"param(:tool_weight)", 30}
           ]
  end

  @tag config: [params: [tool_weight: 50, difficulty: 14]]
  test "the instance's :params override them, and every value used is recorded", %{limen: limen} do
    decision = decide(limen)

    assert %Decision{action: :challenge, params: %{difficulty: 14}, score: 50} = decision
    assert [%{weight: 50}] = decision.matches

    assert decision.clause ==
             "score >= param(:challenge_at) -> {:challenge, difficulty: param(:difficulty)}"

    assert decision.clause_observed == [{"param(:challenge_at)", 40}, {"param(:difficulty)", 14}]

    explained = Decision.explain(decision)
    assert explained =~ "score tool_user_agent +50 when signal(:ua_family) in param(:tools)"
    assert explained =~ "[param(:challenge_at) = 40, param(:difficulty) = 14]"

    # And change at runtime.
    Limen.update_config(limen, :params, challenge_at: 60)
    assert %Decision{action: :allow, clause: "true -> :allow"} = decide(limen)
    assert instance(limen).config.params == %{tool_weight: 50, difficulty: 14, challenge_at: 60}
  end

  @tag config: [params: [lenient_weight: "much", tools: [:chrome]]]
  test "weights that are not integers fall back to their defaults", %{limen: limen} do
    decision = decide(limen, [{"x-lenient", "yes"}])

    assert [%{name: :lenient, weight: -10, observed: observed}] = decision.matches
    assert {"param(:lenient_weight)", -10} in observed
    assert Decision.explain(decision) =~ "score lenient -10 when"
  end

  test "describe/1 lists the parameters and their defaults" do
    text = Policy.describe(Tunable)
    assert text =~ "  param challenge_at, default 40"
    assert text =~ "  score param(:tool_weight) tool_user_agent when"
  end

  test "parameters work on a bare context" do
    assert %{score: 30} = Policy.evaluate(Tunable, %Context{signals: %{ua_family: :tool}})
  end

  test "parameters must be declared, and weights default to integers" do
    compile = fn opts, body ->
      Code.compile_string("""
      defmodule Limen.ParamsTest.Compiled#{System.unique_integer([:positive])} do
        use Limen.Policy, #{opts}
        #{body}
      end
      """)
    end

    assert_raise CompileError, ~r/declares no parameter :missing. Declared: :x/, fn ->
      compile.("params: [x: 1]", "allow :a, when: param(:missing) == 1")
    end

    assert_raise CompileError, ~r/declares no parameter :w/, fn ->
      compile.("params: []", "score :a, param(:w), when: true")
    end

    assert_raise CompileError, ~r/whose default must be an integer/, fn ->
      compile.("params: [w: 1.5]", "score :a, param(:w), when: true")
    end

    assert_raise CompileError, ~r/declares no parameter :t/, fn ->
      compile.("params: []", "decide do\n score >= param(:t) -> :deny\n end")
    end
  end
end
