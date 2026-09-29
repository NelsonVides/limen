defmodule Limen.FactsTest do
  use Limen.Case, async: true

  alias Limen.Decision

  @ua "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  defmodule Members do
    use Limen.Policy, signals: []

    score :anonymous, 50, when: fact(:signed_in) != true
    score :staff, -20, when: fact(:role) == :staff

    decide do
      score >= 50 -> {:challenge, difficulty: 8}
      true -> :allow
    end
  end

  defp decide(limen, conn) do
    Limen.decision(Limen.Plug.call(conn, Limen.Plug.init(instance: limen, policy: Members)))
  end

  test "policies read the facts the application states", %{limen: limen} do
    anonymous = decide(limen, conn(:get, "/"))
    assert %Decision{action: :challenge, facts: %{}} = anonymous
    assert [%{name: :anonymous, observed: [{"fact(:signed_in)", nil}]}] = anonymous.matches

    member =
      conn(:get, "/")
      |> Limen.put_facts(signed_in: true)
      |> Limen.put_facts(%{role: :staff})
      |> then(&decide(limen, &1))

    assert %Decision{action: :allow, score: -20, facts: %{signed_in: true, role: :staff}} = member
    assert [%{name: :staff, observed: [{"fact(:role)", :staff}]}] = member.matches

    explained = Decision.explain(member)
    assert explained =~ "  fact role = :staff\n  fact signed_in = true\n"
    assert explained =~ "when fact(:role) == :staff [fact(:role) = :staff]"
  end

  test "later facts override earlier ones, and keys must be atoms" do
    conn =
      conn(:get, "/")
      |> Limen.put_facts(signed_in: false)
      |> Limen.put_facts(signed_in: true)

    assert conn.private.limen_facts == %{signed_in: true}

    assert_raise ArgumentError, ~r/expected facts as {atom, value}/, fn ->
      Limen.put_facts(conn, %{"signed_in" => true})
    end
  end

  test "socket checks and form checks record facts", %{limen: limen} do
    connect_info = %{
      peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
      x_headers: [],
      user_agent: @ua,
      uri: URI.parse("http://www.example.com/live/websocket")
    }

    assert {:ok, %Decision{stage: :socket, facts: %{signed_in: true}}} =
             Limen.Socket.check(connect_info, %{}, instance: limen, facts: [signed_in: true])

    assert {:ok, %Decision{stage: :trap, facts: %{signed_in: true}}} =
             Limen.Trap.check_form(connect_info, %{}, instance: limen, facts: %{signed_in: true})

    conn = conn(:post, "/signup") |> Limen.put_facts(signed_in: false)

    assert {:ok, %Decision{facts: %{signed_in: false}}} =
             Limen.Trap.check_form(conn, %{}, instance: limen)
  end

  test "fact/1 needs an atom" do
    assert_raise CompileError, ~r/fact\/1 expects an atom literal/, fn ->
      Code.compile_string("""
      defmodule Limen.FactsTest.Invalid do
        use Limen.Policy, signals: []
        allow :x, when: fact("signed_in")
      end
      """)
    end
  end
end
