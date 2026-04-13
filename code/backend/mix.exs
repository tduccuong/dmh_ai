defmodule Dmhai.MixProject do
  use Mix.Project

  def project do
    [
      app: :dmhai,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Dmhai.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto, "~> 3.12"},
      {:req, "~> 0.5"},
      {:floki, "~> 0.36"},
      {:jason, "~> 1.4"}
    ]
  end
end
