defmodule Limen.Maze.Dice do
  @moduledoc """
  Loaded dice: weighted random choices in constant time.

  A die is built once from outcomes and their weights with Vose's alias
  method, in integer arithmetic. Rolling it takes a single uniform random
  integer, whatever the number of outcomes or how skewed their weights, so
  the maze can draw thousands of words per page cheaply.

  Rolls take and return an explicit `:rand` state, so a page seeded from its
  path draws the same outcomes every time.

      iex> die = Limen.Maze.Dice.new([{:heads, 1}, {:tails, 3}])
      iex> {outcome, _state} = Limen.Maze.Dice.roll(die, :rand.seed_s(:exsss, 42))
      iex> outcome in [:heads, :tails]
      true
  """

  @enforce_keys [:size, :total, :outcomes, :thresholds, :aliases]
  defstruct [:size, :total, :outcomes, :thresholds, :aliases]

  @type t :: %__MODULE__{
          size: pos_integer(),
          total: pos_integer(),
          outcomes: tuple(),
          thresholds: tuple(),
          aliases: tuple()
        }

  @doc """
  Builds a die from `{outcome, weight}` pairs with positive integer weights.
  """
  @spec new([{term(), pos_integer()}, ...]) :: t()
  def new([_first | _rest] = weighted) do
    {outcomes, weights} = Enum.unzip(weighted)

    unless Enum.all?(weights, &(is_integer(&1) and &1 > 0)) do
      raise ArgumentError, "dice weights must be positive integers"
    end

    size = length(weights)
    total = Enum.sum(weights)
    {thresholds, aliases} = columns(weights, size, total)

    %__MODULE__{
      size: size,
      total: total,
      outcomes: List.to_tuple(outcomes),
      thresholds: List.to_tuple(for i <- 0..(size - 1), do: Map.get(thresholds, i, total)),
      aliases: List.to_tuple(for i <- 0..(size - 1), do: Map.get(aliases, i, i))
    }
  end

  # Each of the `size` columns holds `total` units: its own outcome's share up
  # to its threshold, and its alias's share above it.
  defp columns(weights, size, total) do
    scaled = Enum.with_index(weights, fn weight, index -> {index, weight * size} end)
    {small, large} = Enum.split_with(scaled, fn {_index, units} -> units < total end)
    pair(small, large, total, %{}, %{})
  end

  defp pair([{s, s_units} | small], [{l, l_units} | large], total, thresholds, aliases) do
    thresholds = Map.put(thresholds, s, s_units)
    aliases = Map.put(aliases, s, l)
    l_units = l_units - (total - s_units)

    if l_units < total,
      do: pair([{l, l_units} | small], large, total, thresholds, aliases),
      else: pair(small, [{l, l_units} | large], total, thresholds, aliases)
  end

  # Whatever is left fills its own column entirely.
  defp pair(_small, _large, _total, thresholds, aliases), do: {thresholds, aliases}

  @doc """
  Rolls the die, returning an outcome and the next random state.
  """
  @spec roll(t(), :rand.state()) :: {term(), :rand.state()}
  def roll(%__MODULE__{size: 1, outcomes: {outcome}}, state), do: {outcome, state}

  def roll(%__MODULE__{size: size, total: total} = die, state) do
    {draw, state} = :rand.uniform_s(size * total, state)
    column = div(draw - 1, total)

    if rem(draw - 1, total) < elem(die.thresholds, column),
      do: {elem(die.outcomes, column), state},
      else: {elem(die.outcomes, elem(die.aliases, column)), state}
  end

  @doc """
  The number of outcomes.
  """
  @spec size(t()) :: pos_integer()
  def size(%__MODULE__{size: size}), do: size
end
