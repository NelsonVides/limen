defmodule Limen.Sketch.Bloom do
  @moduledoc """
  A lock-free Bloom filter on `:atomics`.

  Answers "have I seen this key?" with no false negatives and a configurable
  false positive rate, in fixed memory. Bits are set with compare-and-swap,
  so `put/2` can tell whether it was the first to add a key, which makes the
  filter usable as a replay guard.
  """

  import Bitwise

  @enforce_keys [:ref, :bits, :hashes]
  defstruct [:ref, :bits, :hashes]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref(), bits: pos_integer(), hashes: pos_integer()}
  @opaque hash :: {non_neg_integer(), pos_integer()}

  @doc """
  Creates a filter for `capacity` keys at the given false positive rate.
  """
  @spec new(pos_integer(), float()) :: t()
  def new(capacity, false_positive_rate)
      when capacity > 0 and false_positive_rate > 0 and false_positive_rate < 1 do
    bits = max(ceil(-capacity * :math.log(false_positive_rate) / :math.pow(:math.log(2), 2)), 64)
    hashes = max(round(bits / capacity * :math.log(2)), 1)
    words = div(bits + 63, 64)
    %__MODULE__{ref: :atomics.new(words, signed: false), bits: words * 64, hashes: hashes}
  end

  @doc """
  Adds `key`. Returns `true` if the key was not already present.

  When several processes add the same key concurrently, at least one of them
  gets `true`; in the common uncontended case exactly one does.
  """
  @spec put(t(), term()) :: boolean()
  def put(%__MODULE__{} = filter, key), do: put_hash(filter, hash(key))

  @doc """
  Whether `key` may have been added. `false` is certain.
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = filter, key), do: member_hash?(filter, hash(key))

  @doc """
  Hashes `key` for `put_hash/2` and `member_hash?/2`, so that a key looked up
  in several filters is hashed once.
  """
  @spec hash(term()) :: hash()
  def hash(key),
    do: {:erlang.phash2(key, 1 <<< 32), :erlang.phash2({key, :limen}, 1 <<< 32) ||| 1}

  @doc """
  `put/2` for a key hashed with `hash/1`.
  """
  @spec put_hash(t(), hash()) :: boolean()
  def put_hash(%__MODULE__{ref: ref, bits: bits, hashes: hashes}, {h1, h2}),
    do: set_bits(ref, bits, h1, h2, hashes - 1, false)

  @doc """
  `member?/2` for a key hashed with `hash/1`.
  """
  @spec member_hash?(t(), hash()) :: boolean()
  def member_hash?(%__MODULE__{ref: ref, bits: bits, hashes: hashes}, {h1, h2}),
    do: bits_set?(ref, bits, h1, h2, hashes - 1)

  # Every bit is set, even once one was found clear: `put/2` reports whether
  # any was.
  defp set_bits(_ref, _bits, _h1, _h2, -1, added), do: added

  defp set_bits(ref, bits, h1, h2, i, added) do
    added = set_bit(ref, rem(h1 + i * h2, bits)) or added
    set_bits(ref, bits, h1, h2, i - 1, added)
  end

  defp bits_set?(_ref, _bits, _h1, _h2, -1), do: true

  defp bits_set?(ref, bits, h1, h2, i),
    do: bit_set?(ref, rem(h1 + i * h2, bits)) and bits_set?(ref, bits, h1, h2, i - 1)

  @doc """
  Clears the filter. Not atomic with respect to concurrent updates.
  """
  @spec reset(t()) :: :ok
  def reset(%__MODULE__{ref: ref, bits: bits}) do
    for word <- 1..div(bits, 64)//1, do: :atomics.put(ref, word, 0)
    :ok
  end

  @doc """
  Memory used by the bits, in bytes.
  """
  @spec memory(t()) :: non_neg_integer()
  def memory(%__MODULE__{ref: ref}), do: :atomics.info(ref).memory

  defp set_bit(ref, bit) do
    word = div(bit, 64) + 1
    set_bit(ref, word, 1 <<< rem(bit, 64), :atomics.get(ref, word))
  end

  # A failed exchange returns the word's current value, so a retry reads nothing again.
  defp set_bit(_ref, _word, mask, old) when (old &&& mask) != 0, do: false

  defp set_bit(ref, word, mask, old) do
    case :atomics.compare_exchange(ref, word, old, old ||| mask) do
      :ok -> true
      current -> set_bit(ref, word, mask, current)
    end
  end

  defp bit_set?(ref, bit), do: (:atomics.get(ref, div(bit, 64) + 1) &&& 1 <<< rem(bit, 64)) != 0
end
