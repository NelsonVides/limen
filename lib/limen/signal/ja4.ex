defmodule Limen.Signal.JA4 do
  @moduledoc """
  Reads the [JA4] TLS client fingerprint set by the TLS terminator.

  JA4 hashes what a client offers in the TLS [ClientHello], the first message
  of the handshake: its TLS version, cipher suites, extensions and ALPN
  protocols. It identifies the client's TLS library, whatever user agent it
  claims. The application never sees the ClientHello, so a terminator in
  front of it (for example nginx with FoxIO's [ja4-nginx-module]) must
  compute the fingerprint and forward it in the `:ja4_header` (default
  `x-ja4`). The header is only read when the peer is a configured trusted
  proxy; from anyone else it is ignored, because a client could otherwise
  claim any fingerprint.

  Only well-formed JA4 fingerprints (`t13d1516h2_8daaf6152771_02713d6af862`)
  are accepted. JA4 is [BSD-3-Clause][JA4 license] licensed; Limen does not
  implement other JA4+ methods.

  Provides `:ja4`. When a header is present but not used, the evidence is
  `:untrusted_peer` or `:malformed`.

  [JA4]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md
  [ClientHello]: https://www.rfc-editor.org/rfc/rfc8446#section-4.1.2
  [ja4-nginx-module]: https://github.com/FoxIO-LLC/ja4-nginx-module
  [JA4 license]: https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE-JA4
  """

  @behaviour Limen.Signal

  alias Limen.Context

  @impl true
  def provides, do: [:ja4]

  @impl true
  def collect(ctx), do: resolve(ctx, ctx.instance.config)

  @doc """
  Resolves the fingerprint with an explicit configuration.
  """
  @spec resolve(Context.t(), Limen.Config.t()) :: Context.t()
  def resolve(%Context{} = ctx, config) do
    case {Context.header(ctx, config.ja4_header), ctx.via_proxy} do
      {nil, _via_proxy} -> %{ctx | ja4: nil}
      {_value, false} -> ignored(ctx, :untrusted_peer)
      {value, true} -> if valid?(value), do: %{ctx | ja4: value}, else: ignored(ctx, :malformed)
    end
  end

  defp ignored(%Context{} = ctx, reason) do
    %{ctx | ja4: nil, evidence: Map.put(ctx.evidence, :ja4, reason)}
  end

  @doc """
  Whether `value` is a well-formed JA4 fingerprint.

      iex> Limen.Signal.JA4.valid?("t13d1516h2_8daaf6152771_02713d6af862")
      true

      iex> Limen.Signal.JA4.valid?("t13d1516h2_8daaf6152771")
      false
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(
        <<protocol, version::binary-size(2), sni, counts::binary-size(4), alpn::binary-size(2),
          ?_, ciphers::binary-size(12), ?_, extensions::binary-size(12)>>
      )
      when protocol in [?t, ?q, ?d] and sni in [?d, ?i] do
    digits?(version) and digits?(counts) and alphanumeric?(alpn) and hex?(ciphers) and
      hex?(extensions)
  end

  def valid?(_value), do: false

  defp digits?(<<c, rest::binary>>) when c in ?0..?9, do: digits?(rest)
  defp digits?(<<>>), do: true
  defp digits?(_other), do: false

  defp alphanumeric?(<<c, rest::binary>>) when c in ?0..?9 or c in ?a..?z, do: alphanumeric?(rest)
  defp alphanumeric?(<<>>), do: true
  defp alphanumeric?(_other), do: false

  defp hex?(<<c, rest::binary>>) when c in ?0..?9 or c in ?a..?f, do: hex?(rest)
  defp hex?(<<>>), do: true
  defp hex?(_other), do: false
end
