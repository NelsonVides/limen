defmodule Limen.Signal.Asn.Download do
  @moduledoc """
  Fetches IP-to-ASN data over HTTP(S) into a file, only when it changed.

  Uses OTP's `:httpc`, so it needs no dependency. HTTPS certificates are
  verified against the operating system's trusted certificates
  (`:public_key.cacerts_get/0`), hostname included. The request asks for the
  data only if it changed since the given time (`If-Modified-Since`); the
  body is streamed straight to the file, never held in memory.
  """

  @typedoc """
  `:updated` when the file now holds new data, `:unchanged` when the server
  had nothing newer.
  """
  @type result :: :updated | :unchanged | {:error, term()}

  @doc """
  Downloads `url` into `path` if it changed since `modified_since`
  (milliseconds since the epoch, or `nil` to download unconditionally).
  """
  @spec fetch(String.t(), Path.t(), integer() | nil, pos_integer()) :: result()
  def fetch(url, path, modified_since, timeout) do
    with :ok <- start(url),
         {:ok, tls} <- tls(url) do
      headers = [{~c"user-agent", ~c"Limen"} | if_modified_since(modified_since)]
      http = [timeout: timeout, connect_timeout: min(timeout, 30_000), autoredirect: true] ++ tls
      options = [stream: String.to_charlist(path), body_format: :binary]

      case :httpc.request(:get, {String.to_charlist(url), headers}, http, options) do
        {:ok, :saved_to_file} -> :updated
        {:ok, {{_version, 304, _reason}, _headers, _body}} -> :unchanged
        {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start("https:" <> _rest), do: started(Application.ensure_all_started([:inets, :ssl]))
  defp start(_url), do: started(Application.ensure_all_started(:inets))

  defp started({:ok, _apps}), do: :ok
  defp started({:error, reason}), do: {:error, reason}

  defp tls("https:" <> _rest) do
    {:ok,
     ssl: [
       verify: :verify_peer,
       cacerts: :public_key.cacerts_get(),
       depth: 4,
       customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
     ]}
  rescue
    # No trusted certificates could be found on this system.
    e -> {:error, {:cacerts, Exception.message(e)}}
  end

  defp tls(_url), do: {:ok, []}

  defp if_modified_since(nil), do: []

  defp if_modified_since(at) do
    date = Calendar.strftime(DateTime.from_unix!(at, :millisecond), "%a, %d %b %Y %H:%M:%S GMT")
    [{~c"if-modified-since", String.to_charlist(date)}]
  end
end
