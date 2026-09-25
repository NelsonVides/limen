defmodule Limen.Test.Pow do
  @moduledoc """
  A reference proof-of-work solver for tests.
  """

  alias Limen.Challenge.Token

  @doc """
  Finds the first nonce solving `token` at `difficulty`.
  """
  def solve(token, difficulty), do: solve(token, difficulty, 0)

  defp solve(token, difficulty, nonce) do
    candidate = Integer.to_string(nonce)

    if Token.solved?(token, candidate, difficulty),
      do: candidate,
      else: solve(token, difficulty, nonce + 1)
  end
end
