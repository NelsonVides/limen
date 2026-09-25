defmodule Limen.Policy.Compiler do
  @moduledoc false
  # Turns the conditions of a policy into plain Elixir, validating every
  # helper call at compile time and recording what each condition observes.

  alias Limen.Policy.Runtime

  @identity_keys [:client_ip, :prefix, :ja4, :user_agent]
  @dimensions [:prefix, :client_ip, :ja4, :global]
  @windows [:second, :minute, :hour]
  @request_fields [:path, :method, :host, :query]

  # `score` in a decide block, bound by `__decide__/2` to the total score.
  @score Macro.var(:score, __MODULE__)

  @type info :: %{
          signals: MapSet.t(atom()),
          rates: MapSet.t({atom(), atom()}),
          observed: [{String.t(), Macro.t()}]
        }

  @doc """
  The signal keys every policy can use, whatever its signal modules.
  """
  @spec identity_keys() :: [atom()]
  def identity_keys, do: @identity_keys

  @doc """
  The variable `__decide__/2` binds the total score to.
  """
  @spec score() :: Macro.t()
  def score, do: @score

  @doc """
  Expands the helpers in `ast`, raising on invalid uses.

  `provided` is the set of signal keys the policy's signal modules provide.
  Returns the expanded expression and what it references.
  """
  @spec expand(Macro.t(), Macro.t(), MapSet.t(atom()), Macro.Env.t()) :: {Macro.t(), info()}
  def expand(ast, ctx, provided, env) do
    info = %{signals: MapSet.new(), rates: MapSet.new(), observed: []}
    {expanded, info} = Macro.prewalk(ast, info, &expand_node(&1, &2, ctx, provided, env))
    {expanded, %{info | observed: Enum.reverse(Enum.uniq_by(info.observed, &elem(&1, 0)))}}
  end

  @doc """
  Expands an observed helper call again, on its own, for `__observe__/2`.
  """
  @spec expand_observed(Macro.t(), Macro.t(), MapSet.t(atom()), Macro.Env.t()) :: Macro.t()
  def expand_observed(ast, ctx, provided, env), do: elem(expand(ast, ctx, provided, env), 0)

  # `value in list(:name)`, including its negated form.
  defp expand_node(
         {:in, _meta, [value, {:list, _list_meta, [name]}]} = node,
         info,
         ctx,
         _provided,
         env
       ) do
    list_name!(name, node, env)
    call = quote(do: Limen.Lists.member?(unquote(ctx).instance, unquote(name), unquote(value)))
    {call, observe(info, node)}
  end

  defp expand_node({:list, _meta, [name]} = node, info, ctx, _provided, env) do
    list_name!(name, node, env)
    {quote(do: Limen.Lists.get(unquote(ctx).instance, unquote(name))), info}
  end

  defp expand_node({:signal, _meta, [key]} = node, info, ctx, provided, env) do
    unless is_atom(key) do
      raise_compile(env, node, "signal/1 expects an atom literal, got: #{Macro.to_string(key)}")
    end

    unless key in @identity_keys or MapSet.member?(provided, key) do
      available = Enum.sort(@identity_keys ++ MapSet.to_list(provided))

      raise_compile(
        env,
        node,
        "no signal of this policy provides #{inspect(key)}. " <>
          "Available: #{Enum.map_join(available, ", ", &inspect/1)}. " <>
          "Add the signal module to `use Limen.Policy, signals: [...]`"
      )
    end

    call = quote(do: Limen.Context.signal(unquote(ctx), unquote(key)))
    {call, observe(%{info | signals: MapSet.put(info.signals, key)}, node)}
  end

  defp expand_node({helper, _meta, [name]} = node, info, ctx, _provided, env)
       when helper in [:header, :missing_header, :has_header] do
    unless is_binary(name) do
      raise_compile(env, node, "#{helper}/1 expects a header name string literal")
    end

    name = String.downcase(name)
    header = quote(do: Limen.Context.header(unquote(ctx), unquote(name)))

    call =
      case helper do
        :header -> header
        :missing_header -> quote(do: unquote(header) == nil)
        :has_header -> quote(do: unquote(header) != nil)
      end

    {call, observe(info, node)}
  end

  defp expand_node({:shape_flag, _meta, [flag]} = node, info, ctx, provided, env) do
    unless is_atom(flag), do: raise_compile(env, node, "shape_flag/1 expects an atom literal")

    unless MapSet.member?(provided, :shape_flags) do
      raise_compile(env, node, "shape_flag/1 needs the Limen.Signal.HttpShape signal")
    end

    call = quote(do: Runtime.shape_flag?(unquote(ctx), unquote(flag)))
    {call, observe(info, node)}
  end

  defp expand_node({:rate, _meta, [dimension, opts]} = node, info, ctx, _provided, env) do
    window = if Keyword.keyword?(opts), do: opts[:per]

    unless dimension in @dimensions and window in @windows and Keyword.keys(opts) == [:per] do
      raise_compile(
        env,
        node,
        "rate/2 expects rate(dimension, per: window) with a dimension in " <>
          "#{inspect(@dimensions)} and a window in #{inspect(@windows)}"
      )
    end

    call = quote(do: Runtime.rate(unquote(ctx), unquote(dimension), unquote(window)))
    {call, observe(%{info | rates: MapSet.put(info.rates, {dimension, window})}, node)}
  end

  defp expand_node({field, _meta, []} = node, info, ctx, _provided, _env)
       when field in @request_fields do
    call = quote(do: Map.fetch!(unquote(ctx), unquote(field)))
    {call, observe(info, node)}
  end

  # An ordering comparison with a missing value is false. In term order `nil`
  # sorts after every number, so `signal(:asset_ratio) > 0.8` would otherwise
  # hold whenever the ratio is unknown.
  defp expand_node({op, _meta, [left, right]}, info, _ctx, _provided, _env)
       when op in [:<, :<=, :>, :>=] do
    {left, left_check} = operand(left, Macro.var(:left, __MODULE__))
    {right, right_check} = operand(right, Macro.var(:right, __MODULE__))
    compare = quote(do: Kernel.unquote(op)(unquote(left), unquote(right)))
    {Enum.reduce([right_check, left_check], compare, &unless_nil/2), info}
  end

  defp expand_node(node, info, _ctx, _provided, _env), do: {node, info}

  # Literals and the score, an integer, are never `nil`.
  defp operand(literal, _var) when is_number(literal) or is_binary(literal), do: {literal, nil}
  defp operand(@score, _var), do: {@score, nil}
  defp operand(ast, var), do: {var, {ast, var}}

  defp unless_nil(nil, body), do: body

  defp unless_nil({ast, var}, body) do
    # Generated, as Dialyzer may know the `nil` clause cannot match.
    quote generated: true do
      case unquote(ast) do
        nil -> false
        unquote(var) -> unquote(body)
      end
    end
  end

  defp observe(info, node), do: %{info | observed: [{source(node), node} | info.observed]}

  @doc """
  Renders an expression on a single line, for decision records.
  """
  @spec source(Macro.t()) :: String.t()
  def source(ast), do: String.replace(Macro.to_string(ast), ~r/\s*\n\s*/, " ")

  defp list_name!(name, _node, _env) when is_atom(name), do: :ok

  defp list_name!(_name, node, env) do
    raise_compile(env, node, "list/1 expects an atom literal naming the list")
  end

  @doc """
  Expands a `decide` block into `cond` clauses returning `{source, result}`,
  where `source` is the clause that matched.
  """
  @spec decide([Macro.t()], Macro.t(), MapSet.t(atom()), Macro.Env.t()) ::
          {Macro.t(), [String.t()]}
  def decide(clauses, ctx, provided, env) do
    {expanded, sources} =
      clauses
      |> Enum.map(&decide_clause(&1, ctx, provided, env))
      |> Enum.unzip()

    # Requests no clause matches are allowed.
    fallback =
      case List.last(clauses) do
        {:->, _meta, [[true], _result]} -> []
        _other -> quote(do: (true -> {nil, :allow}))
      end

    {{:cond, [], [[do: expanded ++ fallback]]}, sources}
  end

  defp decide_clause({:->, meta, [[condition], result]}, ctx, provided, env) do
    {expanded_condition, _info} = expand(bind_score(condition), ctx, provided, env)
    {expanded_result, _info} = expand(bind_score(result), ctx, provided, env)
    source = "#{source(condition)} -> #{source(result)}"
    {{:->, meta, [[expanded_condition], {source, expanded_result}]}, source}
  end

  defp decide_clause(other, _ctx, _provided, env) do
    raise_compile(env, other, "decide expects clauses of the form `condition -> action`")
  end

  # `score` in a decide block is the policy's total score; `difficulty_for/1,2`
  # maps it to a challenge difficulty.
  defp bind_score(ast) do
    Macro.prewalk(ast, fn
      {:score, _meta, context} when is_atom(context) ->
        @score

      {:difficulty_for, _meta, args} when is_list(args) and args != [] ->
        quote(do: Runtime.difficulty_for(unquote_splicing(args)))

      node ->
        node
    end)
  end

  @spec raise_compile(Macro.Env.t(), Macro.t(), String.t()) :: no_return()
  defp raise_compile(env, node, message) do
    line =
      case node do
        {_form, meta, _args} when is_list(meta) -> Keyword.get(meta, :line, env.line)
        _other -> env.line
      end

    raise CompileError, file: env.file, line: line, description: message
  end
end
