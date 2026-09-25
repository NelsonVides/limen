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

  alias Limen.Instance

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
            Supervisor.child_spec({Instance.Supervisor, name: name, config: config}, id: name)
          end

        Supervisor.start_link(children, strategy: :one_for_one)

      {:error, {:ok, name}} when is_atom(name) ->
        Instance.Supervisor.start_link(name: name, config: Keyword.get(opts, :config, []))

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
  Switches an instance between `:dry_run` and `:enforce` at runtime.

  Routes and plugs with an explicit `:mode` keep theirs.
  """
  @spec set_mode(instance(), :dry_run | :enforce) :: :ok
  def set_mode(instance, mode), do: Instance.put_config(instance, :mode, mode)
end
