defmodule Limen.SocketTest do
  use Limen.Case, async: true

  alias Limen.Decision

  @ua "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  defp page_token(limen, mode \\ :dry_run) do
    opts = Limen.Plug.init(instance: limen, policy: Limen.Test.Policies.Limited, mode: mode)

    conn(:get, "/live/page")
    |> put_req_header("user-agent", @ua)
    |> put_req_header("accept-language", "en")
    |> Limen.Plug.call(opts)
    |> Limen.Socket.token()
  end

  defp connect_info(overrides \\ %{}) do
    Map.merge(
      %{
        peer_data: %{address: {127, 0, 0, 1}, port: 51_000, ssl_cert: nil},
        x_headers: [],
        user_agent: @ua,
        uri: URI.parse("http://www.example.com/live/page?tab=2")
      },
      overrides
    )
  end

  test "a token issued for a page lets the same client connect", %{limen: limen} do
    token = page_token(limen)

    assert {:ok, %Decision{action: :allow, stage: :socket}} =
             Limen.Socket.check(connect_info(), %{"_limen" => token}, instance: limen)
  end

  test "connections without a valid token are refused in enforce mode", %{limen: limen} do
    token = page_token(limen)

    assert {:error, %Decision{errors: [{:socket, :missing}]}} =
             Limen.Socket.check(connect_info(), %{}, instance: limen, mode: :enforce)

    assert {:error, %Decision{errors: [{:socket, :invalid}]}} =
             Limen.Socket.check(connect_info(%{user_agent: "curl/8.5.0"}), %{"_limen" => token},
               instance: limen,
               mode: :enforce
             )

    assert {:error, %Decision{errors: [{:socket, :malformed}]}} =
             Limen.Socket.check(connect_info(), %{"_limen" => "nope"},
               instance: limen,
               mode: :enforce
             )
  end

  test "in dry-run mode failed checks are reported and let through", %{limen: limen} do
    assert {:ok, %Decision{action: :deny, enforced: false}} =
             Limen.Socket.check(connect_info(), %{}, instance: limen)
  end

  @tag config: [challenge: [bind: [:ja4, :user_agent]]]
  test "tokens follow the pass binding", %{limen: limen} do
    token = page_token(limen)
    moved = connect_info(%{peer_data: %{address: {192, 0, 2, 44}, port: 1, ssl_cert: nil}})

    assert {:ok, %Decision{action: :allow}} =
             Limen.Socket.check(moved, %{"_limen" => token}, instance: limen, mode: :enforce)
  end

  test "banned clients cannot connect", %{limen: limen} do
    token = page_token(limen)
    Limen.ban(limen, {127, 0, 0, 1}, 60)

    assert {:error, %Decision{stage: :socket, matches: [%{kind: :ban}]}} =
             Limen.Socket.check(connect_info(), %{"_limen" => token},
               instance: limen,
               mode: :enforce
             )
  end

  test "socket tokens are not passes", %{limen: limen} do
    token = page_token(limen)

    conn =
      conn(:get, "/")
      |> put_req_header("user-agent", @ua)
      |> put_req_header("cookie", "_limen_pass=" <> token)
      |> Limen.Plug.call(
        Limen.Plug.init(instance: limen, policy: Limen.Test.Policies.Challenging)
      )

    assert %Decision{action: :challenge, evidence: %{pass: :invalid}} = Limen.decision(conn)
  end

  test "no token for pages Limen refused", %{limen: limen} do
    assert page_token(limen, :enforce) != nil

    refused =
      conn(:get, "/")
      |> Limen.Plug.call(
        Limen.Plug.init(instance: limen, policy: Limen.Test.Policies.Login, mode: :enforce)
      )

    assert Limen.Socket.token(refused) == nil
  end

  test "explains how to configure connect info", %{limen: limen} do
    # Built at runtime: the type checker rightly sees a literal cannot succeed.
    missing = :maps.from_list([])

    assert_raise ArgumentError, ~r/connect_info: \[:peer_data/, fn ->
      Limen.Socket.check(missing, %{}, instance: limen)
    end
  end

  test "tokens are issued and checked by one instance", %{limen: limen} do
    other = :"#{limen}_other"

    config = [
      secret_key: String.duplicate("other", 8),
      decision_log: [non_allow_sample_rate: 0.0]
    ]

    start_supervised!({Limen, name: other, config: config}, id: other)
    token = page_token(limen)

    assert {:error, %Decision{instance: ^other, errors: [{:socket, :invalid}]}} =
             Limen.Socket.check(connect_info(), %{"_limen" => token},
               instance: other,
               mode: :enforce
             )
  end

  test "requests Limen made no decision for need the instance", %{limen: limen} do
    conn = conn(:get, "/") |> put_req_header("user-agent", @ua)

    assert_raise ArgumentError, ~r/pass the :instance/, fn -> Limen.Socket.token(conn) end

    token = Limen.Socket.token(conn, instance: limen)

    assert {:ok, %Decision{action: :allow}} =
             Limen.Socket.check(connect_info(), %{"_limen" => token}, instance: limen)
  end

  defmodule PageLive do
    use Phoenix.LiveView

    def render(assigns), do: ~H""
  end

  defmodule Router do
    use Phoenix.Router

    import Phoenix.LiveView.Router

    live "/", PageLive
    live "/:locale", PageLive
    live "/docs/v:version/*page", PageLive, :docs
  end

  describe "Limen.LiveView" do
    # What a LiveView socket holds while mounting: the connect info is the
    # socket's, not the page's.
    defp socket(connect_info, params, connected? \\ true, action \\ nil) do
      websocket = URI.parse("http://www.example.com/live/websocket?vsn=2.0.0")

      %Phoenix.LiveView.Socket{
        transport_pid: if(connected?, do: self()),
        router: Router,
        view: PageLive,
        assigns: %{__changed__: %{}, live_action: action},
        private: %{
          connect_info: Map.put(connect_info, :uri, websocket),
          connect_params: params,
          lifecycle: %Phoenix.LiveView.Lifecycle{}
        }
      }
    end

    defp refused(limen, params, socket) do
      assert {:halt, socket} =
               Limen.LiveView.on_mount([instance: limen, mode: :enforce], params, %{}, socket)

      assert {:redirect, %{to: to}} = socket.redirected
      to
    end

    test "lets valid connections mount", %{limen: limen} do
      socket = socket(connect_info(), %{"_limen" => page_token(limen)})
      assert {:cont, _socket} = Limen.LiveView.on_mount([instance: limen], %{}, %{}, socket)
    end

    test "sends refused connections back to the page, through the HTTP gate", %{limen: limen} do
      assert refused(limen, %{}, socket(connect_info(), %{})) == "/"

      assert refused(limen, %{"locale" => "fr", "tab" => "2"}, socket(connect_info(), %{})) ==
               "/fr?tab=2"

      docs = socket(connect_info(), %{}, true, :docs)
      params = %{"version" => "2", "page" => ["guides", "a b"]}
      assert refused(limen, params, docs) == "/docs/v2/guides/a%20b"

      # Rendered outside the router.
      outside = %{socket(connect_info(), %{}) | router: nil}
      assert refused(limen, :not_mounted_at_router, outside) == "/"
    end

    @tag config: [mode: :enforce]
    test "keeps the connect info to check forms after mounting", %{limen: limen} do
      socket = socket(connect_info(), %{"_limen" => page_token(limen)})
      {:cont, mounted} = Limen.LiveView.on_mount([instance: limen], %{}, %{}, socket)
      # Connect info is gone once mounted, as in LiveView.
      mounted = %{mounted | private: Map.delete(mounted.private, :connect_info)}

      {:safe, fields} = Limen.Trap.form_fields(limen)

      [_all, token] =
        Regex.run(~r/name="_limen_form" value="([^"]+)"/, IO.iodata_to_binary(fields))

      assert {:trapped, %Limen.Decision{stage: :trap, identity: %{client_ip: {127, 0, 0, 1}}}} =
               Limen.LiveView.check_form(mounted, %{"_limen_form" => token}, instance: limen)
    end

    # In production the connect info's URI is the socket's, not the page's.
    @tag config: [mode: :enforce]
    test "form checks record the page's path, not the socket's", %{limen: limen} do
      socket = socket(connect_info(), %{"_limen" => page_token(limen)})

      # Views rendered outside the router get no URL to follow.
      {:cont, outside} =
        Limen.LiveView.on_mount([instance: limen], %{}, %{}, %{socket | router: nil})

      assert outside.private.lifecycle.handle_params == []

      {:cont, mounted} = Limen.LiveView.on_mount([instance: limen], %{}, %{}, socket)
      mounted = %{mounted | private: Map.delete(mounted.private, :connect_info)}
      assert [%{id: :limen_page}] = mounted.private.lifecycle.handle_params

      # Before LiveView reports the page, the socket's URI is all there is.
      assert {:trapped, %Limen.Decision{path: "/live/websocket"}} =
               Limen.LiveView.check_form(mounted, %{}, instance: limen)

      {:cont, mounted} =
        Limen.LiveView.__handle_params__(%{}, "http://www.example.com/signup?step=2", mounted)

      assert {:trapped, %Limen.Decision{path: "/signup", method: "GET"}} =
               Limen.LiveView.check_form(mounted, %{}, instance: limen)
    end

    test "needs the instance" do
      assert_raise ArgumentError, ~r/needs the instance/, fn ->
        Limen.LiveView.on_mount(:default, %{}, %{}, socket(%{}, %{}))
      end
    end

    test "does not check the disconnected render", %{limen: limen} do
      socket = socket(%{}, %{}, false)

      assert {:cont, _socket} =
               Limen.LiveView.on_mount([instance: limen, mode: :enforce], %{}, %{}, socket)
    end
  end
end
