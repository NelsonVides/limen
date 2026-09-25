defmodule Limen.Credo.NoMessaging do
  @moduledoc """
  Flags code that talks to other processes.

  Limen's request path must never call a GenServer or send a message: every
  process a request waits on is a serialisation point an attacker can flood.
  This check reports sending, calling, casting, spawning, logging and IO
  (both `Logger` and `IO` send messages to other processes), so the rule
  holds mechanically rather than by review.

  Modules that are background processes, and therefore may message freely,
  are excluded through the check's `files` parameter in `.credo.exs`.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Nothing on Limen's request path may call a GenServer or send a message.

      Keep the request path to ETS, `:atomics`, `:counters` and
      `:persistent_term` reads. Move anything that must talk to a process into
      a background process that polls shared state, and exclude that file from
      this check in `.credo.exs`.
      """
    ]

  # Any call to these modules messages another process.
  # Elixir modules are keyed by their alias segments, so the check never
  # creates atoms for the code it reads.
  @modules %{
    [:Agent] => :all,
    [:GenServer] => [:call, :cast, :multi_call, :abcast, :reply],
    [:IO] => {:except, [:iodata_to_binary, :iodata_length, :chardata_to_string]},
    [:Logger] =>
      [:debug, :info, :notice, :warning, :warn, :error, :critical, :alert, :emergency] ++
        [:log, :bare_log],
    [:Process] => [:send, :send_after, :exit, :spawn, :link, :monitor],
    [:Task] => :all,
    [:Phoenix, :PubSub] =>
      [:broadcast, :broadcast!, :broadcast_from, :broadcast_from!] ++
        [:local_broadcast, :direct_broadcast],
    :erlang =>
      [:send, :send_after, :send_nosuspend, :spawn, :spawn_link, :spawn_monitor, :spawn_opt],
    :gen_server => :all,
    :gen_statem => [:call, :cast, :send_request],
    :gen => :all,
    :rpc => :all,
    :erpc => :all,
    :logger => :all,
    :io => :all,
    :pg => [:join, :leave]
  }

  @locals [:send, :spawn, :spawn_link, :spawn_monitor]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({{:., _dot_meta, [module_ast, fun]}, meta, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    module = module_name(module_ast)

    if messaging?(module, fun) do
      position = position(module_ast, meta)
      {ast, put_issue(ctx, issue_for(ctx, position, "#{format(module)}.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk({fun, meta, args} = ast, ctx) when fun in @locals and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, Atom.to_string(fun)))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # The trigger starts at the module name. Aliases carry its position; for
  # Erlang modules the call points at the function name, right after `:mod.`.
  defp position({:__aliases__, meta, _parts}, _call_meta), do: meta

  defp position(module, meta) when is_atom(module) do
    case meta[:column] do
      nil -> meta
      column -> Keyword.put(meta, :column, column - String.length(inspect(module)) - 1)
    end
  end

  defp format(parts) when is_list(parts), do: Enum.join(parts, ".")
  defp format(module), do: inspect(module)

  defp module_name({:__aliases__, _meta, [:"Elixir" | parts]}), do: parts
  defp module_name({:__aliases__, _meta, parts}) when is_list(parts), do: parts
  defp module_name(module) when is_atom(module), do: module
  defp module_name(_other), do: nil

  defp messaging?(module, fun) do
    case Map.get(@modules, module) do
      nil -> false
      :all -> true
      {:except, allowed} -> fun not in allowed
      funs -> fun in funs
    end
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "`#{trigger}` talks to another process; the request path must not call a process " <>
          "or send a message.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
