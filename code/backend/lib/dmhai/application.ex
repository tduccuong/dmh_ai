defmodule Dmhai.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Dmhai.Repo,
      Dmhai.DomainBlocker,
      {Finch,
       name: Dmhai.Finch,
       pools: %{
         :default => [
           size: 10,
           conn_max_idle_time: 30_000
         ]
       }},
      {Bandit, plug: Dmhai.Router, scheme: :http, ip: {127, 0, 0, 1}, port: 3000}
    ]

    opts = [strategy: :one_for_one, name: Dmhai.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Dmhai.DB.Init.run()
        Dmhai.DomainBlocker.load_from_db()
        Logger.info("Sessions API on :3000")
        {:ok, pid}

      error ->
        error
    end
  end
end
