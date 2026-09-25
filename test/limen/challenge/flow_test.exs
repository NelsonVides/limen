defmodule Limen.Challenge.FlowTest do
  use Limen.Case, async: true

  alias Limen.Challenge.Token
  alias Limen.Decision
  alias Limen.Test.Policies.Challenging
  alias Limen.Test.Pow

  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:130.0) Gecko/20100101 Firefox/130.0"

  setup %{limen: limen} do
    %{opts: Limen.Plug.init(instance: limen, policy: Challenging)}
  end

  defp request(opts, method \\ :get, path \\ "/articles?page=2", body \\ nil, headers \\ []) do
    conn(method, path, body)
    |> put_req_header("user-agent", @browser)
    |> put_req_header("accept", "text/html,*/*;q=0.8")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, conn -> put_req_header(conn, k, v) end))
    |> Limen.Plug.call(opts)
  end

  defp token(conn), do: attribute(conn.resp_body, "data-token")

  defp attribute(html, name) do
    [_all, value] = Regex.run(~r/#{name}="([^"]*)"/, html)
    value
  end

  defp verify(opts, token, nonce, fields \\ %{}) do
    body =
      %{"token" => token, "nonce" => nonce, "return_to" => "/articles?page=2"}
      |> Map.merge(fields)
      |> URI.encode_query()

    request(opts, :post, "/__limen/verify", body, [
      {"content-type", "application/x-www-form-urlencoded"}
    ])
  end

  defp pass_cookie(conn), do: conn.resp_cookies["_limen_pass"]

  test "a navigation gets the challenge page", %{opts: opts, limen: limen} do
    conn = request(opts)

    assert conn.status == 403
    assert conn.halted
    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "script-src 'self'"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body =~ ~s(data-difficulty="8")
    assert conn.resp_body =~ ~s(name="return_to" value="/articles?page=2")
    assert conn.resp_body =~ ~s(name="instance" value="#{limen}")
    assert conn.resp_body =~ ~r{<script src="/__limen/solver.js\?v=[\w-]+" defer>}
    refute conn.resp_body =~ "<script>"
    assert %Decision{action: :challenge, enforced: true} = Limen.decision(conn)
  end

  test "solving it sets a pass that the fast path accepts", %{opts: opts, limen: limen} do
    capture_events([[:limen, :challenge, :verified]], limen)
    token = token(request(opts))
    verified = verify(opts, token, Pow.solve(token, 8))

    assert verified.status == 303
    assert get_resp_header(verified, "location") == ["/articles?page=2"]
    assert %{value: pass, http_only: true, same_site: "Lax"} = pass_cookie(verified)
    assert %Decision{action: :allow, stage: :endpoint} = Limen.decision(verified)

    assert_receive {:event, [:limen, :challenge, :verified], _measurements,
                    %{result: {:ok, _claims}}}

    conn = request(opts, :get, "/articles?page=2", nil, [{"cookie", "_limen_pass=#{pass}"}])
    refute conn.halted
    assert %Decision{action: :allow, stage: :pass, signals: signals} = Limen.decision(conn)
    assert signals == %{}
  end

  test "a solved token cannot be used twice", %{opts: opts} do
    token = token(request(opts))
    nonce = Pow.solve(token, 8)

    assert verify(opts, token, nonce).status == 303
    replayed = verify(opts, token, nonce)
    assert replayed.status == 403

    assert %Decision{action: :deny, errors: [{:challenge, :pow, :replayed}]} =
             Limen.decision(replayed)
  end

  test "wrong nonces and tokens from other clients fail", %{opts: opts} do
    token = token(request(opts))
    assert verify(opts, token, "1").status == 403 or Token.solved?(token, "1", 8)

    other =
      conn(:get, "/")
      |> put_req_header("user-agent", "curl/8.5.0")
      |> Limen.Plug.call(opts)
      |> then(&attribute(&1.resp_body, "data-token"))

    conn = verify(opts, other, Pow.solve(other, 8))
    assert conn.status == 403
    assert %Decision{errors: [{:challenge, :pow, :invalid}]} = Limen.decision(conn)
  end

  test "a pass stops working when the identity changes", %{opts: opts} do
    token = token(request(opts))
    %{value: pass} = pass_cookie(verify(opts, token, Pow.solve(token, 8)))

    conn =
      conn(:get, "/")
      |> put_req_header("user-agent", "Another browser")
      |> put_req_header("cookie", "_limen_pass=#{pass}")
      |> Limen.Plug.call(opts)

    assert %Decision{action: :challenge, evidence: %{pass: :invalid}} = Limen.decision(conn)
  end

  test "expired challenges send the client back for a fresh one", %{opts: opts} do
    conn = request(opts)
    token = token(conn)

    expired =
      conn(
        :post,
        "/__limen/verify",
        URI.encode_query(%{"token" => token, "nonce" => "0", "return_to" => "/x"})
      )
      |> put_req_header("user-agent", @browser)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_private(:limen_now, System.system_time(:millisecond) + 301_000)
      |> Limen.Plug.call(opts)

    assert expired.status == 303
    assert get_resp_header(expired, "location") == ["/x"]
  end

  test "redirects never leave the site", %{opts: opts} do
    token = token(request(opts))
    conn = verify(opts, token, Pow.solve(token, 8), %{"return_to" => "//evil.example/"})
    assert get_resp_header(conn, "location") == ["/"]
  end

  test "requests that cannot render a page get a plain 403", %{opts: opts} do
    conn =
      conn(:post, "/api/items", "{}")
      |> put_req_header("accept", "application/json")
      |> Limen.Plug.call(opts)

    assert conn.status == 403
    assert get_resp_header(conn, "limen-challenge") == ["required"]
  end

  describe "routes using another instance" do
    setup %{limen: limen} do
      admin = :"#{limen}_admin"

      config = [
        secret_key: String.duplicate("admin", 8),
        decision_log: [non_allow_sample_rate: 0.0]
      ]

      start_supervised!({Limen, name: admin, config: config}, id: admin)
      routes = [{"/admin", Challenging, instance: admin}]
      %{admin: admin, opts: Limen.Plug.init(instance: limen, policy: Challenging, routes: routes)}
    end

    test "are challenged and verified with that instance's keys", %{opts: opts, admin: admin} do
      page = request(opts, :get, "/admin/users")
      assert page.resp_body =~ ~s(name="instance" value="#{admin}")
      assert %Decision{action: :challenge, instance: ^admin} = Limen.decision(page)

      token = token(page)
      fields = %{"instance" => Atom.to_string(admin), "return_to" => "/admin/users"}
      verified = verify(opts, token, Pow.solve(token, 8), fields)

      assert verified.status == 303
      assert %Decision{action: :allow, instance: ^admin} = Limen.decision(verified)
      %{value: pass} = pass_cookie(verified)
      cookie = [{"cookie", "_limen_pass=#{pass}"}]

      refute request(opts, :get, "/admin/users", nil, cookie).halted
      assert request(opts, :get, "/articles", nil, cookie).halted
    end

    test "only accept instances the plug uses", %{opts: opts, admin: admin} do
      token = token(request(opts, :get, "/admin"))
      nonce = Pow.solve(token, 8)

      for instance <- [nil, "limen_unknown", "#{admin}x"] do
        fields = if instance, do: %{"instance" => instance}, else: %{}
        assert verify(opts, token, nonce, fields).status == 403
      end
    end
  end

  describe "without JavaScript" do
    defp wait(opts, token, now_offset) do
      query = URI.encode_query(%{"token" => token, "return_to" => "/articles"})

      conn(:get, "/__limen/wait?" <> query)
      |> put_req_header("user-agent", @browser)
      |> put_private(:limen_now, System.system_time(:millisecond) + now_offset)
      |> Limen.Plug.call(opts)
    end

    test "the page refreshes to the wait endpoint, which lets the client in after the delay", %{
      opts: opts
    } do
      page = request(opts)

      assert page.resp_body =~
               ~r{<noscript><meta http-equiv="refresh" content="5;url=/__limen/wait\?}

      token = token(page)

      too_early = wait(opts, token, 0)
      assert too_early.status == 303
      assert pass_cookie(too_early) == nil

      waited = wait(opts, token, 6_000)
      assert waited.status == 303
      assert get_resp_header(waited, "location") == ["/articles"]
      assert pass_cookie(waited)
    end

    @tag config: [challenge: [no_js: :deny]]
    test "can be denied", %{opts: opts} do
      page = request(opts)
      refute page.resp_body =~ "http-equiv"
      assert page.resp_body =~ "Please enable JavaScript"
      assert wait(opts, token(page), 60_000).status == 403
    end
  end

  test "serves the solver assets", %{opts: opts} do
    for {name, type} <- [
          {"solver.js", "text/javascript"},
          {"worker.js", "text/javascript"},
          {"challenge.css", "text/css"}
        ] do
      conn = Limen.Plug.call(conn(:get, "/__limen/" <> name), opts)
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{type}; charset=utf-8"]
    end

    assert Limen.Plug.call(conn(:get, "/__limen/nope"), opts).status == 404
  end

  @tag config: [challenge: [path: "/.well-known/limen"]]
  test "the challenge path is configurable", %{opts: opts} do
    assert request(opts).resp_body =~ ~s(action="/.well-known/limen/verify")
    assert Limen.Plug.call(conn(:get, "/.well-known/limen/worker.js"), opts).status == 200
  end
end
