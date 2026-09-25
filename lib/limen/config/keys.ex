defmodule Limen.Config.Keys do
  @moduledoc """
  Keys derived from the configured secret.

  Each purpose (challenge tokens, pass cookies, socket tokens) gets its own
  key, derived with HMAC-SHA256, so a token of one kind can never be accepted
  as another. Each field lists the current key first, followed by keys
  derived from `:previous_secret_keys`, which are still accepted when
  verifying so secrets can be rotated without invalidating every pass.

  The struct never shows its contents when inspected.
  """

  @enforce_keys [:challenge, :pass, :socket, :generated]
  defstruct [:challenge, :pass, :socket, :generated]

  @type t :: %__MODULE__{
          challenge: [binary(), ...],
          pass: [binary(), ...],
          socket: [binary(), ...],
          generated: boolean()
        }

  @doc """
  Derives the keys for `secret` and `previous` secrets.

  Without a secret, a random one is generated: tokens then do not survive a
  restart and are not shared between nodes, and `generated` is `true`.
  """
  @spec derive(binary() | nil, [binary()]) :: t()
  def derive(secret, previous \\ []) do
    secrets = [secret || :crypto.strong_rand_bytes(32) | previous]

    %__MODULE__{
      challenge: Enum.map(secrets, &derive_one(&1, "limen/challenge/v1")),
      pass: Enum.map(secrets, &derive_one(&1, "limen/pass/v1")),
      socket: Enum.map(secrets, &derive_one(&1, "limen/socket/v1")),
      generated: secret == nil
    }
  end

  defp derive_one(secret, purpose), do: :crypto.mac(:hmac, :sha256, secret, purpose)

  defimpl Inspect do
    @spec inspect(Limen.Config.Keys.t(), Inspect.Opts.t()) :: String.t()
    def inspect(_keys, _opts), do: "#Limen.Config.Keys<redacted>"
  end
end
