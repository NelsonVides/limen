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
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:bandit, "~> 1.6", only: :test},
      {:benchee, "~> 1.3", only: [:dev, :bench]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
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
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      flags: [:unmatched_returns, :error_handling, :extra_return, :missing_return]
    ]
  end
end
