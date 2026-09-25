defmodule Limen.Case do
  @moduledoc """
  Test case starting an isolated `Limen` instance for every test.

  The instance's name is in the test context as `:limen`, and its
  configuration is the test defaults plus any `@moduletag config: [...]` or
  `@tag config: [...]` overrides. Instances share nothing, so tests using this
  case can run concurrently.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Limen.Case
      import Plug.Conn
      import Plug.Test
    end
  end

  # Decisions are only logged by the tests that check logging.
  @defaults [decision_log: [non_allow_sample_rate: 0.0]]

  setup context do
    name = :"limen_test_#{System.unique_integer([:positive])}"
    config = Keyword.merge(@defaults, Map.get(context, :config, []))
    start_supervised!({Limen, name: name, config: config})
    %{limen: name}
  end

  @doc """
  The running instance `name`.
  """
  def instance(name), do: Limen.Instance.fetch!(name)

  @doc """
  Attaches a telemetry handler forwarding `events` of instance `name` to the
  test process.
  """
  def capture_events(events, name) do
    id = {__MODULE__, make_ref()}
    :telemetry.attach_many(id, events, &__MODULE__.forward_event/4, {self(), name})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  @doc false
  def forward_event(event, measurements, %{instance: name} = metadata, {pid, name}) do
    send(pid, {:event, event, measurements, metadata})
  end

  def forward_event(_event, _measurements, _metadata, _config), do: :ok
end
