defmodule Limen.Signal.Fcrdns.InetRes do
  @moduledoc """
  `Limen.Signal.Fcrdns.DNS` on top of OTP's `:inet_res` resolver.

  Only used by `Limen.Signal.Fcrdns.Resolver`, off the request path.
  """

  @behaviour Limen.Signal.Fcrdns.DNS

  @transient [:timeout, :servfail, :refused, :formerr]

  @impl true
  def reverse(ip, timeout) do
    case :inet_res.gethostbyaddr(ip, timeout) do
      {:ok, {:hostent, name, aliases, _type, _length, _addresses}} ->
        {:ok, Enum.map([name | aliases], &to_string/1)}

      {:error, reason} ->
        error(reason)
    end
  end

  @impl true
  def forward(host, version, timeout) do
    type = if version == 4, do: :a, else: :aaaa

    case :inet_res.getbyname(String.to_charlist(host), type, timeout) do
      {:ok, {:hostent, _name, _aliases, _type, _length, addresses}} -> {:ok, addresses}
      {:error, reason} -> error(reason)
    end
  end

  defp error(reason) when reason in @transient, do: {:error, :transient}
  defp error(reason), do: {:error, reason}
end
