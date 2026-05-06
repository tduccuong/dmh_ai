# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init do
  require Logger
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  @db_dir "/data/db"

  def run do
    File.mkdir_p(@db_dir)
    File.mkdir_p(DmhAi.Constants.assets_dir())

    create_tables()
    seed_admin()
    seed_pools()
    seed_oauth_catalog()
  end

  # NOTE — this module describes the schema as a fresh install only.
  # Schema changes between releases are applied as one-off operator-
  # run DB scripts; never as auto-running migrations on boot.

  defp create_tables do
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      name TEXT,
      model TEXT,
      messages TEXT DEFAULT '[]',
      context TEXT,
      user_id TEXT DEFAULT '',
      mode TEXT DEFAULT 'confidant',
      stream_buffer TEXT,                   -- partial final-answer tokens being streamed from the LLM; NULL when idle
      stream_buffer_ts INTEGER,             -- last stream_buffer update ts (ms); used by FE polling to detect change
      thinking_buffer TEXT,                 -- partial chain-of-thought tokens streamed alongside stream_buffer; NULL when no thinking active. See architecture.md §Polling-based delivery.
      thinking_buffer_ts INTEGER,           -- last thinking_buffer update ts (ms)
      tool_history TEXT DEFAULT NULL,       -- JSON: last-N-turn tool_call / tool_result messages for context retention
      created_at INTEGER,
      updated_at INTEGER DEFAULT 0
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      name TEXT,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user',
      profile TEXT DEFAULT '',
      preferences TEXT,                       -- per-user JSON blob: token-saving toggle, future personal prefs
      last_profile_extracted_msg_ts INTEGER,  -- ProfileExtractor watermark
      browser_consent_at INTEGER,             -- consent gate for browser_task tool
      browser_consent_text_hash TEXT,         -- sha256 of accepted consent text; mismatch re-prompts
      memo_kdf_salt BLOB,                     -- per-user PBKDF2 salt for the memo wrap-key
      memo_wrapped_mmk BLOB,                  -- master memo key wrapped under the wrap-key (0x01 ‖ iv ‖ tag ‖ ct)
      unix_uid INTEGER,                       -- per-user Linux UID inside the sandbox (≥ 10001); allocated lazily
      password_changed INTEGER DEFAULT 0,
      deleted INTEGER DEFAULT 0,
      created_at INTEGER
    )
    """)
    query!(Repo,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_unix_uid ON users (unix_uid) WHERE unix_uid IS NOT NULL")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS auth_tokens (
      token TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      created_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS blocked_domains (
      domain TEXT PRIMARY KEY,
      reason TEXT,
      timeout_count INTEGER DEFAULT 0,
      added_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_fact_counts (
      user_id TEXT NOT NULL,
      topic TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (user_id, topic)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS image_descriptions (
      session_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      name TEXT,
      description TEXT NOT NULL,
      created_at INTEGER,
      PRIMARY KEY (session_id, file_id)
    )
    """)

    query!(Repo, "CREATE UNIQUE INDEX IF NOT EXISTS idx_image_descriptions_name ON image_descriptions (session_id, name)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS video_descriptions (
      session_id TEXT NOT NULL,
      file_id TEXT NOT NULL,
      name TEXT,
      description TEXT NOT NULL,
      created_at INTEGER,
      PRIMARY KEY (session_id, file_id)
    )
    """)

    query!(Repo, "CREATE UNIQUE INDEX IF NOT EXISTS idx_video_descriptions_name ON video_descriptions (session_id, name)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_token_stats (
      session_id TEXT PRIMARY KEY,
      user_id TEXT,
      master_rx_tokens INTEGER DEFAULT 0,
      master_tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS worker_token_stats (
      session_id TEXT NOT NULL,
      task_id     TEXT NOT NULL DEFAULT '',
      worker_id  TEXT NOT NULL,
      user_id    TEXT,
      description TEXT,
      rx_tokens  INTEGER DEFAULT 0,
      tx_tokens  INTEGER DEFAULT 0,
      updated_at INTEGER,
      PRIMARY KEY (session_id, task_id, worker_id)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS tasks (
      task_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      task_num INTEGER,                        -- per-session monotonic from 1; display label (1), (2), …
      task_type TEXT NOT NULL,                 -- 'one_off' | 'periodic'
      intvl_sec INTEGER NOT NULL DEFAULT 0,
      task_title TEXT,
      task_spec TEXT NOT NULL,
      task_status TEXT NOT NULL DEFAULT 'pending',
                                               -- 'pending' | 'ongoing' | 'paused'
                                               -- | 'done' | 'cancelled'
      task_result TEXT,
      time_to_pickup INTEGER,                  -- unix ms; when to next pick up this task
                                               -- (periodic next cycle; one_off future-dated)
      language TEXT NOT NULL DEFAULT 'en',
      attachments TEXT DEFAULT NULL,           -- JSON array of workspace/data paths (structured; not parsed from spec)
      back_to_when_done_task_num INTEGER,      -- Anchor back-reference.
                                               -- Set at pickup_task time when a DIFFERENT task was the
                                               -- current anchor; read at complete/cancel/pause time to
                                               -- restore that prior anchor. Nullable — free mode when nil.
                                               -- See architecture.md §Anchor mutation via back_to_when_done.
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_session ON tasks (session_id, task_status)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks (user_id, task_status)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_tasks_pickup ON tasks (task_status, time_to_pickup)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      task_id TEXT,                           -- nullable: direct-response turns have no task
      kind TEXT NOT NULL,                     -- 'tool' | 'thinking' | 'summary' | 'chain_aborted'
      status TEXT,                            -- 'pending' | 'done' (tool only — mutated in place)
      label TEXT,                             -- human-readable one-liner for FE rendering
      sub_labels TEXT DEFAULT NULL,           -- JSON array of sub-activity labels (for tools with parallel internals)
      hidden INTEGER NOT NULL DEFAULT 0,      -- 1 = persisted for audit only, never shown in the FE timeline
      duration_ms INTEGER,                    -- wall-clock tool-execution duration; stamped on the pending→done flip. Null for non-tool rows.
      ts INTEGER NOT NULL
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_task ON session_progress (task_id, id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_progress_session ON session_progress (session_id, ts)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS user_credentials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      target TEXT NOT NULL,                  -- free-form label: host+user, service name, API name
      account TEXT NOT NULL DEFAULT '',      -- per-account label (email/login from provider userinfo); '' for non-account creds (api_key etc.)
      kind TEXT NOT NULL,                    -- free-form: 'ssh_key' | 'user_pass' | 'api_key' | 'oauth2' | …
      payload TEXT NOT NULL,                 -- plaintext JSON, shape determined by `kind`
      notes TEXT,                            -- free-form notes from the assistant (why/when/how to use)
      expires_at INTEGER,                    -- optional unix ms expiry (OAuth2 access tokens etc.); NULL = non-expiring
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE(user_id, target, account)
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_user_credentials_user ON user_credentials (user_id)")

    # Pending OAuth2 state tokens for the connect_mcp flow. One
    # row per in-flight authorization. Carries everything needed to
    # exchange the code and attach the service to the originating
    # task without re-doing discovery: PKCE verifier, client_id (and
    # optional client_secret), the cached ASM doc, the canonical
    # resource id, and the (user_id, session_id, anchor_task_id,
    # alias) the connection is being established for. Single-use —
    # the callback handler deletes the row on success. TTL via
    # `expires_at` (default `oauthStateTtlSecs`, 600 s).
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pending_oauth_states (
      state              TEXT PRIMARY KEY,
      user_id            TEXT NOT NULL,
      session_id         TEXT NOT NULL,
      anchor_task_id     TEXT NOT NULL,
      alias              TEXT NOT NULL,
      canonical_resource TEXT NOT NULL,
      server_url         TEXT NOT NULL,
      pkce_verifier      TEXT NOT NULL,
      client_id          TEXT NOT NULL,
      client_secret      TEXT,
      asm_json           TEXT NOT NULL,
      scopes             TEXT,
      redirect_uri       TEXT NOT NULL,
      flow_kind          TEXT NOT NULL DEFAULT 'mcp',
      created_at         INTEGER NOT NULL,
      expires_at         INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_pending_oauth_states_user ON pending_oauth_states (user_id)")

    # Curated OAuth-service catalog. Operator-managed: each row is a
    # service the operator has registered an OAuth app with (Google
    # Cloud Console, Slack app config, etc.). The model never sees the
    # client_id/client_secret; it just calls authorize_service(<host>)
    # and the runtime picks the right entry by `host_match`. Per-user
    # tokens land in user_credentials at target="oauth:<host>" — no
    # admin involvement per user.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS oauth_catalog (
      id                     INTEGER PRIMARY KEY AUTOINCREMENT,
      slug                   TEXT NOT NULL UNIQUE,
      display_name           TEXT NOT NULL,
      host_match             TEXT NOT NULL,
      authorization_endpoint TEXT NOT NULL,
      token_endpoint         TEXT NOT NULL,
      scopes_default         TEXT NOT NULL DEFAULT '[]',
      client_id              TEXT NOT NULL DEFAULT '',
      client_secret          TEXT,
      extra_auth_params      TEXT NOT NULL DEFAULT '{}',
      extra_token_params     TEXT NOT NULL DEFAULT '{}',
      -- Userinfo discovery for the multi-account flow. After token
      -- exchange, the OAuth callback handler GETs `userinfo_endpoint`
      -- with the access token and reads the field at the dotted path
      -- `userinfo_field_path` to populate `user_credentials.account`.
      -- Both NULL = the provider has no userinfo endpoint we know how
      -- to call; the credential row is stored with `account=''` (the
      -- unlabelled default). Operators can edit these via the admin
      -- catalog UI when adding new providers.
      userinfo_endpoint      TEXT,
      userinfo_field_path    TEXT,
      enabled                INTEGER NOT NULL DEFAULT 0,
      created_ts             INTEGER NOT NULL,
      updated_ts             INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_oauth_catalog_host ON oauth_catalog (host_match)")

    # Per-user authorized external services. One row per service the
    # user has ever authorized. Survives sessions, restarts, task
    # lifecycles. Authorization here is necessary but not sufficient
    # for the LLM to see the service's tools — task_services must
    # also bind the service to the active task. `server_tools_json`
    # is the last-known tools/list result; `asm_json` caches the
    # authorization-server metadata for the refresh hook.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS authorized_services (
      user_id                TEXT NOT NULL,
      alias                  TEXT NOT NULL,
      canonical_resource     TEXT NOT NULL,
      server_url             TEXT NOT NULL,
      asm_json               TEXT,
      server_tools_json      TEXT,
      server_tools_cached_at INTEGER,
      -- Lifecycle: 'authorized' (token works) | 'needs_auth' (token
      -- refresh failed AS-side; model must call connect_mcp to
      -- recover). `tools_for_task/2` filters out needs_auth services
      -- so the LLM doesn't emit names it can no longer invoke; the
      -- §Authorized MCP services context block surfaces them with a
      -- `[needs re-auth]` annotation so the model knows to act.
      -- `authorize/5` resets to 'authorized' on re-auth.
      status                 TEXT NOT NULL DEFAULT 'authorized',
      created_ts             INTEGER NOT NULL,
      PRIMARY KEY (user_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_user ON authorized_services (user_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_resource ON authorized_services (canonical_resource)")

    # Task ↔ authorized-service junction. One row per service
    # attached to a task. Per-turn tool catalog filters to services
    # in this table for the current anchor task; complete_task /
    # cancel_task drop every row for that task.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS task_services (
      task_id     TEXT NOT NULL,
      user_id     TEXT NOT NULL,
      alias       TEXT NOT NULL,
      attached_ts INTEGER NOT NULL,
      PRIMARY KEY (task_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_task_services_user ON task_services (user_id, alias)")

    # Admin-curated MCP catalog. Each row is a blessed service —
    # admin sets up name + URL + optional metadata, clicks Enable to
    # run a preflight probe (DmhAi.MCP.Probe) which classifies the
    # service as :open / :gated / :not_mcp and persists auth_kind
    # and any AS metadata harvested during the probe. The chat tool
    # `connect_mcp(slug:)` reads this row and skips PRM/ASM
    # discovery, walking users straight into auth.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS mcp_catalog (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      slug              TEXT    NOT NULL UNIQUE,
      name              TEXT    NOT NULL,
      description       TEXT,
      mcp_url           TEXT    NOT NULL,
      icon_url          TEXT,
      categories        TEXT,                          -- JSON array of strings
      enabled           INTEGER NOT NULL DEFAULT 0,    -- 0/1
      auth_kind         TEXT,                          -- 'none' | 'oauth' | 'api_key' | NULL
      auth_metadata     TEXT,                          -- JSON object (PRM hint URL, AS endpoint, scopes…)
      last_probe_status TEXT,                          -- 'open' | 'gated' | 'not_mcp' | 'error' | NULL
      last_probe_error  TEXT,                          -- human-readable error from the probe attempt
      last_probe_at     INTEGER,                       -- ms epoch
      created_at        INTEGER NOT NULL,
      updated_at        INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_mcp_catalog_enabled ON mcp_catalog (enabled)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS model_behavior_stats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role          TEXT NOT NULL,              -- 'assistant' | 'confidant' | 'web_search' | 'compactor' | …
      model         TEXT NOT NULL,              -- routed string, e.g. 'ollama::cloud::gpt-oss:120b-cloud'
      issue_type    TEXT NOT NULL,              -- 'tool_call_schema' | 'task_discipline' | …
      tool_name     TEXT NOT NULL DEFAULT '',   -- tool involved (e.g. 'create_task'); '' for non-tool issues
      count         INTEGER NOT NULL DEFAULT 0,
      first_seen_at INTEGER NOT NULL,
      last_seen_at  INTEGER NOT NULL,
      UNIQUE(role, model, issue_type, tool_name)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_model_behavior_stats_model ON model_behavior_stats (model, count DESC)")

    # Per-task raw message archive. Compaction + tool_history flush
    # write chain-produced messages here, keyed by task, so
    # `fetch_task(N)` can replay a task's history verbatim even after
    # the master session has been compacted and the rolling
    # tool_history window evicted them. See architecture.md §Task
    # state continuity across chains.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS task_chain_archive (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id       TEXT NOT NULL,               -- cryptic BE id (FK to tasks.task_id)
      session_id    TEXT NOT NULL,
      original_ts   INTEGER NOT NULL,            -- the message's own ts when originally written
      role          TEXT NOT NULL,               -- 'user' | 'assistant' | 'tool'
      content       TEXT,                        -- nullable: tool_calls-only assistant msgs
      tool_calls    TEXT,                        -- JSON string, present on assistant with tool_calls
      tool_call_id  TEXT,                        -- present on role='tool'
      archived_at   INTEGER NOT NULL             -- unix ms when compaction wrote this row
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_task_chain_archive_task_ts ON task_chain_archive (task_id, original_ts)")

    # Vector knowledge base — see specs/vector_kb.md.
    #
    #   kb_sources       — registry of every /wiki / /memo / save_memo
    #                      ingest. Source-of-truth for relearn flows.
    #                      `centroid` (averaged chunk embedding) gates
    #                      semantic-merge for inline-text ingest.
    #   kb_chunks_meta   — non-vector metadata for each chunk; rowid
    #                      links 1:1 to the corresponding kb_vec_* row.
    #   kb_vec_knowledge — vec0 virtual table holding the global vectors.
    #   kb_vec_memo      — vec0 virtual table for per-user memos.
    #   kb_seeds         — admin-curated URL list for one-click batch /wiki.
    #   kb_relearn_jobs  — dedup table for the background re-fetch supervisor.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_sources (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      scope        TEXT NOT NULL CHECK (scope IN ('knowledge', 'memo')),
      user_id      TEXT,
      source_kind  TEXT NOT NULL,
      source_ref   TEXT NOT NULL,
      title        TEXT,
      raw_text     TEXT,
      centroid     BLOB,
      tags         TEXT,
      indexed_at   INTEGER NOT NULL,
      UNIQUE(scope, user_id, source_ref)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_sources_scope ON kb_sources (scope, user_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_chunks_meta (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      scope        TEXT NOT NULL CHECK (scope IN ('knowledge', 'memo')),
      user_id      TEXT,
      source_id    INTEGER NOT NULL REFERENCES kb_sources(id) ON DELETE CASCADE,
      chunk_idx    INTEGER NOT NULL,
      chunk_text   TEXT NOT NULL,
      indexed_at   INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_source ON kb_chunks_meta (source_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_scope ON kb_chunks_meta (scope, user_id)")

    # vec0 virtual tables. Dimension is hard-coded; distance metric
    # is cosine (semantic similarity, magnitude-invariant — see
    # specs/vector_kb.md). Distance metric is fixed at table creation.
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_knowledge USING vec0(embedding float[1024] distance_metric=cosine)")
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_memo      USING vec0(embedding float[1024] distance_metric=cosine)")

    # FTS5 inverted index over chunk_text — feeds the BM25 leg of
    # hybrid search. Contentless table (text not duplicated; we
    # already have it in `kb_chunks_meta`); rowid mirrors
    # `kb_chunks_meta.id`. `contentless_delete=1` lets us issue
    # plain `DELETE FROM kb_fts WHERE rowid=?` on chunk delete.
    # Tokenizer `unicode61` handles diacritics + case-folding for
    # multilingual content (Vietnamese / German / etc.) — the
    # default tokenizer is ASCII-only and would index "đỏ" as
    # something useless.
    query!(Repo, """
    CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
      chunk_text,
      content='',
      contentless_delete=1,
      tokenize='unicode61 remove_diacritics 2'
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_seeds (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      url           TEXT NOT NULL UNIQUE,
      label         TEXT,
      tags          TEXT,
      last_run_at   INTEGER,
      last_status   TEXT,
      last_error    TEXT,
      created_at    INTEGER NOT NULL
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_relearn_jobs (
      source_ref   TEXT PRIMARY KEY,
      source_kind  TEXT NOT NULL,
      enqueued_at  INTEGER NOT NULL
    )
    """)

    # Pools — model-routing registry. See arch_wiki/dmh_ai/integrations.md
    # §API Pools. A pool bundles endpoint config + account rotation,
    # addressed in canonical model strings as <pool>::<model>. The
    # `protocol` column drives wire-format dispatch in
    # `DmhAi.Agent.LLM.adapter_for/1`.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pools (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      name             TEXT NOT NULL UNIQUE,
      protocol         TEXT NOT NULL,           -- 'openai' | 'ollama' | 'anthropic'
      base_url         TEXT NOT NULL,
      strategy         TEXT NOT NULL DEFAULT 'least_used',
      cooldown_seconds INTEGER NOT NULL DEFAULT 300,
      num_ctx          INTEGER,                 -- per-pool Ollama options.num_ctx;
                                                -- NULL = don't inject (server default applies)
      accounts         TEXT NOT NULL DEFAULT '[]',
                                                -- JSON array: [{name, api_key, throttled_until?, last_used_ts?}]
      models           TEXT NOT NULL DEFAULT '[]',
                                                -- JSON array of strings; static model
                                                -- list for endpoints that don't expose
                                                -- /models. Empty = discover live.
      rr_cursor        INTEGER NOT NULL DEFAULT 0,
                                                -- round-robin cursor (only used when strategy='round_robin')
      created_ts       INTEGER NOT NULL,
      updated_ts       INTEGER NOT NULL
    )
    """)
  end

  # Seed default pools on first boot. Importable from an operator-managed
  # pools.json (see load_pool_seeds/0 for path order). When no file is
  # found, only the `ollama-cloud` placeholder is inserted so the admin UI
  # has something to edit. Idempotent — re-run on every boot, but only
  # inserts pools that don't already exist by name. Pools whose
  # `protocol` is missing or invalid are skipped with a loud log line —
  # the seed loader does not auto-translate older shapes.
  defp seed_pools do
    existing = query!(Repo, "SELECT name FROM pools", []).rows |> List.flatten() |> MapSet.new()

    seeds = load_pool_seeds()
    valid_protocols = DmhAi.LLM.Pools.valid_protocols()

    now = System.os_time(:millisecond)

    Enum.each(seeds, fn pool ->
      cond do
        MapSet.member?(existing, pool["name"]) ->
          :ok

        pool["protocol"] not in valid_protocols ->
          Logger.error(
            "[DB.Init] pool seed `#{pool["name"] || "(unnamed)"}` skipped: " <>
              "protocol=#{inspect(pool["protocol"])} not in #{inspect(valid_protocols)}"
          )

        true ->
          query!(Repo, """
          INSERT INTO pools (name, protocol, base_url, strategy,
                             cooldown_seconds, num_ctx, accounts, models,
                             rr_cursor, created_ts, updated_ts)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
          """, [
            pool["name"],
            pool["protocol"],
            pool["base_url"],
            pool["strategy"] || "least_used",
            pool["cooldown_seconds"] || 300,
            pool["num_ctx"],
            Jason.encode!(pool["accounts"] || []),
            Jason.encode!(pool["models"] || []),
            now, now
          ])
          Logger.info("[DB.Init] seeded pool: #{pool["name"]}")
      end
    end)
  end

  # Look for an operator-managed pool seed file. Path order:
  #   1. $DMHAI_POOL_SEED  — explicit override
  #   2. /data/pools.json — operator file bind-mounted into the container
  #   3. ./temp/pools.json — repo-local copy used in dev
  # Falls back to a built-in placeholder set if none of those exist.
  defp load_pool_seeds do
    candidate_paths = [
      System.get_env("DMHAI_POOL_SEED"),
      "/data/pools.json",
      "temp/pools.json"
    ]
    |> Enum.reject(&is_nil/1)

    case Enum.find(candidate_paths, &File.exists?/1) do
      nil ->
        default_pool_seeds()

      path ->
        try do
          %{"pools" => pools} = path |> File.read!() |> Jason.decode!()
          Enum.map(pools, fn p ->
            accounts =
              (p["accounts"] || [])
              |> Enum.map(fn a ->
                %{
                  "name"    => a["name"] || a["api_key"] || "unknown",
                  "api_key" => a["api_key"] || a["apiKey"] || a["key"] || ""
                }
              end)

            Map.put(p, "accounts", accounts)
          end)
        rescue
          e ->
            Logger.warning("[DB.Init] pool seed file #{path} unreadable (#{Exception.message(e)}); using defaults")
            default_pool_seeds()
        end
    end
  end

  defp default_pool_seeds do
    [
      %{
        "name" => "ollama-cloud",
        "protocol" => "openai",
        "base_url" => "https://ollama.com/v1",
        "strategy" => "least_used",
        "cooldown_seconds" => 300,
        "accounts" => []
      }
    ]
  end

  # Curated OAuth catalog seed. Two-layer load:
  #
  #   1. priv/oauth_catalog_default.json — shipped with every release.
  #      Pre-populates ~20 popular providers (Google, Microsoft,
  #      GitHub, Slack, etc.), each with `enabled = 0` and empty
  #      credentials. The operator opens the admin UI and fills in
  #      client_id/secret to activate.
  #   2. Optional operator override file (env var or /data path)
  #      UPSERTed by slug — replaces the priv default for matching
  #      slugs and adds new ones.
  #
  # Only runs when the table is empty (idempotent for redeploys).
  # Subsequent edits go through the admin UI, not the seed loader.
  defp seed_oauth_catalog do
    %{rows: [[count]]} = query!(Repo, "SELECT COUNT(*) FROM oauth_catalog")
    if count == 0, do: do_seed_oauth_catalog()
  end

  defp do_seed_oauth_catalog do
    priv_seeds     = load_priv_oauth_catalog_seeds()
    operator_seeds = load_operator_oauth_catalog_seeds()

    # Operator overrides win on slug collision. Build a slug-keyed
    # map so the order is irrelevant; final list preserves operator
    # additions on top of priv defaults.
    by_slug =
      Enum.reduce(priv_seeds ++ operator_seeds, %{}, fn entry, acc ->
        Map.put(acc, entry["slug"], entry)
      end)

    final = Map.values(by_slug)

    if final == [] do
      Logger.info("[DB.Init] no oauth_catalog seeds found; catalog starts empty")
    else
      now = System.os_time(:millisecond)

      Enum.each(final, fn entry -> insert_oauth_catalog_row(entry, now) end)
    end
  end

  defp insert_oauth_catalog_row(entry, now) do
    scopes_json     = entry["scopes_default"] |> List.wrap() |> Jason.encode!()
    extra_auth      = (entry["extra_auth_params"]  || %{}) |> Jason.encode!()
    extra_token     = (entry["extra_token_params"] || %{}) |> Jason.encode!()

    try do
      query!(Repo, """
      INSERT INTO oauth_catalog
        (slug, display_name, host_match,
         authorization_endpoint, token_endpoint,
         scopes_default, client_id, client_secret,
         extra_auth_params, extra_token_params,
         userinfo_endpoint, userinfo_field_path,
         enabled, created_ts, updated_ts)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        entry["slug"],
        entry["display_name"],
        entry["host_match"],
        entry["authorization_endpoint"],
        entry["token_endpoint"],
        scopes_json,
        entry["client_id"] || "",
        entry["client_secret"],
        extra_auth,
        extra_token,
        entry["userinfo_endpoint"],
        entry["userinfo_field_path"],
        if(entry["enabled"] == true, do: 1, else: 0),
        now,
        now
      ])

      Logger.info("[DB.Init] seeded oauth_catalog: #{entry["slug"]}")
    rescue
      e ->
        Logger.warning("[DB.Init] oauth_catalog seed `#{entry["slug"]}` failed: #{Exception.message(e)}")
    end
  end

  # Read the always-shipped seed file from `priv/`. Lives inside the
  # release artifact so every fresh install has the popular providers
  # pre-listed (disabled, no secrets).
  defp load_priv_oauth_catalog_seeds do
    path = Path.join(:code.priv_dir(:dmh_ai), "oauth_catalog_default.json")
    read_oauth_catalog_seed_file(path, log_missing: false)
  end

  # Look for an OPTIONAL operator-managed override file. Path order:
  #   1. $DMHAI_OAUTH_CATALOG_SEED — explicit override
  #   2. /data/oauth_catalog.json — operator file bind-mounted into the container
  #   3. ./temp/oauth_catalog.json — repo-local copy used in dev
  # Operators normally use the admin UI; this file path is for
  # bulk imports / disaster recovery. Returns [] when no file is found.
  defp load_operator_oauth_catalog_seeds do
    [
      System.get_env("DMHAI_OAUTH_CATALOG_SEED"),
      "/data/oauth_catalog.json",
      "temp/oauth_catalog.json"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?/1)
    |> case do
      nil  -> []
      path -> read_oauth_catalog_seed_file(path, log_missing: true)
    end
  end

  defp read_oauth_catalog_seed_file(path, opts) do
    if File.exists?(path) do
      try do
        %{"services" => services} = path |> File.read!() |> Jason.decode!()
        List.wrap(services)
      rescue
        e ->
          Logger.warning("[DB.Init] oauth_catalog seed file #{path} unreadable (#{Exception.message(e)})")
          []
      end
    else
      if Keyword.get(opts, :log_missing, false) do
        Logger.info("[DB.Init] oauth_catalog seed file #{path} not present; skipping")
      end
      []
    end
  end

  defp seed_admin do
    result = query!(Repo, "SELECT id FROM users WHERE email=?", ["admin@dmhai.local"])

    if result.rows == [] do
      uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      password_hash = hash_password("dmh_ai")
      now = :os.system_time(:second)

      query!(Repo, """
      INSERT INTO users (id, email, name, password_hash, role, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """, [uid, "admin@dmhai.local", nil, password_hash, "admin", now])

      Logger.info("[DB] Seeded default admin user")
    end
  end

  # Python stores passwords as {salt_hex}:{hash_hex} where:
  # - salt_hex = secrets.token_hex(16)  — 32 hex chars
  # - hash_hex = hashlib.pbkdf2_hmac('sha256', password.encode(), salt_hex.encode(), 100_000).hex()
  # Note: salt passed to pbkdf2_hmac is salt_hex.encode() i.e. the hex string as UTF-8 bytes.
  defp hash_password(password) do
    salt_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt_hex, 100_000, 32)
    salt_hex <> ":" <> Base.encode16(key, case: :lower)
  end
end
