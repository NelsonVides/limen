defmodule Limen.Bench.Scenarios do
  @moduledoc """
  The request-path operations CI tracks for performance regressions.

  Scenario names are the keys results are compared by, so renaming one starts
  a new series.

  Every sample runs its operation `batch/0` times: single operations take a
  few hundred nanoseconds, too close to timer resolution and scheduling noise
  for a 10% regression threshold to be meaningful. Reported figures are
  divided back to a single operation.

  Every scenario runs against a fresh `Limen` instance with its own
  configuration, so results do not depend on scenario order. Operations
  receive the instance, as the request path does after its single lookup.
  """

  import Bitwise
  import Plug.Test

  alias Limen.Challenge.{Pass, Token}
  alias Limen.{Context, Policy, Signal}
  alias Limen.Signal.{Asn, HttpShape}
  alias Limen.Signal.Asn.Table
  alias Limen.State.{BanList, Gcra, Window}

  @batch 100
  @instance :limen_bench

  @doc """
  Operations per benchmark sample.
  """
  @spec batch() :: pos_integer()
  def batch, do: @batch

  @doc """
  Starts the supervisor scenario instances run under.
  """
  @spec setup() :: :ok
  def setup do
    {:ok, _pid} = DynamicSupervisor.start_link(name: __MODULE__, strategy: :one_for_one)
    :ok
  end

  @doc """
  Returns every scenario as a Benchee job map.
  """
  @spec all() :: %{String.t() => {(Limen.Instance.t() -> term()), keyword()}}
  def all do
    state()
    |> Map.merge(plug())
    |> Map.merge(maze())
    |> Map.merge(asn())
    |> Map.new(fn
      {name, {fun, config}} -> {name, job(fun, config, & &1)}
      {name, {fun, config, prepare}} -> {name, job(fun, config, prepare)}
    end)
  end

  # A scenario's operation receives the fresh instance, or what its optional
  # `prepare` function builds from it.
  defp job(fun, config, prepare) do
    {fn input -> repeat(fun, input, @batch) end,
     before_scenario: fn _input -> prepare.(restart(config)) end}
  end

  @doc """
  Starts a fresh instance with `config` and returns it.
  """
  @spec restart(keyword()) :: Limen.Instance.t()
  def restart(config) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(__MODULE__) do
      :ok = DynamicSupervisor.terminate_child(__MODULE__, pid)
    end

    config = Keyword.put_new(config, :secret_key, String.duplicate("bench", 8))

    {:ok, _pid} =
      DynamicSupervisor.start_child(__MODULE__, {Limen, name: @instance, config: config})

    Limen.Instance.fetch!(@instance)
  end

  defp repeat(_fun, _instance, 0), do: :ok

  defp repeat(fun, instance, n) do
    fun.(instance)
    repeat(fun, instance, n - 1)
  end

  defp state do
    now = fn -> System.system_time(:millisecond) end
    counter = :counters.new(1, [:write_concurrency])

    unique = fn ->
      :counters.add(counter, 1, 1)
      {:bench, {6, :counters.get(counter, 1), 64}}
    end

    %{
      "state: window incr, hot key" =>
        {fn instance -> Window.incr(instance, :second, :bench_hot, now.()) end, []},
      "state: window incr, flood of unique keys" =>
        {fn instance -> Window.incr(instance, :minute, unique.(), now.()) end,
         [state: [max_keys: 1_000]]},
      "state: window count" =>
        {fn instance -> Window.count(instance, :second, :bench_hot, now.()) end, []},
      "state: gcra check" =>
        {fn instance -> Gcra.check(instance, :bench_gcra, 1_000_000, 1_000, 1_000) end, []},
      "state: ban lookup, miss" =>
        {fn instance -> BanList.lookup(instance, {4, 1, 32}, now.()) end, []}
    }
  end

  @proxied [trusted_proxies: ["10.0.0.0/8"], client_ip_header: "x-forwarded-for"]

  defp plug do
    chrome =
      :get
      |> conn("/articles/42")
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> Map.put(:scheme, :https)
      |> Map.put(:req_headers, chrome_headers())

    identify = fn instance ->
      Signal.identify(Context.from_conn(chrome, instance), instance.config)
    end

    Map.merge(requests(chrome, identify), components(chrome, identify))
  end

  defp requests(chrome, identify) do
    opts = Limen.Plug.init(instance: @instance)

    # Clients rotate through a pool large enough that none of them hits the
    # default policy's flood limit, so every call takes the full path.
    pool = List.to_tuple(for n <- 1..20_000, do: with_client(chrome, n))
    counter = :counters.new(1, [:write_concurrency])

    next_client = fn ->
      :counters.add(counter, 1, 1)
      elem(pool, rem(:counters.get(counter, 1), tuple_size(pool)))
    end

    with_pass = fn instance ->
      {pass, _ttl} = Pass.issue(identify.(instance))
      Plug.Conn.put_req_header(chrome, "cookie", "_ga=GA1.1.1; _limen_pass=" <> pass)
    end

    %{
      "plug: pass fast path, chrome via proxy" =>
        {fn conn -> Limen.Plug.call(conn, opts) end, @proxied, with_pass},
      "plug: dry-run, default policy, chrome via proxy" =>
        {fn _instance -> Limen.Plug.call(next_client.(), opts) end, @proxied}
    }
  end

  defp components(chrome, identify) do
    collect = fn instance -> Signal.collect(identify.(instance), Signal.defaults()) end

    with_pass = fn instance ->
      identity = identify.(instance)
      {pass, _ttl} = Pass.issue(identity)
      {pass, identity}
    end

    with_token = fn instance ->
      identity = identify.(instance)
      {Token.issue(identity, 16), identity}
    end

    %{
      "challenge: verify pass cookie" =>
        {fn {pass, identity} -> Pass.verify(pass, identity) end, [], with_pass},
      "challenge: verify token" =>
        {fn {token, identity} -> Token.verify(token, identity) end, [], with_token},
      "policy: evaluate default, chrome" =>
        {fn ctx -> Policy.evaluate(Policy.Default, ctx) end, @proxied, collect},
      "signals: identity via proxy" => {identify, @proxied},
      "signals: http shape, chrome" =>
        {fn instance -> HttpShape.collect(Context.from_conn(chrome, instance)) end, []}
    }
  end

  # Rendering happens once per maze response, off the path of legitimate
  # requests; the rest of a maze response is spent asleep.
  defp maze do
    render = fn instance ->
      IO.iodata_to_binary(
        Limen.Maze.page(instance, "/archive/regional-reports-2291", "/archive", 0)
      )
    end

    %{"maze: render page" => {render, [trap: [paths: ["/archive"]]]}}
  end

  # Lookups in a synthetic table as dense as the iptoasn.com data: 450,000
  # IPv4 and 120,000 IPv6 ranges, built once and published into each
  # scenario's instance.
  defp asn do
    lookup = fn {name, pick} -> Asn.lookup(name, pick.()) end

    %{
      "signals: asn lookup, ipv4" => {lookup, [], &asn_prepare(&1, 4)},
      "signals: asn lookup, ipv6" => {lookup, [], &asn_prepare(&1, 6)}
    }
  end

  defp asn_prepare(instance, version) do
    :ok = Asn.publish(instance.name, asn_table())
    addresses = asn_addresses(version)
    counter = :counters.new(1, [:write_concurrency])
    {instance.name, fn -> next(addresses, counter) end}
  end

  defp next(pool, counter) do
    :counters.add(counter, 1, 1)
    elem(pool, rem(:counters.get(counter, 1), tuple_size(pool)))
  end

  defp asn_table do
    with nil <- :persistent_term.get({__MODULE__, :asn_table}, nil) do
      :rand.seed(:exsss, 1)
      v4 = asn_rows(4, 450_000, 16_777_216, 256..8_192)
      v6 = asn_rows(6, 120_000, 0x2001 <<< 112, (1 <<< 64)..(1 <<< 80))
      {:ok, table} = Table.from_rows(v4 ++ v6)
      :persistent_term.put({__MODULE__, :asn_table}, table)
      table
    end
  end

  defp asn_rows(version, count, start, sizes) do
    {rows, _next} =
      Enum.map_reduce(1..count, start, fn n, first ->
        last = first + Enum.random(sizes)
        asn = rem(n, 80_000) + 1
        row = {asn_address(version, first), asn_address(version, last), asn, "US", "AS#{asn}"}
        {row, last + 1 + Enum.random([0, 0, 0, 256])}
      end)

    rows
  end

  defp asn_address(version, n), do: to_string(:inet.ntoa(asn_ip(n, version)))

  defp asn_ip(n, 4), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
  defp asn_ip(n, 6), do: List.to_tuple(for shift <- 112..0//-16, do: n >>> shift &&& 0xFFFF)

  defp asn_addresses(4),
    do:
      List.to_tuple(for _n <- 1..10_000, do: asn_ip(16_777_216 + :rand.uniform(2_000_000_000), 4))

  defp asn_addresses(6),
    do:
      List.to_tuple(
        for _n <- 1..10_000, do: asn_ip((0x2001 <<< 112) + :rand.uniform(1 <<< 96), 6)
      )

  defp with_client(conn, n) do
    address = "203.0.#{div(n, 256)}.#{rem(n, 256)}"

    headers =
      List.keyreplace(conn.req_headers, "x-forwarded-for", 0, {"x-forwarded-for", address})

    %{conn | req_headers: headers}
  end

  defp chrome_headers do
    [
      {"host", "example.com"},
      {"sec-ch-ua", ~s("Chromium";v="128", "Not;A=Brand";v="24", "Google Chrome";v="128")},
      {"sec-ch-ua-mobile", "?0"},
      {"sec-ch-ua-platform", ~s("Windows")},
      {"upgrade-insecure-requests", "1"},
      {"user-agent",
       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
         "Chrome/128.0.0.0 Safari/537.36"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"sec-fetch-site", "none"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-user", "?1"},
      {"sec-fetch-dest", "document"},
      {"accept-encoding", "gzip, deflate, br, zstd"},
      {"accept-language", "en-US,en;q=0.9"},
      {"x-forwarded-for", "203.0.113.7"},
      {"x-ja4", "t13d1516h2_8daaf6152771_02713d6af862"}
    ]
  end
end
