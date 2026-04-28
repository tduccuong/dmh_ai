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
        Dmhai.Agent.PendingPivots.init()
        Dmhai.Agent.ChainInFlight.init()
        Dmhai.Agent.RunningTools.init()
        attach_finch_telemetry()
        Logger.info("Sessions API on :3000")
        {:ok, pid}

      error ->
        error
    end
  end

  # Diagnostic telemetry for outbound HTTP debugging — surfaces Finch's
  # connection lifecycle + queuing so we can tell whether a slow LLM call
  # is (a) queued waiting for a pool slot, (b) connecting, (c) sending,
  # (d) reading response. Prefixed `[LLM:finch]` for easy log filtering
  # alongside the `[LLM:http req=N]` boundaries added to do_call_request /
  # do_stream_request. Filter only the :ollama.com host so we don't drown
  # in SearXNG / Jina / Telegram chatter.
  defp attach_finch_telemetry do
    events = [
      [:finch, :queue, :start],
      [:finch, :queue, :stop],
      [:finch, :queue, :exception],
      [:finch, :connect, :start],
      [:finch, :connect, :stop],
      [:finch, :send, :start],
      [:finch, :send, :stop],
      [:finch, :recv, :start],
      [:finch, :recv, :stop],
      [:finch, :request, :start],
      [:finch, :request, :stop],
      [:finch, :request, :exception],
      [:finch, :reused_connection],
      [:finch, :conn_max_idle_time_exceeded],
      [:finch, :pool_max_idle_time_exceeded]
    ]

    :telemetry.attach_many(
      "dmhai-finch-debug",
      events,
      &__MODULE__.handle_finch_event/4,
      nil
    )
  end

  @doc false
  def handle_finch_event(event, measurements, metadata, _config) do
    host = metadata[:host] || (metadata[:request] && metadata[:request].host) || ""

    if String.contains?(to_string(host), "ollama") do
      dur_ms = case measurements[:duration] do
        n when is_integer(n) -> System.convert_time_unit(n, :native, :millisecond)
        _ -> nil
      end

      suffix =
        case event do
          [:finch, phase, :stop] -> "#{phase} STOP dur_ms=#{dur_ms}"
          [:finch, phase, :start] -> "#{phase} START"
          [:finch, phase, :exception] -> "#{phase} EXCEPTION kind=#{inspect(metadata[:kind])} reason=#{inspect(metadata[:reason])}"
          [:finch, :reused_connection] -> "reused_connection"
          [:finch, :conn_max_idle_time_exceeded] -> "conn_max_idle_time_exceeded"
          [:finch, :pool_max_idle_time_exceeded] -> "pool_max_idle_time_exceeded"
          other -> inspect(other)
        end

      Logger.info("[LLM:finch] host=#{host} #{suffix}")
    end
  rescue
    _ -> :ok  # never let a telemetry handler crash the emitter
  end
end
