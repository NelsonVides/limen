defmodule Limen.Sketch.CountMin do
  @moduledoc """
  A lock-free Count-Min Sketch on `:atomics`.

  Estimates how many times each key was counted using a fixed `depth × width`
  grid of counters, whatever the number of distinct keys. Estimates never
  undercount; with `N` total increments they overcount by at most
  `e / width × N` with probability `1 - e^-depth`.

  Row indexes are derived from two `:erlang.phash2/2` hashes with the
  Kirsch–Mitzenmacher construction, so an update costs two hashes and `depth`
  atomic increments regardless of depth.
  """

  import Bitwise

  @enforce_keys [:ref, :width, :depth]
  defstruct [:ref, :width, :depth]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref(), width: pos_integer(), depth: pos_integer()}

  @doc """
  Creates a sketch with `width` columns and `depth` rows.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(width, depth) when width > 0 and depth > 0 do
    %__MODULE__{ref: :atomics.new(width * depth, signed: false), width: width, depth: depth}
  end

  @doc """
  Creates a sketch sized for an error of at most `epsilon × N` with
  probability `1 - delta`.
  """
  @spec new_with_error(float(), float()) :: t()
  def new_with_error(epsilon, delta) when epsilon > 0 and delta > 0 and delta < 1 do
    new(ceil(:math.exp(1) / epsilon), ceil(:math.log(1 / delta)))
  end

  @doc """
  Adds `count` to `key` and returns its new estimate.
  """
  @spec add(t(), term(), pos_integer()) :: non_neg_integer()
  def add(%__MODULE__{ref: ref, width: width, depth: depth}, key, count \\ 1) do
    {h1, h2} = hashes(key)
    first = :atomics.add_get(ref, index(width, h1, h2, depth - 1), count)
    add_rows(ref, width, h1, h2, count, depth - 2, first)
  end

  defp add_rows(_ref, _width, _h1, _h2, _count, -1, min), do: min

  defp add_rows(ref, width, h1, h2, count, row, min) do
    value = :atomics.add_get(ref, index(width, h1, h2, row), count)
    add_rows(ref, width, h1, h2, count, row - 1, min(value, min))
  end

  @doc """
  Returns the estimated count for `key`.
  """
  @spec estimate(t(), term()) :: non_neg_integer()
  def estimate(%__MODULE__{ref: ref, width: width, depth: depth}, key) do
    {h1, h2} = hashes(key)
    first = :atomics.get(ref, index(width, h1, h2, depth - 1))
    estimate_rows(ref, width, h1, h2, depth - 2, first)
  end

  defp estimate_rows(_ref, _width, _h1, _h2, -1, min), do: min

  defp estimate_rows(ref, width, h1, h2, row, min) do
    value = :atomics.get(ref, index(width, h1, h2, row))
    estimate_rows(ref, width, h1, h2, row - 1, min(value, min))
  end

  @doc """
  Resets every counter to zero.

  Runs in `O(width × depth)` and is not atomic: concurrent updates may land on
  either side of the reset. Limen only resets sketches of windows no request
  writes to any more.
  """
  @spec reset(t()) :: :ok
  def reset(%__MODULE__{ref: ref, width: width, depth: depth}) do
    for i <- 1..(width * depth)//1, do: :atomics.put(ref, i, 0)
    :ok
  end

  @doc """
  Memory used by the counters, in bytes.
  """
  @spec memory(t()) :: non_neg_integer()
  def memory(%__MODULE__{ref: ref}), do: :atomics.info(ref).memory

  defp hashes(key) do
    h1 = :erlang.phash2(key, 1 <<< 32)
    h2 = :erlang.phash2({key, :limen}, 1 <<< 32) ||| 1
    {h1, h2}
  end

  defp index(width, h1, h2, row), do: row * width + rem(h1 + row * h2, width) + 1
end
