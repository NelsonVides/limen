defmodule Limen.Plug do
  @moduledoc """
  The request gate.

  Place it in your endpoint before the router:

      plug Limen.Plug

  Every request goes through the same pipeline:

    1. **Collect** the client identity into a `Limen.Context`.
    2. **Decide** on an action.
    3. **Act**: continue, or respond on the application's behalf.

  Each evaluation produces a `Limen.Decision`, emitted as a
  `[:limen, :decision]` telemetry event and sampled into
  `Limen.DecisionLog`. The decision is also stored in `conn.private[:limen]`.

  ## Options

    * `:mode` - overrides the configured mode (`:dry_run` or `:enforce`) for
      this plug.

  ## Dry-run

  In dry-run mode the pipeline runs unchanged, including every state update
  and telemetry event; only the final action is skipped and the request
  continues. `decision.enforced` tells the two apart.
  """

  @behaviour Plug

  alias Limen.{Context, Decision, Instance}

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode)

    unless mode in [nil, :dry_run, :enforce] do
      raise ArgumentError, "expected :mode to be :dry_run or :enforce, got: #{inspect(mode)}"
    end

    %{instance: instance!(opts), mode: mode}
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

  @impl true
  def call(conn, %{instance: name, mode: mode}) do
    started = System.monotonic_time()
    instance = Instance.fetch!(name)
    config = instance.config

    ctx = identify(Context.from_conn(conn, instance), config)

    decision = %Decision{
      instance: name,
      action: :allow,
      stage: :decide,
      mode: mode || config.mode
    }

    decision
    |> finalize(ctx, started)
    |> act(conn, instance)
  end

  defp identify(ctx, config) do
    %{ctx | prefix: Limen.IP.prefix(ctx.client_ip, config.ipv4_prefix, config.ipv6_prefix)}
  end

  defp finalize(decision, ctx, started) do
    %{
      decision
      | enforced: decision.mode == :enforce and decision.action != :allow,
        signals: ctx.signals,
        evidence: ctx.evidence,
        identity: Context.identity(ctx),
        method: ctx.method,
        path: ctx.path,
        at: ctx.now,
        duration: System.monotonic_time() - started
    }
  end

  defp act(decision, conn, instance) do
    Limen.Stats.incr(instance, decision.action)
    if decision.enforced, do: Limen.Stats.incr(instance, :enforced)
    Limen.Telemetry.decision(decision, conn)
    Limen.DecisionLog.record(instance, decision)

    conn = Plug.Conn.put_private(conn, :limen, decision)

    if decision.enforced do
      respond(conn, decision)
    else
      conn
    end
  end

  defp respond(conn, %Decision{}), do: plain(conn, 403, "Forbidden")

  defp plain(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
