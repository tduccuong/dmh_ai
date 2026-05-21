# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.AgentSettings do
  @moduledoc """
  Reads per-agent model configuration from admin_cloud_settings.
  Falls back to sensible defaults so the system works out of the box.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Defaults use the canonical `<pool>::<model>` format. See
  # specs/api_pools.md. The `ollama-cloud` pool is seeded on first boot
  # from the operator's pool seed file (defaults to placeholder zero
  # accounts; admin must add their cloud accounts via System Settings →
  # API Pools before these models can be used).
  # Two-tier model layout (see specs/architecture.md §Model tiers):
  #
  #   confidantModel — Confidant answer. Conversational, image-capable.
  #   assistantModel — Assistant answer. Tool-using, image-capable.
  #   swiftModel     — Swift tier. Short, single-shot decisions:
  #                    Swift.classify (anchor pivot), Swift.localize,
  #                    Web.Search query planner, session naming.
  #                    Cheapest model — latency dominates over quality.
  #   oracleModel    — Oracle tier. Long, dense content processing:
  #                    context compaction, task progress summaries,
  #                    web result synthesis, profile extraction +
  #                    condensation. Strong general model.
  #   visionModel    — Vision/OCR. Image describe, video describe,
  #                    PDF OCR. Must be image-capable.
  #   kbEmbeddingModel — Vector KB embedder. See specs/vector_kb.md.
  @defaults %{
    "confidantModel"   => "ollama-cloud::gemma4:31b-cloud",
    "assistantModel"   => "ollama-cloud::gemma4:31b-cloud",
    "swiftModel"       => "ollama-cloud::ministral-3:14b-cloud",
    "oracleModel"      => "ollama-cloud::gemma4:31b-cloud",
    "visionModel"      => "ollama-cloud::gemma4:31b-cloud",
    "kbEmbeddingModel" => "miner::qwen3-embedding:0.6b"
  }

  @log_trace_default false
  @model_behavior_telemetry_enabled_default true

  @spawn_task_timeout_secs_default 30
  @max_tool_result_chars_default 8_000
  @master_compact_turn_threshold_default 50
  @master_compact_fraction_default 0.45
  @max_assistant_turns_per_chain_default 50

  # Cap on the number of `run_script` calls per single chain. The
  # (N+1)th run_script is rejected by Police's run_script_probe_budget
  # gate with a nudge that teaches the model to compose the rest into
  # ONE more script OR ask the user the specific question probes can't
  # answer. Default 5: leaves room for genuinely complex API
  # discovery (probe stages → probe methods → probe fields → execute
  # → verify) while still surfacing scope walls and missing entities
  # to the user fast. See architecture.md §Police gate #11.
  @run_script_probe_budget_default 5

  # Long-running tool execution (see architecture.md
  # §Long-running tool execution). Every `run_script` invocation is
  # wrapped in nohup, registered in `DmhAi.Agent.RunningTools`, and
  # the runtime polls process status every `tool_run_poll_interval_ms`.
  # Anything still running after `run_script_max_runtime_ms` is
  # killed and returns `{:error, "max_runtime exceeded after Ns"}`.
  @tool_run_poll_interval_ms_default 2_000
  @run_script_max_runtime_ms_default 21_600_000

  # `mk_download_link` per-call size cap. Files larger than this are
  # rejected — keeps a runaway `cp /var/log/syslog` (or worse, a model
  # publishing a 50 GB DB dump) from filling user_assets.
  @publish_max_bytes_default 50_000_000

  # `mk_download_link` URL signature TTL. A signed link works
  # without a bearer token until expiry, so the URL can be shared
  # with non-DMH-AI users. Default 7 days bounds the blast radius
  # if a link is over-shared.
  @publish_link_ttl_secs_default 604_800

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

  # Per-task archive sliding window. Caps `task_chain_archive` to the
  # last N rows OR B bytes per task, whichever is tighter. Oldest
  # rows beyond either cap are dropped at append time. No LLM
  # summarisation of archived content — sliding-window eviction only.
  # See architecture.md §Task state continuity across chains.
  @task_archive_row_cap_default 60
  @task_archive_byte_cap_default 120_000

  # Resume-time caps for `pickup_task`'s rehydrated transcript inside
  # the `<requested_task_content>` envelope. Independent of the archive
  # storage caps above (`task_archive_*_cap`); these tighten the
  # rendered view shipped to the LLM on resume.
  @task_resume_max_archive_entries_default 50
  @task_resume_args_cap_default 400

  # Inactive-task related-message classifier. When a chain starts with
  # no active anchor AND the session has at least one inactive task,
  # `Agent.Swift.classify_against_inactive/2` runs ONE batched call
  # listing up to N most-recent inactive tasks and asks for a
  # task_num or "none". On positive match the runtime prepends a
  # guidance hint to the user message before the chain LLM call. See
  # architecture.md §Inactive-task related-message classifier.
  @task_resume_candidate_cap_default 8

  # ProfileExtractor batching. The extractor walks unprocessed user
  # messages across all of a user's sessions and fires its single LLM
  # call once `profile_extract_batch_size` messages have accumulated
  # past the per-user `last_profile_extracted_msg_ts` watermark. The
  # call returns the FULL UPDATED PROFILE (merge happens inside the
  # LLM, not in code) — no separate condense pass.
  # `profile_max_bullets` is a soft size cap injected into the prompt
  # when the existing profile is large; the LLM is asked to merge
  # near-dup keys and drop lowest-signal values to stay under it.
  @profile_extract_batch_size_default 5
  @profile_max_bullets_default 42

  # Auto session naming. The Data handler's `post_name_session` pulls
  # the last N user messages (slash commands skipped) and feeds them
  # to a swift-tier LLM. On a refresh-rename it also passes the
  # current title so the model can bridge the old framing with the
  # new direction (continuity over snap-to-latest). See arch §Session
  # naming.
  @session_namer_user_msg_count_default 4

  # LLM-account rotation throttle durations. Applied by
  # `DmhAi.Agent.LLM` when an account hits a rate-limit (HTTP 429 or
  # stream-inline RL error) or has its quota exhausted (Ollama's
  # weekly cap). Rate-limit defaults to 60 s — matches the typical
  # upstream rolling-window RL and keeps a burst from locking the
  # whole account pool. Quota default is 168 h (7 days) to match
  # Ollama's weekly reset cadence. The 429 handler also parses the
  # `Retry-After` header and, when present, uses it in preference to
  # this default (see `parse_retry_after_ms/1`).
  @rate_limit_throttle_secs_default 60
  @quota_exhausted_throttle_hours_default 168

  # Global per-LLM-call attempt budget. Spans both within-account
  # retry-on-server-error AND cross-account rotation. When 0, the call
  # returns `{:error, :attempts_exhausted}` instead of looping. Without
  # this cap, a single-account pool whose endpoint returns a persistent
  # `5xx` (or transport error) loops indefinitely — `mark_throttled`
  # only fires for `:rate_limited`, so `:all_throttled` is unreachable
  # for `:server_error`. The cap is the only correct termination
  # condition for that shape. See arch_wiki §Retry cap.
  @llm_total_attempts_default 6

  # Outbound HTTP receive_timeout for LLM calls (both streaming and
  # non-streaming). Belt-and-suspenders cap so a stalled connection
  # fails out rather than blocking forever; not the primary defence
  # against hangs (that's `Connection: close` + `compressed: false`
  # in lib/dmh_ai/agent/llm.ex). Default 300 s accommodates cold-loads
  # of large local Ollama models when `num_ctx` forces a KV-cache
  # reallocation — the prior 120 s was too tight for 24B-class
  # models on consumer GPUs (see specs/api_pools.md §num_ctx).
  # Bump higher if your hardware reloads slower; lower if you'd
  # rather fail fast on misbehaving cloud endpoints.
  @llm_receive_timeout_ms_default 300_000

  # Wall-clock budget for the Confidant pre-step (web search planner +
  # memo retrieval, both run in parallel before the main answer
  # streams). When exceeded, the pre-step Task crashes; the chain ends
  # with a visible `chain_aborted` row instead of streaming an answer.
  # Default 60 s comfortably covers cloud Swift latencies and most
  # warm self-hosted models. Operators on slow miners that need
  # cold-load + non-streaming completion budget should bump this; the
  # tradeoff is a longer silent wait before the user sees the error
  # row when something is genuinely wedged.
  @confidant_pre_step_timeout_ms_default 60_000

  # Path to the deployment-wide memo master key file — see
  # specs/memo_encryption.md. Default lives one level OUT of /data/db/
  # so operators backing up the DB don't pick up the key by accident
  # (defeating the encryption-at-rest claim). Generated lazily on
  # first BE start if missing; persistent across restarts. Override
  # via `DMHAI_MEMO_MASTER_KEY` env var (base64-encoded 32 bytes) if
  # the operator prefers an externally-supplied key.
  @memo_master_key_path_default "/data/secrets/dmh_ai_master.key"

  # Output-token ceiling (num_predict) passed to every assistant-mode
  # LLM.stream call. `num_predict` is a ceiling, NOT a prepaid budget
  # — unused headroom has no cost. Set far above any practical
  # tool_call or reply size (long bash scripts easily run to ~1 000
  # tokens) while still bounding a runaway model that never emits EOS.
  @llm_num_predict_assistant_default 16_384

  # Time-to-live (seconds) for a `request_input` form. After this,
  # the BE rejects late submissions and the FE renders the form as
  # expired. The chain that emitted the form stays paused — user can
  # re-ask in a new chain.
  @request_input_ttl_secs_default 600

  # OAuth2 pending-state TTL (seconds). State token mints when a
  # `connect_mcp` flow starts; expires N seconds later. Callbacks
  # past expiry are rejected.
  @oauth_state_ttl_secs_default 600

  # Base URL the BE uses to construct OAuth2 redirect URIs. Combined
  # with a state token to form `<base>/oauth/callback/<state>`. Must
  # match the redirect URI the provider's OAuth App / authorization
  # server allows (or its prefix, when the provider accepts a prefix).
  @oauth_redirect_base_url_default "http://localhost:8080"

  # Web / HTTP defaults
  @http_user_agent_default "Mozilla/5.0 (compatible; DMH-AI/1.0)"
  @searxng_url_default "http://127.0.0.1:8888"
  @jina_base_url_default "https://r.jina.ai/"
  @web_search_max_fetch_pages_default 6
  @web_search_fetch_content_budget_default 18_000
  @web_search_direct_timeout_ms_default 6_000
  @web_search_jina_timeout_ms_default 7_000
  @web_search_total_timeout_ms_default 20_000
  # Hard cap (chars) on raw web-search-results text injected into the
  # Confidant turn. Cuts boilerplate / ads / dup snippets at the tail
  # so the main Confidant LLM call doesn't choke on a 45 KB+ blob.
  # The framing block ("Web search results (retrieved DATE)…") already
  # tells the model to focus on relevant facts and ignore noise.
  @web_results_max_chars_default 12_000

  # Vector knowledge base — see specs/vector_kb.md. Chunk size targets
  # the embedding model's recall sweet spot (256–512 tokens for dense
  # retrieval). qwen3-embedding-0.6b emits 1024-dim vectors; changing
  # `kb_embedding_dim` requires a full reindex (the SQLite-blob backend
  # rejects mismatched rows on insert).
  # Knowledge-scope (`/index`) chunking — long curated documents.
  @kb_chunk_tokens_default 400
  @kb_chunk_overlap_tokens_default 60

  # `/index <url>` BFS crawl. v1 was single-page; v2 (#178) walks
  # same-prefix pages up to a depth + page cap, indexing each. The
  # caps are conservative defaults for typical doc sites; raise
  # `learn_url_max_pages` for a deep API reference, lower
  # `learn_url_max_depth` for a flat marketing site.
  @learn_url_max_depth_default 5
  @learn_url_max_pages_default 200
  @learn_url_concurrency_default 1

  # Ad-hoc `web_crawl` tool (Layer-1 Q&A; ephemeral, not KB-indexed).
  # Defaults are conservative — the result lands inline in the LLM's
  # tool-result message, so 20 × 3000 = ~60 KB plain text. The hard
  # caps prevent a runaway from exhausting context.
  @web_crawl_max_pages_default        20
  @web_crawl_max_pages_hard_cap       50
  @web_crawl_max_depth_default        2
  @web_crawl_max_depth_hard_cap       4
  @web_crawl_max_chars_per_page_default 3000
  @web_crawl_per_fetch_delay_ms_default 300
  @web_crawl_total_timeout_ms_default   30_000
  @web_crawl_branch_factor_default      4    # top-K links to follow per depth boundary

  # Memo-scope (`/memo`) chunking — much smaller. Users typically
  # save 2-sentence facts (~30–40 tokens) and rarely exceed 20
  # sentences (~300–400 tokens). At ~50 tokens / chunk, a typical
  # 2-sentence memo stays as a single sharp chunk while longer
  # memos split into ~3-sentence units. Sharper chunks → query
  # vectors align tightly with the matching fact-bearing chunk
  # → higher cosine scores → the 0.55 threshold becomes a clean
  # signal of "actually about this topic". See specs/vector_kb.md.
  @kb_memo_chunk_tokens_default 50
  @kb_memo_chunk_overlap_tokens_default 10
  @kb_top_n_default 8

  # Maximum Marginal Relevance — diversification on retrieval.
  # The vector store returns the top-`pool_size` candidates by raw
  # cosine; we then MMR-pick the final `top_n` so near-duplicate
  # chunks (e.g. identical boilerplate error blocks copied across
  # many docs) drop out and the model sees diverse context.
  # Lambda controls the balance — 1.0 = pure relevance (no
  # diversification), 0.0 = pure novelty. 0.6 favours relevance
  # while still penalising near-duplicates.
  # See specs/vector_kb.md §retrieval.
  @kb_mmr_pool_size_default 30
  @kb_mmr_lambda_default 0.6

  @kb_embedding_dim_default 1024
  @kb_embedding_batch_size_default 32

  # Cap on memo hits attached to the `<augmented_facts type="memo">`
  # block in Confidant's auto-retrieve pre-step. The score threshold already
  # filters out weak hits; this is a safety against a user whose
  # memo store has many similar entries (e.g. twenty bank-related
  # notes) so the prompt doesn't bloat. See specs/commands.md
  # §Confidant memo auto-retrieve.
  @memo_context_top_k_default 5

  # Inline-text /index semantic-merge gate — a new body whose centroid
  # is at-or-above this cosine score against an existing source merges
  # into that source instead of creating a new one. High enough that
  # distinct topics don't collapse, low enough that "same content with
  # a typo fix / extra paragraph" merges.
  @kb_text_merge_threshold_default 0.92

  # Background relearn supervisor — caps simultaneous re-fetches.
  @kb_relearn_concurrency_default 4

  # Primitive 0.2 — minimum seconds between BG refreshes for the same
  # source_id. A query storm on a hot topic collapses to one upstream
  # HEAD-check per source per window. Per-org tunable; the default
  # balances freshness vs upstream load.
  @bg_refresh_min_interval_s_default 600

  @doc """
  Get the model string for a given agent role. Returns the default if
  unset. Always in `<pool>::<model>` form (see specs/api_pools.md).
  Both the per-role override stored in `admin_cloud_settings` and the
  baked-in `@defaults` use this form.
  """
  @spec model_for(String.t()) :: String.t()
  def model_for(role) when is_binary(role) do
    settings = load()
    val = String.trim(settings[role] || "")
    if val == "", do: @defaults[role] || "", else: val
  end

  @doc "Whether to write verbatim LLM call traces to <session_root>/log_traces/<task_id>.log."
  @spec log_trace() :: boolean()
  def log_trace, do: bool_setting("logTrace", @log_trace_default)

  @doc "Whether to record model misbehavior occurrences to model_behavior_stats for the admin UI."
  @spec model_behavior_telemetry_enabled() :: boolean()
  def model_behavior_telemetry_enabled,
    do: bool_setting("modelBehaviorTelemetryEnabled", @model_behavior_telemetry_enabled_default)

  @doc "Shortcut accessors."
  def confidant_model,    do: model_for("confidantModel")
  def assistant_model,    do: model_for("assistantModel")
  def swift_model,        do: model_for("swiftModel")
  def oracle_model,       do: model_for("oracleModel")
  def vision_model,       do: model_for("visionModel")
  def kb_embedding_model, do: model_for("kbEmbeddingModel")

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

  @spec run_script_probe_budget() :: pos_integer()
  def run_script_probe_budget, do: int_setting("runScriptProbeBudget", @run_script_probe_budget_default)

  @doc "Number of unprocessed user messages required before ProfileExtractor fires one LLM call."
  @spec profile_extract_batch_size() :: pos_integer()
  def profile_extract_batch_size,
    do: int_setting("profileExtractBatchSize", @profile_extract_batch_size_default)

  @doc "Soft upper bound (bullet count) on the merged profile. Injected as a size hint into the extractor prompt."
  @spec profile_max_bullets() :: pos_integer()
  def profile_max_bullets,
    do: int_setting("profileMaxBullets", @profile_max_bullets_default)

  @doc "Number of recent user messages fed to the auto session-namer LLM call."
  @spec session_namer_user_msg_count() :: pos_integer()
  def session_namer_user_msg_count,
    do: int_setting("sessionNamerUserMsgCount", @session_namer_user_msg_count_default)

  @doc "Runtime poll cadence (ms) for in-flight `run_script` processes."
  @spec tool_run_poll_interval_ms() :: pos_integer()
  def tool_run_poll_interval_ms,
    do: int_setting("toolRunPollIntervalMs", @tool_run_poll_interval_ms_default)

  @doc "Hard upper bound (ms) on a single `run_script` invocation. Past this the runtime kills the PID."
  @spec run_script_max_runtime_ms() :: pos_integer()
  def run_script_max_runtime_ms,
    do: int_setting("runScriptMaxRuntimeMs", @run_script_max_runtime_ms_default)

  @doc "Maximum size (bytes) of a single `mk_download_link` publish. Larger files are rejected."
  @spec publish_max_bytes() :: pos_integer()
  def publish_max_bytes,
    do: int_setting("publishMaxBytes", @publish_max_bytes_default)

  @doc "TTL (seconds) of a `mk_download_link` signed URL before the signature expires."
  @spec publish_link_ttl_secs() :: pos_integer()
  def publish_link_ttl_secs,
    do: int_setting("publishLinkTtlSecs", @publish_link_ttl_secs_default)

  @doc """
  Days after which completed `workflow_run_state` rows + their
  step trace get exported to JSONL archive and dropped from the
  live DB. Default 30. See `arch_wiki/dmh_ai/sme/layer-W.md`
  §Retention.
  """
  @spec workflow_run_retention_days() :: pos_integer()
  def workflow_run_retention_days,
    do: int_setting("workflowRunRetentionDays", 30)

  @doc """
  Install-wide HMAC secret used to sign per-workflow webhook URLs.
  Lazily generated on first call (32 random bytes, base64-encoded)
  and persisted in the `settings` table so the URL stays stable
  across restarts. If the operator rotates this value, EVERY armed
  webhook URL must be re-pasted into its external system — by
  design, the secret IS the binding.
  """
  @spec install_secret() :: String.t()
  def install_secret do
    settings = load()

    case settings["installSecret"] do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        new_secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        # Persist alongside the other admin settings (one JSON blob
        # under the `admin_cloud_settings` key). Re-load + merge so we
        # don't clobber concurrent edits.
        DmhAi.Repo
        |> Ecto.Adapters.SQL.query!("""
        INSERT INTO settings (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [
          "admin_cloud_settings",
          Jason.encode!(Map.put(load(), "installSecret", new_secret))
        ])

        new_secret
    end
  end

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
  Per-task archive row cap. Each `task_chain_archive` grouping is
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
  Maximum number of archived messages rendered inside the
  `<requested_task_content>` envelope returned by `pickup_task`. Only
  the newest N are kept; older entries are silently truncated.
  """
  @spec task_resume_max_archive_entries() :: pos_integer()
  def task_resume_max_archive_entries,
    do: int_setting("taskResumeMaxArchiveEntries", @task_resume_max_archive_entries_default)

  @doc """
  Per-tool_call args cap for the `[assistant→tool_name] {args}` line in
  the rehydrated transcript. Truncates oversized args (e.g. multi-KB
  scripts) so a single noisy tool_call can't dominate the envelope.
  """
  @spec task_resume_args_cap() :: pos_integer()
  def task_resume_args_cap,
    do: int_setting("taskResumeArgsCap", @task_resume_args_cap_default)

  @doc """
  Maximum number of inactive tasks listed to the Swift classifier when
  asking whether a chain-start user message is a follow-up to one of
  them. Newest inactive tasks are kept first.
  """
  @spec task_resume_candidate_cap() :: pos_integer()
  def task_resume_candidate_cap,
    do: int_setting("taskResumeCandidateCap", @task_resume_candidate_cap_default)

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
  Global per-LLM-call attempt budget (across within-account retries
  AND cross-account rotation cycles). Default 6.
  """
  @spec llm_total_attempts() :: pos_integer()
  def llm_total_attempts,
    do: int_setting("llmTotalAttempts", @llm_total_attempts_default)

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
  Outbound HTTP `receive_timeout` (ms) for both streaming and
  non-streaming LLM calls. Belt-and-suspenders cap so a stalled
  connection fails out rather than blocking forever. Default 300 s
  to absorb cold-loads of large local Ollama models when `num_ctx`
  forces a KV-cache reallocation.
  """
  @spec llm_receive_timeout_ms() :: pos_integer()
  def llm_receive_timeout_ms,
    do: int_setting("llmReceiveTimeoutMs", @llm_receive_timeout_ms_default)

  @doc "Wall-clock budget (ms) for Confidant's parallel web/memo pre-step."
  @spec confidant_pre_step_timeout_ms() :: pos_integer()
  def confidant_pre_step_timeout_ms,
    do: int_setting("confidantPreStepTimeoutMs", @confidant_pre_step_timeout_ms_default)

  @doc "Filesystem path to the deployment's memo master key file."
  @spec memo_master_key_path() :: String.t()
  def memo_master_key_path,
    do: string_setting("memoMasterKeyPath", @memo_master_key_path_default)

  @doc """
  Output-token ceiling (`num_predict`) applied to every assistant-mode
  LLM.stream call. A ceiling, not a reservation: unused headroom has
  no cost. Raise if long tool_calls (scripts, files) are getting cut
  mid-string; lower to harden against runaway generation.
  """
  @spec llm_num_predict_assistant() :: pos_integer()
  def llm_num_predict_assistant,
    do: int_setting("llmNumPredictAssistant", @llm_num_predict_assistant_default)

  @doc """
  Time-to-live (seconds) for a `request_input` form. The BE rejects
  submissions whose form is older than this; the FE renders the form
  as expired. The chain that emitted the form stays paused.
  """
  @spec request_input_ttl_secs() :: pos_integer()
  def request_input_ttl_secs,
    do: int_setting("requestInputTtlSecs", @request_input_ttl_secs_default)

  @doc "TTL (seconds) for pending OAuth2 state tokens before they expire."
  @spec oauth_state_ttl_secs() :: pos_integer()
  def oauth_state_ttl_secs,
    do: int_setting("oauthStateTtlSecs", @oauth_state_ttl_secs_default)

  @doc """
  Base URL the BE uses when constructing OAuth2 redirect URIs.
  Combined with a state token as `<base>/oauth/callback/<state>`.
  Must match the redirect URI (or its prefix) registered with the
  provider. Genuinely per-deployment — the BE listens on a single
  host; per-user OAuth App credentials are stored separately in
  `user_credentials`.
  """
  @spec oauth_redirect_base_url() :: String.t()
  def oauth_redirect_base_url,
    do: string_setting("oauth_redirect_base_url", @oauth_redirect_base_url_default)

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

  @doc "Hard cap (chars) on raw web-search-results text injected into the Confidant turn."
  @spec web_results_max_chars() :: pos_integer()
  def web_results_max_chars,
    do: int_setting("webResultsMaxChars", @web_results_max_chars_default)

  @doc "Target chunk size (tokens) for `/index` (knowledge-scope) ingestion."
  @spec kb_chunk_tokens() :: pos_integer()
  def kb_chunk_tokens, do: int_setting("kbChunkTokens", @kb_chunk_tokens_default)

  @doc "Overlap (tokens) between adjacent `/index` chunks."
  @spec kb_chunk_overlap_tokens() :: pos_integer()
  def kb_chunk_overlap_tokens, do: int_setting("kbChunkOverlapTokens", @kb_chunk_overlap_tokens_default)

  @doc """
  Target chunk size (tokens) for `/memo` (memo-scope) ingestion.
  Much smaller than `kb_chunk_tokens` because memos are short
  personal facts, not long documents — see the @kb_memo_chunk_*
  comment block above.
  """
  @spec kb_memo_chunk_tokens() :: pos_integer()
  def kb_memo_chunk_tokens, do: int_setting("kbMemoChunkTokens", @kb_memo_chunk_tokens_default)

  @doc "Overlap (tokens) between adjacent `/memo` chunks."
  @spec kb_memo_chunk_overlap_tokens() :: pos_integer()
  def kb_memo_chunk_overlap_tokens, do: int_setting("kbMemoChunkOverlapTokens", @kb_memo_chunk_overlap_tokens_default)

  @doc "Default top-N for retrieve_knowledge / retrieve_memo searches."
  @spec kb_top_n() :: pos_integer()
  def kb_top_n, do: int_setting("kbTopN", @kb_top_n_default)

  @doc "Maximum BFS depth for `/index <url>` deep-crawl. Start URL is depth 0."
  @spec learn_url_max_depth() :: pos_integer()
  def learn_url_max_depth, do: int_setting("learnUrlMaxDepth", @learn_url_max_depth_default)

  @doc "Maximum total pages indexed per `/index <url>` invocation."
  @spec learn_url_max_pages() :: pos_integer()
  def learn_url_max_pages, do: int_setting("learnUrlMaxPages", @learn_url_max_pages_default)

  @doc "Parallel page fetches per crawl. Default 1 (strict sequential — one progress row at a time on the FE)."
  @spec learn_url_concurrency() :: pos_integer()
  def learn_url_concurrency, do: int_setting("learnUrlConcurrency", @learn_url_concurrency_default)

  # ── web_crawl tool ──────────────────────────────────────────────────

  @doc "Default `max_pages` for `web_crawl`; hard-capped by `web_crawl_max_pages_hard_cap/0`."
  @spec web_crawl_max_pages_default() :: pos_integer()
  def web_crawl_max_pages_default,
    do: int_setting("webCrawlMaxPagesDefault", @web_crawl_max_pages_default)

  @doc "Absolute upper bound on `max_pages` regardless of caller arg — protects context."
  @spec web_crawl_max_pages_hard_cap() :: pos_integer()
  def web_crawl_max_pages_hard_cap,
    do: int_setting("webCrawlMaxPagesHardCap", @web_crawl_max_pages_hard_cap)

  @doc "Default `max_depth` for `web_crawl`; hard-capped by `web_crawl_max_depth_hard_cap/0`."
  @spec web_crawl_max_depth_default() :: pos_integer()
  def web_crawl_max_depth_default,
    do: int_setting("webCrawlMaxDepthDefault", @web_crawl_max_depth_default)

  @doc "Absolute upper bound on `max_depth`."
  @spec web_crawl_max_depth_hard_cap() :: pos_integer()
  def web_crawl_max_depth_hard_cap,
    do: int_setting("webCrawlMaxDepthHardCap", @web_crawl_max_depth_hard_cap)

  @doc "Per-page text truncation cap for `web_crawl` results."
  @spec web_crawl_max_chars_per_page() :: pos_integer()
  def web_crawl_max_chars_per_page,
    do: int_setting("webCrawlMaxCharsPerPage", @web_crawl_max_chars_per_page_default)

  @doc "Delay between successive fetches in `web_crawl` (politeness to remote sites)."
  @spec web_crawl_per_fetch_delay_ms() :: non_neg_integer()
  def web_crawl_per_fetch_delay_ms,
    do: int_setting("webCrawlPerFetchDelayMs", @web_crawl_per_fetch_delay_ms_default)

  @doc "Total wall-clock budget per `web_crawl` invocation; returns what's been fetched at deadline."
  @spec web_crawl_total_timeout_ms() :: pos_integer()
  def web_crawl_total_timeout_ms,
    do: int_setting("webCrawlTotalTimeoutMs", @web_crawl_total_timeout_ms_default)

  @doc "Top-K outbound links followed per `web_crawl` depth boundary (the focused-crawl pruning factor)."
  @spec web_crawl_branch_factor() :: pos_integer()
  def web_crawl_branch_factor,
    do: int_setting("webCrawlBranchFactor", @web_crawl_branch_factor_default)

  @doc """
  Cap on memo hits included in the `<augmented_facts type="memo">`
  block injected into Confidant prompts (auto-retrieve pre-step). Top-K is the
  ONLY gate — no score floor (the downstream LLM judges relevance
  from content, see specs/commands.md § Confidant memo auto-retrieve).
  This is a safety against
  many-similar-entry memo stores bloating the prompt.
  """
  @spec memo_context_top_k() :: pos_integer()
  def memo_context_top_k,
    do: int_setting("memoContextTopK", @memo_context_top_k_default)

  @doc "MMR candidate pool size — how many top-cosine hits get considered before MMR-picking the final `kb_top_n`."
  @spec kb_mmr_pool_size() :: pos_integer()
  def kb_mmr_pool_size, do: int_setting("kbMmrPoolSize", @kb_mmr_pool_size_default)

  @doc "MMR diversity / relevance trade-off in [0.0, 1.0]. 1.0 = pure relevance, 0.0 = pure novelty."
  @spec kb_mmr_lambda() :: float()
  def kb_mmr_lambda, do: float_setting("kbMmrLambda", @kb_mmr_lambda_default)

  @doc "Embedding vector dimension. Must match the embedding model's output. Changing this requires reindex."
  @spec kb_embedding_dim() :: pos_integer()
  def kb_embedding_dim, do: int_setting("kbEmbeddingDim", @kb_embedding_dim_default)

  @doc "How many texts the embedder packs into a single /embeddings request."
  @spec kb_embedding_batch_size() :: pos_integer()
  def kb_embedding_batch_size, do: int_setting("kbEmbeddingBatchSize", @kb_embedding_batch_size_default)

  @doc "Cosine threshold above which two inline-text sources merge into one. See specs/vector_kb.md."
  @spec kb_text_merge_threshold() :: float()
  def kb_text_merge_threshold, do: float_setting("kbTextMergeThreshold", @kb_text_merge_threshold_default)

  @doc "Cap on concurrent background relearn jobs."
  @spec kb_relearn_concurrency() :: pos_integer()
  def kb_relearn_concurrency, do: int_setting("kbRelearnConcurrency", @kb_relearn_concurrency_default)

  @doc "Minimum seconds between BG refreshes for the same kb_sources row (Primitive 0.2 debounce)."
  @spec bg_refresh_min_interval_s() :: pos_integer()
  def bg_refresh_min_interval_s,
    do: int_setting("bgRefreshMinIntervalSecs", @bg_refresh_min_interval_s_default)

  @doc "User's chosen video detail level from admin settings. Returns 'low', 'medium', or 'high'."
  @spec video_detail() :: String.t()
  def video_detail do
    settings = load()
    case settings["videoDetail"] do
      v when v in ["low", "medium", "high"] -> v
      _ -> "medium"
    end
  end

  @doc """
  Canonical `<pool>::<model>` strings of all built-in system models in
  the `ollama-cloud` pool. Used by the FE model picker to render the
  baked-in cloud roster (operator-added pools/models extend this list
  but aren't surfaced here).
  """
  @spec system_model_names() :: [String.t()]
  def system_model_names do
    @defaults
    |> Map.values()
    |> Enum.uniq()
    |> Enum.filter(fn m -> String.starts_with?(m, "ollama-cloud::") end)
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

  @doc """
  Per-org settings (Primitive 0.1). Reads `organizations.settings_json`
  layered over install-wide `admin_cloud_settings`. Per-key
  precedence: org override → install-wide → baked-in `@defaults`
  constant. Returns the merged map; pass it to the same
  `int_setting / bool_setting / float_setting / string_setting`
  shape via `get_in/2` if you need a single key.

  Falls back to the install-wide map if `org_id` is nil, empty, or
  not found.
  """
  @spec load_for_org(String.t() | nil) :: map()
  def load_for_org(nil), do: load()
  def load_for_org(""), do: load()

  def load_for_org(org_id) when is_binary(org_id) do
    install_wide = load()

    case org_overrides(org_id) do
      m when is_map(m) and map_size(m) > 0 -> Map.merge(install_wide, m)
      _ -> install_wide
    end
  end

  @doc """
  Pick a single setting with org-aware precedence: org override →
  install-wide → bound `default`. Mirrors the private `*_setting`
  helpers used by every accessor; exposed so per-org call sites can
  read a single key without re-implementing the merge.
  """
  @spec for_org(String.t() | nil, String.t(), any()) :: any()
  def for_org(org_id, key, default) when is_binary(key) do
    case load_for_org(org_id) |> Map.get(key) do
      nil -> default
      ""  -> default
      v   -> v
    end
  end

  defp org_overrides(org_id) do
    case query!(Repo, "SELECT settings_json FROM organizations WHERE id=?", [org_id]).rows do
      [[json]] when is_binary(json) and json != "" -> Jason.decode!(json)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end
end
