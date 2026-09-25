defmodule Limen.Corpus do
  @moduledoc """
  Recorded requests for signal tests.

  Each fixture in `test/fixtures/requests` is a raw HTTP/1.1 request, headers
  in the order they were received, preceded by `# key: value` comment lines:
  `peer` (the address of the connection), `scheme`, and optional
  configuration overrides such as `client_ip_header`.
  """

  @dir Path.expand("../fixtures/requests", __DIR__)

  @type fixture :: %{name: String.t(), conn: Plug.Conn.t(), meta: %{String.t() => String.t()}}

  @doc """
  Lists fixture names.
  """
  @spec names() :: [String.t()]
  def names do
    @dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".http"))
    |> Enum.map(&Path.rootname/1)
    |> Enum.sort()
  end

  @doc """
  Loads a fixture as a test connection.
  """
  @spec load(String.t()) :: fixture()
  def load(name) do
    path = Path.join(@dir, name <> ".http")
    lines = String.split(File.read!(path), ["\r\n", "\n"])
    {comments, [request_line | rest]} = Enum.split_while(lines, &String.starts_with?(&1, "#"))
    meta = Map.new(Enum.flat_map(comments, &meta/1))
    [method, target, _version] = String.split(request_line, " ")

    headers =
      rest
      |> Enum.take_while(&(&1 != ""))
      |> Enum.map(fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {:ok, peer} = Limen.IP.parse(Map.fetch!(meta, "peer"))
    {"host", host} = List.keyfind(headers, "host", 0)
    scheme = String.to_existing_atom(Map.get(meta, "scheme", "http"))

    conn = Plug.Test.conn(method, target)
    conn = %{conn | req_headers: headers, remote_ip: peer, scheme: scheme, host: host}
    %{name: name, conn: conn, meta: meta}
  end

  defp meta("# " <> line) do
    case String.split(line, ": ", parts: 2) do
      [key, value] when key in ["peer", "scheme", "client_ip_header"] -> [{key, value}]
      _description -> []
    end
  end
end
