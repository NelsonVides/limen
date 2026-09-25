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
    deps: [Limen.Config, Limen.Context, Limen.Instance, Limen.IP, Limen.State, Plug, Logger],
    exports: [Asn, Asn.Loader, Behaviour, ClientIP, HttpShape, JA4, UserAgent]

  alias Limen.Context
  alias Limen.Signal.{Asn, Behaviour, ClientIP, HttpShape, JA4}

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
  def defaults, do: [HttpShape, Behaviour, Asn]

  @doc """
  Resolves the client identity: address, prefix, JA4 and user agent.
  """
  @spec identify(Context.t(), Limen.Config.t()) :: Context.t()
  def identify(%Context{} = ctx, config) do
    ctx
    |> ClientIP.resolve(config)
    |> JA4.resolve(config)
    |> Map.put(:user_agent, Context.header(ctx, "user-agent"))
  end

  @doc """
  Runs `signals` in order over the context.
  """
  @spec collect(Context.t(), [module()]) :: Context.t()
  def collect(%Context{} = ctx, signals) do
    Enum.reduce(signals, ctx, fn signal, acc -> signal.collect(acc) end)
  end
end
