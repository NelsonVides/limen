defmodule Limen.DecisionLog.Logger do
  @moduledoc """
  The default `Limen.DecisionLog.Sink`: logs every sampled decision as a
  structured `Logger` report (see `Limen.DecisionLog.report/1`).

  ## Options

    * `:level` - the `Logger` level. Defaults to `:info`.

  For example, to log decisions at the debug level:

      config :my_app, Limen, decision_log: [sink: {Limen.DecisionLog.Logger, level: :debug}]
  """

  @behaviour Limen.DecisionLog.Sink

  require Logger

  @impl true
  def write(decisions, opts) do
    level = Keyword.get(opts, :level, :info)

    Enum.each(decisions, fn decision ->
      Logger.log(level, fn -> Limen.DecisionLog.report(decision) end)
    end)
  end
end
