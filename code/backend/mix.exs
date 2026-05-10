defmodule DmhAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :dmh_ai,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_load_filters: [~r/itgr_.*\.exs$/, ~r/F\d{2}_.*\.exs$/, ~r/R\d{2}_.*\.exs$/],
      test_ignore_filters: [~r/sandbox_case\.exs$/, ~r/flow_helper\.exs$/]
    ]
  end

  def cli do
    [preferred_envs: [flow: :test, "test.sandbox": :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {DmhAi.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto, "~> 3.12"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.9"},
      {:floki, "~> 0.36"},
      {:jason, "~> 1.4"},
      {:hammer, "~> 6.1"},
      {:sqlite_vec, "~> 0.1"}
    ]
  end
end
