defmodule Limen.Challenge.Replay do
  @moduledoc """
  Makes every challenge token single-use.

  Each instance remembers solved tokens in a `Limen.Sketch.RotatingBloom`
  that `Limen.Challenge.Replay.Rotator` rotates every challenge `:ttl`. A
  token is only valid for `:ttl` seconds, so it is always still remembered
  while it could be replayed. Memory is fixed by `:replay_capacity`; a false
  positive (one in a million at capacity) makes a legitimate client solve a
  fresh challenge.

  Tokens are keyed by their MAC, which is unique per token, so remembering
  the token subsumes remembering each (token, nonce) pair.

  Two verifications of the same token racing each other may both succeed (see
  `Limen.Sketch.Bloom.put/2`). Tokens are bound to the client identity, so
  that only gives one client a second pass it could have copied anyway.
  """

  alias Limen.Instance
  alias Limen.Sketch.RotatingBloom

  @doc false
  @spec new(Limen.Config.t()) :: RotatingBloom.t()
  def new(%{challenge: %{replay_capacity: capacity}}), do: RotatingBloom.new(capacity, 1.0e-6)

  @doc """
  Records the token identified by `mac` as used. Returns `false` if it
  already was.
  """
  @spec use_once(Instance.t(), binary()) :: boolean()
  def use_once(%Instance{replay: filter}, mac), do: RotatingBloom.put_new(filter, mac)

  @doc false
  @spec rotate(Instance.t()) :: :ok
  def rotate(%Instance{replay: filter}), do: RotatingBloom.rotate(filter)
end
