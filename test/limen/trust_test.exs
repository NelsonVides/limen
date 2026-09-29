defmodule Limen.TrustTest do
  use Limen.Case, async: true

  alias Limen.{Decision, Policy}

  @ua "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  defmodule Members do
    use Limen.Policy, signals: [Limen.Signal.HttpShape], mode: :enforce

    trust(:signed_in, when: fact(:signed_in) == true)
    trust(:office, when: signal(:client_ip) in list(:office) and header("x-office") == "yes")
    trust(:broken, when: String.length(fact(:missing)) > 0)

    limit :flood, key: :prefix, rate: 1, per: :hour, burst: 0
    deny :everyone_else, when: true
  end

  defp call(conn, limen, policy \\ Members) do
    Limen.Plug.call(conn, Limen.Plug.init(instance: limen, policy: policy))
  end

  test "trusted clients skip bans, limits and every other rule", %{limen: limen} do
    Limen.ban(limen, {127, 0, 0, 1}, 60)

    for _request <- 1..3 do
      conn = call(Limen.put_facts(conn(:get, "/"), signed_in: true), limen)

      refute conn.halted

      assert %Decision{action: :allow, stage: :trust, policy: Members} =
               decision = Limen.decision(conn)

      assert [%{name: :signed_in, kind: :trust, observed: [{"fact(:signed_in)", true}]}] =
               decision.matches

      assert decision.errors == []
      assert Decision.explain(decision) =~ "trust signed_in when fact(:signed_in) == true"
    end
  end

  test "untrusted clients go through the pipeline, with trust errors recorded", %{limen: limen} do
    conn = call(conn(:get, "/"), limen)

    assert conn.status == 403
    assert %Decision{action: :deny, stage: :rule} = decision = Limen.decision(conn)
    assert [{:rule, :broken, _message}] = decision.errors

    # Trust conditions see identity, headers and lists.
    Limen.Lists.put_cidrs(limen, :office, ["127.0.0.0/8"])
    office = call(put_req_header(conn(:get, "/"), "x-office", "yes"), limen)
    assert %Decision{stage: :trust, matches: [%{name: :office}]} = Limen.decision(office)
  end

  @tag config: [trap: [paths: ["/archive"]], maze: [delay: {0, 0}], mode: :enforce]
  test "trusted clients are not caught by traps", %{limen: limen} do
    trusted = call(Limen.put_facts(conn(:get, "/archive/x"), signed_in: true), limen)
    refute trusted.halted
    assert %Decision{stage: :trust, route: "/archive"} = Limen.decision(trusted)
    refute Limen.banned(limen, {127, 0, 0, 1})

    caught = call(conn(:get, "/archive/x"), limen)
    assert %Decision{stage: :trap, action: :maze} = Limen.decision(caught)
  end

  test "socket checks honour a policy's trust rules", %{limen: limen} do
    connect_info = %{
      peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
      x_headers: [],
      user_agent: @ua,
      uri: URI.parse("http://www.example.com/live/websocket")
    }

    Limen.ban(limen, {127, 0, 0, 1}, 60)
    opts = [instance: limen, mode: :enforce, policy: Members]

    assert {:ok, %Decision{action: :allow, stage: :trust, policy: Members}} =
             Limen.Socket.check(connect_info, %{}, [facts: [signed_in: true]] ++ opts)

    assert {:error, %Decision{stage: :socket, matches: [%{kind: :ban}]}} =
             Limen.Socket.check(connect_info, %{}, opts)
  end

  test "trust rules are described and checked on their own" do
    assert Policy.describe(Members) =~ "  trust signed_in when fact(:signed_in) == true"

    assert {:trusted, %{name: :signed_in}} =
             Policy.check_trust(Members, %Limen.Context{facts: %{signed_in: true}})

    assert {:untrusted, []} = Policy.check_trust(Limen.Policy.Default, %Limen.Context{})
  end

  test "trust rules cannot use signals or rates, which are not there yet" do
    for condition <- ["signal(:ua_family) == :chrome", "rate(:prefix, per: :second) > 1"] do
      assert_raise CompileError, ~r/trust :early runs before signals are collected/, fn ->
        Code.compile_string("""
        defmodule Limen.TrustTest.Early#{System.unique_integer([:positive])} do
          use Limen.Policy
          trust :early, when: #{condition}
        end
        """)
      end
    end
  end
end
