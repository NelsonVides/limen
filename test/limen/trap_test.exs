defmodule Limen.TrapTest do
  use Limen.Case, async: true

  alias Limen.{Decision, Trap}

  @moduletag config: [trap: [paths: ["/archive/directory", "/old"]], maze: [delay: {0, 0}]]

  @browser "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

  defp request(limen, path, opts \\ []) do
    method = Keyword.get(opts, :method, :get)

    conn(method, path)
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, {192, 0, 2, 10}))
    |> put_req_header("user-agent", Keyword.get(opts, :user_agent, @browser))
    |> Limen.Plug.call(Limen.Plug.init(instance: limen, mode: Keyword.get(opts, :mode)))
  end

  describe "helpers" do
    test "list the trap paths for robots.txt", %{limen: limen} do
      assert Trap.paths(limen) == ["/archive/directory", "/old"]
      assert Trap.robots(limen) == "Disallow: /archive/directory\nDisallow: /old\n"
    end

    test "link into a trap with a stable, plausible URL", %{limen: limen} do
      href = Trap.href(limen)
      assert href =~ ~r{^/archive/directory/[a-z0-9-]+$}
      assert href == Trap.href(limen)
      assert Trap.href(limen, path: "/old") =~ ~r{^/old/}
      assert_raise ArgumentError, ~r/not a trap path/, fn -> Trap.href(limen, path: "/nope") end
    end

    test "hide the link from people", %{limen: limen} do
      {:safe, html} = Trap.link(limen)
      html = IO.iodata_to_binary(html)

      assert html =~ ~s(href="#{Trap.href(limen)}")
      assert html =~ ~s(rel="nofollow")
      assert html =~ ~s(tabindex="-1")
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(style="position:absolute;left:-10000px)

      {:safe, html} = Trap.link(limen, class: "sr-only", text: "Directory <all>")
      html = IO.iodata_to_binary(html)
      assert html =~ ~s(class="sr-only")
      refute html =~ "style="
      assert html =~ "Directory &lt;all&gt;"
    end

    @tag config: []
    test "need trap paths", %{limen: limen} do
      assert Trap.robots(limen) == ""
      assert_raise ArgumentError, ~r/has no trap paths/, fn -> Trap.link(limen) end
    end
  end

  describe "configuration" do
    test "rejects invalid trap paths" do
      for paths <- [["archive"], ["/archive/"], ["/"], "/archive"] do
        assert_raise ArgumentError, ~r/invalid Limen trap option/, fn ->
          Limen.Config.build(trap: [paths: paths])
        end
      end
    end

    test "rejects traps Limen's own endpoints would shadow" do
      assert_raise ArgumentError, ~r/under the challenge path/, fn ->
        Limen.Config.build(trap: [paths: ["/__limen/trap"]])
      end

      assert_raise ArgumentError, ~r/under the challenge path/, fn ->
        Limen.Config.build(trap: [paths: ["/hidden/x"]], challenge: [path: "/hidden"])
      end
    end
  end

  describe "link traps" do
    @describetag config: [
                   mode: :enforce,
                   trap: [paths: ["/archive/directory"], ban: 600],
                   maze: [delay: {0, 0}]
                 ]

    test "flag the client and send it to the maze", %{limen: limen} do
      conn = request(limen, "/archive/directory/regional-reports")

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body =~ ~s(href="/archive/directory/)

      assert %Decision{action: :maze, stage: :trap, enforced: true, params: %{ban: 600}} =
               decision = Limen.decision(conn)

      assert [%{name: :trap, kind: :trap, observed: [{"trap", "/archive/directory"} | _path]}] =
               decision.matches

      assert Limen.Decision.explain(decision) =~ "trap trap when requested a trap path"

      assert %{action: :maze, origin: :trap, reason: :trap, mode: :enforce} =
               Limen.banned(limen, {192, 0, 2, 10})

      assert Limen.Stats.snapshot(limen).trap_hit == 1
    end

    test "keep flagged clients in the maze, wherever they go", %{limen: limen} do
      request(limen, "/archive/directory/x")
      conn = request(limen, "/products/42")

      assert %Decision{action: :maze, stage: :ban, enforced: true} = Limen.decision(conn)
      assert conn.resp_body =~ ~s(href="/archive/directory/)
      assert request(limen, "/api/items", method: :post).status == 403
      assert request(limen, "/products/42", ip: {192, 0, 2, 11}).state == :unset
    end

    test "escalate a denial ban to the maze", %{limen: limen} do
      Limen.ban(limen, {192, 0, 2, 10}, 60)
      conn = request(limen, "/archive/directory/x")

      assert %Decision{action: :maze, stage: :trap} = Limen.decision(conn)
      assert %{action: :maze} = Limen.banned(limen, {192, 0, 2, 10})
    end

    test "never flag crawlers verified by DNS, or being verified", %{limen: limen} do
      instance = instance(limen)
      expires_at = System.system_time(:millisecond) + 60_000

      :ets.insert(
        instance.state.fcrdns.cache,
        {{{66, 249, 66, 1}, "googlebot"}, :verified, "crawl.googlebot.com", expires_at}
      )

      for ip <- [{66, 249, 66, 1}, {66, 249, 66, 2}] do
        conn = request(limen, "/archive/directory/x", ip: ip, user_agent: @googlebot)

        assert %Decision{action: :allow, stage: :trap, matches: [%{name: :trap}, crawler]} =
                 Limen.decision(conn)

        assert crawler.name == :crawler
        refute conn.halted
        refute Limen.banned(limen, ip)
      end
    end
  end

  describe "link traps in dry-run" do
    @describetag config: [trap: [paths: ["/archive/directory"]], maze: [delay: {0, 0}]]

    test "record everything but let the request through", %{limen: limen} do
      conn = request(limen, "/archive/directory/x")

      refute conn.halted
      assert conn.state == :unset
      assert %Decision{action: :maze, stage: :trap, enforced: false} = Limen.decision(conn)
      assert %{action: :maze, mode: :dry_run} = Limen.banned(limen, {192, 0, 2, 10})

      conn = request(limen, "/products/42", mode: :enforce)
      refute conn.halted
      assert %Decision{action: :maze, stage: :ban, enforced: false} = Limen.decision(conn)
    end
  end

  describe "form traps" do
    @describetag config: [mode: :enforce, trap: [min_fill_time: 2_000]]

    defp form(limen) do
      {:safe, html} = Trap.form_fields(limen)
      document = LazyHTML.from_fragment(IO.iodata_to_binary(html))

      for input <- LazyHTML.query(document, "input"), into: %{} do
        [name] = LazyHTML.attribute(input, "name")
        [value] = LazyHTML.attribute(input, "value")
        {name, value}
      end
    end

    defp submit(limen, params, opts \\ []) do
      conn(:post, "/signup")
      |> Map.put(:remote_ip, {198, 51, 100, 7})
      |> put_req_header("user-agent", @browser)
      |> put_private(
        :limen_now,
        System.system_time(:millisecond) + Keyword.get(opts, :after, 5_000)
      )
      |> Trap.check_form(params, Keyword.merge([instance: limen], opts))
    end

    test "render a decoy field and a signed timestamp", %{limen: limen} do
      assert %{"website" => "", "_limen_form" => token} = form(limen)
      assert byte_size(token) > 20

      {:safe, html} = Trap.form_fields(limen)
      assert IO.iodata_to_binary(html) =~ ~s(tabindex="-1" autocomplete="off")
    end

    test "let people through", %{limen: limen} do
      assert {:ok, %Decision{action: :allow, stage: :trap, matches: [match]}} =
               submit(limen, Map.put(form(limen), "email", "a@example.com"))

      assert %{name: :form_filled_in, observed: [{"elapsed_ms", elapsed}]} = match
      assert elapsed >= 5_000
      refute Limen.banned(limen, {198, 51, 100, 7})
    end

    test "catch filled decoys, hasty submissions and missing or forged timestamps",
         %{limen: limen} do
      cases = [
        {%{form(limen) | "website" => "http://spam.example"}, [], :form_decoy},
        {form(limen), [after: 500], :form_too_fast},
        {Map.delete(form(limen), "_limen_form"), [], :form_token},
        {%{form(limen) | "_limen_form" => "AQAAAZL" <> String.duplicate("x", 24)}, [],
         :form_token}
      ]

      for {params, opts, tell} <- cases do
        assert {:trapped, %Decision{action: :maze, enforced: true, matches: matches}} =
                 submit(limen, params, opts)

        assert tell in Enum.map(matches, & &1.name)
      end

      assert %{action: :maze, origin: :trap} = Limen.banned(limen, {198, 51, 100, 7})
    end

    @tag config: [trap: [min_fill_time: 2_000]]
    test "only report in dry-run mode", %{limen: limen} do
      params = %{form(limen) | "website" => "filled"}

      assert {:ok, %Decision{action: :maze, enforced: false}} = submit(limen, params)
      assert %{mode: :dry_run} = Limen.banned(limen, {198, 51, 100, 7})
      assert {:trapped, _decision} = submit(limen, params, mode: :enforce)
    end

    test "default to the instance that gated the request", %{limen: limen} do
      conn =
        conn(:post, "/signup")
        |> put_req_header("user-agent", @browser)
        |> Limen.Plug.call(Limen.Plug.init(instance: limen))

      assert {:trapped, %Decision{instance: ^limen}} = Trap.check_form(conn, %{})
    end
  end
end
