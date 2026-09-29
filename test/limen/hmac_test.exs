defmodule Limen.HMACTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Limen.HMAC

  property "matches :crypto.mac/4 for any key and message" do
    check all secret <- binary(max_length: 130),
              parts <- list_of(binary(max_length: 100), max_length: 4) do
      assert HMAC.sha256(HMAC.prepare(secret), parts) ==
               :crypto.mac(:hmac, :sha256, secret, parts)
    end
  end

  test "RFC 4231 test case 2" do
    key = HMAC.prepare("Jefe")

    assert Base.encode16(HMAC.sha256(key, "what do ya want for nothing?"), case: :lower) ==
             "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  end
end
