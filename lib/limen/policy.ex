defmodule Limen.Policy do
  @moduledoc """
  A compiled DSL for bot policies.

      defmodule MyApp.BotPolicy do
        use Limen.Policy

        limit :flood, key: :prefix, rate: 50, per: :second, burst: 100

        allow :office, when: signal(:client_ip) in list(:office_networks)
        deny :known_bad_ja4, when: signal(:ja4) in list(:bad_ja4), ban: 3_600

        score :no_accept_language, 20, when: missing_header("accept-language")
        score :datacenter_asn, 30, when: signal(:asn_kind) == :hosting
        score :spoofed_browser, 40, when: shape_flag(:no_client_hints)
        score :burst, 40, when: rate(:prefix, per: :second) > 20

        decide do
          score >= 80 -> :deny
          score >= 40 -> {:challenge, difficulty: difficulty_for(score)}
          true -> :allow
        end
      end

  Every rule compiles to a plain function at compile time; evaluating a
  policy is a handful of function calls and map lookups.

  ## Evaluation

    1. `limit` rules are checked first, for every request the policy covers,
       including clients holding a valid pass. The first exceeded limit
       throttles the request.
    2. `allow`, `deny` and `maze` rules are checked in the order they are
       written; the first that matches settles the request.
    3. Every `score` rule that matches adds its weight (which may be negative)
       to the score.
    4. The first `decide` clause whose condition holds picks the action. With
       no `decide` block, requests scoring 60 or more are challenged.

  A rule whose condition raises does not match; the error is recorded in the
  decision.

  ## Rules

    * `limit name, key: dimension, rate: n, per: window, burst: b` - a hard
      GCRA limit (see `Limen.State.Gcra`) of `n` requests per window
      (`:second`, `:minute`, `:hour` or milliseconds) per `dimension`,
      allowing `b` extra requests at once (default `0`). Exceeding it
      throttles with `Retry-After`.
    * `allow name, when: condition` - allow and stop.
    * `deny name, when: condition` - deny and stop. With `ban: seconds`, the
      prefix is also banned.
    * `maze name, when: condition` - send the client to the maze (see
      `Limen.Maze`) and stop. With `ban: seconds`, the prefix is also flagged,
      so every later request goes to the maze too.
    * `score name, weight, when: condition` - add `weight` to the score.

  ## Conditions

  Conditions are Elixir expressions that can use these helpers:

    * `signal(key)` - a signal value, see `Limen.Signal`. Unknown keys are
      compile errors.
    * `header(name)`, `missing_header(name)`, `has_header(name)`.
    * `shape_flag(flag)` - whether `Limen.Signal.HttpShape` raised `flag`.
    * `rate(dimension, per: window)` - requests the policy saw in the sliding
      `:second`, `:minute` or `:hour` from this client's `:prefix`,
      `:client_ip`, `:ja4`, or from everyone (`:global`).
    * `value in list(name)` - membership in a `Limen.Lists` list.
    * `path()`, `method()`, `host()`, `query()`.

  A signal that was not collected, or has no value for this request, is
  `nil`. Comparing it with `<`, `<=`, `>` or `>=` is false, so
  `signal(:asset_ratio) > 0.8` does not hold for a client that has fetched no
  pages yet.

  In `decide`, `score` is the total score and `difficulty_for(score)` (or
  `difficulty_for(score, opts)`, see `Limen.Policy.Runtime.difficulty_for/2`)
  maps it to a challenge difficulty. Actions are those of `Limen.Decision`,
  with options: `:deny`, `{:deny, ban: 600}`, `{:challenge, difficulty: 18}`,
  `{:throttle, retry_after: 30}`, `{:tarpit, delay: 5_000}`, `:maze`,
  `{:maze, ban: 86_400}`.

  ## Options

    * `:signals` - signal modules to collect. Defaults to
      `Limen.Signal.defaults/0`. Only the values of these signals (and the
      client identity) can be referenced.
    * `:mode` - `:dry_run` or `:enforce` for routes using this policy, unless
      the route itself sets a mode. Defaults to the global mode.

  ## Explanations

  For every rule that matched, the decision records the source of its
  condition and the value of every helper it used, so `Limen.Decision.explain/1`
  shows exactly why a request was treated the way it was. `describe/1`
  renders the policy itself.
  """

  use Boundary,
    type: :strict,
    deps: [Limen.Context, Limen.Decision, Limen.IP, Limen.Lists, Limen.Signal, Limen.State],
    exports: [Default, Runtime]

  alias Limen.{Context, Decision}
  alias Limen.Decision.Match
  alias Limen.Policy.{Compiler, Runtime}

  @type result :: %{
          action: Decision.action(),
          params: map(),
          stage: :rule | :decide,
          score: integer(),
          matches: [Match.t()],
          clause: String.t() | nil,
          errors: [term()]
        }

  @doc false
  defmacro __using__(opts) do
    quote do
      import Limen.Policy, only: [allow: 2, deny: 2, maze: 2, score: 3, limit: 2, decide: 1]
      Module.register_attribute(__MODULE__, :limen_rules, accumulate: true)
      Module.register_attribute(__MODULE__, :limen_limits, accumulate: true)
      Module.register_attribute(__MODULE__, :limen_decide, [])
      @limen_opts unquote(opts)
      @before_compile Limen.Policy
    end
  end

  @doc """
  Allows the request when `condition` holds, skipping scoring.
  """
  defmacro allow(name, opts), do: rule(:allow, name, 0, opts, __CALLER__)

  @doc """
  Denies the request when `condition` holds, skipping scoring.
  """
  defmacro deny(name, opts), do: rule(:deny, name, 0, opts, __CALLER__)

  @doc """
  Sends the client to the maze when `condition` holds, skipping scoring.
  """
  defmacro maze(name, opts), do: rule(:maze, name, 0, opts, __CALLER__)

  @doc """
  Adds `weight` to the score when `condition` holds.
  """
  defmacro score(name, weight, opts) do
    # A negative literal reaches the macro as a unary minus call.
    weight =
      case weight do
        {:-, _meta, [n]} when is_integer(n) -> -n
        weight -> weight
      end

    unless is_integer(weight) do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "score #{inspect(name)} expects an integer weight"
    end

    rule(:score, name, weight, opts, __CALLER__)
  end

  @doc """
  Declares a hard rate limit.
  """
  defmacro limit(name, opts) do
    limit = build_limit(name, opts, __CALLER__)
    quote(do: @limen_limits(unquote(Macro.escape(limit))))
  end

  @doc """
  Maps the total score to an action.
  """
  defmacro decide(do: clauses) do
    quote(do: @limen_decide(unquote(Macro.escape(clauses))))
  end

  defp rule(kind, name, weight, opts, caller) do
    unless is_atom(name) and Keyword.keyword?(opts) and Keyword.has_key?(opts, :when) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "#{kind} expects a rule name and `when: condition`"
    end

    {condition, extra} = Keyword.pop(opts, :when)

    allowed = if kind in [:deny, :maze], do: [:ban], else: []

    unless Enum.all?(Keyword.keys(extra), &(&1 in allowed)) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "unknown options for #{kind} #{inspect(name)}: #{inspect(Keyword.keys(extra))}"
    end

    rule = {kind, name, weight, condition, caller.line, extra}
    quote(do: @limen_rules(unquote(Macro.escape(rule))))
  end

  defp build_limit(name, opts, caller) do
    limit = %{
      name: name,
      key: opts[:key],
      rate: opts[:rate],
      period: period(opts[:per]),
      burst: Keyword.get(opts, :burst, 0)
    }

    if valid_limit?(limit) do
      limit
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "limit expects `limit name, key: :prefix | :client_ip | :ja4 | :global, " <>
            "rate: positive integer, per: :second | :minute | :hour | milliseconds, burst: integer`"
    end
  end

  defp period(:second), do: 1_000
  defp period(:minute), do: 60_000
  defp period(:hour), do: 3_600_000
  defp period(ms) when is_integer(ms) and ms > 0, do: ms
  defp period(_invalid), do: nil

  defp valid_limit?(%{name: name, key: key, rate: rate, period: period, burst: burst}) do
    is_atom(name) and key in [:prefix, :client_ip, :ja4, :global] and is_integer(rate) and
      rate > 0 and period != nil and is_integer(burst) and burst >= 0
  end

  @doc false
  defmacro __before_compile__(env) do
    %{opts: opts, rules: rules, limits: limits, decide: decide} = definitions(env)
    signals = signal_modules(opts, env)

    scope = %{
      ctx: Macro.var(:ctx, __MODULE__),
      score: Compiler.score(),
      provided: MapSet.new(Enum.flat_map(signals, & &1.provides())),
      env: env
    }

    compiled = Enum.map(rules, &compile_rule(&1, scope))
    {decide_ast, clauses} = Compiler.decide(decide, scope.ctx, scope.provided, env)

    metadata =
      compiled
      |> Enum.map(& &1.meta)
      |> rule_metadata()
      |> Map.merge(%{
        limits: limits,
        rates: rates(compiled, decide, scope),
        signals: signals,
        mode: Keyword.get(opts, :mode),
        clauses: clauses
      })

    [
      metadata_function(metadata),
      Enum.map(compiled, &rule_function(&1, scope.ctx)),
      Enum.map(compiled, &observe_function(&1, scope.ctx)),
      decide_function(decide_ast, scope)
    ]
  end

  defp definitions(env) do
    rules = Enum.reverse(Module.get_attribute(env.module, :limen_rules))
    limits = Enum.reverse(Module.get_attribute(env.module, :limen_limits))
    validate_names!(rules, limits, env)

    %{
      opts: Module.get_attribute(env.module, :limen_opts),
      rules: rules,
      limits: limits,
      decide: Module.get_attribute(env.module, :limen_decide) || default_decide()
    }
  end

  # Rules are split once here, so that evaluating a request does not.
  defp rule_metadata(rules) do
    {short_circuit, scored} = Enum.split_with(rules, &(&1.kind in [:allow, :deny, :maze]))
    %{rules: rules, short_circuit: short_circuit, scored: scored}
  end

  defp rates(compiled, decide, scope) do
    compiled
    |> Enum.reduce(decide_rates(decide, scope), &MapSet.union(&1.rates, &2))
    |> Enum.sort()
  end

  defp metadata_function(metadata) do
    for {key, value} <- metadata do
      quote do
        @doc false
        def __limen__(unquote(key)), do: unquote(Macro.escape(value))
      end
    end
  end

  defp decide_function(decide_ast, %{score: score, ctx: ctx}) do
    quote do
      @doc false
      def __decide__(unquote(score), unquote(ctx)) do
        _bound = {unquote(score), unquote(ctx)}
        unquote(decide_ast)
      end
    end
  end

  defp compile_rule({kind, name, weight, condition, line, extra}, scope) do
    {expanded, info} = Compiler.expand(condition, scope.ctx, scope.provided, scope.env)

    observed =
      for {source, ast} <- info.observed do
        {source, Compiler.expand_observed(ast, scope.ctx, scope.provided, scope.env)}
      end

    meta = %{
      name: name,
      kind: kind,
      weight: weight,
      condition: Compiler.source(condition),
      line: line,
      opts: Map.new(extra)
    }

    %{meta: meta, expanded: expanded, observed: observed, rates: info.rates}
  end

  defp rule_function(%{meta: %{name: name}, expanded: expanded}, ctx) do
    quote do
      @doc false
      def __rule__(unquote(name), unquote(ctx)) do
        _bound = unquote(ctx)
        if unquote(expanded), do: true, else: false
      end
    end
  end

  defp observe_function(%{meta: %{name: name}, observed: observed}, ctx) do
    values =
      Enum.map(observed, fn {source, ast} -> quote(do: {unquote(source), unquote(ast)}) end)

    quote do
      @doc false
      def __observe__(unquote(name), unquote(ctx)) do
        _bound = unquote(ctx)
        unquote(values)
      end
    end
  end

  defp default_decide do
    quote do
      score >= 60 -> {:challenge, difficulty: difficulty_for(score)}
      true -> :allow
    end
  end

  # Rates referenced from `decide` must be tracked too.
  defp decide_rates(clauses, scope) do
    clauses
    |> Enum.flat_map(fn {:->, _meta, [[condition], result]} -> [condition, result] end)
    |> Enum.map(fn ast ->
      elem(Compiler.expand(ast, scope.ctx, scope.provided, scope.env), 1).rates
    end)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp signal_modules(opts, env) do
    modules =
      case Keyword.fetch(opts, :signals) do
        {:ok, modules} -> Enum.map(modules, &Macro.expand(&1, env))
        :error -> Limen.Signal.defaults()
      end

    for module <- modules do
      Code.ensure_compiled!(module)

      unless function_exported?(module, :provides, 0) and function_exported?(module, :collect, 1) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "#{inspect(module)} does not implement the Limen.Signal behaviour"
      end

      module
    end
  end

  defp validate_names!(rules, limits, env) do
    names = Enum.map(rules, &elem(&1, 1)) ++ Enum.map(limits, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "duplicate rule names: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  @doc """
  Evaluates the allow, deny and score rules of `policy` and its `decide`
  block against `ctx`.

  Limits are checked separately, see `Limen.Policy.Runtime.check_limits/2`.
  """
  @spec evaluate(module(), Context.t()) :: result()
  def evaluate(policy, %Context{} = ctx) do
    case first_match(policy, policy.__limen__(:short_circuit), ctx, []) do
      {:matched, rule, match, errors} ->
        params = if rule.opts[:ban], do: %{ban: rule.opts.ban}, else: %{}

        %{
          action: rule.kind,
          params: params,
          stage: :rule,
          score: 0,
          matches: [match],
          clause: nil,
          errors: errors
        }

      {:none, errors} ->
        {score, matches, errors} = sum_scores(policy, policy.__limen__(:scored), ctx, errors)
        {clause, result} = policy.__decide__(score, ctx)
        {action, params} = Decision.normalize(result)

        %{
          action: action,
          params: params,
          stage: :decide,
          score: score,
          matches: matches,
          clause: clause,
          errors: errors
        }
    end
  end

  defp first_match(_policy, [], _ctx, errors), do: {:none, errors}

  defp first_match(policy, [rule | rest], ctx, errors) do
    case check(policy, rule, ctx) do
      {:ok, true} -> {:matched, rule, match(policy, rule, ctx), errors}
      {:ok, false} -> first_match(policy, rest, ctx, errors)
      {:error, error} -> first_match(policy, rest, ctx, [error | errors])
    end
  end

  defp sum_scores(policy, rules, ctx, errors) do
    {score, matches, errors} =
      Enum.reduce(rules, {0, [], errors}, fn rule, {score, matches, errors} ->
        case check(policy, rule, ctx) do
          {:ok, true} -> {score + rule.weight, [match(policy, rule, ctx) | matches], errors}
          {:ok, false} -> {score, matches, errors}
          {:error, error} -> {score, matches, [error | errors]}
        end
      end)

    {score, Enum.reverse(matches), errors}
  end

  defp check(policy, rule, ctx) do
    {:ok, policy.__rule__(rule.name, ctx)}
  rescue
    exception -> {:error, {:rule, rule.name, Exception.message(exception)}}
  end

  defp match(policy, rule, ctx) do
    observed =
      try do
        policy.__observe__(rule.name, ctx)
      rescue
        exception -> [{"error", Exception.message(exception)}]
      end

    %Match{
      name: rule.name,
      kind: rule.kind,
      weight: rule.weight,
      condition: rule.condition,
      observed: observed
    }
  end

  @doc """
  Renders `policy` for humans.
  """
  @spec describe(module()) :: String.t()
  def describe(policy) do
    signals = Enum.map_join(policy.__limen__(:signals), ", ", &inspect/1)
    mode = if policy.__limen__(:mode), do: ", mode: #{policy.__limen__(:mode)}", else: ""

    limits =
      for limit <- policy.__limen__(:limits) do
        "  limit #{limit.name}: #{Runtime.describe_limit(limit)}"
      end

    rules =
      for rule <- policy.__limen__(:rules) do
        weight = if rule.kind == :score, do: " #{format_weight(rule.weight)}", else: ""
        ban = if rule.opts[:ban], do: ", ban #{rule.opts.ban}s", else: ""
        "  #{rule.kind}#{weight} #{rule.name} when #{rule.condition}#{ban}"
      end

    clauses = for clause <- policy.__limen__(:clauses), do: "    #{clause}"

    Enum.join(
      ["#{inspect(policy)} (signals: #{signals}#{mode})"] ++
        limits ++ rules ++ ["  decide:"] ++ clauses,
      "\n"
    )
  end

  defp format_weight(weight) when weight >= 0, do: "+#{weight}"
  defp format_weight(weight), do: "#{weight}"
end
