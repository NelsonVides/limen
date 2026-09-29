defmodule Limen.MixProject do
  use Mix.Project

  @source_url "https://github.com/NelsonVides/limen"

  def project do
    [
      app: :limen,
      version: version(),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: compilers(Mix.env()),
      boundary: [default: [check: [apps: [:plug, {:mix, :runtime}]]]],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Native Elixir L7 bot protection: scoring, rate limiting and proof-of-work challenges",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :eex, :inets, :ssl]
    ]
  end

  def cli do
    [preferred_envs: [bench: :bench]]
  end

  # The boundary compiler checks Limen's layers in its own builds (see
  # Limen.Boundary). Dependencies compile in :prod, so applications using
  # Limen need neither the compiler nor the `boundary` package.
  defp compilers(:prod), do: Mix.compilers()
  defp compilers(_env), do: [:boundary | Mix.compilers()]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:boundary, "~> 0.11", only: [:dev, :test, :bench], runtime: false},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:bandit, "~> 1.6", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:benchee, "~> 1.3", only: [:dev, :bench]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # `mix precommit` runs everything CI checks. Like Phoenix's alias of the same
  # name, it fixes what can be fixed (formatting, unused lock entries) and
  # fails on anything else. Tests need the test environment, so they run in a
  # separate `mix` invocation.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "dialyzer",
        "docs --warnings-as-errors",
        "cmd env MIX_ENV=test mix test --warnings-as-errors"
      ],
      bench: "run bench/run.exs"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/static priv/maze mix.exs VERSION README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{version()}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/concepts.md",
        "guides/dry-run-rollout.md",
        "guides/honeypots-and-maze.md",
        "guides/nginx-ja4.md",
        "guides/tuning.md",
        "guides/testing.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [Guides: ~r"guides/"],
      groups_for_modules: [
        Gate: [
          Limen,
          Limen.Plug,
          Limen.Socket,
          Limen.LiveView,
          Limen.Context,
          Limen.Decision,
          Limen.Decision.Match
        ],
        Cluster: [Limen.Cluster],
        Honeypots: [
          Limen.Trap,
          Limen.Maze,
          Limen.Maze.Model,
          Limen.Maze.Dice,
          Limen.Maze.Bundled
        ],
        Instances: [Limen.Instance, Limen.Supervisor, Limen.Owner],
        Configuration: [Limen.Config, Limen.Config.Keys, Limen.Lists],
        Challenge: [
          Limen.Challenge,
          Limen.Challenge.Token,
          Limen.Challenge.Pass,
          Limen.Challenge.Replay,
          Limen.Challenge.Replay.Rotator,
          Limen.Challenge.Page,
          Limen.Challenge.Assets
        ],
        Policies: [
          Limen.Policy,
          Limen.Policy.Default,
          Limen.Policy.Runtime,
          Limen.Tarpit
        ],
        State: [
          Limen.State,
          Limen.State.Window,
          Limen.State.Gcra,
          Limen.State.BanList,
          Limen.State.Rotator,
          Limen.State.Sweeper
        ],
        Sketches: [
          Limen.Sketch,
          Limen.Sketch.CountMin,
          Limen.Sketch.Bloom,
          Limen.Sketch.RotatingBloom,
          Limen.Sketch.HyperLogLog
        ],
        Signals: [
          Limen.Signal,
          Limen.Signal.ClientIP,
          Limen.Signal.JA4,
          Limen.Signal.HttpShape,
          Limen.Signal.UserAgent,
          Limen.Signal.Behaviour,
          Limen.Signal.Asn,
          Limen.Signal.Asn.Source,
          Limen.Signal.Asn.Loader,
          Limen.Signal.Asn.Table,
          Limen.Signal.Asn.Schedule,
          Limen.Signal.Asn.Download,
          Limen.Signal.Fcrdns,
          Limen.Signal.Fcrdns.DNS,
          Limen.Signal.Fcrdns.InetRes,
          Limen.Signal.Fcrdns.Resolver
        ],
        Observability: [
          Limen.Dashboard,
          Limen.Dashboard.Data,
          Limen.Telemetry,
          Limen.DecisionLog,
          Limen.DecisionLog.Sink,
          Limen.DecisionLog.Logger,
          Limen.DecisionLog.Flusher,
          Limen.Stats
        ],
        Utilities: [Limen.IP, Limen.Test]
      ]
    ]
  end

  # The version comes from the latest `v*` tag. A Hex package has no git
  # history, and inside a dependent project `git describe` would answer for the
  # host's repository, so the release workflow writes the tag to VERSION and
  # ships it in the package.
  defp version do
    case File.read(Path.join(__DIR__, "VERSION")) do
      {:ok, version} -> String.trim(version)
      {:error, _reason} -> git_version()
    end
  end

  defp git_version do
    with true <- File.exists?(Path.join(__DIR__, ".git")),
         {described, 0} <-
           System.cmd("git", ~w[describe --tags --match v*],
             cd: __DIR__,
             env: %{"HEX_API_KEY" => nil},
             stderr_to_stdout: true
           ),
         "v" <> version <- String.trim(described),
         {:ok, _parsed} <- Version.parse(version) do
      version
    else
      _no_tag -> "0.0.0-dev"
    end
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_local_path: "_build/dialyzer",
      plt_core_path: "_build/dialyzer",
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end
end
