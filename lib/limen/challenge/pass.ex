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
    case find_header(ctx.cookie_headers, ctx.instance.cookie_pattern) do
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
  Finds cookie `name` in the values of `cookie` headers without parsing
  every cookie.

      iex> Limen.Challenge.Pass.cookie(["a=1; _limen_pass=abc; b=2"], "_limen_pass")
      "abc"
  """
  @spec cookie([String.t()], String.t()) :: String.t() | nil
  def cookie(cookie_headers, name),
    do: find_header(cookie_headers, :binary.compile_pattern(name <> "="))

  # HTTP/2 clients may send each cookie in its own header.
  defp find_header([value | cookie_headers], pattern) do
    case find_cookie(value, pattern, 0) do
      nil -> find_header(cookie_headers, pattern)
      cookie -> cookie
    end
  end

  defp find_header([], _pattern), do: nil

  # Searches for `name=` rather than splitting the header into cookies. The
  # name can also appear inside another cookie's name or value, so a match
  # only counts where a cookie starts.
  defp find_cookie(value, pattern, from) do
    case :binary.match(value, pattern, scope: {from, byte_size(value) - from}) do
      :nomatch ->
        nil

      {start, length} ->
        if starts_cookie?(value, start, start - 1),
          do: cookie_value(value, start + length, start + length),
          else: find_cookie(value, pattern, start + 1)
    end
  end

  # A cookie starts the header or follows a ";", after optional whitespace.
  defp starts_cookie?(_value, _start, -1), do: true

  defp starts_cookie?(value, start, at) do
    case :binary.at(value, at) do
      ?; -> true
      byte when byte in [?\s, ?\t] -> starts_cookie?(value, start, at - 1)
      _other -> blank_since_separator?(value, start)
    end
  end

  # Anything else between the previous ";" and the name must be whitespace
  # as `String.trim_leading/1` knows it, as when cookies were split.
  defp blank_since_separator?(value, start) do
    after_separator =
      case :binary.matches(value, ";", scope: {0, start}) do
        [] -> 0
        separators -> elem(List.last(separators), 0) + 1
      end

    String.trim_leading(binary_part(value, after_separator, start - after_separator)) == ""
  end

  # The value runs to the next ";" or the end of the header.
  defp cookie_value(value, from, at) when at == byte_size(value),
    do: String.trim_trailing(binary_part(value, from, at - from))

  defp cookie_value(value, from, at) do
    case :binary.at(value, at) do
      ?; -> String.trim_trailing(binary_part(value, from, at - from))
      _byte -> cookie_value(value, from, at + 1)
    end
  end
end
