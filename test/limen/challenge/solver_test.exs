defmodule Limen.Challenge.SolverTest do
  @moduledoc """
  Runs the vendored worker under Node.js, as a browser would run it.
  """

  use Limen.Case, async: true

  alias Limen.Challenge.Token
  alias Limen.Context

  @moduletag :node

  @worker Path.expand("../../../priv/static/worker.js", __DIR__)

  defp run_node(script) do
    harness = """
    const fs = require("fs");
    globalThis.self = globalThis;
    self.postMessage = (message) => { console.log(JSON.stringify(message)); };
    eval(fs.readFileSync(#{inspect(@worker)}, "utf8"));
    #{script}
    """

    {output, 0} = System.cmd("node", ["-e", harness], stderr_to_stdout: true)
    output
  end

  test "the fallback SHA-256 matches :crypto" do
    inputs = [
      "",
      "abc",
      String.duplicate("a", 55),
      String.duplicate("b", 56),
      String.duplicate("c", 200)
    ]

    output =
      run_node("""
      const inputs = #{JSON.encode!(inputs)};
      for (const input of inputs) {
        const bytes = self.limenSha256(new TextEncoder().encode(input));
        console.log(Buffer.from(bytes).toString("hex"));
      }
      """)

    expected = Enum.map(inputs, &Base.encode16(:crypto.hash(:sha256, &1), case: :lower))
    assert String.split(output, "\n", trim: true) == expected
  end

  test "the worker finds nonces the server accepts", %{instance: instance} do
    ctx = %Context{
      instance: instance,
      prefix: {4, 1, 32},
      user_agent: "node",
      now: System.system_time(:millisecond)
    }

    token = Token.issue(ctx, 14)

    output =
      run_node(
        ~s|self.onmessage({data: {token: #{inspect(token)}, difficulty: 14, start: 0, step: 1}});|
      )

    %{"nonce" => nonce} = JSON.decode!(String.trim(output))

    assert Token.solved?(token, nonce, 14)
  end
end
