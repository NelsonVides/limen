defmodule Limen.Test.FakeDNS do
  @moduledoc """
  A `Limen.Signal.Fcrdns.DNS` answering from a table set by tests.
  """

  @behaviour Limen.Signal.Fcrdns.DNS

  @key {__MODULE__, :records}

  @doc """
  Sets the records: `{:ptr, ip} => hosts | error` and `{:a, host} => ips | error`.
  """
  def put(records), do: :persistent_term.put(@key, records)

  @impl true
  def reverse(ip, _timeout), do: answer({:ptr, ip})

  @impl true
  def forward(host, _version, _timeout), do: answer({:a, host})

  defp answer(question) do
    case Map.get(:persistent_term.get(@key, %{}), question, {:error, :nxdomain}) do
      {:error, reason} -> {:error, reason}
      records -> {:ok, records}
    end
  end
end
