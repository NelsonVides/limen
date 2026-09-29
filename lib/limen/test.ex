defmodule Limen.Test do
  @moduledoc """
  Helpers for testing an application that uses Limen.

  An application's tests usually share one instance, the one its
  supervision tree starts, configured for tests in `config/test.exs`. Most
  tests should not care about Limen at all, so run that instance in dry-run
  mode: every request is evaluated and recorded, and none is refused. The
  tests that are about Limen then enforce it request by request, and give
  each test a client address of its own, so they can run concurrently
  without seeing each other's bans:

      test "a client without a user agent is challenged", %{conn: conn} do
        conn =
          conn
          |> Limen.Test.put_client_ip(Limen.Test.unique_ip())
          |> Limen.Test.put_mode(:enforce)
          |> get(~p"/")

        assert html_response(conn, 403) =~ "Checking your browser"
        assert %Limen.Decision{action: :challenge} = Limen.decision(conn)
      end

  Changing the instance itself, with `Limen.set_mode/2` or
  `Limen.update_config/3`, affects every test using it: keep those to tests
  that run on their own (`async: false`).

  ## LiveView

  `Phoenix.LiveViewTest` connects its sockets with the test's request, but
  reports the test adapter's address as the socket's peer, not the
  `remote_ip` the request was given; `put_client_ip/2` sets both, so the
  socket check sees the client the HTTP gate saw. `put_socket_token/2` then
  gives the socket the token the page would embed, and `put_mode/2` applies
  to the socket check and to `Limen.LiveView.check_form/3` too:

      conn =
        conn
        |> Limen.Test.put_client_ip(Limen.Test.unique_ip())
        |> Limen.Test.put_mode(:enforce)
        |> put_req_header("user-agent", "Mozilla/5.0 ...")
        |> Limen.Test.put_socket_token(otp_app: :my_app)

      {:ok, view, _html} = live(conn, ~p"/signup")

  ## Decision log sinks

  A `Limen.DecisionLog.Sink` normally runs in a background process, which a
  test's Ecto sandbox doesn't allow. Configure the test instance with
  `decision_log: [delivery: :inline]` to hand each sampled decision to the
  sink in the process that made it, so what it writes is in the test's
  transaction as soon as the request returns. See the testing guide.

  ## Isolated instances

  To test a policy on its own, start an instance of your own for the test,
  which shares nothing with any other:

      setup do
        start_supervised!({Limen, name: :policy_test, config: [mode: :enforce]})
        :ok
      end

      test "curl is challenged" do
        opts = Limen.Plug.init(instance: :policy_test, policy: MyApp.BotPolicy)
        conn = conn(:get, "/") |> put_req_header("user-agent", "curl/8.5.0")

        assert %Limen.Decision{action: :challenge} = Limen.decision(Limen.Plug.call(conn, opts))
      end
  """

  @doc """
  An IPv6 address no other call returns, in the documentation range
  `2001:db8::/32`: a client of its own for a test.

  Addresses differ in their `/48` (for the first 65,536 calls) and in their
  `/64`, so they are different clients whatever the instance's
  `:ipv6_prefix`.
  """
  @spec unique_ip() :: :inet.ip6_address()
  def unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {0x2001, 0x0DB8, rem(n, 0x10000), rem(div(n, 0x10000), 0x10000), 0, 0, 0, 1}
  end

  @doc """
  Makes `ip` the address of the client sending `conn`, for `Limen.Plug` and
  for `Phoenix.LiveViewTest` sockets, which read it from the connection's
  peer data.
  """
  @spec put_client_ip(Plug.Conn.t(), :inet.ip_address()) :: Plug.Conn.t()
  def put_client_ip(%Plug.Conn{} = conn, ip) when is_tuple(ip) do
    %{conn | remote_ip: ip}
    |> Plug.Test.put_peer_data(%{address: ip, port: 51_000, ssl_cert: nil})
  end

  @doc """
  Sets the mode for this request only, overriding the instance's, the
  plug's, the route's and the policy's: `Limen.Plug`, form checks with the
  connection, and in LiveView tests the socket check and
  `Limen.LiveView.check_form/3` follow it.
  """
  @spec put_mode(Plug.Conn.t(), :dry_run | :enforce) :: Plug.Conn.t()
  def put_mode(%Plug.Conn{} = conn, mode) when mode in [:dry_run, :enforce] do
    Plug.Conn.put_private(conn, :limen_mode, mode)
  end

  @doc """
  The connect parameters carrying the socket token for the client of
  `conn`, as `app.js` sends them. Options are those of
  `Limen.Socket.token/2`: pass the instance unless `conn` already went
  through `Limen.Plug`.
  """
  @spec socket_params(Plug.Conn.t(), keyword()) :: %{String.t() => String.t()}
  def socket_params(%Plug.Conn{} = conn, opts \\ []) do
    %{Limen.Socket.param() => Limen.Socket.token(conn, opts)}
  end

  if Code.ensure_loaded?(Phoenix.LiveViewTest) do
    @doc """
    Adds the socket token for the client of `conn` to the connect
    parameters `Phoenix.LiveViewTest.live/2` connects with, keeping any
    already set. Options are those of `socket_params/2`.
    """
    @spec put_socket_token(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
    def put_socket_token(%Plug.Conn{} = conn, opts \\ []) do
      params =
        Map.merge(conn.private[:live_view_connect_params] || %{}, socket_params(conn, opts))

      Phoenix.LiveViewTest.put_connect_params(conn, params)
    end
  end
end
