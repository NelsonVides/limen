defmodule Limen.Lists do
  @moduledoc """
  Named lists policies can test membership against, such as known-bad JA4
  fingerprints or allow-listed networks.

  Lists belong to an instance and live in `:persistent_term`, so a membership
  test on the request path is a lookup with no copying. Replacing a list
  triggers a global GC scan in the runtime: reload lists when they change,
  not per request.

  There are three kinds of lists:

    * exact lists, whose members are compared as terms (`put/3`);
    * CIDR lists, whose members are address ranges and which match any
      address inside them (`put_cidrs/3`);
    * substring lists, which match any string containing one of their
      members, case included (`put_substrings/3`), for user agents and
      other headers.

  Lists can also be configured with the instance, and are then loaded when it
  starts:

      config :my_app, Limen,
        lists: [
          bad_ja4: ["t13d1812h1_85036bcba153_375ca2c5e164"],
          office: {:cidr, ["192.0.2.0/24", "2001:db8::/32"]},
          scrapers: {:substrings, ["SiteSucker", "HTTrack"]}
        ]

  In a policy, `signal(:user_agent) in list(:scrapers)` then holds for any
  user agent containing `SiteSucker` or `HTTrack`. A substring list is
  searched in one pass, however many members it has.

  In a policy, `signal(:ja4) in list(:bad_ja4)` compiles to `member?/3`
  against the request's instance. Testing a list that was never defined is
  not an error: it has no members.
  """

  use Limen.Boundary, type: :strict, deps: [Limen.Instance, Limen.IP]

  alias Limen.{Instance, IP}

  @type instance :: atom() | Instance.t()
  @type name :: atom()

  @doc """
  Defines or replaces the exact list `name` of `instance`.
  """
  @spec put(instance(), name(), Enumerable.t()) :: :ok
  def put(instance, name, values) when is_atom(name) do
    values = Enum.to_list(values)
    :persistent_term.put(key(instance, name), {:exact, Map.new(values, &{&1, true}), values})
  end

  @doc """
  Defines or replaces the CIDR list `name` of `instance`.

  Raises `ArgumentError` on an invalid range.
  """
  @spec put_cidrs(instance(), name(), [String.t() | IP.prefix()]) :: :ok
  def put_cidrs(instance, name, ranges) when is_atom(name) and is_list(ranges) do
    :persistent_term.put(key(instance, name), {:cidr, IP.cidr_set(ranges), ranges})
  end

  @doc """
  Defines or replaces the substring list `name` of `instance`.

  A string is a member when it contains any of `substrings`, which must not
  be empty strings.
  """
  @spec put_substrings(instance(), name(), [String.t()]) :: :ok
  def put_substrings(instance, name, substrings) when is_atom(name) and is_list(substrings) do
    unless Enum.all?(substrings, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError, "expected non-empty strings, got: #{inspect(substrings)}"
    end

    pattern = if substrings != [], do: :binary.compile_pattern(substrings)
    :persistent_term.put(key(instance, name), {:substrings, pattern, substrings})
  end

  @doc """
  Removes the list `name` of `instance`.
  """
  @spec delete(instance(), name()) :: :ok
  def delete(instance, name) do
    _existed = :persistent_term.erase(key(instance, name))
    :ok
  end

  @doc """
  Whether `value` is a member of list `name` of `instance`.

  For CIDR lists, `value` must be an address tuple, and for substring lists
  a string.

      iex> Limen.Lists.put(:doc_instance, :doc_example, ["a", "b"])
      iex> Limen.Lists.member?(:doc_instance, :doc_example, "a")
      true
      iex> Limen.Lists.put_cidrs(:doc_instance, :doc_networks, ["192.0.2.0/24"])
      iex> Limen.Lists.member?(:doc_instance, :doc_networks, {192, 0, 2, 7})
      true
      iex> Limen.Lists.put_substrings(:doc_instance, :doc_agents, ["HTTrack"])
      iex> Limen.Lists.member?(:doc_instance, :doc_agents, "Mozilla/4.5 (compatible; HTTrack 3.0x)")
      true
      iex> Limen.Lists.member?(:doc_instance, :undefined_list, "a")
      false
  """
  @spec member?(instance(), name(), term()) :: boolean()
  def member?(instance, name, value) do
    case :persistent_term.get(key(instance, name), nil) do
      {:exact, members, _values} ->
        is_map_key(members, value)

      {:cidr, set, _ranges} when is_tuple(value) ->
        IP.member?(set, value)

      {:substrings, pattern, _values} when is_binary(value) and pattern != nil ->
        contains?(value, pattern)

      _undefined_or_not_an_address ->
        false
    end
  end

  defp contains?(value, pattern), do: :binary.match(value, pattern) != :nomatch

  @doc """
  Returns the members of list `name` of `instance` as given, or `[]`.
  """
  @spec get(instance(), name()) :: list()
  def get(instance, name) do
    case :persistent_term.get(key(instance, name), nil) do
      {_kind, _index, values} -> values
      nil -> []
    end
  end

  @doc false
  @spec load(atom(), keyword()) :: :ok
  def load(instance, lists) do
    Enum.each(lists, fn
      {name, {:cidr, ranges}} -> put_cidrs(instance, name, ranges)
      {name, {:substrings, substrings}} -> put_substrings(instance, name, substrings)
      {name, values} -> put(instance, name, values)
    end)
  end

  # Runs when an instance stops, so scanning every persistent term is fine.
  @doc false
  @spec clear(atom()) :: :ok
  def clear(instance) do
    for {{__MODULE__, ^instance, _name} = key, _list} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ok
  end

  defp key(%Instance{name: instance}, name), do: {__MODULE__, instance, name}
  defp key(instance, name) when is_atom(instance), do: {__MODULE__, instance, name}
end
