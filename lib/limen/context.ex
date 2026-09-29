defmodule Limen.Context do
  @moduledoc """
  Everything Limen knows about a request while it is being evaluated.

  A context is built once per request by `Limen.Plug`, for one
  `Limen.Instance`, which it carries so that everything downstream reads its
  configuration and state without looking anything up. Identity fields
  (`client_ip`, `prefix`, `ja4`, `user_agent`) are always populated; the
  `signals` map is filled by the `Limen.Signal` modules a policy depends on.

  `Limen.Signal.identify/2` reads the identity headers in one pass over the
  request headers, and with them the ones later stages need: `fetch_dest`
  (the [`sec-fetch-dest`](https://www.w3.org/TR/fetch-metadata/#sec-fetch-dest-header)
  header) and `cookie_headers` (the values of the `cookie` headers, in
  order, unparsed).

  `via_proxy` tells whether `client_ip` came from a forwarding header set by
  a trusted proxy (see `Limen.Signal.ClientIP`); a request from a trusted
  proxy that carried no such header is the proxy's own.

  Every signal value that ends up in a context is copied into the
  `Limen.Decision` record, so a decision can always be explained from the
  values that produced it.
  """

  use Boundary, type: :strict, deps: [Limen.Instance, Limen.IP, Plug]

  @type prefix :: Limen.IP.prefix()

  @type t :: %__MODULE__{
          instance: Limen.Instance.t() | nil,
          peer_ip: :inet.ip_address() | nil,
          client_ip: :inet.ip_address() | nil,
          via_proxy: boolean(),
          prefix: prefix() | nil,
          ja4: String.t() | nil,
          user_agent: String.t() | nil,
          fetch_dest: String.t() | nil,
          cookie_headers: [String.t()],
          method: String.t(),
          scheme: :http | :https,
          host: String.t(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), String.t()}],
          now: integer(),
          monotonic: integer(),
          signals: %{optional(atom()) => term()},
          evidence: %{optional(atom()) => term()},
          rates: %{optional(term()) => non_neg_integer() | tuple()}
        }

  defstruct instance: nil,
            peer_ip: nil,
            client_ip: nil,
            via_proxy: false,
            prefix: nil,
            ja4: nil,
            user_agent: nil,
            fetch_dest: nil,
            cookie_headers: [],
            method: "GET",
            scheme: :http,
            host: "",
            path: "/",
            query: "",
            headers: [],
            now: 0,
            monotonic: 0,
            signals: %{},
            evidence: %{},
            rates: %{}

  @doc """
  Builds a context for `instance` from a `Plug.Conn`, without resolving
  identity.

  `now` is the system time in milliseconds, used for time windows and token
  expiry; `monotonic` is monotonic time in microseconds, used for limits.
  Tests can pin both with the `:limen_now` and `:limen_monotonic` private
  connection fields.
  """
  @spec from_conn(Plug.Conn.t(), Limen.Instance.t() | nil) :: t()
  def from_conn(%Plug.Conn{private: private} = conn, instance \\ nil) do
    %__MODULE__{
      instance: instance,
      peer_ip: conn.remote_ip,
      client_ip: conn.remote_ip,
      method: conn.method,
      scheme: conn.scheme,
      host: conn.host,
      path: conn.request_path,
      query: conn.query_string,
      headers: conn.req_headers,
      now: Map.get_lazy(private, :limen_now, fn -> System.system_time(:millisecond) end),
      monotonic:
        Map.get_lazy(private, :limen_monotonic, fn -> System.monotonic_time(:microsecond) end)
    }
  end

  @doc """
  Returns the first value of the request header `name`, or `nil`.

  `name` must be lowercase, as Plug normalises header names.
  """
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  @doc """
  Returns the value of signal `key`, or `nil` when it was not collected.
  """
  @spec signal(t(), atom()) :: term()
  def signal(%__MODULE__{} = ctx, :client_ip), do: ctx.client_ip
  def signal(%__MODULE__{} = ctx, :prefix), do: ctx.prefix
  def signal(%__MODULE__{} = ctx, :ja4), do: ctx.ja4
  def signal(%__MODULE__{} = ctx, :user_agent), do: ctx.user_agent
  def signal(%__MODULE__{signals: signals}, key), do: Map.get(signals, key)

  @doc """
  Stores a signal value and, optionally, the evidence that produced it.
  """
  @spec put_signal(t(), atom(), term(), term()) :: t()
  def put_signal(ctx, key, value, evidence \\ nil)

  def put_signal(%__MODULE__{signals: signals} = ctx, key, value, nil) do
    %{ctx | signals: Map.put(signals, key, value)}
  end

  def put_signal(%__MODULE__{signals: signals, evidence: evidence} = ctx, key, value, why) do
    %{ctx | signals: Map.put(signals, key, value), evidence: Map.put(evidence, key, why)}
  end

  @doc """
  Stores several signal values at once, with evidence for some of them.

  Equivalent to calling `put_signal/4` for each value, in one update of the
  context.
  """
  @spec put_signals(t(), map(), map()) :: t()
  def put_signals(%__MODULE__{signals: signals, evidence: evidence} = ctx, values, why \\ %{}) do
    %{ctx | signals: Map.merge(signals, values), evidence: Map.merge(evidence, why)}
  end

  @doc """
  The identity of the client, as recorded in decisions and bound into tokens.
  """
  @spec identity(t()) :: map()
  def identity(%__MODULE__{} = ctx) do
    %{
      client_ip: ctx.client_ip,
      prefix: ctx.prefix,
      ja4: ctx.ja4,
      user_agent: ctx.user_agent,
      via_proxy: ctx.via_proxy
    }
  end
end
