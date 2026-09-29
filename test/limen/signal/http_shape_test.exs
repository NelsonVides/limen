defmodule Limen.Signal.HttpShapeTest do
  use ExUnit.Case, async: true

  alias Limen.Context
  alias Limen.Signal.{HttpShape, UserAgent}

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
            "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

  defp flags(brands) do
    headers = [
      {"user-agent", @chrome},
      {"sec-ch-ua", brands},
      {"sec-ch-ua-mobile", "?0"},
      {"sec-ch-ua-platform", ~s("Windows")},
      {"accept", "text/html"},
      {"accept-language", "en"},
      {"accept-encoding", "gzip"},
      {"sec-fetch-mode", "navigate"}
    ]

    ctx = %Context{headers: headers, scheme: :https, user_agent: @chrome}
    HttpShape.flags(ctx, UserAgent.parse(@chrome))
  end

  test "client hint brands must name the claimed browser" do
    assert flags(~s("Chromium";v="128", "Google Chrome";v="128")) == []
    assert flags(~s("Not;A=Brand";v="24", "Chromium";v="128")) == []

    assert flags(~s("Microsoft Edge";v="128", "Not;A=Brand";v="24")) ==
             [:client_hint_brand_mismatch]
  end

  test "a headless brand in the client hints is flagged" do
    assert :headless in flags(~s("HeadlessChrome";v="128", "Google Chrome";v="128"))
  end
end
