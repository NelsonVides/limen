defmodule Limen.DecisionLog.Sink do
  @moduledoc """
  Where `Limen.DecisionLog.Flusher` writes sampled decisions.

  A sink gets the decisions sampled since the last flush, oldest first, in
  the flusher's own process, every `:flush_interval` milliseconds and when
  the instance stops. Nothing it does touches the request path, so it can
  take its time: write to a database, a file or a queue.

      defmodule MyApp.DecisionSink do
        @behaviour Limen.DecisionLog.Sink

        @impl true
        def write(decisions, _opts) do
          rows = Enum.map(decisions, &Limen.DecisionLog.report/1)
          MyApp.Repo.insert_all("bot_decisions", rows)
          :ok
        end
      end

      config :my_app, Limen, decision_log: [sink: MyApp.DecisionSink]

  The `:sink` option takes a module, or `{module, opts}` to pass `opts` to
  every call. Only one sink is configured; one that writes to several
  places can call the others. `Limen.DecisionLog.report/1` turns a decision
  into a map of plain values.

  A sink that raises or exits loses that batch: the error is logged and the
  next flush goes on with the decisions sampled after it. The default sink,
  `Limen.DecisionLog.Logger`, writes each decision as a `Logger` report.
  """

  @doc """
  Writes a batch of sampled decisions, oldest first. Never called with an
  empty batch.
  """
  @callback write(decisions :: [Limen.Decision.t(), ...], opts :: keyword()) :: term()
end
