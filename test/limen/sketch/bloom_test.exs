defmodule Limen.Sketch.BloomTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.Sketch.{Bloom, RotatingBloom}

  property "has no false negatives" do
    check all keys <- uniq_list_of(binary(min_length: 1), max_length: 200) do
      bloom = Bloom.new(500, 0.01)
      Enum.each(keys, &Bloom.put(bloom, &1))
      assert Enum.all?(keys, &Bloom.member?(bloom, &1))
    end
  end

  test "keeps false positives near the configured rate" do
    bloom = Bloom.new(10_000, 0.01)
    for n <- 1..10_000, do: Bloom.put(bloom, {:in, n})

    false_positives = Enum.count(1..20_000, &Bloom.member?(bloom, {:out, &1}))
    assert false_positives / 20_000 < 0.02
  end

  test "keys hashed once keep false positives near the configured rate" do
    bloom = Bloom.new(10_000, 0.01)
    for n <- 1..10_000, do: Bloom.put_hash(bloom, Bloom.hash_once({:in, n}))

    false_positives =
      Enum.count(1..20_000, &Bloom.member_hash?(bloom, Bloom.hash_once({:out, &1})))

    assert false_positives / 20_000 < 0.02
  end

  test "put reports whether the key is new" do
    bloom = Bloom.new(100, 0.001)
    assert Bloom.put(bloom, "a")
    refute Bloom.put(bloom, "a")
    assert Bloom.reset(bloom) == :ok
    refute Bloom.member?(bloom, "a")
  end

  test "rotating filters remember keys for one to two rotations" do
    filter = RotatingBloom.new(100, 0.001)

    assert RotatingBloom.put_new(filter, "a")
    refute RotatingBloom.put_new(filter, "a")

    RotatingBloom.rotate(filter)
    assert RotatingBloom.member?(filter, "a")
    refute RotatingBloom.put_new(filter, "a")

    RotatingBloom.rotate(filter)
    refute RotatingBloom.member?(filter, "a")
    assert RotatingBloom.put_new(filter, "a")
  end

  test "concurrent writers lose no key, and at least one of them adds each" do
    bloom = Bloom.new(40_000, 0.01)

    added =
      1..8
      |> Task.async_stream(fn _writer -> Enum.filter(1..5_000, &Bloom.put(bloom, &1)) end)
      |> Enum.flat_map(fn {:ok, keys} -> keys end)

    assert Enum.all?(1..5_000, &Bloom.member?(bloom, &1))
    assert MapSet.size(MapSet.new(added)) == 5_000
  end

  test "a key hashed once can be looked up in several filters" do
    [a, b] = for _filter <- 1..2, do: Bloom.new(1_000, 0.01)
    hash = Bloom.hash({:prefix, "/path"})

    assert Bloom.put_hash(a, hash)
    assert Bloom.member?(a, {:prefix, "/path"})
    assert Bloom.member_hash?(a, hash)
    refute Bloom.member_hash?(b, hash)
  end
end
