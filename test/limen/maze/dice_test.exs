defmodule Limen.Maze.DiceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Maze.Dice

  doctest Dice

  defp rolls(die, count, seed) do
    {outcomes, _state} =
      Enum.map_reduce(1..count, :rand.seed_s(:exsss, seed), fn _roll, state ->
        Dice.roll(die, state)
      end)

    Enum.frequencies(outcomes)
  end

  property "outcomes come up in proportion to their weights" do
    check all weights <- list_of(integer(1..20), min_length: 1, max_length: 12),
              seed <- integer(1..1_000_000) do
      die = Dice.new(Enum.with_index(weights, fn weight, index -> {index, weight} end))
      total = Enum.sum(weights)
      frequencies = rolls(die, 20_000, seed)

      for {weight, index} <- Enum.with_index(weights) do
        expected = 20_000 * weight / total
        observed = Map.get(frequencies, index, 0)
        # Five standard deviations of a binomial count.
        assert abs(observed - expected) <= 5 * :math.sqrt(expected) + 1
      end
    end
  end

  test "the same random state rolls the same outcomes" do
    die = Dice.new(a: 1, b: 2, c: 3, d: 4)
    assert rolls(die, 100, 7) == rolls(die, 100, 7)
  end

  test "a single outcome needs no random draw" do
    state = :rand.seed_s(:exsss, 1)
    assert Dice.roll(Dice.new(only: 5), state) == {:only, state}
  end

  test "weights must be positive integers" do
    assert_raise ArgumentError, fn -> Dice.new(a: 0) end
    assert_raise ArgumentError, fn -> Dice.new(a: 1.5) end
  end
end
