# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Supervision tree is :rest_for_one — children listed AFTER a
    # given child are restarted along with it. This is what guarantees
    # that:
    #
    #   1. DmhAi.Repo starts first.
    #   2. DmhAi.DB.SchemaInit runs synchronously in its `init/1`,
    #      creating tables (and running Permissions.Migration) before
    #      ANY downstream child can query the DB.
    #   3. TaskRuntime and other DB-touching children come up against
    #      a guaranteed-populated schema.
    #
    # On a fresh install, without the explicit phasing above, TaskRuntime's
    # 500-ms-after-boot `:rehydrate` query hits an empty DB, crashes,
    # exceeds max_restarts, takes Repo down with it, and the entire
    # supervision tree collapses. See `DmhAi.DB.SchemaInit` moduledoc.
    children = [
      DmhAi.Repo,
      DmhAi.DB.SchemaInit,
      DmhAi.SysLog,
      DmhAi.DomainBlocker,
      {Finch,
       name: DmhAi.Finch,
       pools: %{
         :default => [
           size: 10,
           conn_max_idle_time: 30_000
         ]
       }},
      # Agent infrastructure — must start before the HTTP server
      {Registry, keys: :unique, name: DmhAi.Agent.Registry},
      DmhAi.Agent.Supervisor,
      {Task.Supervisor, name: DmhAi.Agent.TaskSupervisor},
      DmhAi.Agent.TaskRuntime,
      # Background re-fetch of stale KB sources triggered by every
      # fetch_index call. See specs/vector_kb.md §Auto-relearn.
      DmhAi.VectorDB.Relearn
    ] ++
      (if Application.get_env(:dmh_ai, :start_http, true) do
        [{Bandit, plug: DmhAi.Router, scheme: :http, ip: bind_ip(), port: 8080}]
      else
        []
      end) ++
      if Application.get_env(:dmh_ai, :start_https, true) and File.exists?("/app/ssl/cert.pem") do
        [{Bandit,
          plug: DmhAi.Router,
          scheme: :https,
          ip: bind_ip(),
          port: 8443,
          certfile: "/app/ssl/cert.pem",
          keyfile: "/app/ssl/key.pem"}]
      else
        []
      end

    opts = [strategy: :rest_for_one, name: DmhAi.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if Application.get_env(:dmh_ai, :run_startup_check, true), do: DmhAi.StartupCheck.run()
        DmhAi.DomainBlocker.load_from_db()
        DmhAi.Agent.PendingPivots.init()
        DmhAi.Agent.ChainInFlight.init()
        DmhAi.Agent.BackgroundPipelines.init()
        DmhAi.Agent.RunningTools.init()
        DmhAi.GeoIP.init()
        attach_finch_telemetry()
        Logger.info("Sessions API on :3000")
        {:ok, pid}

      error ->
        error
    end
  end

  # Resolve the configured `bind_host` (set in runtime.exs from
  # `DMHAI_BIND_HOST`, default `127.0.0.1`) into the `:inet` IP-tuple
  # Bandit expects. Fail-safe: any malformed override falls back to
  # loopback rather than accidentally binding `0.0.0.0` on a typo.
  # See architecture.md §Network exposure.
  defp bind_ip do
    host = Application.get_env(:dmh_ai, :bind_host, "127.0.0.1")

    case host |> to_charlist() |> :inet.parse_address() do
      {:ok, ip} ->
        ip

      {:error, _} ->
        require Logger
        Logger.warning(
          "[Application] DMHAI_BIND_HOST=#{inspect(host)} is not a valid IP literal — falling back to 127.0.0.1"
        )

        {127, 0, 0, 1}
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
      "dmh_ai-finch-debug",
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
