defmodule Limen.Signal.Fcrdns.DNS do
  @moduledoc """
  DNS lookups used to verify crawlers, as a behaviour so they can be replaced
  (in tests, or with a caching resolver).

  Errors that may be transient (timeouts, server failures) must be returned
  as `{:error, :transient}`; any other error means the name or address does
  not resolve.
  """

  @doc """
  Host names an address points back to (PTR records), waiting at most
  `timeout` milliseconds.
  """
  @callback reverse(:inet.ip_address(), timeout :: pos_integer()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Addresses of `host` for IP `version` 4 (A records) or 6 (AAAA records),
  waiting at most `timeout` milliseconds.
  """
  @callback forward(String.t(), 4 | 6, timeout :: pos_integer()) ::
              {:ok, [:inet.ip_address()]} | {:error, term()}
end
