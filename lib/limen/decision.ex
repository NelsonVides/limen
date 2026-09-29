defmodule Limen.Decision do
  @moduledoc """
  The explainable record of a verdict.

  Every request Limen evaluates produces exactly one decision. It carries the
  action, whether the action was enforced, the stage that produced it, every
  rule that matched together with the values it observed, the `decide`
  clause that picked the action with the values it observed, the facts the
  application stated about the request (see `Limen.put_facts/2`), and every
  signal collected for it. `explain/1` renders it for humans.

  ## Actions

    * `:allow` - the request continues.
    * `:challenge` - the client must solve a proof-of-work challenge
      (`params.difficulty` leading zero bits, from 1 to 32; 1 costs nothing
      and only shows that the client runs the challenge's script, see the
      tuning guide).
    * `:throttle` - `429 Too Many Requests` (`params.retry_after` seconds).
    * `:deny` - `403 Forbidden`; `params.ban` seconds, when set, also bans the
      client prefix.
    * `:tarpit` - nothing is sent for `params.delay` milliseconds, then
      `403 Forbidden`. A tarpit never bans.
    * `:maze` - the client gets a slow, endless maze page (see `Limen.Maze`)
      instead of the application; `params.ban` seconds, when set, also flags
      the client prefix so every later request goes to the maze too.

  ## Stages

  The stage names the step of the pipeline that settled the decision:
  `:off`, `:endpoint` (a Limen challenge endpoint), `:trap` (a honeypot, see
  `Limen.Trap`), `:trust` (a policy's `trust` rule), `:ban`, `:limit`,
  `:pass`, `:rule` (an `allow`, `deny` or `maze` rule short-circuited),
  `:decide` (the score thresholds), or `:socket` (a WebSocket or LiveView
  connection check).
  """

  use Limen.Boundary, type: :strict, deps: [Limen.IP], exports: [Match]

  alias Limen.Decision.Match

  @type action :: :allow | :challenge | :throttle | :deny | :tarpit | :maze
  @type mode :: :dry_run | :enforce
  @type stage ::
          :off | :endpoint | :trap | :trust | :ban | :limit | :pass | :rule | :decide | :socket

  @type t :: %__MODULE__{
          instance: atom() | nil,
          action: action(),
          params: map(),
          mode: mode(),
          enforced: boolean(),
          stage: stage(),
          policy: module() | nil,
          route: String.t() | nil,
          score: integer(),
          matches: [Match.t()],
          clause: String.t() | nil,
          clause_observed: [{String.t(), term()}],
          facts: map(),
          signals: map(),
          evidence: map(),
          identity: map(),
          errors: [term()],
          method: String.t() | nil,
          path: String.t() | nil,
          at: integer(),
          duration: non_neg_integer()
        }

  defstruct instance: nil,
            action: :allow,
            params: %{},
            mode: :dry_run,
            enforced: false,
            stage: :decide,
            policy: nil,
            route: nil,
            score: 0,
            matches: [],
            clause: nil,
            clause_observed: [],
            facts: %{},
            signals: %{},
            evidence: %{},
            identity: %{},
            errors: [],
            method: nil,
            path: nil,
            at: 0,
            duration: 0

  defmodule Match do
    @moduledoc """
    A rule that matched, and the values its condition observed.
    """

    @type kind ::
            :trust | :allow | :deny | :maze | :score | :limit | :ban | :pass | :list | :trap
    @type t :: %__MODULE__{
            name: atom(),
            kind: kind(),
            weight: integer(),
            condition: String.t() | nil,
            observed: [{String.t(), term()}]
          }

    defstruct [:name, :kind, weight: 0, condition: nil, observed: []]
  end

  @doc """
  Normalises the value returned by a policy's `decide` block into an action
  and its parameters.
  """
  @spec normalize(term()) :: {action(), map()}
  def normalize(:allow), do: {:allow, %{}}
  def normalize(:deny), do: {:deny, %{}}
  def normalize(:throttle), do: {:throttle, %{retry_after: 1}}
  def normalize(:tarpit), do: {:tarpit, %{delay: 5_000}}
  def normalize(:maze), do: {:maze, %{}}
  def normalize(:challenge), do: {:challenge, %{difficulty: 16}}
  def normalize({action, opts}) when is_list(opts), do: normalize({action, Map.new(opts)})

  def normalize({:challenge, difficulty}) when is_integer(difficulty),
    do: normalize({:challenge, %{difficulty: difficulty}})

  def normalize({:throttle, seconds}) when is_integer(seconds),
    do: normalize({:throttle, %{retry_after: seconds}})

  def normalize({:tarpit, ms}) when is_integer(ms), do: normalize({:tarpit, %{delay: ms}})

  def normalize({action, %{} = params})
      when action in [:allow, :deny, :throttle, :tarpit, :maze] do
    {default_action, defaults} = normalize(action)
    {default_action, Map.merge(defaults, params)}
  end

  def normalize({:challenge, %{} = params}) do
    difficulty = min(max(Map.get(params, :difficulty, 16), 1), 32)
    {:challenge, Map.put(params, :difficulty, difficulty)}
  end

  def normalize(other) do
    raise ArgumentError,
          "a policy decided #{inspect(other)}, expected :allow, :deny, :throttle, :tarpit, " <>
            ":maze, :challenge or {action, opts}"
  end

  @doc """
  Renders a decision as human-readable lines.
  """
  @spec explain(t()) :: String.t()
  def explain(%__MODULE__{} = decision) do
    lines =
      [explain_header(decision)] ++
        explain_identity(decision) ++
        explain_facts(decision) ++
        Enum.map(decision.matches, &explain_match/1) ++
        explain_clause(decision) ++
        explain_signals(decision) ++
        Enum.map(decision.errors, &"  error: #{inspect(&1)}")

    Enum.join(lines, "\n")
  end

  defp explain_header(decision) do
    enforcement =
      cond do
        decision.enforced -> "enforced"
        # An allowed request has nothing to enforce.
        decision.action == :allow -> "#{decision.mode} mode"
        true -> "not enforced, #{decision.mode}"
      end

    policy = if decision.policy, do: " by #{inspect(decision.policy)}", else: ""

    "#{decision.action}#{format_params(decision.params)} (#{enforcement}) " <>
      "at stage #{decision.stage}#{policy}, score #{decision.score}"
  end

  defp explain_identity(decision) do
    for {key, value} <- decision.identity, value != nil do
      "  #{key}: #{format_value(key, value)}"
    end
  end

  defp explain_facts(decision) do
    for {key, value} <- Enum.sort(decision.facts), do: "  fact #{key} = #{inspect(value)}"
  end

  defp explain_match(%Match{} = match) do
    weight = if match.kind == :score, do: " #{format_weight(match.weight)}", else: ""
    condition = if match.condition, do: " when #{match.condition}", else: ""
    "  #{match.kind} #{match.name}#{weight}#{condition}#{format_observed(match.observed)}"
  end

  defp format_observed([]), do: ""

  defp format_observed(observed) do
    " [" <> Enum.map_join(observed, ", ", fn {e, v} -> "#{e} = #{inspect(v)}" end) <> "]"
  end

  defp explain_clause(%{clause: nil}), do: []

  defp explain_clause(%{clause: clause, clause_observed: observed}),
    do: ["  decided by: #{clause}#{format_observed(observed)}"]

  defp format_weight(weight) when weight >= 0, do: "+#{weight}"
  defp format_weight(weight), do: "#{weight}"

  defp explain_signals(decision) do
    for {key, value} <- Enum.sort(decision.signals) do
      why =
        case Map.fetch(decision.evidence, key) do
          {:ok, evidence} -> " (#{inspect(evidence)})"
          :error -> ""
        end

      "  signal #{key} = #{inspect(value)}#{why}"
    end
  end

  defp format_params(params) when map_size(params) == 0, do: ""

  defp format_params(params) do
    "(" <> Enum.map_join(Enum.sort(params), ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end) <> ")"
  end

  defp format_value(:prefix, prefix), do: Limen.IP.prefix_to_string(prefix)
  defp format_value(:client_ip, ip), do: to_string(:inet.ntoa(ip))
  defp format_value(_key, value) when is_binary(value), do: value
  defp format_value(_key, value), do: inspect(value)
end
