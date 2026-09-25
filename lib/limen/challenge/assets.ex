defmodule Limen.Challenge.Assets do
  @moduledoc """
  The challenge page's script, worker and stylesheet.

  They are read from `priv/static` at compile time and served from memory.
  URLs carry a content hash, so the files can be cached for a year.
  """

  @static Path.expand("../../../priv/static", __DIR__)

  @files [
    {"solver.js", "text/javascript"},
    {"worker.js", "text/javascript"},
    {"challenge.css", "text/css"}
  ]

  for {name, _type} <- @files, do: @external_resource(Path.join(@static, name))

  @assets Map.new(@files, fn {name, type} ->
            {name, {type <> "; charset=utf-8", File.read!(Path.join(@static, name))}}
          end)

  @version @assets
           |> Enum.sort()
           |> Enum.map(fn {_name, {_type, content}} -> content end)
           |> then(&:crypto.hash(:sha256, &1))
           |> binary_part(0, 6)
           |> Base.url_encode64(padding: false)

  @doc """
  The URL of asset `name` under the challenge base path.
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url(base, name) when is_map_key(@assets, name), do: "#{base}/#{name}?v=#{@version}"

  @doc """
  Serves asset `name`, or `404` if there is no such asset.
  """
  @spec serve(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, name) do
    case Map.fetch(@assets, name) do
      {:ok, {type, content}} ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
        |> Plug.Conn.send_resp(200, content)

      :error ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
    end
  end
end
