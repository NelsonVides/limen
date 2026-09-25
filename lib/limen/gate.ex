defmodule Limen.Gate do
  @moduledoc false
  # What every entry point (the plug, the challenge endpoints, the socket
  # check) does with a decision once it is made: fill in the record, count
  # it, emit it and sample it.

  alias Limen.{Context, Decision}
  alias Limen.Decision.Match
  alias Limen.State.BanList

  @doc """
  Completes a decision with what the context knows about the request.
  """
  @spec finalize(Decision.t(), Context.t(), integer()) :: Decision.t()
  def finalize(decision, ctx, started) do
    %{
      decision
      | instance: ctx.instance.name,
        enforced: decision.enforced or (decision.mode == :enforce and decision.action != :allow),
        signals: ctx.signals,
        evidence: ctx.evidence,
        identity: Context.identity(ctx),
        method: ctx.method,
        path: ctx.path,
        at: ctx.now,
        duration: System.monotonic_time() - started
    }
  end

  @doc """
  Counts, emits and samples a decision.
  """
  @spec emit(Decision.t(), Plug.Conn.t() | nil, Limen.Instance.t()) :: :ok
  def emit(decision, conn, instance) do
    Limen.Stats.incr(instance, decision.action)
    if decision.enforced, do: Limen.Stats.incr(instance, :enforced)
    Limen.Telemetry.decision(decision, conn)
    Limen.DecisionLog.record(instance, decision)
  end

  @doc """
  The decision for a banned client: denied, or sent to the maze when the ban
  says so. A ban created in dry-run mode is reported but never enforced.
  """
  @spec banned(BanList.ban(), Decision.mode(), Decision.stage()) :: Decision.t()
  def banned(ban, mode, stage \\ :ban) do
    match = %Match{
      name: :banned,
      kind: :ban,
      condition: "prefix is banned",
      observed: [
        {"reason", ban.reason},
        {"origin", ban.origin},
        {"action", ban.action},
        {"expires_at", ban.expires_at}
      ]
    }

    %Decision{
      action: ban.action,
      stage: stage,
      mode: if(mode == :enforce and ban.mode == :enforce, do: :enforce, else: :dry_run),
      matches: [match]
    }
  end
end
