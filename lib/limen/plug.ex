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
    4. **Pass**: a valid pass cookie (see `Limen.Challenge`) allows the
       request right away, without collecting any other signal.
    5. **Collect** the policy's signals.
    6. **Rules**: `allow` and `deny` rules, then scoring and `decide`. See
       `Limen.Policy`.
    7. **Act**: continue, or respond on the application's behalf: `403` for
       denials, `429` with `Retry-After` for throttling, the challenge page
       for challenged navigations.

  Requests under the challenge path (`/__limen` by default) are Limen's own
  endpoints and never reach the application. They are served by the plug's
  instance, and verify solutions with the keys of whichever instance issued
  the challenge.

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

  alias Limen.{Challenge, Context, Decision, Gate, Instance, Policy, Signal}
  alias Limen.Challenge.{Assets, Page, Pass, Replay, Token}
  alias Limen.Decision.Match
  alias Limen.Policy.Runtime
  alias Limen.Signal.Behaviour
  alias Limen.State.BanList

  @impl true
  def init(opts) do
    instance = Instance.name!(opts)
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

    instances = Enum.uniq(for {_segments, _path, {_policy, _mode, name}} <- routes, do: name)
    %{routes: routes, instance: instance, instances: instances}
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
  def call(%Plug.Conn{path_info: path_info} = conn, %{routes: routes, instance: name} = opts) do
    instance = Instance.fetch!(name)

    case strip_prefix(instance.config.challenge.segments, path_info) do
      {:ok, endpoint} ->
        endpoint(conn, endpoint, instance, opts)

      :error ->
        {_segments, path, target} = Enum.find(routes, &prefix?(elem(&1, 0), path_info))
        gate(conn, path, target, instance)
    end
  end

  defp prefix?(segments, path_info), do: strip_prefix(segments, path_info) != :error

  defp strip_prefix([], rest), do: {:ok, rest}
  defp strip_prefix([segment | segments], [segment | rest]), do: strip_prefix(segments, rest)
  defp strip_prefix(_segments, _path_info), do: :error

  defp gate(conn, _route, :off, _instance), do: conn

  defp gate(conn, route, target, instance) do
    started = System.monotonic_time()
    instance = target_instance(target, instance)
    config = instance.config
    ctx = Signal.identify(Context.from_conn(conn, instance), config)
    {conn, ctx} = Behaviour.track(conn, ctx)

    case evaluate(target, ctx, config) do
      :continue ->
        conn

      {decision, ctx} ->
        %{decision | route: route}
        |> Gate.finalize(ctx, started)
        |> act(conn, ctx)
    end
  end

  # Routes may use another instance than the plug's.
  defp target_instance({_policy, _mode, name}, %Instance{name: name} = instance), do: instance
  defp target_instance({_policy, _mode, name}, _instance), do: Instance.fetch!(name)
  defp target_instance(:track, instance), do: instance

  defp evaluate(:track, ctx, config) do
    case BanList.lookup(ctx.instance, ctx.prefix, ctx.now) do
      nil -> :continue
      ban -> {Gate.banned(ban, config.mode), ctx}
    end
  end

  defp evaluate({policy, route_mode, _instance}, ctx, config) do
    mode = route_mode || policy.__limen__(:mode) || config.mode

    case BanList.lookup(ctx.instance, ctx.prefix, ctx.now) do
      nil -> run_policy(policy, Runtime.track(policy, ctx), mode)
      ban -> {%{Gate.banned(ban, mode) | policy: policy}, ctx}
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
        case Pass.verify(ctx) do
          {:ok, expires_at} -> {passed(ctx, expires_at, mode, policy), ctx}
          {:error, :missing} -> apply_rules(policy, ctx, mode)
          {:error, reason} -> apply_rules(policy, put_evidence(ctx, :pass, reason), mode)
        end
    end
  end

  defp put_evidence(ctx, key, value), do: %{ctx | evidence: Map.put(ctx.evidence, key, value)}

  defp passed(ctx, expires_at, mode, policy) do
    Limen.Stats.incr(ctx.instance, :pass)

    match = %Match{
      name: :pass_cookie,
      kind: :pass,
      condition: "a valid pass cookie",
      observed: [{"expires_at", expires_at}]
    }

    %Decision{action: :allow, stage: :pass, mode: mode, policy: policy, matches: [match]}
  end

  defp apply_rules(policy, ctx, mode) do
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

  defp act(decision, conn, ctx) do
    record_ban(decision, ctx)
    conn = emit(decision, conn, ctx.instance)
    if decision.enforced, do: respond(conn, decision, ctx), else: conn
  end

  defp emit(decision, conn, instance) do
    Gate.emit(decision, conn, instance)
    Plug.Conn.put_private(conn, :limen, decision)
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

  defp respond(conn, %Decision{action: :challenge, params: %{difficulty: difficulty}}, ctx) do
    if Challenge.navigation?(conn) do
      challenge(conn, difficulty, ctx)
    else
      conn
      |> Plug.Conn.put_resp_header("limen-challenge", "required")
      |> plain(403, "Challenge required")
    end
  end

  defp respond(conn, %Decision{action: :throttle, params: params}, _ctx) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(params.retry_after))
    |> plain(429, "Too Many Requests")
  end

  defp respond(conn, %Decision{action: :tarpit, params: params}, ctx) do
    Limen.Tarpit.hold(ctx.instance, params.delay)
    plain(conn, 403, "Forbidden")
  end

  defp respond(conn, %Decision{}, _ctx), do: plain(conn, 403, "Forbidden")

  defp challenge(conn, difficulty, %Context{instance: instance} = ctx) do
    token = Token.issue(ctx, difficulty)
    Limen.Stats.incr(instance, :challenge_issued)
    metadata = %{identity: Context.identity(ctx)}

    Limen.Telemetry.execute(
      instance.name,
      [:challenge, :issued],
      %{difficulty: difficulty},
      metadata
    )

    page = Page.render(token, difficulty, Challenge.return_to(conn), instance)

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.put_resp_header("content-security-policy", Page.content_security_policy())
    |> Plug.Conn.put_resp_header("referrer-policy", "same-origin")
    |> Plug.Conn.put_resp_header("x-robots-tag", "noindex")
    |> no_store()
    |> Plug.Conn.send_resp(instance.config.challenge.status, page)
    |> Plug.Conn.halt()
  end

  defp plain(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> no_store()
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end

  defp no_store(conn), do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

  ## Challenge endpoints

  defp endpoint(conn, [asset], _instance, _opts)
       when asset in ["solver.js", "worker.js", "challenge.css"] do
    Plug.Conn.halt(Assets.serve(conn, asset))
  end

  defp endpoint(%Plug.Conn{method: "POST"} = conn, ["verify"], instance, opts) do
    {params, conn} = form_params(conn)
    settle(conn, params, :pow, issuer(params, instance, opts))
  end

  defp endpoint(%Plug.Conn{method: "GET"} = conn, ["wait"], instance, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    settle(conn, conn.query_params, :wait, issuer(conn.query_params, instance, opts))
  end

  defp endpoint(conn, _path, _instance, _opts) do
    Plug.Conn.halt(Plug.Conn.send_resp(conn, 404, "Not Found"))
  end

  # The page names the instance that issued the challenge, so that routes
  # using another instance are verified with its keys. Only instances this
  # plug uses are accepted.
  defp issuer(params, instance, %{instances: instances}) do
    case Enum.find(instances, &(Atom.to_string(&1) == params["instance"])) do
      nil -> instance
      name when name == instance.name -> instance
      name -> Instance.fetch!(name)
    end
  end

  # Checks a solution (or, without JavaScript, the waiting time) and hands
  # out a pass. Every attempt is a decision at the :endpoint stage.
  defp settle(conn, params, method, instance) do
    started = System.monotonic_time()
    config = instance.config
    ctx = Signal.identify(Context.from_conn(conn, instance), config)
    return_to = Challenge.safe_return_to(params["return_to"])

    result =
      case BanList.lookup(instance, ctx.prefix, ctx.now) do
        nil -> check_solution(method, params, ctx, config)
        _ban -> {:error, :banned}
      end

    Limen.Telemetry.execute(instance.name, [:challenge, :verified], %{count: 1}, %{
      result: result,
      method: method,
      identity: Context.identity(ctx)
    })

    decision =
      result
      |> endpoint_decision(method, config)
      |> Gate.finalize(ctx, started)

    conn = emit(decision, conn, instance)

    case result do
      {:ok, _claims} ->
        Limen.Stats.incr(instance, :challenge_solved)
        {value, max_age} = Pass.issue(ctx)
        redirect(Pass.put_cookie(conn, instance, value, max_age), return_to)

      {:error, reason} when reason in [:expired, :too_early] ->
        Limen.Stats.incr(instance, :challenge_failed)
        redirect(conn, return_to)

      {:error, _reason} ->
        Limen.Stats.incr(instance, :challenge_failed)
        plain(conn, 403, "Challenge failed")
    end
  end

  defp check_solution(method, params, ctx, config) do
    with {:ok, claims} <- Token.verify(params["token"], ctx),
         :ok <- proof(method, params, claims, ctx, config),
         true <- Replay.use_once(ctx.instance, claims.mac) || {:error, :replayed} do
      {:ok, claims}
    end
  end

  defp proof(:pow, params, claims, _ctx, _config) do
    if Token.solved?(params["token"], params["nonce"], claims.difficulty),
      do: :ok,
      else: {:error, :unsolved}
  end

  defp proof(:wait, _params, claims, ctx, config) do
    case config.challenge.no_js do
      {:meta_refresh, seconds} ->
        if div(ctx.now, 1_000) >= claims.issued_at + seconds, do: :ok, else: {:error, :too_early}

      :deny ->
        {:error, :no_js_disabled}
    end
  end

  defp endpoint_decision({:ok, claims}, method, config) do
    match = %Match{
      name: :challenge_solved,
      kind: :pass,
      condition: if(method == :pow, do: "proof of work", else: "waited without JavaScript"),
      observed: [{"difficulty", claims.difficulty}, {"issued_at", claims.issued_at}]
    }

    %Decision{action: :allow, stage: :endpoint, mode: config.mode, matches: [match]}
  end

  defp endpoint_decision({:error, reason}, method, config) do
    %Decision{
      action: :deny,
      stage: :endpoint,
      mode: config.mode,
      enforced: true,
      errors: [{:challenge, method, reason}]
    }
  end

  defp redirect(conn, to) do
    conn
    |> Plug.Conn.put_resp_header("location", to)
    |> no_store()
    |> Plug.Conn.send_resp(303, "")
    |> Plug.Conn.halt()
  end

  # The form may already have been parsed by Plug.Parsers.
  defp form_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case Plug.Conn.read_body(conn, length: 4_096) do
      {:ok, body, conn} -> {decode_query(body), conn}
      {_more_or_error, _body_or_reason, conn} -> {%{}, conn}
      {:error, _reason} -> {%{}, conn}
    end
  end

  defp form_params(%Plug.Conn{body_params: params} = conn), do: {params, conn}

  defp decode_query(body) do
    URI.decode_query(body)
  rescue
    ArgumentError -> %{}
  end
end
