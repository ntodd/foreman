defmodule ForemanAgent.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :foreman_agent,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {ForemanAgent.Application, []},
      extra_applications: [:logger, :crypto, :public_key, :ssl, :inets]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:foreman_protocol, path: "../foreman_protocol"},
      {:slipstream, "~> 1.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:muontrap, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.3", only: :test},
      {:plug, "~> 1.18", only: :test},
      {:bandit, "~> 1.12", only: :test}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp releases do
    [
      foreman_agent: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, &copy_feature/1, :tar]
      ]
    ]
  end

  # The devcontainer feature ships inside the agent release, so a box always
  # runs the feature version its agent was built and tested with.
  defp copy_feature(release) do
    target = Path.join([release.path, "lib", "foreman_agent-#{@version}", "priv", "feature"])
    File.rm_rf!(target)
    File.cp_r!(Path.expand("../../features/src/foreman", __DIR__), target)
    release
  end
end
