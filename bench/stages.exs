# Where the full path spends its time, stage by stage.
#
#     MIX_ENV=bench mix run bench/stages.exs
#
# Job k runs the first k stages of `Limen.Plug` on the full path (default
# policy, a new Chrome client behind a trusted proxy on every request), so a
# stage costs the difference with the job before it. Stages that update state
# run for real, as in a request. The stages mirror the order of
# `Limen.Plug.call/2`; keep them in step when it changes.

Code.require_file("scenarios.exs", __DIR__)

defmodule Limen.Bench.Stages do
  @moduledoc false

  alias Limen.Challenge.Pass
  alias Limen.{Context, Decision, Gate, Instance, Policy, Signal}
  alias Limen.Policy.Runtime
  alias Limen.Signal.Behaviour
  alias Limen.State.BanList

  @policy Limen.Policy.Default

  @doc """
  The stages of the full path in order, as `{name, step}`. A step takes and
  returns the state of the request.
  """
  def all, do: identity() ++ signals() ++ decision()

  defp identity do
    [
      {"instance lookup", &lookup/1},
      {"context from conn", &context/1},
      {"identify: address, prefix, JA4", &identify/1},
      {"behaviour tracking", &track/1},
      {"ban lookup", &ban/1},
      {"rate tracking", &rates/1},
      {"limits", &limits/1},
      {"pass cookie, none sent", &pass/1}
    ]
  end

  defp signals do
    for signal <- @policy.__limen__(:signals) do
      {"collect #{inspect(signal)}", &%{&1 | ctx: signal.collect(&1.ctx)}}
    end
  end

  defp decision do
    [
      {"policy evaluation", &evaluate/1},
      {"decision and finalize", &decide/1},
      {"emit", &emit/1}
    ]
  end

  @doc """
  Runs `steps` over a request.
  """
  def run(steps, conn) do
    state = %{conn: conn, instance: nil, ctx: nil, result: nil, decision: nil}
    Enum.reduce(steps, state, fn {_name, step}, state -> step.(state) end)
  end

  defp lookup(state), do: %{state | instance: Instance.fetch!(:limen_bench)}
  defp context(state), do: %{state | ctx: Context.from_conn(state.conn, state.instance)}
  defp identify(state), do: %{state | ctx: Signal.identify(state.ctx, state.instance.config)}

  defp track(state) do
    {conn, ctx} = Behaviour.track(state.conn, state.ctx)
    %{state | conn: conn, ctx: ctx}
  end

  defp ban(state) do
    _ban = BanList.lookup(state.instance, state.ctx.prefix, state.ctx.now)
    state
  end

  defp rates(state), do: %{state | ctx: Runtime.track(@policy, state.ctx)}

  defp limits(state) do
    _result = Runtime.check_limits(@policy, state.ctx)
    state
  end

  defp pass(state) do
    _result = Pass.verify(state.ctx)
    state
  end

  defp evaluate(state), do: %{state | result: Policy.evaluate(@policy, state.ctx)}

  defp decide(%{result: result} = state) do
    decision =
      %Decision{
        action: result.action,
        params: result.params,
        stage: result.stage,
        mode: :dry_run,
        policy: @policy,
        score: result.score,
        matches: result.matches,
        clause: result.clause,
        errors: result.errors
      }
      |> Gate.finalize(state.ctx, System.monotonic_time())

    %{state | decision: decision}
  end

  defp emit(state) do
    Gate.emit(state.decision, state.conn, state.instance)
    %{state | conn: Plug.Conn.put_private(state.conn, :limen, state.decision)}
  end
end

alias Limen.Bench.{Scenarios, Stages}

Scenarios.setup()
Scenarios.restart(Scenarios.proxied())
next_client = Scenarios.next_client()
opts = Limen.Plug.init(instance: :limen_bench)
batch = Scenarios.batch()
repeat = fn f -> fn -> Enum.each(1..batch, fn _n -> f.() end) end end
stages = Stages.all()

# Job 0 only takes the next client: the loop's own cost.
jobs =
  for k <- 0..length(stages), into: %{} do
    steps = Enum.take(stages, k)
    {k, repeat.(fn -> Stages.run(steps, next_client.()) end)}
  end

jobs = Map.put(jobs, :plug, repeat.(fn -> Limen.Plug.call(next_client.(), opts) end))

suite =
  Benchee.run(Map.new(jobs, fn {k, job} -> {to_string(k), job} end),
    time: 3,
    warmup: 1,
    print: [configuration: false, benchmarking: false],
    formatters: []
  )

median = Map.new(suite.scenarios, &{&1.name, &1.run_time_data.statistics.median / batch})
format = &"#{round(&1)} ns"

rows =
  for {{name, _step}, k} <- Enum.with_index(stages, 1) do
    cumulative = median[to_string(k)]
    "| #{name} | #{format.(cumulative - median[to_string(k - 1)])} | #{format.(cumulative)} |"
  end

Mix.shell().info("""
| Stage | Cost | Cumulative |
|---|---|---|
| loop and next client | #{format.(median["0"])} | #{format.(median["0"])} |
#{Enum.join(rows, "\n")}

Limen.Plug.call/2 on the same requests: #{format.(median["plug"])}\
""")
