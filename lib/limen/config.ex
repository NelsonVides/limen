defmodule Limen.Config do
  @moduledoc """
  Instance configuration.

  Every `Limen` instance is configured on its own. Options come from your
  application's environment when started with `{Limen, otp_app: app}` (see
  `from_app/1`), or are given directly with `{Limen, name: name, config: opts}`.
  They are validated once, when the instance starts, and published with it,
  so the request path never reads the application environment.

      config :my_app, Limen,
        mode: :enforce,
        ipv6_prefix: 56

  ## Options

    * `:secret_key` - at least 32 random bytes, used to sign challenge tokens
      and pass cookies. Every node serving the same site needs the same key.
      Without one, a random key is generated at startup and a warning is
      logged. Set it from `config/runtime.exs`, never in compiled config.

    * `:previous_secret_keys` - earlier secret keys, still accepted when
      verifying tokens, for rotating the secret.

    * `:mode` - `:dry_run` (default) or `:enforce`. In dry-run mode every
      decision is computed, recorded and emitted exactly as in enforce mode,
      but the request always continues. Routes and policies can override it.

    * `:trusted_proxies` - [CIDR] ranges of the reverse proxies and TLS
      terminators in front of the application. Forwarding headers and the JA4
      header are only read from these peers. Defaults to `[]`.

    * `:client_ip_header` - how trusted proxies report the client address:
      [`"x-forwarded-for"`][X-Forwarded-For], `"x-real-ip"`,
      [`"forwarded"`][Forwarded] (RFC 7239) or `nil`
      (default) to always use the peer address. Forwarding chains are walked
      from the right, skipping trusted proxies, so clients cannot spoof their
      address by sending the header themselves.

    * `:ja4_header` - request header the TLS terminator stores the [JA4]
      fingerprint in. Defaults to `"x-ja4"`.

    * `:ipv4_prefix` - prefix length IPv4 clients are aggregated to. Defaults
      to `32`.

    * `:ipv6_prefix` - prefix length IPv6 clients are aggregated to. One of
      `48`, `56` or `64` (default).

    * `:decision_log` - sampled structured decision log, see `Limen.DecisionLog`:
      * `:sample_rate` - fraction of `:allow` decisions logged. Defaults to `0.0`.
      * `:non_allow_sample_rate` - fraction of other decisions logged. Defaults
        to `1.0`.
      * `:size` - ring buffer capacity. Defaults to `1024`.
      * `:flush_interval` - milliseconds between flushes to the sink.
        Defaults to `1000`.
      * `:sink` - where flushed decisions go: a `Limen.DecisionLog.Sink`
        module, or `{module, opts}`. Defaults to `Limen.DecisionLog.Logger`,
        which logs them at its `:level` (`:info` by default).
      * `:delivery` - `:batched` (default): the flusher hands sampled
        decisions to the sink in batches, away from the request path.
        `:inline`, **for tests only**: each sampled decision goes to the
        sink at once, in the process that made it, so a sink writing
        through an Ecto sandbox sees the test's connection and a test can
        assert on what it wrote right after the request. A sink that raises
        raises in that process, failing the test. It puts the sink on the
        request path, so never use it in production. See "Decision log
        sinks" in the testing guide.

    * `:asn` - IP to ASN data, see `Limen.Signal.Asn`:
      * `:file` - an [iptoasn.com][iptoasn] `ip2asn-combined.tsv` file (optionally
        gzipped) loaded at startup. With `:url`, where downloads are kept.
        Defaults to `nil`.
      * `:url` - where to download the data from and check it for changes,
        such as `"https://iptoasn.com/data/ip2asn-combined.tsv.gz"`. Needs a
        `:file`. Checks ask for data newer than the file, so when changing
        the `:url` to another source, remove the file or change `:file` too.
        Defaults to `nil`: no downloads.
      * `:refresh` - when to check the `:url`, see
        `Limen.Signal.Asn.Schedule`:
        * `:every` - milliseconds between checks, at least a minute.
          Defaults to a day.
        * `:jitter` - up to this share of `:every` is added to each wait at
          random, so nodes do not check together. Defaults to `0.1`.
        * `:window` - a `{from, to}` pair of `Time`s (UTC), or a list of
          them, outside which scheduled checks do not run; `to` before
          `from` runs over midnight. Defaults to `nil`: any time.
        * `:max_utilization` - postpone a scheduled check while the BEAM's
          schedulers are busier than this share, between `0` and `1`.
          Defaults to `0.9`; `nil` does not check.
        * `:max_memory` - postpone a scheduled check while the BEAM uses
          more than this many bytes. Defaults to `nil`: no limit.
        * `:retry` - milliseconds before trying a postponed check again, and
          a failed one, doubling with each failure up to `:every`. Defaults
          to ten minutes.
        * `:timeout` - milliseconds a download may take. Defaults to five
          minutes.
      * `:hosting` - additional ASNs classified as hosting providers, on top
        of the built-in list.
      * `:source` - the `Limen.Signal.Asn.Source` addresses are looked up in.
        Defaults to `Limen.Signal.Asn`, the iptoasn.com data of `:file` and
        `:url`, which must not be set with another source.

    * `:fcrdns` - crawler verification, see `Limen.Signal.Fcrdns`:
      * `:crawlers` - map of crawler names (as classified by
        `Limen.Signal.UserAgent`) to the DNS suffixes their hosts must have,
        merged over the built-in map.
      * `:dns` - module implementing `Limen.Signal.Fcrdns.DNS`. Defaults to
        `Limen.Signal.Fcrdns.InetRes`.
      * `:verified_ttl`, `:failed_ttl`, `:error_ttl` - seconds results are
        cached. Default to `86_400`, `3_600` and `60`.
      * `:max_pending` - addresses waiting for verification. Defaults to
        `1_000`; beyond that, claims stay unverified until the queue drains.
      * `:max_cache` - cached results. Defaults to `100_000`.
      * `:interval` - milliseconds between resolver runs. Defaults to `50`.
      * `:concurrency` and `:timeout` - lookups in flight and milliseconds
        each may take. Default to `16` and `2_000`.

    * `:user_agents` - tokens `Limen.Signal.UserAgent` classifies, on top of
      its built-in lists, by family: `:crawler`, `:ai_crawler`,
      `:link_preview`, `:headless` or `:tool`, each a list of tokens (named
      after themselves) or `{token, name}` pairs, and `:ignore`, a list of
      built-in tokens to leave out. Listing a built-in token under a family
      moves it there. Tokens are matched as they appear in user agents, case
      included. Defaults to `[]`.

    * `:shape` - HTTP shape analysis, see `Limen.Signal.HttpShape`:
      * `:ignore_headers` - headers left out of the header-order shape, such
        as those added by your proxies. Forwarding headers and the JA4 header
        are always left out.

    * `:challenge` - the proof-of-work challenge, see `Limen.Challenge`:
      * `:path` - where Limen serves its challenge endpoints. Defaults to
        `"/__limen"`.
      * `:ttl` - seconds a challenge stays valid. Defaults to `300`.
      * `:pass_ttl` - seconds a pass cookie stays valid. Defaults to `3_600`.
      * `:bind` - what pass cookies and socket tokens are bound to: any of
        `:prefix`, `:ja4` and `:user_agent`. Defaults to all three. Leaving
        `:prefix` out keeps passes valid when a client changes networks,
        such as a phone moving from Wi-Fi to mobile data, at the cost of
        letting a pass be used from anywhere with the same JA4 and user
        agent. Changing it invalidates the passes already issued.
      * `:cookie` - the pass cookie name. Defaults to `"_limen_pass"`.
      * `:status` - HTTP status of the challenge page. Defaults to `403`.
      * `:page` - the module writing the challenge page, with texts in the
        visitor's language or markup of your own, see
        `Limen.Challenge.Page`. Defaults to `Limen.Challenge.Page`, in
        English.
      * `:no_js` - what clients without JavaScript get: `{:meta_refresh,
        seconds}` (default `{:meta_refresh, 5}`) lets them through after
        waiting, `:deny` shows a message asking to enable JavaScript.
      * `:secure_cookie` - `true`, `false` or `:auto` (default, secure over
        HTTPS).
      * `:replay_capacity` - solved challenges remembered per `:ttl` to
        reject replays. Defaults to `100_000`.

    * `:cluster` - ban propagation across nodes, see `Limen.Cluster`:
      * `:enabled` - `false` (default) or `true`. Read at startup.
      * `:scope` - the [`:pg`][pg] scope the instance starts and uses, which must
        be unique among the instances of a node. Defaults to one named after
        the instance, so instances of the same name on different nodes share
        their bans.
      * `:interval` - milliseconds between broadcasts. Defaults to `100`.
      * `:max_outbox` - bans waiting to be broadcast. Defaults to `10_000`.

    * `:trap` - honeypots, see `Limen.Trap`:
      * `:paths` - trap path prefixes, such as `["/archive/directory"]`. A
        request under one of them is a confession: its prefix is flagged and
        sent to the maze. Defaults to `[]` (no link traps).
      * `:ban` - seconds a prefix that fell into a trap stays flagged.
        Defaults to `86_400`.
      * `:form_field` - name of the decoy field of `Limen.Trap.form_fields/2`.
        Defaults to `"website"`.
      * `:min_fill_time` - milliseconds a person needs at least to fill in a
        form; faster submissions are confessions. Defaults to `3_000`.

    * `:maze` - the slow, endless pages trapped clients get, see `Limen.Maze`:
      * `:corpus` - text files the maze's language model also learns from,
        so its pages read like your site. Defaults to `[]`.
      * `:bundled_corpus` - whether to learn from Limen's own neutral text
        too. Defaults to `true`; at least one corpus is needed.
      * `:drift` - `nil` (default), `:daily` or `:weekly`: how often every
        page changes. Without drift a page never changes.
      * `:max_concurrent` - requests held in the maze at once; beyond that,
        they get an immediate `429`. Defaults to `200`.
      * `:admit` - `{module, function, args}`, called with `args` before a
        client is held; unless it returns `true`, the client gets an
        immediate `429`, as when the maze is full. For refusing the maze
        while the application is under load; it runs on the request path,
        so it must be cheap and must not call a process. Defaults to `nil`:
        every client is admitted up to `:max_concurrent`.
      * `:max_duration` - milliseconds a maze response may take. Defaults to
        `60_000`.
      * `:delay` - `{min, max}` milliseconds between chunks. Defaults to
        `{1_000, 5_000}`.
      * `:chunk` - `{min, max}` bytes per chunk. Defaults to `{64, 512}`.
      * `:paragraphs` - `{min, max}` paragraphs per page. Defaults to
        `{4, 10}`.
      * `:links` - `{min, max}` links in a page's navigation and related
        lists. Defaults to `{4, 10}`.

    * `:tarpit` - limits on tarpitted requests, see `Limen.Tarpit`:
      * `:max_concurrent` - requests held at once. Defaults to `1_000`.
      * `:max_delay` - longest delay in milliseconds. Defaults to `30_000`.

    * `:params` - values of policy parameters, overriding the defaults
      policies declare, as a keyword list; see "Parameters" in
      `Limen.Policy`. Defaults to `[]`.

    * `:lists` - named lists loaded at startup, see `Limen.Lists`: a list of
      values, `{:cidr, ranges}` or `{:substrings, strings}` per name.

    * `:state` - sizing of the shared state, see `Limen.State`:
      * `:max_keys` - exact keys per time-window epoch slot. Each window
        keeps up to three slots. Defaults to `50_000`.
      * `:sketch_width` and `:sketch_depth` - dimensions of the Count-Min
        Sketch counting keys beyond `:max_keys`, one per slot. Defaults to
        `8_192` and `4` (256 KiB per slot).
      * `:gcra_max_keys` - keys tracked by hard limits. Defaults to
        `100_000`.
      * `:max_bans` - concurrent bans. Defaults to `100_000`.
      * `:sweep_interval` - milliseconds between sweeps of expired bans and
        idle limits. Defaults to `5_000`.
      * `:path_filter_capacity` - (prefix, path) pairs remembered per minute
        to count distinct paths per client. Defaults to `1_000_000` (about
        1 MiB per generation).
      * `:hll_precision` - precision of the HyperLogLog counting distinct
        client prefixes. Defaults to `12` (4 KiB, 1.6% error).

      Sketch dimensions are read once at startup.

  ## Changing options at runtime

  `Limen.update_config/3` changes an option of a running instance. Options
  given as keyword lists are merged into their current values, as if they
  had been given together at startup, so changing one leaves the others as
  they are:

      Limen.update_config(:my_app, :trap, min_fill_time: 1_000)

  Some options are only read when the instance starts, and changing them at
  runtime raises: `:lists` (use `Limen.Lists` instead), `:secret_key` and
  `:previous_secret_keys`, and in their groups `:state` `:max_keys`,
  `:sketch_width`, `:sketch_depth`, `:path_filter_capacity` and
  `:hll_precision`; `:cluster` `:enabled` and `:scope`; `:decision_log`
  `:size`; `:challenge` `:replay_capacity`; `:maze` `:corpus` and
  `:bundled_corpus`; `:asn` `:file`, `:url` and `:refresh`. Restart the
  instance to change them.

  [CIDR]: https://www.rfc-editor.org/rfc/rfc4632
  [X-Forwarded-For]: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For
  [Forwarded]: https://www.rfc-editor.org/rfc/rfc7239
  [JA4]: https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md
  [iptoasn]: https://iptoasn.com/
  [pg]: https://www.erlang.org/doc/apps/kernel/pg.html
  """

  use Limen.Boundary, type: :strict, deps: [Limen.HMAC, Limen.IP]

  alias Limen.Config.Keys

  @decision_log_defaults %{
    sample_rate: 0.0,
    non_allow_sample_rate: 1.0,
    size: 1024,
    flush_interval: 1_000,
    sink: {Limen.DecisionLog.Logger, []},
    delivery: :batched
  }

  @state_defaults %{
    max_keys: 50_000,
    sketch_width: 8_192,
    sketch_depth: 4,
    gcra_max_keys: 100_000,
    max_bans: 100_000,
    sweep_interval: 5_000,
    path_filter_capacity: 1_000_000,
    hll_precision: 12
  }

  @asn_refresh_defaults %{
    every: 86_400_000,
    jitter: 0.1,
    window: nil,
    max_utilization: 0.9,
    max_memory: nil,
    retry: 600_000,
    timeout: 300_000
  }

  @asn_defaults %{
    file: nil,
    url: nil,
    hosting: [],
    source: Limen.Signal.Asn,
    refresh: @asn_refresh_defaults
  }

  @fcrdns_crawlers %{
    "googlebot" => ["googlebot.com", "google.com"],
    "bingbot" => ["search.msn.com"],
    "applebot" => ["applebot.apple.com"],
    "yandexbot" => ["yandex.ru", "yandex.net", "yandex.com"],
    "baiduspider" => ["baidu.com", "baidu.jp"],
    "slurp" => ["crawl.yahoo.net"],
    "amazonbot" => ["crawl.amazonbot.amazon"]
  }

  @fcrdns_defaults %{
    crawlers: @fcrdns_crawlers,
    dns: Limen.Signal.Fcrdns.InetRes,
    verified_ttl: 86_400,
    failed_ttl: 3_600,
    error_ttl: 60,
    max_pending: 1_000,
    max_cache: 100_000,
    interval: 50,
    concurrency: 16,
    timeout: 2_000
  }
  @shape_defaults %{ignore_headers: %{}}

  @tarpit_defaults %{max_concurrent: 1_000, max_delay: 30_000}

  @trap_defaults %{paths: [], ban: 86_400, form_field: "website", min_fill_time: 3_000}

  @maze_defaults %{
    corpus: [],
    bundled_corpus: true,
    drift: nil,
    max_concurrent: 200,
    admit: nil,
    max_duration: 60_000,
    delay: {1_000, 5_000},
    chunk: {64, 512},
    paragraphs: {4, 10},
    links: {4, 10}
  }
  @cluster_defaults %{enabled: false, scope: nil, interval: 100, max_outbox: 10_000}

  @challenge_defaults %{
    path: "/__limen",
    ttl: 300,
    pass_ttl: 3_600,
    bind: [:prefix, :ja4, :user_agent],
    cookie: "_limen_pass",
    status: 403,
    page: Limen.Challenge.Page,
    no_js: {:meta_refresh, 5},
    secure_cookie: :auto,
    replay_capacity: 100_000
  }

  @defaults %{
    mode: :dry_run,
    challenge: Map.put(@challenge_defaults, :segments, ["__limen"]),
    trusted_proxies: %{lengths: %{}, members: %{}},
    client_ip_header: nil,
    ja4_header: "x-ja4",
    asn: @asn_defaults,
    fcrdns: @fcrdns_defaults,
    shape: @shape_defaults,
    user_agents: %{markers: %{}, pattern: nil},
    tarpit: @tarpit_defaults,
    trap: Map.put(@trap_defaults, :routes, []),
    maze: @maze_defaults,
    lists: [],
    params: %{},
    cluster: @cluster_defaults,
    ipv4_prefix: 32,
    ipv6_prefix: 64,
    decision_log: @decision_log_defaults,
    state: @state_defaults
  }

  @type t :: %{atom() => term()}

  # Options only read when an instance starts: changing them at runtime would
  # do nothing, or leave the instance inconsistent.
  @startup_only %{
    lists: :all,
    state: [:max_keys, :sketch_width, :sketch_depth, :path_filter_capacity, :hll_precision],
    cluster: [:enabled, :scope],
    decision_log: [:size],
    challenge: [:replay_capacity],
    maze: [:corpus, :bundled_corpus],
    asn: [:file, :url, :refresh]
  }

  @doc """
  The instances configured for `app`, with their options.

  With no `:instances` option there is a single instance named after the
  application. Otherwise each entry of `:instances` is an instance, whose
  options are merged over the top-level ones.

      config :my_app, Limen,
        mode: :dry_run,
        instances: [public: [], admin: [mode: :enforce]]
  """
  @spec from_app(atom()) :: [{atom(), keyword()}]
  def from_app(app) when is_atom(app) do
    {instances, shared} = Keyword.pop(Application.get_env(app, Limen, []), :instances)

    case instances do
      nil -> [{app, shared}]
      instances -> for {name, opts} <- instances, do: {name, Keyword.merge(shared, opts)}
    end
  end

  @doc """
  Builds a validated configuration from options.

  Raises `ArgumentError` on an unknown or invalid option.
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    {secrets, opts} = Keyword.split(opts, [:secret_key, :previous_secret_keys])
    secret = Keyword.get(secrets, :secret_key)
    keys = keys!(secret, Keyword.get(secrets, :previous_secret_keys, []))

    base = Map.merge(@defaults, %{keys: keys, options: %{}})

    opts
    |> Enum.reduce(base, fn {key, value}, acc -> put(acc, key, value) end)
    |> check_traps!()
  end

  # Checked once every option is known, whatever their order.
  defp check_traps!(config) do
    case outside_challenge(config.trap.paths, config) do
      :ok -> config
      {:error, message} -> raise ArgumentError, "invalid Limen trap option: #{message}"
    end
  end

  @doc """
  Validates and changes one option of a built configuration.

  A keyword list is merged into the option's current value, recursively,
  so `update(config, :trap, min_fill_time: 0)` keeps the trap paths. Any
  other value replaces the current one. Raises `ArgumentError` on an invalid
  value, and on a change to an option only read at startup (see "Changing
  options at runtime" above).
  """
  @spec update(t(), atom(), term()) :: t()
  def update(config, key, value) do
    value = merge(Map.get(config.options, key), value)

    config
    |> put(key, value)
    |> check_traps!()
    |> check_startup_only!(config, key)
  end

  defp merge(current, given) do
    if keyword?(current) and keyword?(given),
      do: Keyword.merge(current, given, fn _key, current, given -> merge(current, given) end),
      else: given
  end

  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)

  defp check_startup_only!(updated, config, key) do
    changed =
      case Map.fetch(@startup_only, key) do
        {:ok, :all} -> updated[key] != config[key]
        {:ok, keys} -> Enum.find(keys, &(updated[key][&1] != config[key][&1]))
        :error -> nil
      end

    cond do
      changed in [nil, false] ->
        updated

      key == :lists ->
        raise ArgumentError, "lists are loaded at startup, change them with Limen.Lists instead"

      changed == true ->
        raise ArgumentError, "the #{inspect(key)} option is read at startup, restart the instance"

      true ->
        raise ArgumentError,
              "the #{inspect(key)} option #{inspect(changed)} is read at startup, " <>
                "restart the instance"
    end
  end

  @doc false
  @spec put(t(), atom(), term()) :: t()
  def put(_config, key, _value) when key in [:secret_key, :previous_secret_keys, :keys] do
    raise ArgumentError, "secret keys cannot be changed at runtime, restart the instance instead"
  end

  def put(config, key, value) do
    case validate(key, value, config) do
      {:ok, validated} ->
        config
        |> Map.put(key, validated)
        |> Map.update(:options, %{key => value}, &Map.put(&1, key, value))

      {:error, message} ->
        raise ArgumentError, "invalid Limen #{key} option: #{message}"
    end
  end

  @doc false
  @spec defaults() :: t()
  def defaults, do: @defaults

  defp keys!(secret, previous) do
    for key <- [secret | previous], key != nil, not (is_binary(key) and byte_size(key) >= 32) do
      raise ArgumentError, "invalid secret key: expected a binary of at least 32 bytes"
    end

    Keys.derive(secret, previous)
  end

  defp validate(:mode, mode, _config) when mode in [:dry_run, :enforce], do: {:ok, mode}
  defp validate(:mode, _mode, _config), do: {:error, "expected :dry_run or :enforce"}

  defp validate(:trusted_proxies, ranges, _config) when is_list(ranges) do
    {:ok, Limen.IP.cidr_set(ranges)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp validate(:client_ip_header, header, _config)
       when header in [nil, "x-forwarded-for", "x-real-ip", "forwarded"],
       do: {:ok, header}

  defp validate(:client_ip_header, _header, _config),
    do: {:error, ~s(expected nil, "x-forwarded-for", "x-real-ip" or "forwarded")}

  defp validate(:ja4_header, header, _config) when is_binary(header),
    do: {:ok, String.downcase(header)}

  defp validate(:asn, opts, _config) when is_list(opts) do
    {refresh, opts} = Keyword.pop(opts, :refresh, [])

    with {:ok, asn} <- merge_known(@asn_defaults, opts, &valid_asn?/2),
         {:ok, refresh} <- asn_refresh(refresh) do
      cond do
        asn.url && is_nil(asn.file) ->
          {:error, "an :asn :url needs a :file to keep the data in"}

        asn.source != Limen.Signal.Asn and (asn.file || asn.url) ->
          {:error, ":file and :url are the default source's, not #{inspect(asn.source)}'s"}

        true ->
          {:ok, %{asn | refresh: refresh}}
      end
    end
  end

  defp validate(:fcrdns, opts, _config) when is_list(opts) do
    with {:ok, fcrdns} <- merge_known(@fcrdns_defaults, opts, &valid_fcrdns?/2) do
      crawlers = Map.merge(@fcrdns_crawlers, Map.new(fcrdns.crawlers, fn {k, v} -> {k, v} end))
      {:ok, %{fcrdns | crawlers: crawlers}}
    end
  end

  defp validate(:shape, opts, _config) when is_list(opts) do
    valid? = fn :ignore_headers, headers ->
      is_list(headers) and Enum.all?(headers, &is_binary/1)
    end

    with {:ok, shape} <- merge_known(%{ignore_headers: []}, opts, valid?) do
      {:ok,
       %{shape | ignore_headers: Map.new(shape.ignore_headers, &{String.downcase(&1), true})}}
    end
  end

  defp validate(:user_agents, opts, _config) when is_list(opts) do
    markers =
      Enum.reduce_while(opts, %{}, fn {kind, tokens}, acc ->
        case user_agent_tokens(kind, tokens) do
          {:ok, tokens} -> {:cont, Map.merge(acc, tokens)}
          :error -> {:halt, {:error, "invalid #{inspect(kind)} tokens: #{inspect(tokens)}"}}
        end
      end)

    with %{} <- markers do
      searched = for {token, {:marker, _family, _name}} <- markers, do: token
      pattern = if searched != [], do: :binary.compile_pattern(searched)
      {:ok, %{markers: markers, pattern: pattern}}
    end
  end

  defp validate(:params, params, _config) when is_list(params) do
    if Keyword.keyword?(params),
      do: {:ok, Map.new(params)},
      else: {:error, "expected a keyword list of parameter names and values"}
  end

  defp validate(:lists, lists, _config) when is_list(lists) do
    Enum.each(lists, &validate_list!/1)

    {:ok, lists}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp validate(:challenge, opts, _config) when is_list(opts) do
    with {:ok, challenge} <- merge_known(@challenge_defaults, opts, &valid_challenge?/2) do
      # In a fixed order, so the default is recognised however it was given.
      bind = Enum.filter([:prefix, :ja4, :user_agent], &(&1 in challenge.bind))

      {:ok,
       %{challenge | bind: bind}
       |> Map.put(:segments, String.split(challenge.path, "/", trim: true))}
    end
  end

  defp validate(:cluster, opts, _config) when is_list(opts) do
    merge_known(@cluster_defaults, opts, fn
      :enabled, enabled -> is_boolean(enabled)
      :scope, scope -> is_atom(scope)
      _limit, value -> is_integer(value) and value > 0
    end)
  end

  defp validate(:trap, opts, config) when is_list(opts) do
    with {:ok, trap} <- merge_known(@trap_defaults, opts, &valid_trap?/2),
         :ok <- outside_challenge(trap.paths, config) do
      {:ok,
       Map.put(trap, :routes, Enum.map(trap.paths, &{String.split(&1, "/", trim: true), &1}))}
    end
  end

  defp validate(:maze, opts, _config) when is_list(opts) do
    with {:ok, maze} <- merge_known(@maze_defaults, opts, &valid_maze?/2) do
      cond do
        maze.corpus == [] and not maze.bundled_corpus ->
          {:error, "the maze needs a :corpus when :bundled_corpus is false"}

        missing = Enum.find(maze.corpus, &(not File.regular?(&1))) ->
          {:error, "corpus file #{inspect(missing)} does not exist"}

        true ->
          {:ok, maze}
      end
    end
  end

  defp validate(:tarpit, opts, _config) when is_list(opts) do
    merge_known(@tarpit_defaults, opts, fn _key, value -> is_integer(value) and value >= 0 end)
  end

  defp validate(:ipv4_prefix, length, _config) when length in 8..32, do: {:ok, length}

  defp validate(:ipv4_prefix, _length, _config),
    do: {:error, "expected an integer between 8 and 32"}

  defp validate(:ipv6_prefix, length, _config) when length in [48, 56, 64], do: {:ok, length}
  defp validate(:ipv6_prefix, _length, _config), do: {:error, "expected 48, 56 or 64"}

  defp validate(:decision_log, opts, _config) when is_list(opts) do
    with {:ok, log} <- merge_known(@decision_log_defaults, opts, &valid_decision_log?/2) do
      {:ok, Map.update!(log, :sink, &sink/1)}
    end
  end

  defp validate(:state, opts, _config) when is_list(opts) do
    merge_known(@state_defaults, opts, fn _key, value -> is_integer(value) and value > 0 end)
  end

  defp validate(key, value, _config) when is_map_key(@defaults, key),
    do: {:error, "invalid value #{inspect(value)}"}

  defp validate(key, _value, _config), do: {:error, "unknown option #{inspect(key)}"}

  defp valid_decision_log?(rate, value) when rate in [:sample_rate, :non_allow_sample_rate],
    do: is_number(value) and value >= 0 and value <= 1

  defp valid_decision_log?(:delivery, delivery), do: delivery in [:batched, :inline]
  defp valid_decision_log?(:sink, {module, opts}), do: sink?(module) and Keyword.keyword?(opts)
  defp valid_decision_log?(:sink, module), do: sink?(module)
  defp valid_decision_log?(_size_or_interval, value), do: is_integer(value) and value > 0

  defp sink({_module, _opts} = sink), do: sink
  defp sink(module), do: {module, []}

  defp sink?(module),
    do: is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :write, 2)

  defp validate_list!({name, {:cidr, ranges}}) when is_atom(name) and is_list(ranges),
    do: Limen.IP.cidr_set(ranges)

  defp validate_list!({name, {:substrings, substrings}} = list)
       when is_atom(name) and is_list(substrings) do
    unless Enum.all?(substrings, &token?/1),
      do: raise(ArgumentError, "invalid list #{inspect(list)}")
  end

  defp validate_list!({name, values}) when is_atom(name) and is_list(values), do: :ok
  defp validate_list!(other), do: raise(ArgumentError, "invalid list #{inspect(other)}")

  defp user_agent_tokens(:ignore, tokens) when is_list(tokens) do
    if Enum.all?(tokens, &token?/1), do: {:ok, Map.new(tokens, &{&1, :ignore})}, else: :error
  end

  defp user_agent_tokens(family, tokens)
       when family in [:crawler, :ai_crawler, :link_preview, :headless, :tool] and
              is_list(tokens) do
    named = Enum.map(tokens, &named_token/1)

    if Enum.all?(named, fn {token, name} -> token?(token) and is_binary(name) end),
      do: {:ok, Map.new(named, fn {token, name} -> {token, {:marker, family, name}} end)},
      else: :error
  end

  defp user_agent_tokens(_family, _tokens), do: :error

  # A token alone is named after itself: `"NewBot/"` is `"newbot"`.
  defp named_token({token, name}), do: {token, name}

  defp named_token(token) when is_binary(token) do
    name = String.trim_trailing(String.trim(token), "/")
    {token, String.downcase(name)}
  end

  defp named_token(other), do: {other, nil}

  defp token?(token), do: is_binary(token) and token != ""

  defp valid_fcrdns?(:crawlers, crawlers) do
    is_map(crawlers) and
      Enum.all?(crawlers, fn {name, suffixes} ->
        is_binary(name) and is_list(suffixes) and Enum.all?(suffixes, &is_binary/1)
      end)
  end

  defp valid_fcrdns?(:dns, module), do: is_atom(module)
  defp valid_fcrdns?(_key, value), do: is_integer(value) and value > 0

  defp valid_trap?(:paths, paths), do: is_list(paths) and Enum.all?(paths, &valid_path?/1)

  defp valid_trap?(:form_field, name), do: is_binary(name) and name =~ ~r/^[A-Za-z0-9_-]+$/
  defp valid_trap?(:ban, ttl), do: is_integer(ttl) and ttl > 0
  defp valid_trap?(:min_fill_time, ms), do: is_integer(ms) and ms >= 0

  defp asn_refresh(opts) when is_list(opts) do
    with {:ok, refresh} <- merge_known(@asn_refresh_defaults, opts, &valid_refresh?/2) do
      {:ok, Map.update!(refresh, :window, &windows/1)}
    end
  end

  defp asn_refresh(_opts), do: {:error, "expected :refresh options as a keyword list"}

  defp valid_asn?(:file, file), do: is_nil(file) or is_binary(file)
  defp valid_asn?(:url, url), do: is_nil(url) or (is_binary(url) and url =~ ~r{^https?://.})

  defp valid_asn?(:hosting, asns),
    do: is_list(asns) and Enum.all?(asns, &(is_integer(&1) and &1 > 0))

  defp valid_asn?(:source, source),
    do: is_atom(source) and Code.ensure_loaded?(source) and function_exported?(source, :lookup, 2)

  defp valid_asn?(:refresh, _refresh), do: false

  defp valid_refresh?(:every, every), do: is_integer(every) and every >= 60_000
  defp valid_refresh?(:jitter, jitter), do: is_number(jitter) and jitter >= 0 and jitter <= 1
  defp valid_refresh?(:window, nil), do: true
  defp valid_refresh?(:window, {_from, _to} = window), do: valid_window?(window)

  defp valid_refresh?(:window, [_first | _rest] = windows),
    do: Enum.all?(windows, &valid_window?/1)

  defp valid_refresh?(:max_utilization, max),
    do: is_nil(max) or (is_number(max) and max > 0 and max <= 1)

  defp valid_refresh?(:max_memory, max), do: is_nil(max) or (is_integer(max) and max > 0)
  defp valid_refresh?(key, ms) when key in [:retry, :timeout], do: is_integer(ms) and ms >= 1_000
  defp valid_refresh?(_key, _value), do: false

  defp valid_window?({%Time{} = from, %Time{} = to}), do: Time.compare(from, to) != :eq
  defp valid_window?(_window), do: false

  defp windows({_from, _to} = window), do: [window]
  defp windows(windows), do: windows

  defp valid_maze?(:corpus, files), do: is_list(files) and Enum.all?(files, &is_binary/1)
  defp valid_maze?(:bundled_corpus, bundled), do: is_boolean(bundled)
  defp valid_maze?(:drift, drift), do: drift in [nil, :daily, :weekly]
  defp valid_maze?(:admit, nil), do: true

  defp valid_maze?(:admit, {module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid_maze?(key, value) when key in [:max_concurrent, :max_duration],
    do: is_integer(value) and value > 0

  defp valid_maze?(_range, {min, max}),
    do: is_integer(min) and is_integer(max) and min >= 0 and min <= max

  defp valid_maze?(_key, _value), do: false

  defp valid_path?("/" <> rest = path), do: rest != "" and not String.ends_with?(path, "/")
  defp valid_path?(_path), do: false

  # Limen serves its own endpoints under the challenge path before anything
  # else, so a trap there would never be reached.
  defp outside_challenge(paths, %{challenge: %{path: challenge}}) do
    case Enum.find(paths, &(&1 == challenge or String.starts_with?(&1, challenge <> "/"))) do
      nil -> :ok
      path -> {:error, "trap path #{inspect(path)} is under the challenge path"}
    end
  end

  defp valid_challenge?(:path, "/" <> _rest = path), do: not String.ends_with?(path, "/")
  defp valid_challenge?(:cookie, name), do: is_binary(name) and name =~ ~r/^[A-Za-z0-9_-]+$/
  defp valid_challenge?(:status, status), do: status in 200..599
  defp valid_challenge?(:no_js, :deny), do: true
  defp valid_challenge?(:no_js, {:meta_refresh, s}), do: is_integer(s) and s >= 0
  defp valid_challenge?(:secure_cookie, secure), do: secure in [true, false, :auto]

  defp valid_challenge?(:page, page) do
    is_atom(page) and Code.ensure_loaded?(page) and function_exported?(page, :text, 2) and
      function_exported?(page, :render, 1)
  end

  defp valid_challenge?(:bind, bind),
    do: is_list(bind) and bind -- [:prefix, :ja4, :user_agent] == [] and bind == Enum.uniq(bind)

  defp valid_challenge?(key, value) when key in [:ttl, :pass_ttl, :replay_capacity],
    do: is_integer(value) and value > 0

  defp valid_challenge?(_key, _value), do: false

  @doc false
  @spec merge_known(map(), keyword(), (atom(), term() -> boolean())) ::
          {:ok, map()} | {:error, String.t()}
  def merge_known(defaults, opts, valid?) do
    Enum.reduce_while(opts, {:ok, defaults}, fn {key, value}, {:ok, acc} ->
      cond do
        not Map.has_key?(defaults, key) ->
          {:halt, {:error, "unknown option #{inspect(key)}"}}

        valid?.(key, value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        true ->
          {:halt, {:error, "invalid value for #{inspect(key)}: #{inspect(value)}"}}
      end
    end)
  end
end
