defmodule Limen.Socket do
  @moduledoc """
  Gates WebSocket connections, which bypass `Limen.Plug`.

  Phoenix dispatches sockets before any plug in the endpoint runs, so a
  client that never passed the HTTP gate could still open a LiveView or
  channel socket. To close that gap:

    1. when rendering a page, embed a socket token issued for the request
       (`token/2`), for example in a meta tag;
    2. send it back as a connect parameter (`_limen` by default);
    3. check it when the socket connects, with `check/3` in a socket's
       `connect/3` callback or with the `Limen.LiveView` `on_mount` hook.

  Tokens are signed with the keys of an instance, and must be checked by the
  same instance.

  The token is signed with its own key and bound to the client prefix, JA4
  and user agent, like a pass cookie, but it is not a pass: it cannot be used
  as a cookie. A client whose identity changed since the page was served
  fails the check, reloads the page, and goes through the HTTP gate again.

  Checking needs the peer address, `x-` headers (for `x-forwarded-for` and
  the JA4 header behind a proxy) and the user agent:

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:peer_data, :x_headers, :user_agent, :uri, session: @session]]

  Each check is a decision at the `:socket` stage, emitted and sampled like
  any other. In dry-run mode failed checks are reported and let through.
  """

  alias Limen.{Challenge, Context, Decision, Gate, Instance, Signal}
  alias Limen.Decision.Match
  alias Limen.State.BanList

  @version 1

  @doc """
  The connect parameter the token is expected in.
  """
  @spec param() :: String.t()
  def param, do: "_limen"

  @doc """
  Issues a socket token for the client of `conn`.

  Returns `nil` when Limen denied the request, in which case the page is
  not being rendered anyway.

  ## Options

    * `:instance` or `:otp_app` - the instance issuing the token. Defaults to
      the instance that made the decision for the request, and must be given
      when `Limen.Plug` made none (on `:off` and `:track` routes).
  """
  @spec token(Plug.Conn.t(), keyword()) :: String.t() | nil
  def token(%Plug.Conn{} = conn, opts \\ []) do
    case Limen.decision(conn) do
      %Decision{enforced: true, action: action} when action != :allow ->
        nil

      decision ->
        instance = Instance.fetch!(token_instance(decision, opts))
        ctx = Signal.identify(Context.from_conn(conn, instance), instance.config)
        expires_at = div(ctx.now, 1_000) + instance.config.challenge.pass_ttl
        [key | _previous] = Challenge.keys(instance, :socket)
        mac = Challenge.mac(key, [<<expires_at::32>>, Challenge.binding(ctx)])
        Base.url_encode64(<<@version, expires_at::32>> <> mac, padding: false)
    end
  end

  defp token_instance(%Decision{instance: name}, []) when name != nil, do: name

  defp token_instance(_decision, []) do
    raise ArgumentError,
          "Limen made no decision for this request, pass the :instance issuing the socket token"
  end

  defp token_instance(_decision, opts), do: Instance.name!(opts)

  @doc """
  Checks a socket connection.

  `connect_info` is what Phoenix passes to `connect/3` (see the module
  documentation for the keys it needs) and `params` the connect parameters.

  ## Options

    * `:instance` or `:otp_app` - the instance checking the token, as for
      `Limen.Plug`. Required.
    * `:mode` - `:dry_run` or `:enforce`, overriding the instance's mode.

  Returns `{:ok, decision}` when the connection may proceed (always, in
  dry-run mode) and `{:error, decision}` when it must be refused.
  """
  @spec check(map(), map(), keyword()) :: {:ok, Decision.t()} | {:error, Decision.t()}
  def check(connect_info, params, opts) do
    started = System.monotonic_time()
    instance = Instance.fetch!(Instance.name!(opts))
    mode = Keyword.get(opts, :mode) || instance.config.mode
    ctx = Signal.identify(context(connect_info, instance), instance.config)

    decision =
      case BanList.lookup(instance, ctx.prefix, ctx.now) do
        nil -> verify(Map.get(params || %{}, param()), ctx, mode)
        ban -> Gate.banned(ban, mode, :socket)
      end

    decision = Gate.finalize(decision, ctx, started)
    :ok = Gate.emit(decision, nil, instance)
    if decision.enforced, do: {:error, decision}, else: {:ok, decision}
  end

  defp verify(token, ctx, mode) do
    case verify_token(token, ctx) do
      {:ok, expires_at} ->
        match = %Match{
          name: :socket_token,
          kind: :pass,
          condition: "a valid socket token",
          observed: [{"expires_at", expires_at}]
        }

        %Decision{action: :allow, stage: :socket, mode: mode, matches: [match]}

      {:error, reason} ->
        %Decision{action: :deny, stage: :socket, mode: mode, errors: [{:socket, reason}]}
    end
  end

  defp verify_token(nil, _ctx), do: {:error, :missing}

  defp verify_token(token, %Context{now: now} = ctx) when is_binary(token) do
    with {:ok, <<@version, expires_at::32, mac::binary-16>>} <-
           Base.url_decode64(token, padding: false),
         true <- div(now, 1_000) < expires_at || {:error, :expired},
         true <-
           authentic?(ctx.instance, expires_at, mac, Challenge.binding(ctx)) ||
             {:error, :invalid} do
      {:ok, expires_at}
    else
      {:error, reason} when reason in [:expired, :invalid] -> {:error, reason}
      _malformed -> {:error, :malformed}
    end
  end

  defp verify_token(_token, _ctx), do: {:error, :malformed}

  defp authentic?(instance, expires_at, mac, binding) do
    Enum.any?(Challenge.keys(instance, :socket), fn key ->
      Plug.Crypto.secure_compare(Challenge.mac(key, [<<expires_at::32>>, binding]), mac)
    end)
  end

  @doc false
  @spec context(map(), Instance.t()) :: Context.t()
  def context(connect_info, instance) do
    address = address!(connect_info)
    uri = Map.get(connect_info, :uri) || %URI{}

    %Context{
      instance: instance,
      peer_ip: address,
      client_ip: address,
      method: "GET",
      scheme: scheme(uri),
      host: uri.host || "",
      path: uri.path || "/",
      query: uri.query || "",
      headers: headers(connect_info),
      now: System.system_time(:millisecond),
      monotonic: System.monotonic_time(:microsecond)
    }
  end

  defp address!(%{peer_data: %{address: address}}), do: address

  defp address!(_connect_info) do
    raise ArgumentError,
          "Limen.Socket needs the :peer_data connect info, add it to the socket's " <>
            "connect_info: [:peer_data, :x_headers, :user_agent, :uri]"
  end

  defp headers(connect_info) do
    headers = Map.get(connect_info, :x_headers) || []

    case Map.get(connect_info, :user_agent) do
      nil -> headers
      user_agent -> [{"user-agent", user_agent} | headers]
    end
  end

  defp scheme(%URI{scheme: scheme}) when scheme in ["https", "wss"], do: :https
  defp scheme(_uri), do: :http
end
