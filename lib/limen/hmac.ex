defmodule Limen.HMAC do
  @moduledoc false
  # HMAC-SHA256 (RFC 2104) with keys prepared once.
  #
  # `:crypto.mac/4` sets up a MAC context on every call, which costs more
  # than the two hashes of an HMAC over a short message. With the key padded
  # and masked ahead of time, an HMAC is two one-shot hashes, about half the
  # time of `:crypto.mac/4` for the tokens and passes Limen verifies on the
  # request path.

  use Boundary, type: :strict, deps: []

  @block 64
  @ipad :binary.copy(<<0x36>>, @block)
  @opad :binary.copy(<<0x5C>>, @block)

  @typedoc "A key prepared for `sha256/2`: the padded key masked for each hash."
  @type key :: {binary(), binary()}

  @doc """
  Prepares `secret` for `sha256/2`.
  """
  @spec prepare(binary()) :: key()
  def prepare(secret) when byte_size(secret) > @block,
    do: prepare(:crypto.hash(:sha256, secret))

  def prepare(secret) when is_binary(secret) do
    block = secret <> :binary.copy(<<0>>, @block - byte_size(secret))
    {:crypto.exor(block, @ipad), :crypto.exor(block, @opad)}
  end

  @doc """
  The HMAC-SHA256 of `data` with a prepared key.
  """
  @spec sha256(key(), iodata()) :: binary()
  def sha256({inner, outer}, data),
    do: :crypto.hash(:sha256, [outer, :crypto.hash(:sha256, [inner | data])])
end
