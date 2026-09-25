defmodule Limen do
  @moduledoc """
  Native Elixir L7 bot protection.

  *Limen* (Latin): threshold. The point every request crosses before it enters.

  Limen classifies requests, rate-limits, challenges and blocks automated
  traffic entirely inside the BEAM: no sidecar, no external service, all state
  in ETS, `:atomics` and `:persistent_term`. Nothing on the request path calls
  a process or sends a message.

  ## Instances

  Limen runs as one or more *instances*, each with its own configuration and
  state, started in your supervision tree. Configuration lives in your
  application's environment:

      # config/runtime.exs
      config :my_app, Limen, mode: :dry_run

      # application.ex
      children = [{Limen, otp_app: :my_app}, MyAppWeb.Endpoint]

      # endpoint
      plug Limen.Plug, otp_app: :my_app

  That starts one instance, named after the application. To run several,
  list them under `:instances`; top-level options are shared by all of them:

      config :my_app, Limen,
        mode: :dry_run,
        instances: [public: [], admin: [mode: :enforce]]

      plug Limen.Plug, instance: :public

  Instance names are node-wide. An instance can also be started from options
  alone, which is how tests get isolated instances:

      start_supervised!({Limen, name: :my_test, config: [mode: :enforce]})

  The request path finds its instance with a single `:persistent_term` read.

  Start with `Limen.Plug` and the options in `Limen.Config`.
  """

  use Boundary,
    deps: [EEx, Logger, Plug, Plug.Crypto],
    exports: [
      Config,
      Context,
      Decision,
      Decision.Match,
      DecisionLog,
      DecisionLog.Flusher,
      Instance,
      IP,
      Challenge,
      {Challenge, []},
      Lists,
      Plug,
      State,
      {State, []},
      Policy,
      {Policy, []},
      Signal,
      {Signal, []},
      Stats,
      Supervisor,
      Tarpit,
      Telemetry
    ]

  alias Limen.{Instance, IP}
  alias Limen.State.BanList

  @type instance :: atom()

  @doc """
  Starts the instances configured for `:otp_app`, or a single instance from
  `:name` and `:config`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case {Keyword.fetch(opts, :otp_app), Keyword.fetch(opts, :name)} do
      {{:ok, app}, :error} ->
        children =
          for {name, config} <- Limen.Config.from_app(app) do
            Supervisor.child_spec({Limen.Supervisor, name: name, config: config}, id: name)
          end

        Supervisor.start_link(children, strategy: :one_for_one)

      {:error, {:ok, name}} when is_atom(name) ->
        Limen.Supervisor.start_link(name: name, config: Keyword.get(opts, :config, []))

      _invalid ->
        raise ArgumentError,
              "expected {Limen, otp_app: app} or {Limen, name: name, config: opts}, got: " <>
                inspect(opts)
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:name] || opts[:otp_app]},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns the decision Limen made for `conn`, if it went through `Limen.Plug`.
  """
  @spec decision(Plug.Conn.t()) :: Limen.Decision.t() | nil
  def decision(%Plug.Conn{private: private}), do: Map.get(private, :limen)

  @doc """
  Bans a client for `ttl` seconds.

  `target` is an address (tuple or string), which is aggregated to its prefix
  like any request would be, or a prefix in CIDR notation whose length matches
  the instance's aggregation (`:ipv4_prefix` or `:ipv6_prefix`). To block
  arbitrary ranges, use a policy rule with a list instead.

  Options are those of `Limen.State.BanList.ban/4`; `:origin` defaults to
  `:admin`.
  """
  @spec ban(instance(), :inet.ip_address() | String.t() | IP.prefix(), pos_integer(), keyword()) ::
          :ok | {:error, :full}
  def ban(instance, target, ttl, opts \\ []) do
    instance = Instance.fetch!(instance)
    prefix = to_prefix!(instance, target)
    BanList.ban(instance, prefix, ttl, Keyword.put_new(opts, :origin, :admin))
  end

  @doc """
  Lifts a ban. Accepts the same targets as `ban/4`.
  """
  @spec unban(instance(), :inet.ip_address() | String.t() | IP.prefix()) :: :ok
  def unban(instance, target) do
    instance = Instance.fetch!(instance)
    BanList.unban(instance, to_prefix!(instance, target))
  end

  @doc """
  Returns the active ban covering `target`, if any.
  """
  @spec banned(instance(), :inet.ip_address() | String.t() | IP.prefix()) :: BanList.ban() | nil
  def banned(instance, target) do
    instance = Instance.fetch!(instance)
    BanList.lookup(instance, to_prefix!(instance, target), System.system_time(:millisecond))
  end

  defp to_prefix!(%Instance{config: config}, {version, n, length} = prefix)
       when version in [4, 6] and is_integer(n) and is_integer(length) do
    expected = if version == 4, do: config.ipv4_prefix, else: config.ipv6_prefix

    if length != expected do
      raise ArgumentError,
            "cannot ban #{IP.prefix_to_string(prefix)}: bans apply to /#{expected} prefixes " <>
              "for IPv#{version}, use a policy list to block other ranges"
    end

    prefix
  end

  defp to_prefix!(%Instance{config: config}, ip) when is_tuple(ip) do
    IP.prefix(ip, config.ipv4_prefix, config.ipv6_prefix)
  end

  defp to_prefix!(instance, string) when is_binary(string) do
    with :error <- IP.parse(string),
         :error <- IP.parse_cidr(string) do
      raise ArgumentError, "expected an IP address or CIDR prefix, got: #{inspect(string)}"
    else
      {:ok, {_version, _n, _length} = prefix} -> to_prefix!(instance, prefix)
      {:ok, ip} -> to_prefix!(instance, ip)
    end
  end

  @doc """
  Switches an instance between `:dry_run` and `:enforce` at runtime.

  Routes and plugs with an explicit `:mode` keep theirs.
  """
  @spec set_mode(instance(), :dry_run | :enforce) :: :ok
  def set_mode(instance, mode), do: Instance.put_config(instance, :mode, mode)
end
