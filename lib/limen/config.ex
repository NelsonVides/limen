defmodule Limen.Config do
  @moduledoc """
  Instance configuration.

  Every `Limen` instance is configured on its own. Options come from your
  application's environment when started with `{Limen, otp_app: app}` (see
  `from_app/1`), or are given directly with `{Limen, name: name, config: opts}`.
  They are validated once, when the instance starts, and published with it,
  so the request path never reads the application environment.

      config :my_app, Limen,
        mode: :enforce,
        ipv6_prefix: 56

  ## Options

    * `:mode` - `:dry_run` (default) or `:enforce`. In dry-run mode every
      decision is computed, recorded and emitted exactly as in enforce mode,
      but the request always continues. Routes and policies can override it.

    * `:ipv4_prefix` - prefix length IPv4 clients are aggregated to. Defaults
      to `32`.

    * `:ipv6_prefix` - prefix length IPv6 clients are aggregated to. One of
      `48`, `56` or `64` (default).

    * `:decision_log` - sampled structured decision log, see `Limen.DecisionLog`:
      * `:sample_rate` - fraction of `:allow` decisions logged. Defaults to `0.0`.
      * `:non_allow_sample_rate` - fraction of other decisions logged. Defaults
        to `1.0`.
      * `:size` - ring buffer capacity. Defaults to `1024`.
      * `:flush_interval` - milliseconds between flushes to `Logger`. Defaults
        to `1000`.
      * `:level` - `Logger` level. Defaults to `:info`.
  """

  use Boundary, type: :strict, deps: [Logger]

  @decision_log_defaults %{
    sample_rate: 0.0,
    non_allow_sample_rate: 1.0,
    size: 1024,
    flush_interval: 1_000,
    level: :info
  }

  @defaults %{
    mode: :dry_run,
    ipv4_prefix: 32,
    ipv6_prefix: 64,
    decision_log: @decision_log_defaults
  }

  @type t :: %{atom() => term()}

  @doc """
  The instances configured for `app`, with their options.

  With no `:instances` option there is a single instance named after the
  application. Otherwise each entry of `:instances` is an instance, whose
  options are merged over the top-level ones.

      config :my_app, Limen,
        mode: :dry_run,
        instances: [public: [], admin: [mode: :enforce]]
  """
  @spec from_app(atom()) :: [{atom(), keyword()}]
  def from_app(app) when is_atom(app) do
    {instances, shared} = Keyword.pop(Application.get_env(app, Limen, []), :instances)

    case instances do
      nil -> [{app, shared}]
      instances -> for {name, opts} <- instances, do: {name, Keyword.merge(shared, opts)}
    end
  end

  @doc """
  Builds a validated configuration from options.

  Raises `ArgumentError` on an unknown or invalid option.
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    Enum.reduce(opts, @defaults, fn {key, value}, acc -> put(acc, key, value) end)
  end

  @doc """
  Validates and sets one option.
  """
  @spec put(t(), atom(), term()) :: t()
  def put(config, key, value) do
    case validate(key, value, config) do
      {:ok, value} -> Map.put(config, key, value)
      {:error, message} -> raise ArgumentError, "invalid Limen #{key} option: #{message}"
    end
  end

  @doc false
  @spec defaults() :: t()
  def defaults, do: @defaults

  defp validate(:mode, mode, _config) when mode in [:dry_run, :enforce], do: {:ok, mode}
  defp validate(:mode, _mode, _config), do: {:error, "expected :dry_run or :enforce"}

  defp validate(:ipv4_prefix, length, _config) when length in 8..32, do: {:ok, length}

  defp validate(:ipv4_prefix, _length, _config),
    do: {:error, "expected an integer between 8 and 32"}

  defp validate(:ipv6_prefix, length, _config) when length in [48, 56, 64], do: {:ok, length}
  defp validate(:ipv6_prefix, _length, _config), do: {:error, "expected 48, 56 or 64"}

  defp validate(:decision_log, opts, _config) when is_list(opts) do
    merge_known(@decision_log_defaults, opts, fn
      rate, value when rate in [:sample_rate, :non_allow_sample_rate] ->
        is_number(value) and value >= 0 and value <= 1

      :size, value ->
        is_integer(value) and value > 0

      :flush_interval, value ->
        is_integer(value) and value > 0

      :level, value ->
        value in Logger.levels()
    end)
  end

  defp validate(key, value, _config) when is_map_key(@defaults, key),
    do: {:error, "invalid value #{inspect(value)}"}

  defp validate(key, _value, _config), do: {:error, "unknown option #{inspect(key)}"}

  @doc false
  @spec merge_known(map(), keyword(), (atom(), term() -> boolean())) ::
          {:ok, map()} | {:error, String.t()}
  def merge_known(defaults, opts, valid?) do
    Enum.reduce_while(opts, {:ok, defaults}, fn {key, value}, {:ok, acc} ->
      cond do
        not Map.has_key?(defaults, key) ->
          {:halt, {:error, "unknown option #{inspect(key)}"}}

        valid?.(key, value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        true ->
          {:halt, {:error, "invalid value for #{inspect(key)}: #{inspect(value)}"}}
      end
    end)
  end
end
