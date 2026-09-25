defmodule Limen.Tarpit do
  @moduledoc """
  Holds tarpitted requests before denying them.

  Delaying a response costs the BEAM very little (the request process sleeps)
  and costs a scraper a connection for the whole delay. It still holds a
  connection on your side, so each instance holds at most `:max_concurrent`
  requests at once, counted with `:atomics`; beyond that, requests are denied
  immediately. Delays are capped at `:max_delay` milliseconds. Both are
  options of the `:tarpit` configuration, see `Limen.Config`.
  """

  alias Limen.Instance

  @doc false
  @spec new() :: :atomics.atomics_ref()
  def new, do: :atomics.new(1, [])

  @doc """
  Sleeps for `delay` milliseconds, capped, unless too many requests are
  already held. Returns the time actually held.
  """
  @spec hold(Instance.t(), non_neg_integer()) :: non_neg_integer()
  def hold(%Instance{tarpit: held, config: %{tarpit: config}}, delay)
      when is_integer(delay) and delay >= 0 do
    if :atomics.add_get(held, 1, 1) <= config.max_concurrent do
      delay = cap(delay, config.max_delay)

      try do
        Process.sleep(delay)
        delay
      after
        :atomics.sub(held, 1, 1)
      end
    else
      :atomics.sub(held, 1, 1)
      0
    end
  end

  defp cap(delay, max) when is_integer(max) and max >= 0 and max < delay, do: max
  defp cap(delay, _max), do: delay

  @doc """
  Number of requests an instance currently holds.
  """
  @spec held(atom() | Instance.t()) :: non_neg_integer()
  def held(instance), do: :atomics.get(Instance.fetch!(instance).tarpit, 1)
end
