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

  @sandbox_container "dmh_ai-assistant-sandbox"
  # Bind-mounted host volumes that must exist + be writable for the
  # release to function. user_workspaces was added by #190 (per-user
  # permission redesign — see specs/permissions.md).
  @data_dirs ["/data/user_assets", "/data/user_workspaces", "/data/db", "/data/system_logs"]
  @ollama_host "localhost"
  @ollama_port 11_434

  def run do
    Logger.info("[StartupCheck] starting environment checks")

    results = [
      check_docker_socket(),
      check_sandbox_running(),
      check_sandbox_exec(),
      check_sandbox_iptables(),
      check_data_paths()
    ] ++ warn_checks()

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

  defp check_docker_socket do
    case System.cmd("docker", ["info", "--format", "{{.ID}}"],
           stderr_to_stdout: true) do
      {_, 0} -> {:ok, :docker_socket}
      {out, _} -> {:fatal, :docker_socket, "docker info failed: #{String.trim(out)}"}
    end
  rescue
    e -> {:fatal, :docker_socket, Exception.message(e)}
  end

  defp check_sandbox_running do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", @sandbox_container],
           stderr_to_stdout: true) do
      {"true\n", 0} -> {:ok, :sandbox_running}
      {out, _} -> {:fatal, :sandbox_running, "#{@sandbox_container} not running: #{String.trim(out)}"}
    end
  rescue
    e -> {:fatal, :sandbox_running, Exception.message(e)}
  end

  defp check_sandbox_exec do
    case System.cmd("docker", ["exec", @sandbox_container, "sh", "-c", "echo ok"],
           stderr_to_stdout: true) do
      {"ok\n", 0} -> {:ok, :sandbox_exec}
      {out, code} -> {:fatal, :sandbox_exec, "exec returned #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:fatal, :sandbox_exec, Exception.message(e)}
  end

  # Verify the sandbox booted with the LAN fence applied (#190 §Network
  # isolation). We probe `iptables -L OUTPUT -n` from inside the
  # sandbox and look for:
  #   • the admin ACCEPT pass-through (`owner UID match 10000`), and
  #   • at least 5 REJECT rules — one per RFC1918 / loopback /
  #     link-local range that start.sh installs.
  #
  # Rationale (operator surfacing): if `cap_add: NET_ADMIN` was lost
  # (custom seccomp profile, AppArmor, host kernel without netfilter),
  # the sandbox still boots but every non-admin script can reach
  # `192.168.x.x`, the host itself, etc. — silent security
  # degradation. Surfacing it as FATAL forces the operator to fix the
  # host policy or knowingly disable this check before serving users.
  @expected_reject_count 5
  @admin_uid_marker "owner UID match 10000"

  defp check_sandbox_iptables do
    case System.cmd(
           "docker",
           ["exec", @sandbox_container, "sh", "-c", "iptables -L OUTPUT -n 2>&1"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        rejects = output |> String.split("\n") |> Enum.count(&String.contains?(&1, "REJECT"))
        has_admin_accept = String.contains?(output, @admin_uid_marker)

        cond do
          rejects < @expected_reject_count ->
            {:fatal, :sandbox_iptables,
             "expected ≥ #{@expected_reject_count} REJECT rules in OUTPUT chain, got #{rejects} — " <>
               "sandbox/start.sh did not install the LAN fence " <>
               "(check `cap_add: NET_ADMIN` in docker-compose.yml + host AppArmor/seccomp policy)"}

          not has_admin_accept ->
            {:fatal, :sandbox_iptables,
             "admin pass-through ACCEPT rule missing from OUTPUT chain — admin LAN access broken " <>
               "(expected a rule with marker `#{@admin_uid_marker}`)"}

          true ->
            {:ok, :sandbox_iptables}
        end

      {output, _} ->
        {:fatal, :sandbox_iptables,
         "iptables -L OUTPUT failed inside sandbox: #{String.trim(output)} — " <>
           "likely cause: `cap_add: NET_ADMIN` missing from sandbox in docker-compose.yml, " <>
           "or host kernel lacks netfilter support"}
    end
  rescue
    e -> {:fatal, :sandbox_iptables, Exception.message(e)}
  end

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

  defp warn_checks do
    [
      check_ollama_master(),
      check_ollama_sandbox(),
      check_sandbox_internet()
    ]
  end

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

  defp check_ollama_sandbox do
    url = "http://#{@ollama_host}:#{@ollama_port}/api/tags"

    case System.cmd(
           "docker",
           ["exec", @sandbox_container, "sh", "-c",
            "curl -sf --max-time 5 #{url} -o /dev/null && echo ok || echo fail"],
           stderr_to_stdout: true
         ) do
      {"ok\n", 0} -> {:ok, :ollama_sandbox}
      {out, _}    -> {:warn, :ollama_sandbox, "sandbox cannot reach Ollama: #{String.trim(out)}"}
    end
  rescue
    e -> {:warn, :ollama_sandbox, Exception.message(e)}
  end

  defp check_sandbox_internet do
    case System.cmd(
           "docker",
           ["exec", @sandbox_container, "sh", "-c",
            "curl -sf --max-time 5 https://1.1.1.1 -o /dev/null && echo ok || echo fail"],
           stderr_to_stdout: true
         ) do
      {"ok\n", 0} -> {:ok, :sandbox_internet}
      {out, _}    -> {:warn, :sandbox_internet, "sandbox has no internet: #{String.trim(out)}"}
    end
  rescue
    e -> {:warn, :sandbox_internet, Exception.message(e)}
  end
end
