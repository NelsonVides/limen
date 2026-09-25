defmodule Limen.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/NelsonVides/limen"

  def project do
    [
      app: :limen,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:boundary | Mix.compilers()],
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
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [preferred_envs: [bench: :bench]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:boundary, "~> 0.11", runtime: false},
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:bandit, "~> 1.6", only: :test},
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
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [
        Gate: [Limen, Limen.Plug, Limen.Context, Limen.Decision, Limen.Decision.Match],
        Configuration: [Limen.Config],
        Observability: [Limen.Telemetry, Limen.DecisionLog, Limen.Stats],
        Utilities: [Limen.IP]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end
end
