# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.StartupCheck do
  @moduledoc """
  Runs environment checks at startup. FATAL failures halt the application;
  WARN failures are logged but do not prevent startup.
  """
  require Logger

  # Bind-mounted host volumes that must exist + be writable for the
  # release to function.
  @data_dirs ["/data/user_assets", "/data/user_workspaces", "/data/db", "/data/system_logs"]
  @ollama_host "localhost"
  @ollama_port 11_434

  def run do
    Logger.info("[StartupCheck] starting environment checks")

    results = [
      check_data_paths(),
      check_ollama_master()
    ]

    fatal_failures = Enum.filter(results, &match?({:fatal, _, _}, &1))
    warn_failures  = Enum.filter(results, &match?({:warn,  _, _}, &1))

    for {:warn, name, reason} <- warn_failures do
      Logger.warning("[StartupCheck] WARN #{name}: #{reason}")
    end

    case fatal_failures do
      [] ->
        Logger.info("[StartupCheck] all checks passed")
        :ok

      failures ->
        for {:fatal, name, reason} <- failures do
          Logger.error("[StartupCheck] FATAL #{name}: #{reason}")
        end
        raise "Startup check failed — see FATAL errors above"
    end
  end

  # ── fatal checks ────────────────────────────────────────────────────────────

  defp check_data_paths do
    failures =
      Enum.flat_map(@data_dirs, fn dir ->
        File.mkdir_p(dir)
        probe = Elixir.Path.join(dir, ".startup_check")

        case File.write(probe, "") do
          :ok ->
            File.rm(probe)
            []

          {:error, reason} ->
            ["#{dir}: #{:file.format_error(reason)}"]
        end
      end)

    case failures do
      [] -> {:ok, :data_paths}
      _  -> {:fatal, :data_paths, Enum.join(failures, "; ")}
    end
  end

  # ── warn checks ─────────────────────────────────────────────────────────────

  defp check_ollama_master do
    case :gen_tcp.connect(String.to_charlist(@ollama_host), @ollama_port, [], 5_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        {:ok, :ollama_master}

      {:error, reason} ->
        {:warn, :ollama_master,
         "cannot reach #{@ollama_host}:#{@ollama_port} — #{:inet.format_error(reason)}"}
    end
  end
end
