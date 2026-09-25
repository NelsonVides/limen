defmodule Limen.Plug do
  @moduledoc """
  The request gate.

  Place it in your endpoint before the router (and before `Plug.Static` if
  asset requests should count towards client behaviour):

      plug Limen.Plug,
        otp_app: :my_app,
        policy: MyApp.BotPolicy,
        routes: [
          {"/health", :off},
          {"/assets", :track},
          {"/login", MyApp.LoginPolicy, mode: :enforce}
        ]

  ## Pipeline

  Every request goes through the same stages; the first to settle it wins:

    1. **Identify** the client: address, prefix and JA4 (see `Limen.Signal`),
       and track its behaviour.
    2. **Ban**: a banned prefix is denied.
    3. **Limit**: the policy's hard limits.
    4. **Collect** the policy's signals.
    5. **Rules**: `allow` and `deny` rules, then scoring and `decide`. See
       `Limen.Policy`.
    6. **Act**: continue, or respond on the application's behalf.

  Each evaluation produces a `Limen.Decision`, emitted as a
  `[:limen, :decision]` telemetry event, sampled into `Limen.DecisionLog`,
  and stored in `conn.private[:limen]` (see `Limen.decision/1`).

  The `Limen` instance is resolved when the plug is initialised (at compile
  time in an endpoint); at runtime the plug reads it with a single
  `:persistent_term` lookup per request.

  ## Options

    * `:instance` - the name of the `Limen` instance to use.
    * `:otp_app` - use the instance named after this application, as started
      by `{Limen, otp_app: app}`. One of `:instance` or `:otp_app` is required.
    * `:policy` - the policy module for requests no route matches. Defaults
      to `Limen.Policy.Default`.
    * `:mode` - `:dry_run` or `:enforce`, overriding the policy's and the
      instance's mode.
    * `:routes` - per-path overrides, as `{path, target}` or
      `{path, policy, opts}`. A path matches itself and everything below it
      (`"/login"` matches `/login` and `/login/otp`, not `/loginx`); the most
      specific path wins. Targets:
      * `:off` - Limen does nothing at all, for health checks and the like.
      * `:track` - track client behaviour and enforce bans, nothing else; for
        static assets.
      * a policy module, with optional `mode:` and `instance:` (to use
        another instance for that path).

  ## Dry-run

  In dry-run mode the pipeline runs unchanged, including every state update
  (counters, limits, bans) and telemetry event; only the final action is
  skipped and the request continues. `decision.enforced` tells the two apart.
  Bans created in dry-run mode are never enforced, not even on enforcing
  routes.
  """

  @behaviour Plug

  alias Limen.{Context, Decision, Instance, Policy, Signal}
  alias Limen.Decision.Match
  alias Limen.Policy.Runtime
  alias Limen.Signal.Behaviour
  alias Limen.State.BanList

  @impl true
  def init(opts) do
    instance = instance!(opts)
    policy = Keyword.get(opts, :policy, Limen.Policy.Default)
    mode = Keyword.get(opts, :mode)
    validate_policy!(policy)
    validate_mode!(mode)

    # The most specific route first; the catch-all default last.
    routes =
      opts
      |> Keyword.get(:routes, [])
      |> Enum.map(&route(&1, instance))
      |> then(&[{[], nil, {policy, mode, instance}} | &1])
      |> Enum.sort_by(fn {segments, path, _target} -> {-length(segments), is_nil(path)} end)

    %{routes: routes, instance: instance}
  end

  @doc false
  @spec instance!(keyword()) :: atom()
  def instance!(opts) do
    case {Keyword.get(opts, :instance), Keyword.get(opts, :otp_app)} do
      {name, nil} when is_atom(name) and name != nil ->
        name

      {nil, app} when is_atom(app) and app != nil ->
        app

      _missing_or_both ->
        raise ArgumentError, "expected either an :instance or an :otp_app option"
    end
  end

  defp route({path, target}, _instance) when target in [:off, :track],
    do: {segments(path), path, target}

  defp route({path, policy}, instance) when is_atom(policy),
    do: route({path, policy, []}, instance)

  defp route({path, policy, opts}, instance) when is_atom(policy) and is_list(opts) do
    validate_policy!(policy)
    mode = Keyword.get(opts, :mode)
    validate_mode!(mode)
    {segments(path), path, {policy, mode, Keyword.get(opts, :instance, instance)}}
  end

  defp route(other, _instance) do
    raise ArgumentError,
          "invalid Limen route #{inspect(other)}, expected {path, :off | :track | policy} " <>
            "or {path, policy, opts}"
  end

  defp segments(path) when is_binary(path), do: String.split(path, "/", trim: true)

  defp validate_policy!(policy) do
    unless Code.ensure_loaded?(policy) and function_exported?(policy, :__limen__, 1) do
      raise ArgumentError, "#{inspect(policy)} is not a Limen.Policy"
    end
  end

  defp validate_mode!(mode) do
    unless mode in [nil, :dry_run, :enforce] do
      raise ArgumentError, "expected :mode to be :dry_run or :enforce, got: #{inspect(mode)}"
    end
  end

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, %{routes: routes, instance: default}) do
    {_segments, path, target} = Enum.find(routes, &prefix?(elem(&1, 0), path_info))
    gate(conn, path, target, default)
  end

  defp prefix?([], _path_info), do: true
  defp prefix?([segment | rest], [segment | path_info]), do: prefix?(rest, path_info)
  defp prefix?(_segments, _path_info), do: false

  defp gate(conn, _route, :off, _default), do: conn

  defp gate(conn, route, target, default) do
    started = System.monotonic_time()
    instance = Instance.fetch!(target_instance(target, default))
    config = instance.config
    ctx = Signal.identify(Context.from_conn(conn, instance), config)
    {conn, ctx} = Behaviour.track(conn, ctx)

    case evaluate(target, ctx, config) do
      :continue ->
        conn

      {decision, ctx} ->
        %{decision | route: route}
        |> finalize(ctx, started)
        |> act(conn, ctx)
    end
  end

  defp target_instance({_policy, _mode, instance}, _default), do: instance
  defp target_instance(:track, default), do: default

  defp evaluate(:track, ctx, config) do
    case BanList.lookup(ctx.instance, ctx.prefix, ctx.now) do
      nil -> :continue
      ban -> {banned(ban, config.mode), ctx}
    end
  end

  defp evaluate({policy, route_mode, _instance}, ctx, config) do
    mode = route_mode || policy.__limen__(:mode) || config.mode

    case BanList.lookup(ctx.instance, ctx.prefix, ctx.now) do
      nil -> run_policy(policy, Runtime.track(policy, ctx), mode)
      ban -> {%{banned(ban, mode) | policy: policy}, ctx}
    end
  end

  # Rates are counted before limits are checked, so they include every
  # request the policy sees, including throttled ones.
  defp run_policy(policy, ctx, mode) do
    case Runtime.check_limits(policy, ctx) do
      {:exceeded, match, retry_after} ->
        decision = %Decision{
          action: :throttle,
          params: %{retry_after: retry_after},
          stage: :limit,
          mode: mode,
          policy: policy,
          matches: [match]
        }

        {decision, ctx}

      :ok ->
        ctx = Signal.collect(ctx, policy.__limen__(:signals))
        result = Policy.evaluate(policy, ctx)

        decision = %Decision{
          action: result.action,
          params: result.params,
          stage: result.stage,
          mode: mode,
          policy: policy,
          score: result.score,
          matches: result.matches,
          clause: result.clause,
          errors: result.errors
        }

        {decision, ctx}
    end
  end

  # A ban created in dry-run mode is reported but never enforced.
  defp banned(ban, mode) do
    match = %Match{
      name: :banned,
      kind: :ban,
      condition: "prefix is banned",
      observed: [{"reason", ban.reason}, {"origin", ban.origin}, {"expires_at", ban.expires_at}]
    }

    %Decision{
      action: :deny,
      stage: :ban,
      mode: if(mode == :enforce and ban.mode == :enforce, do: :enforce, else: :dry_run),
      matches: [match]
    }
  end

  defp finalize(decision, ctx, started) do
    %{
      decision
      | instance: ctx.instance.name,
        enforced: decision.mode == :enforce and decision.action != :allow,
        signals: ctx.signals,
        evidence: ctx.evidence,
        identity: Context.identity(ctx),
        method: ctx.method,
        path: ctx.path,
        at: ctx.now,
        duration: System.monotonic_time() - started
    }
  end

  defp act(decision, conn, %Context{instance: instance} = ctx) do
    record_ban(decision, ctx)
    Limen.Stats.incr(instance, decision.action)
    if decision.enforced, do: Limen.Stats.incr(instance, :enforced)
    Limen.Telemetry.decision(decision, conn)
    Limen.DecisionLog.record(instance, decision)

    conn = Plug.Conn.put_private(conn, :limen, decision)
    if decision.enforced, do: respond(conn, decision, instance), else: conn
  end

  # Bans are state, not the final action: they are recorded in both modes,
  # carrying the mode so dry-run bans are never enforced.
  defp record_ban(%Decision{action: :deny, params: %{ban: ttl}} = decision, ctx)
       when is_integer(ttl) and ttl > 0 do
    reason =
      case decision.matches do
        [%Match{name: name} | _rest] -> name
        [] -> decision.clause
      end

    opts = [mode: decision.mode, origin: :policy, reason: reason, now: ctx.now]
    _result = BanList.ban(ctx.instance, ctx.prefix, ttl, opts)
    :ok
  end

  defp record_ban(_decision, _ctx), do: :ok

  defp respond(conn, %Decision{action: :throttle, params: params}, _instance) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(params.retry_after))
    |> plain(429, "Too Many Requests")
  end

  defp respond(conn, %Decision{action: :tarpit, params: params}, instance) do
    Limen.Tarpit.hold(instance, params.delay)
    plain(conn, 403, "Forbidden")
  end

  defp respond(conn, %Decision{action: :challenge}, _instance),
    do: plain(conn, 403, "Challenge required")

  defp respond(conn, %Decision{}, _instance), do: plain(conn, 403, "Forbidden")

  defp plain(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
