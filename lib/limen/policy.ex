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

  A policy compiles to plain functions: evaluating a request is one call into
  the policy module, which checks its rules with local calls.

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
    * `fact(key)` - a fact the application stated about the request, such
      as `fact(:signed_in)`, or `nil`; see `Limen.put_facts/2`.
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

    * `:signals` - signal modules the policy can use. Defaults to
      `Limen.Signal.defaults/0`. Only the values of these signals (and the
      client identity) can be referenced, and only the modules providing a
      value the policy refers to are collected.
    * `:mode` - `:dry_run` or `:enforce` for routes using this policy, unless
      the route itself sets a mode. Defaults to the global mode.

  ## Explanations

  For every rule that matched, the decision records the source of its
  condition and the value of every helper it used, so `Limen.Decision.explain/1`
  shows exactly why a request was treated the way it was. `describe/1`
  renders the policy itself.
  """

  use Limen.Boundary,
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

    # Described once here, rather than for every request it throttles.
    if valid_limit?(limit) do
      Map.put(limit, :condition, Runtime.describe_limit(limit))
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
    scope = scope(signals, env)
    compiled = Enum.map(rules, &compile_rule(&1, scope))
    {decide_ast, clauses} = Compiler.decide(decide, scope.ctx, scope.provided, env)

    metadata =
      %{rules: Enum.map(compiled, & &1.meta)}
      |> Map.merge(references(compiled, decide, signals, scope))
      |> Map.merge(%{limits: limits, mode: Keyword.get(opts, :mode), clauses: clauses})

    [
      metadata_function(metadata),
      evaluate_function(compiled, scope.ctx),
      Enum.map(compiled, &rule_function(&1, scope.ctx)),
      Enum.map(compiled, &match_function(&1, scope.ctx)),
      decide_function(decide_ast, scope)
    ]
  end

  # What compiling a condition needs: the variables generated functions bind,
  # the signal values the policy can refer to, and where it is compiled.
  defp scope(signals, env) do
    %{
      ctx: Macro.var(:ctx, __MODULE__),
      score: Compiler.score(),
      provided: MapSet.new(Enum.flat_map(signals, & &1.provides())),
      env: env
    }
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

  # The rates to track and the signals to collect, from what the rules and the
  # decide block refer to.
  defp references(compiled, decide, signals, scope) do
    %{rates: rates, signals: keys} =
      Enum.reduce(compiled, decide_references(decide, scope), &merge_references/2)

    %{rates: Enum.sort(rates), signals: collected(signals, keys)}
  end

  defp merge_references(%{rates: rates, signals: signals}, acc) do
    %{rates: MapSet.union(acc.rates, rates), signals: MapSet.union(acc.signals, signals)}
  end

  # A signal that provides none of the values the policy refers to is not
  # collected: it could not change the decision.
  defp collected(signals, keys) do
    Enum.filter(signals, fn signal -> Enum.any?(signal.provides(), &MapSet.member?(keys, &1)) end)
  end

  defp metadata_function(metadata) do
    for {key, value} <- metadata do
      quote do
        @doc false
        def __limen__(unquote(key)), do: unquote(Macro.escape(value))
      end
    end
  end

  # Evaluating a request is a single call into the policy, which checks its
  # rules with local calls in the order they are written.
  defp evaluate_function(compiled, ctx) do
    {short_circuit, scored} =
      Enum.split_with(compiled, &(&1.meta.kind in [:allow, :deny, :maze]))

    scoring =
      quote do
        score = 0
        matches = []
        unquote_splicing(Enum.map(scored, &score_rule(&1.meta, ctx)))
        {clause, result} = __decide__(score, unquote(ctx))
        {action, params} = Limen.Decision.normalize(result)

        %{
          action: action,
          params: params,
          stage: :decide,
          score: score,
          matches: :lists.reverse(matches),
          clause: clause,
          errors: errors
        }
      end

    body = List.foldr(short_circuit, scoring, &short_circuit_rule(&1.meta, &2, ctx))

    quote do
      unquote(inline(compiled))

      @doc false
      def __evaluate__(unquote(ctx)) do
        errors = []
        unquote(body)
      end
    end
  end

  # Inlined, each call keeps only the clause of the rule it names.
  defp inline([]), do: nil
  defp inline(_compiled), do: quote(do: @compile({:inline, __rule__: 2, __match__: 2}))

  # The first allow, deny or maze rule that matches settles the request.
  defp short_circuit_rule(%{name: name, kind: kind, opts: opts}, next, ctx) do
    params = if opts[:ban], do: %{ban: opts.ban}, else: %{}

    quote do
      case __rule__(unquote(name), unquote(ctx)) do
        true ->
          %{
            action: unquote(kind),
            params: unquote(Macro.escape(params)),
            stage: :rule,
            score: 0,
            matches: [__match__(unquote(name), unquote(ctx))],
            clause: nil,
            errors: errors
          }

        result ->
          errors =
            case result do
              false -> errors
              {:error, error} -> [error | errors]
            end

          unquote(next)
      end
    end
  end

  # Every score rule that matches adds its weight.
  defp score_rule(%{name: name, weight: weight}, ctx) do
    quote do
      {score, matches, errors} =
        case __rule__(unquote(name), unquote(ctx)) do
          true ->
            {score + unquote(weight), [__match__(unquote(name), unquote(ctx)) | matches], errors}

          false ->
            {score, matches, errors}

          {:error, error} ->
            {score, matches, [error | errors]}
        end
    end
  end

  defp decide_function(decide_ast, %{score: score, ctx: ctx}) do
    quote do
      defp __decide__(unquote(score), unquote(ctx)) do
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

    %{
      meta: meta,
      expanded: expanded,
      observed: observed,
      rates: info.rates,
      signals: info.signals
    }
  end

  # A rule whose condition raises does not match; the error is recorded.
  defp rule_function(%{meta: %{name: name}, expanded: expanded}, ctx) do
    quote do
      defp __rule__(unquote(name), unquote(ctx)) do
        _bound = unquote(ctx)
        if unquote(expanded), do: true, else: false
      rescue
        exception -> {:error, {:rule, unquote(name), Exception.message(exception)}}
      end
    end
  end

  # A matching rule records its condition and the value of every helper the
  # condition used.
  defp match_function(%{meta: meta, observed: observed}, ctx) do
    values =
      Enum.map(observed, fn {source, ast} -> quote(do: {unquote(source), unquote(ast)}) end)

    quote do
      defp __match__(unquote(meta.name), unquote(ctx)) do
        _bound = unquote(ctx)

        observed =
          try do
            unquote(values)
          rescue
            exception -> [{"error", Exception.message(exception)}]
          end

        %Limen.Decision.Match{
          name: unquote(meta.name),
          kind: unquote(meta.kind),
          weight: unquote(meta.weight),
          condition: unquote(meta.condition),
          observed: observed
        }
      end
    end
  end

  defp default_decide do
    quote do
      score >= 60 -> {:challenge, difficulty: difficulty_for(score)}
      true -> :allow
    end
  end

  # Rates and signals referenced from `decide` must be tracked and collected
  # too.
  defp decide_references(clauses, scope) do
    clauses
    |> Enum.flat_map(fn {:->, _meta, [[condition], result]} -> [condition, result] end)
    |> Enum.map(&elem(Compiler.expand(&1, scope.ctx, scope.provided, scope.env), 1))
    |> Enum.reduce(%{rates: MapSet.new(), signals: MapSet.new()}, &merge_references/2)
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
  def evaluate(policy, %Context{} = ctx), do: policy.__evaluate__(ctx)

  @doc """
  Renders `policy` for humans.
  """
  @spec describe(module()) :: String.t()
  def describe(policy) do
    signals = Enum.map_join(policy.__limen__(:signals), ", ", &inspect/1)
    mode = if policy.__limen__(:mode), do: ", mode: #{policy.__limen__(:mode)}", else: ""

    limits =
      for limit <- policy.__limen__(:limits) do
        "  limit #{limit.name}: #{limit.condition}"
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
