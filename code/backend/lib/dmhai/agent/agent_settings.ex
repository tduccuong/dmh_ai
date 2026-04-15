# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.AgentSettings do
  @moduledoc """
  Reads per-agent model configuration from admin_cloud_settings.
  Falls back to sensible defaults so the system works out of the box.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @defaults %{
    "confidantModel"       => "gemini-3-flash-preview:cloud",
    "assistantModel"       => "ministral-3:14b-cloud",
    "workerModel"          => "kimi-k2.5:cloud",
    "compactorModel"       => "gemini-3-flash-preview:cloud",
    "webSearchModel"       => "ministral-3:14b-cloud",
    "imageDescriberModel"  => "gemini-3-flash-preview:cloud",
    "videoDescriberModel"  => "gemini-3-flash-preview:cloud",
    "profileExtractorModel" => "gemini-3-flash-preview:cloud"
  }

  @worker_max_iter_default 20
  @spawn_task_timeout_secs_default 30
  @worker_context_n_default 20
  @worker_context_m_default 10

  @doc "Get the model string for a given agent role. Returns the default if unset."
  @spec model_for(String.t()) :: String.t()
  def model_for(role) when is_binary(role) do
    settings = load()
    val = String.trim(settings[role] || "")
    plain = if val == "", do: @defaults[role] || "", else: val
    to_routed(plain)
  end

  # Convert a plain model name (e.g. "gemini-3-flash-preview:cloud") to the
  # routed format ("ollama::cloud::..." or "ollama::local::...").
  # If the value already contains "::" it is assumed to be pre-formatted.
  defp to_routed(model) do
    if String.contains?(model, "::") do
      model
    else
      pool = if String.ends_with?(model, "-cloud") or String.ends_with?(model, ":cloud"), do: "cloud", else: "local"
      "ollama::#{pool}::#{model}"
    end
  end

  @doc "Shortcut accessors."
  def confidant_model,        do: model_for("confidantModel")
  def assistant_model,        do: model_for("assistantModel")
  def worker_model,           do: model_for("workerModel")
  def compactor_model,        do: model_for("compactorModel")
  def web_search_model,       do: model_for("webSearchModel")
  def image_describer_model,  do: model_for("imageDescriberModel")
  def video_describer_model,  do: model_for("videoDescriberModel")
  def profile_extractor_model, do: model_for("profileExtractorModel")

  @doc "Timeout in seconds applied to each bash command run inside spawn_task."
  @spec spawn_task_timeout_secs() :: pos_integer()
  def spawn_task_timeout_secs, do: int_setting("spawnTaskTimeoutSecs", @spawn_task_timeout_secs_default)

  @doc "Worker context compaction: number of messages in the middle (stub) tier."
  @spec worker_context_n() :: pos_integer()
  def worker_context_n, do: int_setting("workerContextN", @worker_context_n_default)

  @doc "Worker context compaction: number of most-recent messages to leave untouched."
  @spec worker_context_m() :: pos_integer()
  def worker_context_m, do: int_setting("workerContextM", @worker_context_m_default)

  @doc "Max tool-call iterations for a non-periodic worker. Periodic workers ignore this."
  @spec worker_max_iter() :: pos_integer()
  def worker_max_iter, do: int_setting("workerMaxIter", @worker_max_iter_default)

  @doc "User's chosen video detail level from admin settings. Returns 'low', 'medium', or 'high'."
  @spec video_detail() :: String.t()
  def video_detail do
    settings = load()
    case settings["videoDetail"] do
      v when v in ["low", "medium", "high"] -> v
      _ -> "medium"
    end
  end

  @doc "Plain model names of all built-in system models (cloud only)."
  @spec system_model_names() :: [String.t()]
  def system_model_names do
    @defaults
    |> Map.values()
    |> Enum.uniq()
    |> Enum.filter(fn m -> String.ends_with?(m, ":cloud") or String.ends_with?(m, "-cloud") end)
  end

  defp int_setting(key, default) do
    settings = load()
    case settings[key] do
      n when is_integer(n) and n > 0 -> n
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n > 0 -> n
          _ -> default
        end
      _ -> default
    end
  end

  defp load do
    try do
      result = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end
    rescue
      _ -> %{}
    end
  end
end
