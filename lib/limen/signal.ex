defmodule Limen.Signal do
  @moduledoc """
  A source of facts about a request.

  A signal reads the request (and, for behavioural signals, Limen's shared
  state) and stores one or more named values in the `Limen.Context`. Policies
  refer to those values by name with `signal/1`; the core knows nothing about
  what they mean.

  Every value a signal stores is copied into the `Limen.Decision`, together
  with any evidence the signal attached with `Limen.Context.put_signal/4`, so
  a decision can always be explained from its inputs.

  ## Identity

  The client address, its prefix and the JA4 fingerprint are resolved for
  every request, before any other signal, because the pass cookie fast path
  is bound to them. See `Limen.Signal.ClientIP` and `Limen.Signal.JA4`.

  ## Built-in signals

  | Module | Values |
  |---|---|
  | `Limen.Signal.HttpShape` | `:ua_family`, `:ua_version`, `:shape`, `:shape_flags` |
  | `Limen.Signal.Behaviour` | `:requests_per_minute`, `:not_found_ratio`, `:asset_ratio`, ... |
  | `Limen.Signal.Asn` | `:asn`, `:asn_kind`, `:asn_country`, `:asn_name` |
  | `Limen.Signal.Fcrdns` | `:fcrdns` |

  ## Writing a signal

      defmodule MyApp.Signal.Tor do
        @behaviour Limen.Signal

        @impl true
        def provides, do: [:tor_exit]

        @impl true
        def collect(ctx) do
          exit? = Limen.Lists.member?(:tor_exits, ctx.client_ip)
          Limen.Context.put_signal(ctx, :tor_exit, exit?)
        end
      end

  `collect/1` runs on the request path: it must not call processes or send
  messages, and should cost at most a few microseconds.
  """

  use Boundary,
    type: :strict,
    deps: [
      Limen.Config,
      Limen.Context,
      Limen.Instance,
      Limen.IP,
      Limen.State,
      Limen.Telemetry,
      Plug,
      Logger
    ],
    exports: [
      Asn,
      Asn.Loader,
      Behaviour,
      ClientIP,
      Fcrdns,
      Fcrdns.DNS,
      Fcrdns.InetRes,
      Fcrdns.Resolver,
      HttpShape,
      JA4,
      UserAgent
    ]

  alias Limen.Context
  alias Limen.Signal.{Asn, Behaviour, ClientIP, Fcrdns, HttpShape, JA4}

  # Whether a header name is `literal`. Matching literals in clause heads
  # starts a binary match, which allocates a match context per header;
  # comparing sizes first costs as little and allocates nothing.
  defguardp is_name(name, literal) when byte_size(name) == byte_size(literal) and name === literal

  @doc """
  The names of the values this signal stores.
  """
  @callback provides() :: [atom()]

  @doc """
  Computes the signal's values and stores them in the context.
  """
  @callback collect(Context.t()) :: Context.t()

  @doc """
  The built-in signals collected by default.
  """
  @spec defaults() :: [module()]
  def defaults, do: [HttpShape, Fcrdns, Behaviour, Asn]

  @doc """
  Resolves the client identity: address, prefix, JA4 and user agent.

  Also reads the `sec-fetch-dest` and `cookie` headers into the context, in
  the same pass over the headers.
  """
  @spec identify(Context.t(), Limen.Config.t()) :: Context.t()
  def identify(%Context{headers: headers, evidence: evidence} = ctx, config) do
    {forwarded, ja4, user_agent, fetch_dest, cookies} =
      read(headers, {config.client_ip_header, config.ja4_header}, [], nil, nil, nil, [])

    {client, via_proxy, prefix, source} = ClientIP.client(ctx.peer_ip, config, forwarded)
    {ja4, evidence} = ja4(JA4.check(ja4, via_proxy), Map.put(evidence, :client_ip, source))

    # One update: each one copies the context.
    %{
      ctx
      | client_ip: client,
        via_proxy: via_proxy,
        prefix: prefix,
        ja4: ja4,
        user_agent: user_agent,
        fetch_dest: fetch_dest,
        cookie_headers: cookies,
        evidence: evidence
    }
  end

  defp ja4({:ignored, reason}, evidence), do: {nil, Map.put(evidence, :ja4, reason)}
  defp ja4(ja4, evidence), do: {ja4, evidence}

  # Each header name is compared once. The first value of a repeated header
  # wins, as with `Limen.Context.header/2`; the client address header and
  # cookie headers keep every value, in order.
  defp read([{name, value} | rest], wanted, forwarded, ja4, nil, dest, cookies)
       when is_name(name, "user-agent"),
       do: read(rest, wanted, forwarded, ja4, value, dest, cookies)

  defp read([{name, value} | rest], wanted, forwarded, ja4, ua, nil, cookies)
       when is_name(name, "sec-fetch-dest"),
       do: read(rest, wanted, forwarded, ja4, ua, value, cookies)

  defp read([{name, value} | rest], wanted, forwarded, ja4, ua, dest, cookies)
       when is_name(name, "cookie"),
       do: read(rest, wanted, forwarded, ja4, ua, dest, [value | cookies])

  defp read([{name, value} | rest], {name, _ja4} = wanted, forwarded, ja4, ua, dest, cookies),
    do: read(rest, wanted, [value | forwarded], ja4, ua, dest, cookies)

  defp read([{name, value} | rest], {_ip, name} = wanted, forwarded, nil, ua, dest, cookies),
    do: read(rest, wanted, forwarded, value, ua, dest, cookies)

  defp read([_header | rest], wanted, forwarded, ja4, ua, dest, cookies),
    do: read(rest, wanted, forwarded, ja4, ua, dest, cookies)

  defp read([], _wanted, forwarded, ja4, ua, dest, cookies),
    do: {:lists.reverse(forwarded), ja4, ua, dest, :lists.reverse(cookies)}

  @doc """
  Runs `signals` in order over the context.
  """
  @spec collect(Context.t(), [module()]) :: Context.t()
  def collect(%Context{} = ctx, signals) do
    Enum.reduce(signals, ctx, fn signal, acc -> signal.collect(acc) end)
  end
end
