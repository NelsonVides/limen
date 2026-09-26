defmodule Limen.Signal.ClientIP do
  @moduledoc """
  Resolves the client address and prefix.

  The peer address of the connection is the client unless the peer is one of
  the configured `:trusted_proxies`. In that case the address is read from the
  configured `:client_ip_header`:

    * [`"x-forwarded-for"`][X-Forwarded-For] and [`"forwarded"`][Forwarded]
      are chains each proxy appends to.
      They are walked from the right, skipping trusted proxies; the first
      untrusted address is the client. Anything to its left was written by
      the client and is ignored, so sending the header yourself spoofs
      nothing.
    * `"x-real-ip"` holds a single address set by the proxy.

  When the header is missing or malformed the peer address is used, and the
  evidence records why. The client address is then aggregated to its prefix
  (see `Limen.IP.prefix/3`).

  Provides `:client_ip` and `:prefix`; evidence for `:client_ip` is `:peer`,
  `{:header, name}` or `{:invalid, name}`.

  [X-Forwarded-For]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For
  [Forwarded]: https://www.rfc-editor.org/rfc/rfc7239
  """

  @behaviour Limen.Signal

  alias Limen.{Context, IP}

  @impl true
  def provides, do: [:client_ip, :prefix]

  @impl true
  def collect(ctx), do: resolve(ctx, ctx.instance.config)

  @doc """
  Resolves the client identity with an explicit configuration.
  """
  @spec resolve(Context.t(), Limen.Config.t()) :: Context.t()
  def resolve(%Context{peer_ip: peer} = ctx, config) do
    via_proxy = IP.member?(config.trusted_proxies, peer)

    {client, source} =
      if via_proxy and config.client_ip_header != nil do
        from_header(ctx, config.client_ip_header, config.trusted_proxies, peer)
      else
        {peer, :peer}
      end

    %{
      ctx
      | client_ip: client,
        via_proxy: via_proxy,
        prefix: IP.prefix(client, config.ipv4_prefix, config.ipv6_prefix),
        evidence: Map.put(ctx.evidence, :client_ip, source)
    }
  end

  defp from_header(ctx, "x-real-ip" = name, _trusted, peer) do
    with value when is_binary(value) <- Context.header(ctx, name),
         {:ok, ip} <- IP.parse(value) do
      {ip, {:header, name}}
    else
      nil -> {peer, :peer}
      :error -> {peer, {:invalid, name}}
    end
  end

  defp from_header(ctx, name, trusted, peer) do
    case chain(ctx.headers, name) do
      [] ->
        {peer, :peer}

      hops ->
        case rightmost_untrusted(hops, trusted) do
          {:ok, ip} -> {ip, {:header, name}}
          :invalid -> {peer, {:invalid, name}}
        end
    end
  end

  # All hops of every header instance, in order. Proxies may add a new header
  # line instead of appending to the existing one.
  defp chain(headers, name) do
    for {^name, value} <- headers,
        hop <- String.split(value, ","),
        hop = String.trim(hop),
        hop != "" do
      if name == "forwarded", do: forwarded_for(hop), else: hop
    end
  end

  # A malformed hop means the chain cannot be trusted past that point, so the
  # peer is used instead. When every hop is a trusted proxy, the request came
  # from inside the trusted network and the leftmost hop is the client.
  defp rightmost_untrusted(hops, trusted) do
    hops
    |> Enum.reverse()
    |> Enum.reduce_while(:invalid, fn hop, _leftmost_trusted -> step(parse_hop(hop), trusted) end)
  end

  defp step({:ok, ip}, trusted) do
    if IP.member?(trusted, ip), do: {:cont, {:ok, ip}}, else: {:halt, {:ok, ip}}
  end

  defp step(:error, _trusted), do: {:halt, :invalid}

  defp parse_hop(nil), do: :error
  defp parse_hop(hop), do: IP.parse(hop)

  # Extracts the address from one RFC 7239 element, e.g.
  # `for="[2001:db8::17]:4711";proto=https`. Obfuscated and unknown
  # identifiers yield nil.
  defp forwarded_for(element) do
    element
    |> String.split(";")
    |> Enum.find_value(&for_pair(String.split(String.trim(&1), "=", parts: 2)))
  end

  defp for_pair([key, value]) do
    if String.downcase(key) == "for", do: node_address(String.trim(value, "\""))
  end

  defp for_pair(_other), do: nil

  defp node_address("[" <> rest), do: hd(String.split(rest, "]", parts: 2))
  defp node_address(ipv4), do: hd(String.split(ipv4, ":", parts: 2))
end
