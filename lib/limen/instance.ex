defmodule Limen.Instance do
  @moduledoc """
  A running Limen instance: its configuration and handles to its state.

  When an instance starts, it creates its tables and counters and publishes
  this struct in `:persistent_term` under its name. The request path reads it
  once, at the start of each request, and hands it down in the
  `Limen.Context`: finding an instance never involves a process, a registry or
  an ETS lookup.

  Changing an instance's configuration at runtime (`update_config/3`)
  republishes the struct, which triggers a global GC scan in the runtime:
  treat it as an operator action, not something to do per request.
  """

  use Limen.Boundary, type: :strict, deps: [Limen.Config]

  @enforce_keys [:name, :config]
  defstruct [
    :name,
    :config,
    :supervisor,
    :stats,
    :log,
    :state,
    :tarpit,
    :maze,
    :replay,
    :cookie_pattern,
    :pass_binding
  ]

  @type t :: %__MODULE__{
          name: atom(),
          config: Limen.Config.t(),
          supervisor: pid() | nil,
          stats: :counters.counters_ref() | nil,
          log: map() | nil,
          state: map() | nil,
          tarpit: :atomics.atomics_ref() | nil,
          maze: :atomics.atomics_ref() | nil,
          replay: term(),
          cookie_pattern: :binary.cp() | nil,
          pass_binding: [:prefix | :ja4 | :user_agent] | nil
        }

  @doc """
  Returns the running instance `name`.

  Raises if it is not running.
  """
  @spec fetch!(atom() | t()) :: t()
  def fetch!(%__MODULE__{} = instance), do: instance

  def fetch!(name) when is_atom(name) do
    case :persistent_term.get({Limen, name}, nil) do
      nil ->
        raise ArgumentError,
              "the Limen instance #{inspect(name)} is not running, start it with " <>
                "{Limen, otp_app: app} or {Limen, name: #{inspect(name)}} in your supervision tree"

      instance ->
        instance
    end
  end

  @doc """
  Returns the running instance `name`, or `nil`.
  """
  @spec get(atom()) :: t() | nil
  def get(name) when is_atom(name), do: :persistent_term.get({Limen, name}, nil)

  @doc """
  The instance name given by an `:instance` or an `:otp_app` option, as
  `Limen.Plug` and the socket checks take it.
  """
  @spec name!(keyword()) :: atom()
  def name!(opts) do
    case {Keyword.get(opts, :instance), Keyword.get(opts, :otp_app)} do
      {name, nil} when is_atom(name) and name != nil ->
        name

      {nil, app} when is_atom(app) and app != nil ->
        app

      _missing_or_both ->
        raise ArgumentError, "expected either an :instance or an :otp_app option"
    end
  end

  @doc """
  Validates and changes one configuration option of a running instance.

  Keyword lists are merged into the option's current value, see
  `Limen.Config.update/3`. Raises `ArgumentError` on an invalid value, or
  for an option only read when the instance starts.
  """
  @spec update_config(atom(), atom(), term()) :: :ok
  def update_config(name, key, value) do
    instance = fetch!(name)
    publish(%{instance | config: Limen.Config.update(instance.config, key, value)})
  end

  @doc """
  The pid of the process with child id `id` in the instance's supervisor.
  """
  @spec whereis(atom() | t(), module()) :: pid() | nil
  def whereis(instance, id) do
    %__MODULE__{supervisor: supervisor} = fetch!(instance)

    Enum.find_value(Supervisor.which_children(supervisor), fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  # What is derived from the configuration is derived again on every
  # publish, so a configuration change cannot leave it stale: the pass
  # cookie's name, compiled for searching cookie headers, and what passes
  # are bound to, `nil` for the whole identity, where the fast path reads it.
  @doc false
  @spec publish(t()) :: :ok
  def publish(%__MODULE__{name: name, config: %{challenge: challenge}} = instance) do
    pattern = :binary.compile_pattern(challenge.cookie <> "=")
    binding = if challenge.bind != [:prefix, :ja4, :user_agent], do: challenge.bind

    :persistent_term.put(
      {Limen, name},
      %{instance | cookie_pattern: pattern, pass_binding: binding}
    )
  end

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(name) do
    _existed = :persistent_term.erase({Limen, name})
    :ok
  end
end
