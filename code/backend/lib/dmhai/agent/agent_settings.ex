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
    "confidantModel"         => "gemini-3-flash-preview:cloud",
    "assistantModel"         => "ministral-3:14b-cloud",
    "languageDetectorModel"  => "ministral-3:8b-cloud",
    "workerModel"          => "qwen3-coder-next:cloud",
    "compactorModel"       => "gemini-3-flash-preview:cloud",
    "summarizerModel"      => "gemini-3-flash-preview:cloud",
    "webSearchModel"       => "ministral-3:14b-cloud",
    "imageDescriberModel"  => "gemini-3-flash-preview:cloud",
    "videoDescriberModel"  => "gemini-3-flash-preview:cloud",
    "profileExtractorModel" => "gemini-3-flash-preview:cloud"
  }

  @worker_max_iter_default 20
  @spawn_task_timeout_secs_default 30
  @worker_context_n_default 8
  @worker_context_m_default 6
  @max_tool_result_chars_default 8_000
  @master_compact_turn_threshold_default 90
  @master_compact_fraction_default 0.45
  @job_poll_min_interval_sec_default 5
  @job_poll_samples_per_cycle_default 10
  @job_orphan_timeout_sec_default 300
  @job_progress_summary_every_n_rows_default 6
  @job_progress_summary_min_interval_sec_default 30

  # Web / HTTP defaults
  @http_user_agent_default "Mozilla/5.0 (compatible; DMH-AI/1.0)"
  @searxng_url_default "http://127.0.0.1:8888"
  @jina_base_url_default "https://r.jina.ai/"
  @web_search_max_fetch_pages_default 6
  @web_search_fetch_content_budget_default 18_000
  @web_search_direct_timeout_ms_default 6_000
  @web_search_jina_timeout_ms_default 7_000
  @web_search_total_timeout_ms_default 20_000
  @synthesis_threshold_default 45_000
  @synthesis_fallback_chars_default 8_000

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
  def confidant_model,          do: model_for("confidantModel")
  def assistant_model,          do: model_for("assistantModel")
  def language_detector_model,  do: model_for("languageDetectorModel")
  def worker_model,           do: model_for("workerModel")
  def compactor_model,        do: model_for("compactorModel")
  def summarizer_model,       do: model_for("summarizerModel")
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

  @doc "Hard character limit for tool results fed into worker context. Larger results are summarised first."
  @spec max_tool_result_chars() :: pos_integer()
  def max_tool_result_chars, do: int_setting("maxToolResultChars", @max_tool_result_chars_default)

  @doc "Master session compaction: compact after this many recent turns."
  @spec master_compact_turn_threshold() :: pos_integer()
  def master_compact_turn_threshold, do: int_setting("masterCompactTurnThreshold", @master_compact_turn_threshold_default)

  @doc "Master session compaction: compact when recent chars exceed this fraction of estimated context budget."
  @spec master_compact_fraction() :: float()
  def master_compact_fraction, do: float_setting("masterCompactFraction", @master_compact_fraction_default)

  @doc "Minimum seconds between job progress polls (K floor). Never poll faster than this."
  @spec job_poll_min_interval_sec() :: pos_integer()
  def job_poll_min_interval_sec, do: int_setting("jobPollMinIntervalSec", @job_poll_min_interval_sec_default)

  @doc "Target samples per periodic cycle (M). Poll interval = max(K, intvl/M)."
  @spec job_poll_samples_per_cycle() :: pos_integer()
  def job_poll_samples_per_cycle, do: int_setting("jobPollSamplesPerCycle", @job_poll_samples_per_cycle_default)

  @doc "Consider a running job orphaned if no progress written in this many seconds."
  @spec job_orphan_timeout_sec() :: pos_integer()
  def job_orphan_timeout_sec, do: int_setting("jobOrphanTimeoutSec", @job_orphan_timeout_sec_default)

  @doc "Fire a progress summary every N new worker_status rows."
  @spec job_progress_summary_every_n_rows() :: pos_integer()
  def job_progress_summary_every_n_rows, do: int_setting("jobProgressSummaryEveryNRows", @job_progress_summary_every_n_rows_default)

  @doc "Minimum seconds between unsolicited progress summaries (rate limit)."
  @spec job_progress_summary_min_interval_sec() :: pos_integer()
  def job_progress_summary_min_interval_sec, do: int_setting("jobProgressSummaryMinIntervalSec", @job_progress_summary_min_interval_sec_default)

  @doc "HTTP User-Agent string for outbound web requests."
  @spec http_user_agent() :: String.t()
  def http_user_agent, do: string_setting("httpUserAgent", @http_user_agent_default)

  @doc "SearXNG base URL."
  @spec searxng_url() :: String.t()
  def searxng_url, do: string_setting("searxngUrl", @searxng_url_default)

  @doc "Jina reader base URL (appended with the target URL)."
  @spec jina_base_url() :: String.t()
  def jina_base_url, do: string_setting("jinaBaseUrl", @jina_base_url_default)

  @doc "Max number of search-result pages fetched per web search cycle."
  @spec web_search_max_fetch_pages() :: pos_integer()
  def web_search_max_fetch_pages, do: int_setting("webSearchMaxFetchPages", @web_search_max_fetch_pages_default)

  @doc "Character budget for accumulated page content per web search cycle."
  @spec web_search_fetch_content_budget() :: pos_integer()
  def web_search_fetch_content_budget, do: int_setting("webSearchFetchContentBudget", @web_search_fetch_content_budget_default)

  @doc "HTTP receive timeout (ms) for direct page fetches in web_search."
  @spec web_search_direct_timeout_ms() :: pos_integer()
  def web_search_direct_timeout_ms, do: int_setting("webSearchDirectTimeoutMs", @web_search_direct_timeout_ms_default)

  @doc "HTTP receive timeout (ms) for Jina reader fetches."
  @spec web_search_jina_timeout_ms() :: pos_integer()
  def web_search_jina_timeout_ms, do: int_setting("webSearchJinaTimeoutMs", @web_search_jina_timeout_ms_default)

  @doc "Task.await_many timeout (ms) for the parallel fetch phase."
  @spec web_search_total_timeout_ms() :: pos_integer()
  def web_search_total_timeout_ms, do: int_setting("webSearchTotalTimeoutMs", @web_search_total_timeout_ms_default)

  @doc "Raw result character count above which synthesis is triggered before injection."
  @spec synthesis_threshold() :: pos_integer()
  def synthesis_threshold, do: int_setting("synthesisThreshold", @synthesis_threshold_default)

  @doc "Character limit for the truncated fallback when synthesis fails."
  @spec synthesis_fallback_chars() :: pos_integer()
  def synthesis_fallback_chars, do: int_setting("synthesisFallbackChars", @synthesis_fallback_chars_default)

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

  defp string_setting(key, default) do
    settings = load()
    case settings[key] do
      s when is_binary(s) and s != "" -> s
      _ -> default
    end
  end

  defp float_setting(key, default) do
    settings = load()
    case settings[key] do
      n when is_float(n) and n > 0 -> n
      n when is_integer(n) and n > 0 -> n * 1.0
      s when is_binary(s) ->
        case Float.parse(s) do
          {n, _} when n > 0 -> n
          _ -> default
        end
      _ -> default
    end
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
