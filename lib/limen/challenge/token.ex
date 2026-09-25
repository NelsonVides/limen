defmodule Limen.Challenge.Token do
  @moduledoc """
  Stateless, signed challenge tokens.

  A token carries a version, the difficulty, when it was issued and when it
  expires, and a random salt, followed by a truncated HMAC-SHA256 over those
  fields and the client identity (see `Limen.Challenge.binding/1`). The
  identity is not stored in the token, so a token solved by one client is
  useless to any other.

      <<version, difficulty, issued_at::32, expires_at::32, salt::8 bytes, mac::16 bytes>>

  It is sent URL-safe base64 encoded, 46 characters.
  """

  alias Limen.{Challenge, Context}

  @version 1

  @type claims :: %{
          difficulty: pos_integer(),
          issued_at: non_neg_integer(),
          expires_at: non_neg_integer(),
          mac: binary()
        }

  @doc """
  Issues a token for the client in `ctx`.
  """
  @spec issue(Context.t(), pos_integer()) :: String.t()
  def issue(%Context{now: now} = ctx, difficulty) when difficulty in 1..32 do
    issued_at = div(now, 1_000)
    expires_at = issued_at + ctx.instance.config.challenge.ttl

    payload =
      <<@version, difficulty, issued_at::32, expires_at::32>> <> :crypto.strong_rand_bytes(8)

    [key | _previous] = Challenge.keys(ctx.instance, :challenge)
    mac = Challenge.mac(key, [payload, Challenge.binding(ctx)])
    Base.url_encode64(payload <> mac, padding: false)
  end

  @doc """
  Verifies a token presented by the client in `ctx`.
  """
  @spec verify(String.t(), Context.t()) ::
          {:ok, claims()} | {:error, :malformed | :invalid | :expired}
  def verify(token, %Context{now: now} = ctx) when is_binary(token) do
    with {:ok,
          <<@version, difficulty, issued_at::32, expires_at::32, _salt::binary-8, mac::binary-16>> =
            raw} <-
           Base.url_decode64(token, padding: false),
         payload = binary_part(raw, 0, byte_size(raw) - 16),
         :ok <-
           authentic(
             Challenge.keys(ctx.instance, :challenge),
             payload,
             mac,
             Challenge.binding(ctx)
           ),
         :ok <- fresh(expires_at, now) do
      {:ok, %{difficulty: difficulty, issued_at: issued_at, expires_at: expires_at, mac: mac}}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :malformed}
    end
  end

  def verify(_token, _ctx), do: {:error, :malformed}

  defp authentic(keys, payload, mac, binding) do
    valid? =
      Enum.any?(keys, fn key ->
        Plug.Crypto.secure_compare(Challenge.mac(key, [payload, binding]), mac)
      end)

    if valid?, do: :ok, else: {:error, :invalid}
  end

  defp fresh(expires_at, now) do
    if div(now, 1_000) < expires_at, do: :ok, else: {:error, :expired}
  end

  @doc """
  Whether `nonce` solves `token` at `difficulty`: `SHA-256(token <> nonce)`
  starts with at least `difficulty` zero bits.

  Nonces are decimal strings of at most 20 digits.
  """
  @spec solved?(String.t(), String.t(), pos_integer()) :: boolean()
  def solved?(token, nonce, difficulty) when is_binary(nonce) and byte_size(nonce) in 1..20 do
    decimal?(nonce) and leading_zeros?(:crypto.hash(:sha256, token <> nonce), difficulty)
  end

  def solved?(_token, _nonce, _difficulty), do: false

  defp decimal?(<<c, rest::binary>>) when c in ?0..?9, do: decimal?(rest)
  defp decimal?(<<>>), do: true
  defp decimal?(_other), do: false

  defp leading_zeros?(digest, bits) do
    <<prefix::size(^bits), _rest::bitstring>> = digest
    prefix == 0
  end
end
