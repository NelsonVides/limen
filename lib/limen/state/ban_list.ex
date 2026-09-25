defmodule Limen.State.BanList do
  @moduledoc """
  Banned prefixes, with expiry.

  A ban is keyed on the same prefix every other piece of state uses (see
  `Limen.IP.prefix/3`), so checking one is a single ETS lookup. Expired bans
  are ignored on lookup and removed later by `Limen.State.Sweeper`.

  Each ban records the mode of whatever created it. A ban created by a policy
  in dry-run mode is looked up and reported exactly like any other, but never
  enforced, so a dry-run policy can never block traffic, not even through
  state it leaves behind.

  The list holds at most `:max_bans` entries; further bans are refused.
  """

  alias Limen.Instance

  @type origin :: :policy | :admin | :remote
  @type ban :: %{
          prefix: Limen.IP.prefix(),
          expires_at: integer(),
          reason: term(),
          mode: :dry_run | :enforce,
          origin: origin()
        }

  @doc """
  Bans `prefix` for `ttl` seconds.

  If the prefix is already banned, the ban is extended when the new one lasts
  longer, and escalated to `:enforce` when either ban enforces.

  ## Options

    * `:reason` - recorded with the ban and reported in decisions.
    * `:mode` - `:enforce` (default) or `:dry_run`.
    * `:origin` - `:policy`, `:admin` (default) or `:remote`.
    * `:now` - the current system time in milliseconds.
  """
  @spec ban(Instance.t(), Limen.IP.prefix(), pos_integer(), keyword()) :: :ok | {:error, :full}
  def ban(%Instance{} = instance, prefix, ttl, opts \\ []) when is_integer(ttl) and ttl > 0 do
    entry = entry(prefix, ttl, opts)
    %{table: table, size: size} = instance.state.bans

    cond do
      :ets.member(table, prefix) ->
        extend(table, entry)

      :atomics.get(size, 1) >= instance.config.state.max_bans ->
        Limen.Stats.incr(instance, :saturated)
        {:error, :full}

      :ets.insert_new(table, entry) ->
        :atomics.add(size, 1, 1)
        added(instance, entry, ttl)

      true ->
        extend(table, entry)
    end
  end

  defp entry(prefix, ttl, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
    mode = Keyword.get(opts, :mode, :enforce)

    {prefix, now + ttl * 1_000, Keyword.get(opts, :reason), mode,
     Keyword.get(opts, :origin, :admin)}
  end

  defp extend(table, {prefix, expires_at, reason, mode, origin} = entry) do
    case :ets.lookup(table, prefix) do
      [{^prefix, current_expiry, _reason, current_mode, _origin}]
      when current_expiry >= expires_at and (current_mode == :enforce or mode == :dry_run) ->
        :ok

      [{^prefix, current_expiry, _reason, current_mode, _origin}] ->
        mode = if current_mode == :enforce, do: :enforce, else: mode
        expires_at = max(current_expiry, expires_at)
        :ets.insert(table, {prefix, expires_at, reason, mode, origin})
        :ok

      [] ->
        :ets.insert(table, entry)
        :ok
    end
  end

  defp added(instance, {prefix, expires_at, reason, _mode, origin}, ttl) do
    Limen.Stats.incr(instance, :ban_added)

    Limen.Telemetry.execute(instance.name, [:ban, :added], %{ttl: ttl}, %{
      prefix: prefix,
      reason: reason,
      origin: origin,
      expires_at: expires_at
    })
  end

  @doc """
  Returns the active ban for `prefix` at `now` (milliseconds), if any.
  """
  @spec lookup(Instance.t(), Limen.IP.prefix() | nil, integer()) :: ban() | nil
  def lookup(_instance, nil, _now), do: nil

  def lookup(%Instance{state: %{bans: %{table: table}}}, prefix, now) do
    case :ets.lookup(table, prefix) do
      [{^prefix, expires_at, reason, mode, origin}] when expires_at > now ->
        %{prefix: prefix, expires_at: expires_at, reason: reason, mode: mode, origin: origin}

      _expired_or_missing ->
        nil
    end
  end

  @doc """
  Lifts the ban on `prefix`.
  """
  @spec unban(Instance.t(), Limen.IP.prefix()) :: :ok
  def unban(%Instance{state: %{bans: %{table: table, size: size}}}, prefix) do
    if :ets.take(table, prefix) != [], do: :atomics.sub(size, 1, 1)
    :ok
  end

  @doc """
  Lists active bans, soonest to expire first.
  """
  @spec list(Instance.t(), integer()) :: [ban()]
  def list(%Instance{state: %{bans: %{table: table}}}, now \\ System.system_time(:millisecond)) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn {_prefix, expires_at, _reason, _mode, _origin} -> expires_at > now end)
    |> Enum.sort_by(fn {_prefix, expires_at, _reason, _mode, _origin} -> expires_at end)
    |> Enum.map(fn {prefix, expires_at, reason, mode, origin} ->
      %{prefix: prefix, expires_at: expires_at, reason: reason, mode: mode, origin: origin}
    end)
  end

  @doc """
  Removes expired bans and returns how many were removed.
  """
  @spec sweep(Instance.t(), integer()) :: non_neg_integer()
  def sweep(
        %Instance{state: %{bans: %{table: table, size: size}}},
        now \\ System.system_time(:millisecond)
      ) do
    swept = :ets.select_delete(table, [{{:_, :"$1", :_, :_, :_}, [{:"=<", :"$1", now}], [true]}])
    :atomics.put(size, 1, :ets.info(table, :size))
    swept
  end
end
