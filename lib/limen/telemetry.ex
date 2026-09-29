defmodule Limen.Telemetry do
  @moduledoc """
  Telemetry events emitted by Limen.

  Handlers run synchronously in the request process, so they must be cheap and
  must not block. Every event's metadata includes the `:instance` name.
  Attach heavier consumers to a sampled source instead, such as
  `Limen.DecisionLog`.

  ## Events

    * `[:limen, :decision]` - every evaluated request, in every mode.
      * Measurements: `:duration` (native time units), `:score`.
      * Metadata: `:decision` (a `Limen.Decision`), `:conn`.

    * `[:limen, :challenge, :issued]` - a challenge page was served.
      * Measurements: `:difficulty`.
      * Metadata: `:identity`.

    * `[:limen, :challenge, :verified]` - a challenge solution was checked.
      * Measurements: `:count` (always 1).
      * Metadata: `:result` (`:ok` or `{:error, reason}`), `:method` (`:pow`
        or `:wait`), `:identity`.

    * `[:limen, :ban, :added]` - a prefix was banned, or flagged for the maze.
      * Measurements: `:ttl` (seconds).
      * Metadata: `:prefix`, `:reason`, `:origin` (`:policy`, `:admin`,
        `:trap` or `:remote`), `:action` (`:deny` or `:maze`), `:expires_at`.

    * `[:limen, :maze, :served]` - a maze response ended.
      * Measurements: `:duration` (native time units), `:bytes`, `:chunks`.
      * Metadata: `:result` (`:complete`, `:deadline` when the rest was sent
        at once, or `:closed` when the client went away), `:path`,
        `:identity`.

    * `[:limen, :state, :saturated]` - a capped table refused a new key;
      requests for it fall back to approximate state.
      * Measurements: `:count` (always 1).
      * Metadata: `:table`.

    * `[:limen, :state, :rotated]` - a time window moved to a new epoch.
      * Measurements: `:cleared` (entries dropped).
      * Metadata: `:window`, `:epoch`.

    * `[:limen, :asn, :loaded]` - IP-to-ASN data was loaded, see
      `Limen.Signal.Asn.Loader`.
      * Measurements: `:duration` (native time units, building included),
        `:ranges`, `:bytes`.
      * Metadata: `:source` (`{:file, path}`, `{:url, url}` or `:rows`).

    * `[:limen, :asn, :checked]` - the `:url` was checked for new data.
      * Measurements: `:duration` (native time units).
      * Metadata: `:url`, `:result` (`:updated`, `:unchanged`, `:postponed`
        or `:error`) and `:reason` (why it was postponed or failed, else
        `nil`).

    * `[:limen, :fcrdns, :resolved]` - a crawler verification finished, see
      `Limen.Signal.Fcrdns`.
      * Measurements: `:duration` (native time units).
      * Metadata: `:ip`, `:crawler` (the name it claimed), `:result`
        (`:verified`, `:failed` or `:error` for a transient DNS error),
        `:host` (the verified host, else `nil`) and `:reason` (why it failed,
        else `nil`).
  """

  use Limen.Boundary, type: :strict, deps: []

  @doc false
  @spec decision(Limen.Decision.t(), Plug.Conn.t() | nil) :: :ok
  def decision(decision, conn) do
    :telemetry.execute(
      [:limen, :decision],
      %{duration: decision.duration, score: decision.score},
      %{instance: decision.instance, decision: decision, conn: conn}
    )
  end

  @doc false
  @spec execute(atom(), [atom()], map(), map()) :: :ok
  def execute(instance, event, measurements, metadata) do
    :telemetry.execute([:limen | event], measurements, Map.put(metadata, :instance, instance))
  end
end
