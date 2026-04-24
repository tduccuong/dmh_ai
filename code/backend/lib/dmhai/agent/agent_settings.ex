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
    "assistantModel"         => "gpt-oss:120b-cloud",
    "compactorModel"       => "gemini-3-flash-preview:cloud",
    "summarizerModel"      => "gemini-3-flash-preview:cloud",
    "webSearchModel"       => "ministral-3:14b-cloud",
    "imageDescriberModel"  => "gemini-3-flash-preview:cloud",
    "videoDescriberModel"  => "gemini-3-flash-preview:cloud",
    "profileExtractorModel" => "gemini-3-flash-preview:cloud"
  }

  @log_trace_default false
  @model_behavior_telemetry_enabled_default true

  @spawn_task_timeout_secs_default 30
  @max_tool_result_chars_default 8_000
  @master_compact_turn_threshold_default 50
  @master_compact_fraction_default 0.45
  @max_assistant_turns_per_chain_default 50

  # Estimated usable context window (in tokens) of the assistant LLM.
  # Used by ContextEngine.should_compact? to derive the char-based
  # compaction trigger. Conservative floor across cloud models (many
  # sit at ~128 k, some larger). Operators can tune via the
  # `estimatedContextTokens` setting.
  @estimated_context_tokens_default 64_000

  # Document extraction
  @min_extracted_text_chars_default 50
  @ocr_pages_per_chunk_default 8
  @ocr_page_cap_default 16

  # Tool-result retention — number of recent turns whose tool_call /
  # tool_result message pairs stay in the Assistant's context on the
  # next turn, so follow-up questions can be answered without re-
  # extracting. Bounded independently by a byte budget so a chain of
  # heavy OCRs can't balloon context.
  @tool_result_retention_turns_default 5
  @tool_result_retention_bytes_default 120_000

  # Per-task archive sliding window. Caps `task_turn_archive` to the
  # last N rows OR B bytes per task, whichever is tighter. Oldest
  # rows beyond either cap are dropped at append time. No LLM
  # summarisation of archived content — sliding-window eviction only.
  # See architecture.md §Task state continuity across chains.
  @task_archive_row_cap_default 60
  @task_archive_byte_cap_default 120_000

  # LLM-account rotation throttle durations. Applied by
  # `Dmhai.Agent.LLM` when an account hits a rate-limit (HTTP 429 or
  # stream-inline RL error) or has its quota exhausted (Ollama's
  # weekly cap). Rate-limit defaults to 60 s — matches the typical
  # upstream rolling-window RL and keeps a burst from locking the
  # whole account pool. Quota default is 168 h (7 days) to match
  # Ollama's weekly reset cadence. The 429 handler also parses the
  # `Retry-After` header and, when present, uses it in preference to
  # this default (see `parse_retry_after_ms/1`).
  @rate_limit_throttle_secs_default 60
  @quota_exhausted_throttle_hours_default 168

  # Output-token ceiling (num_predict) passed to every assistant-mode
  # LLM.stream call. `num_predict` is a ceiling, NOT a prepaid budget
  # — unused headroom has no cost. Set far above any practical
  # tool_call or reply size (long bash scripts easily run to ~1 000
  # tokens) while still bounding a runaway model that never emits EOS.
  @llm_num_predict_assistant_default 16_384

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

  @doc "Whether to write verbatim LLM call traces to <session_root>/log_traces/<task_id>.log."
  @spec log_trace() :: boolean()
  def log_trace, do: bool_setting("logTrace", @log_trace_default)

  @doc "Whether to record model misbehavior occurrences to model_behavior_stats for the admin UI."
  @spec model_behavior_telemetry_enabled() :: boolean()
  def model_behavior_telemetry_enabled,
    do: bool_setting("modelBehaviorTelemetryEnabled", @model_behavior_telemetry_enabled_default)

  @doc "Shortcut accessors."
  def confidant_model,          do: model_for("confidantModel")
  def assistant_model,          do: model_for("assistantModel")
  def compactor_model,        do: model_for("compactorModel")
  def summarizer_model,       do: model_for("summarizerModel")
  def web_search_model,       do: model_for("webSearchModel")
  def image_describer_model,  do: model_for("imageDescriberModel")
  def video_describer_model,  do: model_for("videoDescriberModel")
  def profile_extractor_model, do: model_for("profileExtractorModel")

  @doc "Timeout in seconds applied to each bash command run inside spawn_task."
  @spec spawn_task_timeout_secs() :: pos_integer()
  def spawn_task_timeout_secs, do: int_setting("spawnTaskTimeoutSecs", @spawn_task_timeout_secs_default)

  @doc "Hard character limit for tool results fed back to the assistant. Larger results are truncated."
  @spec max_tool_result_chars() :: pos_integer()
  def max_tool_result_chars, do: int_setting("maxToolResultChars", @max_tool_result_chars_default)

  @doc "Session compaction: compact after this many recent turns."
  @spec master_compact_turn_threshold() :: pos_integer()
  def master_compact_turn_threshold, do: int_setting("masterCompactTurnThreshold", @master_compact_turn_threshold_default)

  @doc "Session compaction: compact when recent chars exceed this fraction of estimated context budget."
  @spec master_compact_fraction() :: float()
  def master_compact_fraction, do: float_setting("masterCompactFraction", @master_compact_fraction_default)

  @doc """
  Per-chain safety cap on the number of turns (LLM roundtrips) before the
  chain aborts with a carry-on message. Terminology: one **turn** is one
  LLM call + its tool execution; one **chain** is the sequence of turns
  until the assistant emits user-facing text. See architecture.md
  §Assistant Mode.
  """
  @spec max_assistant_turns_per_chain() :: pos_integer()
  def max_assistant_turns_per_chain, do: int_setting("maxAssistantTurnsPerChain", @max_assistant_turns_per_chain_default)

  @doc "Minimum post-trim char count for an `extract_content` result to count as 'meaningful' (not blank/scanned)."
  @spec min_extracted_text_chars() :: pos_integer()
  def min_extracted_text_chars, do: int_setting("minExtractedTextChars", @min_extracted_text_chars_default)

  @doc "How many rendered PDF pages to send per vision-LLM OCR call."
  @spec ocr_pages_per_chunk() :: pos_integer()
  def ocr_pages_per_chunk, do: int_setting("ocrPagesPerChunk", @ocr_pages_per_chunk_default)

  @doc "Hard cap on PDF page count for OCR. Above this, extract_content fails with a nudge to split the file."
  @spec ocr_page_cap() :: pos_integer()
  def ocr_page_cap, do: int_setting("ocrPageCap", @ocr_page_cap_default)

  @doc "Estimated usable context-window size (in tokens) of the assistant LLM."
  @spec estimated_context_tokens() :: pos_integer()
  def estimated_context_tokens,
    do: int_setting("estimatedContextTokens", @estimated_context_tokens_default)

  @doc "Number of recent turns whose tool_call / tool_result messages are retained in context."
  @spec tool_result_retention_turns() :: pos_integer()
  def tool_result_retention_turns,
    do: int_setting("toolResultRetentionTurns", @tool_result_retention_turns_default)

  @doc "Upper byte budget for retained tool messages. When exceeded, oldest-first eviction trims to fit."
  @spec tool_result_retention_bytes() :: pos_integer()
  def tool_result_retention_bytes,
    do: int_setting("toolResultRetentionBytes", @tool_result_retention_bytes_default)

  @doc """
  Per-task archive row cap. Each `task_turn_archive` grouping is
  trimmed to this many rows at append time; oldest beyond the cap are
  dropped. Row = one persisted message (user OR assistant OR tool),
  so ~30 user+assistant pairs fit in the default 60.
  """
  @spec task_archive_row_cap() :: pos_integer()
  def task_archive_row_cap,
    do: int_setting("taskArchiveRowCap", @task_archive_row_cap_default)

  @doc """
  Per-task archive byte budget. Measured over the `content` column
  sum. Applied alongside `task_archive_row_cap` — oldest rows are
  dropped until BOTH caps are satisfied. A single heavy message (e.g.
  pasted 80 KB paragraph) shrinks the effective window further.
  """
  @spec task_archive_byte_cap() :: pos_integer()
  def task_archive_byte_cap,
    do: int_setting("taskArchiveByteCap", @task_archive_byte_cap_default)

  @doc """
  Rate-limit throttle duration (seconds). Applied to an LLM account
  when it returns 429 / rate-limited AND the response carried no
  `Retry-After` header to honor. Default 60 s — a typical upstream
  rate-limit rolling window.
  """
  @spec rate_limit_throttle_secs() :: pos_integer()
  def rate_limit_throttle_secs,
    do: int_setting("rateLimitThrottleSecs", @rate_limit_throttle_secs_default)

  @doc """
  Quota-exhausted throttle duration (hours). Applied when an LLM
  account signals its quota is spent (Ollama's "weekly usage limit"
  message). Default 168 h (7 days) to match Ollama cloud's weekly
  reset.
  """
  @spec quota_exhausted_throttle_hours() :: pos_integer()
  def quota_exhausted_throttle_hours,
    do: int_setting("quotaExhaustedThrottleHours", @quota_exhausted_throttle_hours_default)

  @doc """
  Output-token ceiling (`num_predict`) applied to every assistant-mode
  LLM.stream call. A ceiling, not a reservation: unused headroom has
  no cost. Raise if long tool_calls (scripts, files) are getting cut
  mid-string; lower to harden against runaway generation.
  """
  @spec llm_num_predict_assistant() :: pos_integer()
  def llm_num_predict_assistant,
    do: int_setting("llmNumPredictAssistant", @llm_num_predict_assistant_default)

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

  @doc "Map of every model-role setting key → its baked-in default name. Exposed to the FE via /admin/settings."
  @spec model_defaults() :: %{String.t() => String.t()}
  def model_defaults, do: @defaults

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

  defp bool_setting(key, default) do
    settings = load()
    case settings[key] do
      true    -> true
      false   -> false
      "true"  -> true
      "false" -> false
      _       -> default
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
