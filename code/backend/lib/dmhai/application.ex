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
      # Agent infrastructure — must start before the HTTP server
      {Registry, keys: :unique, name: Dmhai.Agent.Registry},
      Dmhai.Agent.Supervisor,
      {Task.Supervisor, name: Dmhai.Agent.TaskSupervisor},
      {Task.Supervisor, name: Dmhai.Agent.WorkerSupervisor},
      {Bandit, plug: Dmhai.Router, scheme: :http, ip: {0, 0, 0, 0}, port: 8080},
      {Bandit,
       plug: Dmhai.Router,
       scheme: :https,
       ip: {0, 0, 0, 0},
       port: 8443,
       certfile: "/app/ssl/cert.pem",
       keyfile: "/app/ssl/key.pem"}
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
