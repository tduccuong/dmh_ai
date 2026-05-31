# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Sandbox do
  @moduledoc """
  Source of truth for the assistant's Alpine sandbox container —
  container name and the set of pre-installed top-level packages.

  The package list feeds `run_script`'s tool description so the model
  can reason about which commands exist without needing to fail-and-
  install. It's derived at runtime from `/etc/apk/world` inside the
  container (the Dockerfile's explicit apk-add set, not transitive
  dependencies) and cached in `:persistent_term` — the inspection
  runs once on first access.

  Falls back to a minimal hardcoded default if the container is
  unavailable at inspection time (typical during cold BE boot before
  the sandbox has started). A later call from a live session will
  populate the cache properly.
  """

  @default_container_name "dmh_ai-assistant-sandbox"

  @cache_key {__MODULE__, :installed_tools}

  # Fallback when docker exec fails (sandbox not yet running, docker
  # daemon unreachable, etc). Matches the minimal set every working
  # sandbox image has historically shipped with.
  @fallback_tools ~w(curl wget python3 jq git nodejs npm)

  @doc """
  Container name of the assistant sandbox. Resolved at call time
  (not compile time) so the sandbox-runtime test tier can swap it
  for a throwaway sister container via `Application.put_env(:dmh_ai,
  :sandbox_container_name, ...)`. Production never sets this and
  gets the default.
  """
  def container_name,
    do: Application.get_env(:dmh_ai, :sandbox_container_name, @default_container_name)

  @doc """
  List of top-level packages installed in the sandbox — sorted,
  deduped, lowercase. Cached across the BE's lifetime.
  """
  @spec installed_tools() :: [String.t()]
  def installed_tools do
    case :persistent_term.get(@cache_key, :__unset__) do
      :__unset__ ->
        tools = inspect_container()
        :persistent_term.put(@cache_key, tools)
        tools

      cached ->
        cached
    end
  end

  @doc """
  Force a re-inspection on next `installed_tools/0`. Useful after the
  sandbox image is rebuilt without restarting the BE.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Probe whether the materialised SSH keypair at `priv_key_path`
  currently authenticates against `<remote_user>@<host_part>`.
  Runs as `username` inside the sandbox (the per-user uid that
  owns the keystore file). Returns `:ok` on remote-side success
  (exit 0 of the trivial command `true`), `{:error, reason}` on
  anything else — `reason` carries the ssh-client's stderr so the
  caller can surface install-vs-network distinctions in tool
  results. Hard cap: ~6 seconds total (5-second `ConnectTimeout`
  + a small docker-exec overhead budget).

  Authoritative for the `provision_ssh_identity` lookup-hit path:
  no cached "verified" state — every call runs the probe, the
  probe is the verification. See `integrations.md` §SSH
  provisioning / §Verification.
  """
  @spec probe_ssh(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def probe_ssh(username, priv_key_path, remote_user, host_part)
      when is_binary(username) and is_binary(priv_key_path) and
             is_binary(remote_user) and is_binary(host_part) do
    user_host =
      case remote_user do
        "" -> host_part
        u  -> u <> "@" <> host_part
      end

    ssh_args = [
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=5",
      "-o", "StrictHostKeyChecking=accept-new",
      "-i", priv_key_path,
      user_host,
      "true"
    ]

    docker_args =
      ["exec", "-u", username, container_name(), "ssh"] ++ ssh_args

    case System.cmd("docker", docker_args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "exit #{code}: " <> String.slice(out, 0, 400)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Resolve `host` from inside the sandbox container as the per-user
  uid (mirrors `probe_ssh/4`'s execution context — same DNS view).
  Returns `:ok` when `getent hosts <host>` exits 0, `{:error, reason}`
  otherwise.

  Run BEFORE any ssh / curl probe whose failure shape would otherwise
  look like an auth problem: a DNS-unresolvable name fails ssh with
  `Could not resolve hostname`, which models routinely misread as a
  credentials gap. Pre-probing DNS lets the tool return an
  `unreachable` envelope naming the routable-address gap directly.
  """
  @spec probe_dns(String.t(), String.t()) :: :ok | {:error, String.t()}
  def probe_dns(username, host_part)
      when is_binary(username) and is_binary(host_part) do
    docker_args =
      ["exec", "-u", username, container_name(), "getent", "hosts", host_part]

    case System.cmd("docker", docker_args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "exit #{code}: " <> String.slice(out, 0, 200)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── private ────────────────────────────────────────────────────────────

  defp inspect_container do
    case System.cmd("docker",
           ["exec", container_name(), "cat", "/etc/apk/world"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> parse_world_file(out)
      _        -> @fallback_tools
    end
  rescue
    # docker binary missing, path-related errors, etc.
    _ -> @fallback_tools
  end

  # `/etc/apk/world` is line-separated package names, optionally with
  # version constraints (`pkg=1.2`, `pkg>1.0`). We want bare package
  # names only, sorted and deduped.
  defp parse_world_file(contents) do
    contents
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn line ->
      line
      |> String.split(~r/[=<>~]/, parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
