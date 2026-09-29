defmodule Limen.Challenge.Pass do
  @moduledoc """
  The pass cookie a client gets for solving a challenge.

  Like challenge tokens, passes are stateless: an expiry and a truncated
  [HMAC]-SHA256 over it and the client identity (see
  `Limen.Challenge.binding/1`), with a key only used for passes.

      <<version, expires_at::32, mac::16 bytes>>

  Verifying one is the fast path of `Limen.Plug`: parse the cookie header,
  decode 28 characters, compute one HMAC.

  [HMAC]: https://www.rfc-editor.org/rfc/rfc2104
  """

  alias Limen.{Challenge, Context}

  @version 1

  @doc """
  Issues a pass for the client in `ctx`, returning the cookie value and its
  lifetime in seconds.
  """
  @spec issue(Context.t()) :: {String.t(), pos_integer()}
  def issue(%Context{now: now} = ctx) do
    ttl = ctx.instance.config.challenge.pass_ttl
    expires_at = div(now, 1_000) + ttl
    [key | _previous] = Challenge.keys(ctx.instance, :pass)
    mac = Challenge.mac(key, [<<expires_at::32>>, Challenge.binding(ctx)])
    {Base.url_encode64(<<@version, expires_at::32>> <> mac, padding: false), ttl}
  end

  @doc """
  Verifies the pass the client in `ctx` presents, if any.
  """
  @spec verify(Context.t()) ::
          {:ok, non_neg_integer()} | {:error, :missing | :malformed | :invalid | :expired}
  def verify(%Context{} = ctx) do
    case cookie(ctx.headers, ctx.instance.config.challenge.cookie) do
      nil -> {:error, :missing}
      value -> verify(value, ctx)
    end
  end

  @doc """
  Verifies a pass cookie value for the client in `ctx`.
  """
  @spec verify(String.t(), Context.t()) ::
          {:ok, non_neg_integer()} | {:error, :malformed | :invalid | :expired}
  def verify(value, %Context{now: now} = ctx) do
    with {:ok, <<@version, expires_at::32, mac::binary-16>>} <-
           Base.url_decode64(value, padding: false),
         true <- div(now, 1_000) < expires_at || {:error, :expired},
         keys = Challenge.keys(ctx.instance, :pass),
         true <- authentic?(keys, expires_at, mac, Challenge.binding(ctx)) || {:error, :invalid} do
      {:ok, expires_at}
    else
      {:error, reason} when reason in [:expired, :invalid] -> {:error, reason}
      _malformed -> {:error, :malformed}
    end
  end

  defp authentic?(keys, expires_at, mac, binding) do
    Enum.any?(keys, fn key ->
      Plug.Crypto.secure_compare(Challenge.mac(key, [<<expires_at::32>>, binding]), mac)
    end)
  end

  @doc """
  Sets the pass cookie on `conn`.
  """
  @spec put_cookie(Plug.Conn.t(), Limen.Instance.t(), String.t(), pos_integer()) :: Plug.Conn.t()
  def put_cookie(conn, %Limen.Instance{config: %{challenge: config}}, value, max_age) do
    secure =
      case config.secure_cookie do
        :auto -> conn.scheme == :https
        secure -> secure
      end

    Plug.Conn.put_resp_cookie(conn, config.cookie, value,
      max_age: max_age,
      path: "/",
      http_only: true,
      secure: secure,
      same_site: "Lax"
    )
  end

  @doc """
  Finds cookie `name` in request headers without parsing every cookie.

      iex> Limen.Challenge.Pass.cookie([{"cookie", "a=1; _limen_pass=abc; b=2"}], "_limen_pass")
      "abc"
  """
  @spec cookie([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def cookie(headers, name), do: find_header(headers, name <> "=")

  # HTTP/2 clients may send each cookie in its own header.
  defp find_header([{"cookie", value} | headers], prefix) do
    case find_cookie(:binary.split(value, ";", [:global]), prefix) do
      nil -> find_header(headers, prefix)
      cookie -> cookie
    end
  end

  defp find_header([_header | headers], prefix), do: find_header(headers, prefix)
  defp find_header([], _prefix), do: nil

  defp find_cookie([], _prefix), do: nil

  defp find_cookie([pair | rest], prefix) do
    pair = String.trim_leading(pair)
    size = byte_size(prefix)

    case pair do
      <<^prefix::binary-size(^size), value::binary>> -> String.trim_trailing(value)
      _other -> find_cookie(rest, prefix)
    end
  end
end
