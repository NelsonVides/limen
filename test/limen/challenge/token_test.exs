defmodule Limen.Challenge.TokenTest do
  use Limen.Case, async: true
  use ExUnitProperties

  alias Limen.Challenge.{Pass, Token}
  alias Limen.Context
  alias Limen.Test.Pow

  doctest Limen.Challenge
  doctest Limen.Challenge.Pass

  @secret String.duplicate("s", 32)
  @moduletag config: [secret_key: @secret]

  setup %{instance: instance} do
    %{client: &client(instance, &1)}
  end

  defp client(instance, overrides) do
    struct!(
      %Context{
        instance: instance,
        prefix: {4, 0xC0000201, 32},
        ja4: "t13d1516h2_8daaf6152771_02713d6af862",
        user_agent: "Mozilla/5.0",
        now: 1_800_000_000_000
      },
      overrides
    )
  end

  describe "challenge tokens" do
    test "verify what they issue, with their claims", %{client: client} do
      token = Token.issue(client.([]), 12)

      assert byte_size(token) == 46

      assert {:ok, %{difficulty: 12, issued_at: 1_800_000_000, expires_at: 1_800_000_300}} =
               Token.verify(token, client.([]))
    end

    test "are bound to the prefix, JA4 and user agent", %{client: client} do
      token = Token.issue(client.([]), 12)

      assert Token.verify(token, client.(prefix: {4, 0xC0000202, 32})) == {:error, :invalid}
      assert Token.verify(token, client.(ja4: nil)) == {:error, :invalid}
      assert Token.verify(token, client.(user_agent: "curl/8.5.0")) == {:error, :invalid}
    end

    test "expire", %{client: client} do
      token = Token.issue(client.([]), 12)
      assert Token.verify(token, client.(now: 1_800_000_299_999)) |> elem(0) == :ok
      assert Token.verify(token, client.(now: 1_800_000_300_000)) == {:error, :expired}
    end

    property "reject any tampering", %{client: client} do
      token = Token.issue(client.([]), 12)
      {:ok, raw} = Base.url_decode64(token, padding: false)

      check all position <- integer(0..(byte_size(raw) - 1)), flip <- integer(1..255) do
        <<head::binary-size(^position), byte, rest::binary>> = raw

        tampered =
          Base.url_encode64(<<head::binary, Bitwise.bxor(byte, flip), rest::binary>>,
            padding: false
          )

        assert {:error, _reason} = Token.verify(tampered, client.([]))
      end
    end

    test "reject garbage", %{client: client} do
      assert Token.verify("not a token", client.([])) == {:error, :malformed}
      assert Token.verify(nil, client.([])) == {:error, :malformed}
      assert Token.verify("", client.([])) == {:error, :malformed}
    end

    test "survive secret rotation", %{client: client, instance: instance} do
      token = Token.issue(client.([]), 12)

      rotated =
        rekey(instance, secret_key: String.duplicate("n", 32), previous_secret_keys: [@secret])

      assert {:ok, _claims} = Token.verify(token, client.(instance: rotated))

      rotated = rekey(instance, secret_key: String.duplicate("n", 32))
      assert Token.verify(token, client.(instance: rotated)) == {:error, :invalid}
    end

    test "are bound to the instance's secret", %{client: client, instance: instance} do
      token = Token.issue(client.([]), 12)
      other = rekey(instance, [])
      assert Token.verify(token, client.(instance: other)) == {:error, :invalid}
    end

    test "solutions need the requested leading zero bits", %{client: client} do
      token = Token.issue(client.([]), 10)
      nonce = Pow.solve(token, 10)

      assert Token.solved?(token, nonce, 10)
      refute Token.solved?(token, nonce, 30)
      refute Token.solved?(token, "12a", 1)
      refute Token.solved?(token, String.duplicate("1", 21), 1)
      refute Token.solved?(token, nil, 1)
    end
  end

  describe "passes" do
    test "verify what they issue", %{client: client} do
      {value, 3_600} = Pass.issue(client.([]))
      assert byte_size(value) == 28
      assert {:ok, 1_800_003_600} = Pass.verify(value, client.([]))
    end

    test "are bound to the client identity and expire", %{client: client} do
      {value, _ttl} = Pass.issue(client.([]))

      assert Pass.verify(value, client.(user_agent: "other")) == {:error, :invalid}
      assert Pass.verify(value, client.(now: 1_800_003_600_000)) == {:error, :expired}
      assert Pass.verify("garbage", client.([])) == {:error, :malformed}
    end

    @tag config: [secret_key: @secret, challenge: [bind: [:user_agent, :ja4]]]
    test "are bound to what :bind names", %{client: client, limen: limen} do
      {value, _ttl} = Pass.issue(client.([]))

      assert {:ok, _expires_at} = Pass.verify(value, client.(prefix: {4, 0xCB007101, 32}))
      assert Pass.verify(value, client.(user_agent: "other")) == {:error, :invalid}
      assert Pass.verify(value, client.(ja4: nil)) == {:error, :invalid}

      # Challenge tokens stay bound to the whole identity.
      token = Token.issue(client.([]), 8)
      assert Token.verify(token, client.(prefix: {4, 0xCB007101, 32})) == {:error, :invalid}

      # Passes issued under one binding are not accepted under another.
      Limen.update_config(limen, :challenge, bind: [:prefix, :ja4, :user_agent])
      assert Pass.verify(value, client.(instance: instance(limen))) == {:error, :invalid}

      Limen.update_config(limen, :challenge, bind: [:ja4, :user_agent])
      assert {:ok, _expires_at} = Pass.verify(value, client.(instance: instance(limen)))
    end

    test ":bind names parts of the identity" do
      for invalid <- [[:asn], [:ja4, :ja4], :prefix] do
        assert_raise ArgumentError, ~r/invalid value for :bind/, fn ->
          Limen.Config.build(challenge: [bind: invalid])
        end
      end
    end

    test "cannot be used as challenge tokens or vice versa", %{client: client} do
      {value, _ttl} = Pass.issue(client.([]))
      token = Token.issue(client.([]), 8)

      assert {:error, _reason} = Token.verify(value, client.([]))
      assert {:error, _reason} = Pass.verify(token, client.([]))
    end

    test "are read from any cookie header" do
      assert Pass.cookie(["a=1", "b=2;  _limen_pass=v1 ; c=3"], "_limen_pass") == "v1"
      assert Pass.cookie(["x_limen_pass=no"], "_limen_pass") == nil
      assert Pass.cookie(["a=_limen_pass=no; _limen_pass=v2"], "_limen_pass") == "v2"
    end

    test "follow the cookie name when it changes at runtime", %{limen: limen, client: client} do
      {value, _ttl} = Pass.issue(client.([]))
      Limen.update_config(limen, :challenge, cookie: "renamed")
      renamed = client.(instance: instance(limen), cookie_headers: ["renamed=#{value}"])

      assert {:ok, _expires_at} = Pass.verify(renamed)

      assert Pass.verify(%{renamed | cookie_headers: ["_limen_pass=#{value}"]}) ==
               {:error, :missing}
    end
  end

  test "secret keys must be long enough and cannot change at runtime", %{limen: limen} do
    assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
      Limen.Config.build(secret_key: "short")
    end

    assert_raise ArgumentError, ~r/cannot be changed at runtime/, fn ->
      Limen.update_config(limen, :secret_key, @secret)
    end

    assert inspect(instance(limen).config.keys) == "#Limen.Config.Keys<redacted>"
  end

  # The instance with its keys derived from other secrets.
  defp rekey(instance, secrets), do: %{instance | config: Limen.Config.build(secrets)}
end
