defmodule Limen.Signal.Fcrdns do
  @moduledoc """
  Verifies that a request claiming to come from a search engine crawler
  really does, with forward-confirmed reverse DNS (FCrDNS): the check search
  engines document themselves, as [Google does for Googlebot][FCrDNS].

  A crawler's address must point back, through its reverse DNS ([PTR])
  record, to a host under the crawler's published domains (for Googlebot,
  `googlebot.com` or `google.com`), and that host must resolve back to the
  same address. Anyone can put `Googlebot` in a user agent; only Google
  controls those DNS records.

  DNS is far too slow for the request path, so this signal only ever reads a
  cache. The first request from an unverified crawler address puts it on a
  bounded queue and reports `:pending`; `Limen.Signal.Fcrdns.Resolver`
  resolves queued addresses in the background and caches the result, which
  later requests read.

  Provides `:fcrdns`:

    * `:verified` - the address belongs to the crawler it claims to be;
    * `:failed` - it does not: the user agent is spoofed;
    * `:pending` - verification is queued or a lookup failed transiently;
    * `:unverifiable` - a crawler Limen has no DNS suffixes for;
    * `:not_claimed` - the user agent does not claim to be a crawler.

  The evidence names the claimed crawler and, once resolved, the host or the
  reason verification failed. Crawlers and their suffixes are configured with
  the `:fcrdns` option, see `Limen.Config`.

  [FCrDNS]: https://developers.google.com/search/docs/crawling-indexing/verifying-googlebot
  [PTR]: https://www.rfc-editor.org/rfc/rfc1035#section-3.3.12
  """

  @behaviour Limen.Signal

  alias Limen.{Context, Instance, IP}
  alias Limen.Signal.UserAgent

  @type result :: :verified | :failed | :error

  @impl true
  def provides, do: [:fcrdns]

  @impl true
  def collect(%Context{instance: instance} = ctx) do
    %Instance{config: %{fcrdns: config}, state: %{fcrdns: tables}} = instance

    case crawler(ctx) do
      nil ->
        Context.put_signal(ctx, :fcrdns, :not_claimed)

      name when is_map_key(config.crawlers, name) ->
        {value, evidence} = lookup(tables, ctx.client_ip, name, ctx.now, config)
        Context.put_signal(ctx, :fcrdns, value, Map.put(evidence, :crawler, name))

      name ->
        Context.put_signal(ctx, :fcrdns, :unverifiable, %{crawler: name})
    end
  end

  # Reuses the user agent parsed by the HTTP shape signal when available.
  defp crawler(%Context{signals: %{ua_family: :crawler}, evidence: %{ua_family: %{name: name}}}),
    do: name || "unknown"

  defp crawler(%Context{signals: %{ua_family: _other}}), do: nil

  defp crawler(%Context{user_agent: user_agent}) do
    case UserAgent.parse(user_agent) do
      %{family: :crawler, name: name} -> name || "unknown"
      _browser_or_tool -> nil
    end
  end

  defp lookup(_tables, nil, _name, _now, _config), do: {:pending, %{}}

  defp lookup(tables, ip, name, now, config) do
    key = {ip, name}

    case :ets.lookup(tables.cache, key) do
      [{^key, :verified, host, expires_at}] when expires_at > now ->
        {:verified, %{host: host}}

      [{^key, :failed, reason, expires_at}] when expires_at > now ->
        {:failed, %{reason: reason}}

      [{^key, :error, _reason, expires_at}] when expires_at > now ->
        {:pending, %{reason: :transient}}

      _missing_or_expired ->
        {enqueue(tables, key, config), %{}}
    end
  end

  defp enqueue(%{pending: pending, size: size}, key, config) do
    if :atomics.get(size, 1) < config.max_pending and :ets.insert_new(pending, {key}) do
      :atomics.add(size, 1, 1)
    end

    :pending
  end

  @doc """
  Verifies that `ip` belongs to a crawler whose hosts are under `suffixes`,
  with the `dns` module and at most `timeout` milliseconds per lookup.

  Returns `{:verified, host}`, `{:failed, reason}` or `{:error, :transient}`.
  """
  @spec verify(:inet.ip_address(), [String.t()], module(), pos_integer()) ::
          {:verified, String.t()} | {:failed, term()} | {:error, :transient}
  def verify(ip, suffixes, dns, timeout) do
    {version, _n} = IP.to_integer(ip)

    with {:ok, hosts} <- dns.reverse(ip, timeout),
         {:ok, host} <- matching_host(hosts, suffixes),
         {:ok, addresses} <- dns.forward(host, version, timeout) do
      if ip in addresses or IP.to_integer(ip) in Enum.map(addresses, &IP.to_integer/1),
        do: {:verified, host},
        else: {:failed, {:forward_mismatch, host}}
    else
      {:error, :transient} -> {:error, :transient}
      {:error, reason} -> {:failed, reason}
    end
  end

  defp matching_host(hosts, suffixes) do
    hosts = Enum.map(hosts, &String.trim_trailing(String.downcase(&1), "."))

    case Enum.find(hosts, &under_suffix?(&1, suffixes)) do
      nil -> {:error, {:unexpected_host, List.first(hosts)}}
      host -> {:ok, host}
    end
  end

  defp under_suffix?(host, suffixes) do
    Enum.any?(suffixes, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end
end
