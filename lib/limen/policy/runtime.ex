defmodule Limen.Policy.Runtime do
  @moduledoc """
  Functions compiled policies call on the request path.
  """

  alias Limen.Context
  alias Limen.Decision.Match
  alias Limen.State.{Gcra, Window}

  @doc """
  Whether the HTTP shape signal raised `flag`.
  """
  @spec shape_flag?(Context.t(), atom()) :: boolean()
  def shape_flag?(%Context{signals: signals}, flag) do
    case signals do
      %{shape_flags: flags} when is_list(flags) -> flag in flags
      _not_collected -> false
    end
  end

  @doc """
  The sliding-window rate of `dimension` over `window`, as tracked for the
  current policy by `track/2`.
  """
  @spec rate(Context.t(), atom(), atom()) :: non_neg_integer()
  def rate(%Context{rates: rates}, dimension, window), do: Map.get(rates, {dimension, window}, 0)

  @doc """
  The value of parameter `name` in the instance's `:params`, or `default`.
  """
  @spec param(Context.t(), atom(), term()) :: term()
  def param(%Context{instance: %{config: %{params: params}}}, name, default) do
    case params do
      %{^name => value} -> value
      _default -> default
    end
  end

  def param(%Context{}, _name, default), do: default

  @doc """
  A score weight from parameter `name`: its configured value when it is an
  integer, else `default`.
  """
  @spec weight(Context.t(), atom(), integer()) :: integer()
  def weight(ctx, name, default) do
    case param(ctx, name, default) do
      weight when is_integer(weight) -> weight
      _invalid -> default
    end
  end

  @doc """
  Maps a score to a proof-of-work difficulty in leading zero bits.

  Scores up to `:from` get `:base` bits; every `:step` points above that add
  one bit, up to `:max`. Each extra bit doubles the expected work.

      iex> Limen.Policy.Runtime.difficulty_for(40)
      16
      iex> Limen.Policy.Runtime.difficulty_for(85)
      18
      iex> Limen.Policy.Runtime.difficulty_for(1_000)
      22
  """
  @spec difficulty_for(integer(), keyword()) :: pos_integer()
  def difficulty_for(score, opts \\ []) do
    base = Keyword.get(opts, :base, 16)
    from = Keyword.get(opts, :from, 40)
    step = Keyword.get(opts, :step, 20)
    max = Keyword.get(opts, :max, 22)
    min(base + div(max(score - from, 0), step), max)
  end

  @doc """
  Counts the request in every rate window `policy` refers to, and stores the
  resulting rates in the context.

  Runs for every request the policy covers, including pass holders, so rates
  reflect all traffic.
  """
  @spec track(module(), Context.t()) :: Context.t()
  def track(policy, %Context{} = ctx) do
    rates =
      Enum.reduce(policy.__limen__(:rates), ctx.rates, fn {dimension, window}, rates ->
        case subject(ctx, dimension) do
          nil ->
            rates

          subject ->
            key = {:limen_rate, policy, dimension, subject}
            count = Window.incr(ctx.instance, window, key, ctx.now)
            Map.put(rates, {dimension, window}, count)
        end
      end)

    %{ctx | rates: rates}
  end

  @doc """
  Checks the hard limits of `policy`, returning the first exceeded.
  """
  @spec check_limits(module(), Context.t()) :: :ok | {:exceeded, Match.t(), pos_integer()}
  def check_limits(policy, %Context{} = ctx) do
    Enum.reduce_while(policy.__limen__(:limits), :ok, fn limit, :ok ->
      case check_limit(policy, limit, ctx) do
        :ok -> {:cont, :ok}
        exceeded -> {:halt, exceeded}
      end
    end)
  end

  defp check_limit(policy, %{name: name, key: dimension} = limit, ctx) do
    case subject(ctx, dimension) do
      nil ->
        :ok

      subject ->
        key = {:limen_limit, policy, name, subject}

        case Gcra.check(ctx.instance, key, limit.rate, limit.period, limit.burst, ctx.monotonic) do
          :ok ->
            :ok

          {:error, retry_after_ms} ->
            match = %Match{
              name: name,
              kind: :limit,
              condition: limit.condition,
              observed: [{"retry_after_ms", retry_after_ms}]
            }

            {:exceeded, match, max(div(retry_after_ms + 999, 1_000), 1)}
        end
    end
  end

  @doc """
  Describes a limit for humans.
  """
  @spec describe_limit(map()) :: String.t()
  def describe_limit(%{rate: rate, period: period, burst: burst, key: key}) do
    "#{rate} per #{format_period(period)} by #{key}, burst #{burst}"
  end

  defp format_period(1_000), do: "second"
  defp format_period(60_000), do: "minute"
  defp format_period(3_600_000), do: "hour"
  defp format_period(ms), do: "#{ms} ms"

  defp subject(ctx, :prefix), do: ctx.prefix
  defp subject(ctx, :client_ip), do: ctx.client_ip
  defp subject(ctx, :ja4), do: ctx.ja4
  defp subject(_ctx, :global), do: :global
end
