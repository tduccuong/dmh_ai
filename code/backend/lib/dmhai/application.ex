# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Dmhai.Repo,
      Dmhai.SysLog,
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
      Dmhai.Agent.TaskRuntime
    ] ++
      (if Application.get_env(:dmhai, :start_http, true) do
        [{Bandit, plug: Dmhai.Router, scheme: :http, ip: {0, 0, 0, 0}, port: 8080}]
      else
        []
      end) ++
      if Application.get_env(:dmhai, :start_https, true) and File.exists?("/app/ssl/cert.pem") do
        [{Bandit,
          plug: Dmhai.Router,
          scheme: :https,
          ip: {0, 0, 0, 0},
          port: 8443,
          certfile: "/app/ssl/cert.pem",
          keyfile: "/app/ssl/key.pem"}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Dmhai.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if Application.get_env(:dmhai, :run_startup_check, true), do: Dmhai.StartupCheck.run()
        Dmhai.DB.Init.run()
        Dmhai.DomainBlocker.load_from_db()
        Logger.info("Sessions API on :3000")
        {:ok, pid}

      error ->
        error
    end
  end
end
