defmodule Limen.Sketch.RotatingBloom do
  @moduledoc """
  "Seen recently" as two Bloom filter generations.

  Keys are added to the current generation and looked up in both. Rotating
  clears the older generation and makes it current, so a key is remembered
  for at least one full rotation period and at most two, in fixed memory and
  without per-key expiry.
  """

  alias Limen.Sketch.Bloom

  @enforce_keys [:generations, :cursor]
  defstruct [:generations, :cursor]

  @type t :: %__MODULE__{generations: {Bloom.t(), Bloom.t()}, cursor: :atomics.atomics_ref()}

  @doc """
  Creates a filter remembering `capacity` keys per generation.
  """
  @spec new(pos_integer(), float()) :: t()
  def new(capacity, false_positive_rate) do
    %__MODULE__{
      generations:
        {Bloom.new(capacity, false_positive_rate), Bloom.new(capacity, false_positive_rate)},
      cursor: :atomics.new(1, signed: false)
    }
  end

  @doc """
  Adds `key` unless it was seen recently. Returns `true` if it was new.
  """
  @spec put_new(t(), term()) :: boolean()
  def put_new(%__MODULE__{} = filter, key) do
    {current, previous} = generations(filter)
    hash = Bloom.hash(key)
    not Bloom.member_hash?(previous, hash) and Bloom.put_hash(current, hash)
  end

  @doc """
  Whether `key` was seen recently.
  """
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = filter, key) do
    {current, previous} = generations(filter)
    hash = Bloom.hash(key)
    Bloom.member_hash?(current, hash) or Bloom.member_hash?(previous, hash)
  end

  @doc """
  Forgets the older generation and starts a new one.
  """
  @spec rotate(t()) :: :ok
  def rotate(%__MODULE__{cursor: cursor} = filter) do
    {_current, previous} = generations(filter)
    Bloom.reset(previous)
    :atomics.add(cursor, 1, 1)
  end

  defp generations(%__MODULE__{generations: {a, b}, cursor: cursor}) do
    if rem(:atomics.get(cursor, 1), 2) == 0, do: {a, b}, else: {b, a}
  end
end
