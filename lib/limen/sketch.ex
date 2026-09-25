defmodule Limen.Sketch do
  @moduledoc """
  Fixed-memory probabilistic structures for high-cardinality state.

  Exact per-key state stops scaling once an attacker can mint keys, for
  example by rotating through the addresses of an IPv6 `/48`. Sketches trade
  a bounded, documented error for memory that does not grow with the number
  of keys.

  All sketches are backed by `:atomics`, so they are safe to update from any
  process without locks, and are allocated once up front.

    * `Limen.Sketch.CountMin` - frequency estimates that never undercount.
  """

  use Boundary, type: :strict, deps: [], exports: [CountMin]
end
