defmodule Limen.Sketch.HyperLogLog do
  @moduledoc """
  A lock-free [HyperLogLog] on `:atomics`.

  Estimates the number of distinct keys added with a relative standard error
  of about `1.04 / sqrt(2^precision)` (1.6% at the default precision of 12)
  in `2^precision` bytes: registers are 8 bits wide and packed eight to a
  64-bit atomic, updated with compare-and-swap.

  Estimates use Otmar Ertl's [improved estimator], which keeps that error
  across the whole range. The original estimator errs about twice as much
  around `2.5 × 2^precision` keys, where it switches to counting empty
  registers.

  Adding a key costs one hash and usually one atomic read; estimating scans
  every register, so estimates belong in background processes, not on the
  request path.

  [HyperLogLog]: https://doi.org/10.46298/dmtcs.3545
  [improved estimator]: https://arxiv.org/abs/1702.01284
  """

  import Bitwise

  @enforce_keys [:ref, :precision]
  defstruct [:ref, :precision]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref(), precision: 4..16}

  @doc """
  Creates a sketch with `2^precision` registers.
  """
  @spec new(4..16) :: t()
  def new(precision \\ 12) when precision in 4..16 do
    %__MODULE__{ref: :atomics.new(div(1 <<< precision, 8), signed: false), precision: precision}
  end

  @doc """
  Adds `key`.
  """
  @spec add(t(), term()) :: :ok
  def add(%__MODULE__{ref: ref, precision: precision}, key) do
    hash = :erlang.phash2(key, 1 <<< 32) ||| :erlang.phash2({key, :limen}, 1 <<< 32) <<< 32
    register = hash >>> (64 - precision)
    rest = hash &&& (1 <<< (64 - precision)) - 1
    rank = min(leading_zeros(rest, 64 - precision) + 1, 255)
    raise_register(ref, div(register, 8) + 1, rem(register, 8) * 8, rank)
  end

  defp leading_zeros(0, bits), do: bits
  defp leading_zeros(value, bits), do: bits - bit_length(value)

  defp bit_length(value, bits \\ 0)
  defp bit_length(0, bits), do: bits
  defp bit_length(value, bits) when value >= 1 <<< 16, do: bit_length(value >>> 16, bits + 16)
  defp bit_length(value, bits) when value >= 1 <<< 4, do: bit_length(value >>> 4, bits + 4)
  defp bit_length(value, bits), do: bit_length(value >>> 1, bits + 1)

  defp raise_register(ref, word, shift, rank),
    do: raise_register(ref, word, shift, rank, :atomics.get(ref, word))

  # A failed exchange returns the word's current value, so a retry reads nothing again.
  defp raise_register(_ref, _word, shift, rank, old) when (old >>> shift &&& 0xFF) >= rank,
    do: :ok

  defp raise_register(ref, word, shift, rank, old) do
    new = (old &&& bnot(0xFF <<< shift)) ||| rank <<< shift

    case :atomics.compare_exchange(ref, word, old, new) do
      :ok -> :ok
      current -> raise_register(ref, word, shift, rank, current)
    end
  end

  # The estimator's constant for any number of registers, 1 / (2 ln 2).
  @alpha 1 / (2 * :math.log(2))

  @doc """
  Estimates the number of distinct keys added to any of `sketches`.

  Passing several sketches of the same precision estimates their union.
  """
  @spec cardinality(t() | [t(), ...]) :: non_neg_integer()
  def cardinality(%__MODULE__{} = sketch), do: cardinality([sketch])

  def cardinality([%__MODULE__{precision: precision} | _rest] = sketches) do
    m = 1 <<< precision
    q = 64 - precision
    refs = for %__MODULE__{ref: ref} <- sketches, do: ref
    {sum, zeros, full} = sum_words(refs, div(m, 8), q + 1, 0.0, 0, 0)

    # Ertl's estimator, whose loop over the histogram of register values
    # unrolls into `sum`: the registers between 1 and q, each weighted
    # 2^-value. Empty and full registers (value q + 1) are corrected for.
    if zeros == m do
      0
    else
      z = m * sigma(zeros / m) + sum + m * tau(1 - full / m) / (1 <<< q)
      round(@alpha * m * m / z)
    end
  end

  @inverse_powers List.to_tuple(for value <- 0..255, do: :math.pow(2, -value))

  # Registers are read a word (eight registers) at a time, taking each
  # register's largest value across sketches, which is their union.
  defp sum_words(_refs, 0, _full_value, sum, zeros, full), do: {sum, zeros, full}

  defp sum_words([ref], word, full_value, sum, zeros, full) do
    {sum, zeros, full} = sum_word(:atomics.get(ref, word), full_value, sum, zeros, full)
    sum_words([ref], word - 1, full_value, sum, zeros, full)
  end

  defp sum_words(refs, word, full_value, sum, zeros, full) do
    union =
      Enum.reduce(refs, 0, fn ref, union -> max_registers(:atomics.get(ref, word), union) end)

    {sum, zeros, full} = sum_word(union, full_value, sum, zeros, full)
    sum_words(refs, word - 1, full_value, sum, zeros, full)
  end

  defp sum_word(0, _full_value, sum, zeros, full), do: {sum, zeros + 8, full}

  defp sum_word(word, full_value, sum, zeros, full),
    do: sum_registers(word, 8, full_value, sum, zeros, full)

  defp sum_registers(_word, 0, _full_value, sum, zeros, full), do: {sum, zeros, full}

  defp sum_registers(word, left, full_value, sum, zeros, full) do
    case word &&& 0xFF do
      0 ->
        sum_registers(word >>> 8, left - 1, full_value, sum, zeros + 1, full)

      ^full_value ->
        sum_registers(word >>> 8, left - 1, full_value, sum, zeros, full + 1)

      value ->
        sum_registers(
          word >>> 8,
          left - 1,
          full_value,
          sum + elem(@inverse_powers, value),
          zeros,
          full
        )
    end
  end

  defp max_registers(a, b) do
    for shift <- 0..56//8, reduce: 0 do
      union -> union ||| max(a >>> shift &&& 0xFF, b >>> shift &&& 0xFF) <<< shift
    end
  end

  # σ(x) = x + Σ x^(2^k) 2^(k-1) and τ(x) = (1 - x - Σ (1 - x^(2^-k))^2 2^-k) / 3,
  # for k ≥ 1, summed until adding a term no longer changes the float.
  defp sigma(x), do: sigma(x, 1.0, x)

  defp sigma(x, y, z) do
    x = x * x
    next = z + x * y
    if next == z, do: z, else: sigma(x, y + y, next)
  end

  defp tau(x) when x == 0 or x == 1, do: 0.0
  defp tau(x), do: tau(x, 1.0, 1 - x)

  defp tau(x, y, z) do
    x = :math.sqrt(x)
    y = y * 0.5
    next = z - (1 - x) * (1 - x) * y
    if next == z, do: z / 3, else: tau(x, y, next)
  end

  @doc """
  Clears every register. Not atomic with respect to concurrent updates.
  """
  @spec reset(t()) :: :ok
  def reset(%__MODULE__{ref: ref, precision: precision}) do
    for word <- 1..div(1 <<< precision, 8), do: :atomics.put(ref, word, 0)
    :ok
  end

  @doc """
  Memory used by the registers, in bytes.
  """
  @spec memory(t()) :: non_neg_integer()
  def memory(%__MODULE__{ref: ref}), do: :atomics.info(ref).memory
end
