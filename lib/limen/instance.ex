defmodule Limen.Instance do
  @moduledoc """
  A running Limen instance: its configuration and handles to its state.

  When an instance starts, it creates its tables and counters and publishes
  this struct in `:persistent_term` under its name. The request path reads it
  once, at the start of each request, and hands it down in the
  `Limen.Context`: finding an instance never involves a process, a registry or
  an ETS lookup.

  Changing an instance's configuration at runtime republishes the struct,
  which triggers a global GC scan in the runtime: treat it as an operator
  action, not something to do per request.
  """

  use Boundary, type: :strict, deps: [Limen.Config]

  @enforce_keys [:name, :config]
  defstruct [:name, :config, :supervisor, :stats, :log, :state]

  @type t :: %__MODULE__{
          name: atom(),
          config: Limen.Config.t(),
          supervisor: pid() | nil,
          stats: :counters.counters_ref() | nil,
          log: map() | nil,
          state: map() | nil
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
  Validates and replaces one configuration option of a running instance.
  """
  @spec put_config(atom(), atom(), term()) :: :ok
  def put_config(name, key, value) do
    instance = fetch!(name)
    publish(%{instance | config: Limen.Config.put(instance.config, key, value)})
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

  @doc false
  @spec publish(t()) :: :ok
  def publish(%__MODULE__{name: name} = instance),
    do: :persistent_term.put({Limen, name}, instance)

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(name) do
    _existed = :persistent_term.erase({Limen, name})
    :ok
  end
end
