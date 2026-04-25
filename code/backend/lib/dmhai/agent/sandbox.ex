# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.Sandbox do
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

  @container_name "dmh_ai-assistant-sandbox"

  @cache_key {__MODULE__, :installed_tools}

  # Fallback when docker exec fails (sandbox not yet running, docker
  # daemon unreachable, etc). Matches the minimal set every working
  # sandbox image has historically shipped with.
  @fallback_tools ~w(curl wget python3 jq git nodejs npm)

  @doc "Container name of the assistant sandbox."
  def container_name, do: @container_name

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

  # ── private ────────────────────────────────────────────────────────────

  defp inspect_container do
    case System.cmd("docker",
           ["exec", @container_name, "cat", "/etc/apk/world"],
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
