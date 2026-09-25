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

  A ban's action says what banned clients get: `:deny` (a `403`) or `:maze`
  (the slow pages of `Limen.Maze`, for clients caught by a `Limen.Trap`).

  The list holds at most `:max_bans` entries; further bans are refused.

  When clustering is enabled (see `Limen.Cluster`), bans and unbans made on
  this node are also queued for broadcast; bans received from other nodes
  are not broadcast again.
  """

  alias Limen.Instance

  @type origin :: :policy | :admin | :trap | :remote
  @type action :: :deny | :maze
  @type ban :: %{
          prefix: Limen.IP.prefix(),
          expires_at: integer(),
          reason: term(),
          mode: :dry_run | :enforce,
          origin: origin(),
          action: action()
        }

  @doc """
  Bans `prefix` for `ttl` seconds.

  If the prefix is already banned, the ban is extended when the new one lasts
  longer, escalated to `:enforce` when either ban enforces, and to the maze
  when either sends there: a client caught in a trap stays caught.

  ## Options

    * `:reason` - recorded with the ban and reported in decisions.
    * `:mode` - `:enforce` (default) or `:dry_run`.
    * `:action` - `:deny` (default) or `:maze`.
    * `:origin` - `:policy`, `:admin` (default), `:trap` or `:remote`.
    * `:now` - the current system time in milliseconds.
  """
  @spec ban(Instance.t(), Limen.IP.prefix(), pos_integer(), keyword()) :: :ok | {:error, :full}
  def ban(%Instance{} = instance, prefix, ttl, opts \\ []) when is_integer(ttl) and ttl > 0 do
    entry = entry(prefix, ttl, opts)
    %{table: table, size: size} = instance.state.bans

    cond do
      :ets.member(table, prefix) ->
        extend(instance, table, entry)

      :atomics.get(size, 1) >= instance.config.state.max_bans ->
        Limen.Stats.incr(instance, :saturated)
        {:error, :full}

      :ets.insert_new(table, entry) ->
        :atomics.add(size, 1, 1)
        publish(instance, {:ban, entry}, elem(entry, 4))
        added(instance, entry, ttl)

      true ->
        extend(instance, table, entry)
    end
  end

  defp entry(prefix, ttl, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)
    mode = Keyword.get(opts, :mode, :enforce)

    {prefix, now + ttl * 1_000, Keyword.get(opts, :reason), mode,
     Keyword.get(opts, :origin, :admin), Keyword.get(opts, :action, :deny)}
  end

  defp extend(instance, table, {prefix, expires_at, reason, mode, origin, action} = entry) do
    publish(instance, {:ban, entry}, origin)

    case :ets.lookup(table, prefix) do
      [{^prefix, current_expiry, _reason, current_mode, _origin, current_action}] ->
        current = {current_expiry, current_mode, current_action}

        merged =
          {max(current_expiry, expires_at), strongest(current_mode, mode, :enforce),
           strongest(current_action, action, :maze)}

        # The reason and origin only change when the ban does.
        if merged != current do
          {expires_at, mode, action} = merged
          :ets.insert(table, {prefix, expires_at, reason, mode, origin, action})
        end

        :ok

      [] ->
        :ets.insert(table, entry)
        :ok
    end
  end

  defp strongest(current, new, strong) when strong in [current, new], do: strong
  defp strongest(_current, new, _strong), do: new

  defp added(instance, {prefix, expires_at, reason, _mode, origin, action}, ttl) do
    Limen.Stats.incr(instance, :ban_added)

    Limen.Telemetry.execute(instance.name, [:ban, :added], %{ttl: ttl}, %{
      prefix: prefix,
      reason: reason,
      origin: origin,
      action: action,
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
      [{^prefix, expires_at, _reason, _mode, _origin, _action} = entry] when expires_at > now ->
        to_map(entry)

      _expired_or_missing ->
        nil
    end
  end

  @doc """
  Lifts the ban on `prefix`.
  """
  @spec unban(Instance.t(), Limen.IP.prefix(), keyword()) :: :ok
  def unban(%Instance{state: %{bans: %{table: table, size: size}}} = instance, prefix, opts \\ []) do
    if :ets.take(table, prefix) != [], do: :atomics.sub(size, 1, 1)
    publish(instance, {:unban, prefix}, Keyword.get(opts, :origin, :admin))
  end

  # Queues a local change for broadcast when clustering is enabled.
  defp publish(_instance, _change, :remote), do: :ok
  defp publish(%Instance{config: %{cluster: %{enabled: false}}}, _change, _origin), do: :ok

  defp publish(%Instance{config: config, state: %{bans: bans}}, change, _origin) do
    %{outbox: outbox, outbox_size: size} = bans

    if :atomics.add_get(size, 1, 1) <= config.cluster.max_outbox do
      true = :ets.insert(outbox, {:erlang.unique_integer([:monotonic]), change})
      :ok
    else
      :atomics.sub(size, 1, 1)
    end
  end

  @doc false
  @spec drain_outbox(Instance.t()) :: [{:ban, tuple()} | {:unban, Limen.IP.prefix()}]
  def drain_outbox(%Instance{state: %{bans: %{outbox: outbox, outbox_size: size}}}) do
    entries = :ets.tab2list(outbox)
    Enum.each(entries, fn {id, _change} -> :ets.delete(outbox, id) end)
    :atomics.sub(size, 1, length(entries))
    for {_id, change} <- Enum.sort(entries), do: change
  end

  @doc false
  @spec apply_remote(Instance.t(), {:ban, tuple()} | {:unban, Limen.IP.prefix()}, integer()) ::
          :ok
  def apply_remote(instance, {:ban, {prefix, expires_at, reason, mode, _origin, action}}, now) do
    case div(expires_at - now + 999, 1_000) do
      ttl when ttl > 0 ->
        opts = [reason: reason, mode: mode, action: action, origin: :remote, now: now]
        _result = ban(instance, prefix, ttl, opts)
        :ok

      _expired ->
        :ok
    end
  end

  def apply_remote(instance, {:unban, prefix}, _now), do: unban(instance, prefix, origin: :remote)

  @doc """
  Lists active bans, soonest to expire first.
  """
  @spec list(Instance.t(), integer()) :: [ban()]
  def list(%Instance{state: %{bans: %{table: table}}}, now \\ System.system_time(:millisecond)) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn entry -> elem(entry, 1) > now end)
    |> Enum.sort_by(fn entry -> elem(entry, 1) end)
    |> Enum.map(&to_map/1)
  end

  defp to_map({prefix, expires_at, reason, mode, origin, action}) do
    %{
      prefix: prefix,
      expires_at: expires_at,
      reason: reason,
      mode: mode,
      origin: origin,
      action: action
    }
  end

  @doc """
  Removes expired bans and returns how many were removed.
  """
  @spec sweep(Instance.t(), integer()) :: non_neg_integer()
  def sweep(
        %Instance{state: %{bans: %{table: table, size: size}}},
        now \\ System.system_time(:millisecond)
      ) do
    swept =
      :ets.select_delete(table, [{{:_, :"$1", :_, :_, :_, :_}, [{:"=<", :"$1", now}], [true]}])

    :atomics.put(size, 1, :ets.info(table, :size))
    swept
  end
end
