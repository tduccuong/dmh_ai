# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.DB.Init.Tables do
  @moduledoc """
  Canonical schema for a fresh install. One function — `create_all/0` —
  issues every `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`
  statement the running app needs. The module describes the schema as it
  exists today; schema changes between releases are applied as one-off
  operator-run DB scripts outside the app, never as auto-running migrations
  on boot.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 2]

  def create_all do
    # Organizations — Primitive 0.1. Every scoped artefact in the
    # system points back here via `org_id`. NEVER NULL on any scoped
    # row. Fresh installs auto-create one row via BootstrapSeed so
    # the rest of the schema can rely on the foreign key existing.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS organizations (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      settings_json TEXT,
      created_at    INTEGER NOT NULL
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY NOT NULL,
      name TEXT,
      model TEXT,
      messages TEXT DEFAULT '[]',
      context TEXT,
      user_id TEXT DEFAULT '',
      mode TEXT DEFAULT 'assistant',
      -- Streaming state (partial final-answer + chain-of-thought
      -- tokens during a turn) lives in DmhAi.Agent.EphemeralCache
      -- ETS, NOT this table. See architecture.md §Streaming state
      -- lives in ETS, not the DB. Per-token DB writes monopolised
      -- SQLite's single-writer slot in WAL mode.
      cancelled_at INTEGER,                  -- Stop-button stamp; chain loop aborts on its next iteration
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
      email_aliases TEXT,                     -- JSON array of additional emails the user is known by in third-party SaaS (Primitive 0.9). Default NULL = no aliases. Admin-only edit. Identities.resolve/2 tries primary then aliases.
      name TEXT,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'user',       -- install-level superuser flag: 'admin' = admin of the deployment itself; 'user' = regular user. Distinct from org_role.
      org_id TEXT NOT NULL,                    -- FK organizations.id; never NULL (Primitive 0.1)
      org_role TEXT NOT NULL DEFAULT 'member', -- role within their org: 'member' | 'manager' | 'admin'
      profile TEXT DEFAULT '',
      preferences TEXT,                       -- per-user JSON blob: token-saving toggle, future personal prefs
      last_profile_extracted_msg_ts INTEGER,  -- ProfileExtractor watermark
      memo_kdf_salt BLOB,                     -- per-user PBKDF2 salt for the memo wrap-key
      memo_wrapped_mmk BLOB,                  -- master memo key wrapped under the wrap-key (0x01 ‖ iv ‖ tag ‖ ct)
      unix_uid INTEGER,                       -- per-user Linux UID inside the sandbox (≥ 10001); allocated lazily
      password_changed INTEGER DEFAULT 0,
      deleted INTEGER DEFAULT 0,
      created_at INTEGER
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_users_org ON users (org_id)")
    query!(Repo,
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_unix_uid ON users (unix_uid) WHERE unix_uid IS NOT NULL")

    # Bearer tokens are stored as sha256 hashes (lowercase hex), not
    # the raw 256-bit token returned to the client. Token entropy is
    # already 256 bits via :crypto.strong_rand_bytes(32) in
    # post_login, so plain sha256 (no salt, no PBKDF2) is the right
    # fit — there's nothing to brute-force at that entropy. The hash
    # converts a SQL-exfil into "no live tokens leaked"; without it,
    # `SELECT * FROM auth_tokens` is every active session.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS auth_tokens (
      token_hash TEXT PRIMARY KEY,
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

    # Per-tier token accounting. One row per (session_id, user_id) pair,
    # plus one synthetic per-user row keyed by the sentinel session_id
    # `_user_global` for LLM calls made outside a session (ProfileExtractor,
    # KB ingest tagger). `get_global_stats/1` sums across ALL rows for the
    # user — including the sentinel — to give a complete user-global total.
    # Tier names are the atoms `:master | :swift | :oracle | :vision |
    # :embedding`; TokenTracker.add/5 picks the column pair by atom.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_token_stats (
      session_id TEXT PRIMARY KEY,
      user_id TEXT,
      master_rx_tokens    INTEGER DEFAULT 0,
      master_tx_tokens    INTEGER DEFAULT 0,
      swift_rx_tokens     INTEGER DEFAULT 0,
      swift_tx_tokens     INTEGER DEFAULT 0,
      oracle_rx_tokens    INTEGER DEFAULT 0,
      oracle_tx_tokens    INTEGER DEFAULT 0,
      vision_rx_tokens    INTEGER DEFAULT 0,
      vision_tx_tokens    INTEGER DEFAULT 0,
      embedding_rx_tokens INTEGER DEFAULT 0,
      embedding_tx_tokens INTEGER DEFAULT 0,
      updated_at INTEGER
    )
    """)


    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_progress (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      kind TEXT NOT NULL,                     -- 'tool' | 'thinking' | 'summary' | 'chain_aborted' | 'chain_end'
      status TEXT,                            -- 'pending' | 'done' (tool only — mutated in place)
      label TEXT,                             -- human-readable one-liner for FE rendering
      sub_labels TEXT DEFAULT NULL,           -- JSON array of sub-activity labels (for tools with parallel internals)
      hidden INTEGER NOT NULL DEFAULT 0,      -- 1 = persisted for audit only, never shown in the FE timeline
      duration_ms INTEGER,                    -- wall-clock tool-execution duration; stamped on the pending→done flip. Null for non-tool rows.
      ts INTEGER NOT NULL
    )
    """)

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

    # Primitive 0.9 — Identities. Cache mapping a DMH-AI org user
    # to the same person's identifier inside a connector vendor
    # (HubSpot owner_id, Slack U02ABC..., Google Workspace directory
    # id, M365 AAD object id, …). One row per (org, user, slug).
    # Populated on demand by `Identities.resolve/2` via the
    # connector's manifest-declared `identity_lookup` function;
    # admin can write directly via POST /admin/identities for
    # manual overrides (`resolved_via='manual_override'`, `ttl_s=0`).
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS connector_identities (
      org_id          TEXT NOT NULL,                  -- isolation key
      user_id         TEXT NOT NULL,                  -- DMH-AI users.id
      connector_slug  TEXT NOT NULL,                  -- e.g. "hubspot", "google_workspace"
      external_id     TEXT NOT NULL,                  -- the vendor's identifier
      resolved_via    TEXT NOT NULL,                  -- "primary_email" | "alias:<n>" | "manual_override"
      cached_at       INTEGER NOT NULL,               -- UTC seconds
      ttl_s           INTEGER NOT NULL DEFAULT 86400, -- 24h default; 0 = permanent (manual override)
      PRIMARY KEY (org_id, user_id, connector_slug)
    )
    """)

    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_connector_identities_slug ON connector_identities (connector_slug)")

    # Pending OAuth2 state tokens for the connect_mcp flow. One
    # row per in-flight authorization. Carries everything needed to
    # exchange the code and attach the service to the originating
    # session without re-doing discovery: PKCE verifier, client_id (and
    # optional client_secret), the cached ASM doc, the canonical
    # resource id, and the (user_id, session_id, alias) the connection
    # is being established for. Single-use — the callback handler
    # deletes the row on success. TTL via `expires_at` (default
    # `oauthStateTtlSecs`, 600 s).
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pending_oauth_states (
      state              TEXT PRIMARY KEY,
      user_id            TEXT NOT NULL,
      session_id         TEXT NOT NULL,
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
    # client_id/client_secret; it just calls authorize_service(<slug>)
    # and the runtime picks the right entry by `host_match`. Per-user
    # tokens land in user_credentials at target="oauth:<slug>" — no
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
    # user has ever authorized. Survives sessions, restarts.
    # Authorization here is necessary but not sufficient for the LLM
    # to see the service's tools — `session_services` must also bind
    # the service to the active session. `server_tools_json` is the
    # last-known tools/list result; `asm_json` caches the
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
      -- recover). `tools_for_session/2` filters out needs_auth
      -- services so the LLM doesn't emit names it can no longer
      -- invoke; the §Authorized MCP services context block surfaces
      -- them with a `[needs re-auth]` annotation so the model knows
      -- to act. `authorize/5` resets to 'authorized' on re-auth.
      status                 TEXT NOT NULL DEFAULT 'authorized',
      created_ts             INTEGER NOT NULL,
      PRIMARY KEY (user_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_user ON authorized_services (user_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_authorized_services_resource ON authorized_services (canonical_resource)")

    # Session ↔ authorized-service junction. One row per service
    # attached to a chat session. Per-turn tool catalog filters to
    # services in this table for the current session.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS session_services (
      session_id  TEXT NOT NULL,
      user_id     TEXT NOT NULL,
      alias       TEXT NOT NULL,
      attached_ts INTEGER NOT NULL,
      PRIMARY KEY (session_id, alias)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_session_services_user ON session_services (user_id, alias)")

    # Admin-curated MCP catalog. Each row is a blessed service —
    # admin sets up name + URL + optional metadata, clicks Enable to
    # run a preflight probe (DmhAi.MCP.Probe) which classifies the
    # service as :open / :gated / :not_mcp and persists auth_kind
    # and any AS metadata harvested during the probe. The chat tool
    # `connect_mcp(slug:)` reads this row and skips PRM/ASM
    # discovery, walking users straight into auth.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS mcp_catalog (
      id                   INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id               TEXT NOT NULL,                  -- FK organizations.id; per-org MCP catalog (Primitive 0.1)
      slug                 TEXT NOT NULL,
      name                 TEXT NOT NULL,
      description          TEXT,
      mcp_url              TEXT NOT NULL,
      icon_url             TEXT,
      categories           TEXT,                          -- JSON array of strings
      enabled              INTEGER NOT NULL DEFAULT 0,    -- 0/1; overall connector on/off
      enabled_capabilities TEXT,                          -- JSON array of capability ids; NULL = all enabled (admin-not-yet-curated)
      auth_kind            TEXT,                          -- 'none' | 'oauth' | 'api_key' | NULL
      auth_metadata        TEXT,                          -- JSON object (PRM hint URL, AS endpoint, scopes…)
      last_probe_status    TEXT,                          -- 'open' | 'gated' | 'not_mcp' | 'error' | NULL
      last_probe_error     TEXT,                          -- human-readable error from the probe attempt
      last_probe_at        INTEGER,                       -- ms epoch
      created_at           INTEGER NOT NULL,
      updated_at           INTEGER NOT NULL,
      UNIQUE(org_id, slug)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_mcp_catalog_enabled ON mcp_catalog (org_id, enabled)")

    # Connector functions catalog — the data layer for arch_wiki/dmh_ai/
    # sme/layer-W.md §L1 (function manifests). Each row is one
    # connector function's contract: args (with provenance), returns,
    # error classes, OAuth scopes. Populated by `Discovery.run/2` at
    # admin's click, seeded from `priv/connectors/<slug>/functions.json`
    # on first deploy when the table is empty for a slug.
    #
    # Source of truth = DB. The connector module's code carries the
    # discovery mechanism + runtime caller + shim translators ONLY;
    # the function contract itself lives here so vendor changes are
    # absorbed by an admin Discover click, not a code redeploy.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS connector_functions (
      id                     INTEGER PRIMARY KEY AUTOINCREMENT,
      connector_slug         TEXT NOT NULL,
      function_name          TEXT NOT NULL,
      permission             TEXT NOT NULL,                   -- 'read' | 'write' | 'admin'
      args_json              TEXT NOT NULL,                   -- {arg: {type, required, provenance, ...}}
      returns_json           TEXT NOT NULL,                   -- {field: type}
      error_classes_json     TEXT,
      scopes_required_json   TEXT,
      idempotency_key        TEXT,                            -- 'required' | 'none'
      vendor_endpoint_hint   TEXT,                            -- "POST /crm/v3/objects/deals" — diagnostics
      callable_from_json     TEXT,                            -- '[\"chat\",\"task\"]' | '[\"task\"]'
      poll_trigger_capable   INTEGER NOT NULL DEFAULT 0,
      cursor_arg             TEXT,
      cursor_response_path   TEXT,
      items_path             TEXT,
      min_poll_seconds       INTEGER,
      default_poll_seconds   INTEGER,
      discovered_at          INTEGER NOT NULL,
      discovered_by          TEXT NOT NULL DEFAULT 'seed',   -- 'seed' | user_id of admin who clicked
      UNIQUE(connector_slug, function_name)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_connector_functions_slug ON connector_functions (connector_slug)")

    # Per-user vendor metadata cache (§L2) — pipelines, custom
    # properties, owners, channels. Populated at compile time when
    # `inspect_function_property` resolves a `:vendor_enum` provenance.
    # Rows expire on `expires_at`; lazy-refresh on next lookup miss.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS connector_vendor_metadata (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      connector_slug    TEXT NOT NULL,
      user_id           TEXT NOT NULL,
      path              TEXT NOT NULL,                       -- dotted path: "deal.create.stage"
      schema_json       TEXT NOT NULL,                       -- {type, enum, description, source}
      discovered_at     INTEGER NOT NULL,
      expires_at        INTEGER,                              -- ms epoch; NULL = never expires
      UNIQUE(connector_slug, user_id, path)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_connector_vendor_metadata_lookup ON connector_vendor_metadata (connector_slug, user_id, path)")

    # Discovery run audit log. Every admin click on a Discover
    # button creates a row; FE polls (or subscribes) for status
    # transitions. Final state is success / failed with row counts
    # + error text for diagnostics.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS connector_discovery_runs (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      connector_slug    TEXT NOT NULL,
      layer             TEXT NOT NULL,                       -- 'functions' | 'metadata' | 'docs'
      status            TEXT NOT NULL,                       -- 'queued' | 'running' | 'success' | 'failed'
      started_at        INTEGER,
      completed_at      INTEGER,
      error_text        TEXT,
      records_affected  INTEGER,
      triggered_by      TEXT,                                 -- admin user_id; 'seed' for first-deploy fill
      created_at        INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_connector_discovery_runs_slug ON connector_discovery_runs (connector_slug, layer, created_at DESC)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS model_behavior_stats (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role          TEXT NOT NULL,              -- 'assistant' | 'confidant' | 'web_search' | 'compactor' | …
      model         TEXT NOT NULL,              -- routed string, e.g. 'ollama::cloud::gpt-oss:120b-cloud'
      issue_type    TEXT NOT NULL,              -- 'tool_call_schema' | 'arguments_decode' | …
      tool_name     TEXT NOT NULL DEFAULT '',   -- tool involved (e.g. 'run_script'); '' for non-tool issues
      count         INTEGER NOT NULL DEFAULT 0,
      first_seen_at INTEGER NOT NULL,
      last_seen_at  INTEGER NOT NULL,
      UNIQUE(role, model, issue_type, tool_name)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_model_behavior_stats_model ON model_behavior_stats (model, count DESC)")


    # Workflow store — per arch_wiki/dmh_ai/sme/layer-W.md.
    #
    # A workflow is an SME-authored automation plan, compiled by the
    # Assistant from natural-language descriptions and persisted here
    # in versioned form. Two tables:
    #
    #   workflows           — slug + display_name + current_version
    #                         + active_version. One row per logical
    #                         workflow.
    #   workflow_versions   — append-only history; one row per save.
    #                         ir_json holds the full compiled IR.
    #
    # active_version is set when the user explicitly arms a workflow
    # ("arm v3" in chat); NULL means "draft only, never fires."
    # current_version is the highest version saved so far; the next
    # save lands at current_version + 1.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflows (
      id              TEXT NOT NULL,                  -- slug, deterministic from display_name; PK with org_id
      org_id          TEXT NOT NULL,                  -- FK organizations.id
      display_name    TEXT NOT NULL,
      created_by      TEXT NOT NULL,                  -- FK users.id; the OWNER. Immutable.
                                                       -- Runtime executor uses this as caller_ctx.user_id;
                                                       -- "my X" in source prose binds to this user.
      current_version INTEGER NOT NULL,
      active_version  INTEGER,                        -- nullable; non-NULL when armed
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      PRIMARY KEY (org_id, id)
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_versions (
      workflow_id          TEXT NOT NULL,             -- FK workflows.id
      org_id               TEXT NOT NULL,             -- FK workflows.org_id (denormalised for cheap reads)
      version              INTEGER NOT NULL,
      ir_json              TEXT NOT NULL,             -- the full IR (trigger, nodes, edges, outputs)
      change_note          TEXT,                      -- one-line summary of THIS version's delta (e.g. "added approval gate before send")
      description          TEXT NOT NULL,             -- short prose summary of WHAT the workflow does — what the picker shows for the current_version. Required at upsert; the model writes one or two operator-readable sentences.
      compiled_at          INTEGER NOT NULL,
      compiled_in_session  TEXT NOT NULL,             -- the chat session that produced this version
      compiled_by_user_id  TEXT NOT NULL,             -- who edited this version (may differ from workflows.created_by)
      PRIMARY KEY (org_id, workflow_id, version)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_versions_session ON workflow_versions (compiled_in_session)")

    # Phase B — per-run state for the deterministic executor. One
    # row per workflow invocation. Bindings persisted at every step
    # boundary so an executor crash mid-run resumes at the last
    # successful step. `status` flips through running → completed |
    # failed | waiting | timed_out.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_run_state (
      id               TEXT PRIMARY KEY,                -- UUID
      workflow_id      TEXT NOT NULL,
      workflow_version INTEGER NOT NULL,
      org_id           TEXT NOT NULL,
      task_id          TEXT NOT NULL,                   -- wrapping task
      owner_user_id    TEXT NOT NULL,                   -- snapshot of workflows.created_by at run start
      trigger_payload  TEXT NOT NULL,                   -- JSON: data that triggered THIS instance
      bindings         TEXT NOT NULL,                   -- JSON {trigger, emits}
      current_node     INTEGER,                         -- where the executor is
      status           TEXT NOT NULL,                   -- spawned | running | waiting | paused | completed | failed | cancelled | timed_out
      paused           INTEGER NOT NULL DEFAULT 0,      -- user-set; executor checks before walking next node
      last_error       TEXT,                            -- structured envelope JSON on failure
      started_at       INTEGER NOT NULL,
      updated_at       INTEGER NOT NULL,
      completed_at     INTEGER
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_run_state_task ON workflow_run_state (task_id)")
    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_run_state_status ON workflow_run_state (status)")
    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_run_state_workflow ON workflow_run_state (org_id, workflow_id, started_at DESC)")

    # Subordinate table — open `wait` predicates for a run. A run
    # in `status='waiting'` has one or more rows here; matching events
    # (scheduler tick, webhook ingress, approval decision) resume
    # the run via Executor.resume_run/2.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_run_waits (
      run_id     TEXT NOT NULL,
      node_id    INTEGER NOT NULL,
      kind       TEXT NOT NULL,                          -- 'approval' | 'webhook' | 'schedule'
      predicate  TEXT NOT NULL,                          -- JSON
      expires_at INTEGER,                                -- NULL = no timeout
      PRIMARY KEY (run_id, node_id)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_run_waits_kind ON workflow_run_waits (kind)")

    # Per-step trace. One row per node the executor walks. Fed by
    # Executor.handle_step / handle_branch / handle_gate / handle_wait
    # at the start of each step (status='running') and updated to
    # terminal state (completed | failed | waiting | skipped) when
    # the step resolves. Surface for `/runs/:run_id` viewer + the
    # workflow-runs dashboard (#505).
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_run_steps (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id          TEXT NOT NULL,
      node_id         INTEGER NOT NULL,
      started_at      INTEGER NOT NULL,
      completed_at    INTEGER,                          -- NULL while running / waiting
      status          TEXT NOT NULL,                    -- running | waiting | completed | failed | skipped
      resolved_input  TEXT,                              -- JSON: args after Mustache substitution
      output          TEXT,                              -- JSON: emit map the step produced
      error           TEXT,                              -- JSON: structured error envelope if failed
      waiting_on      TEXT,                              -- JSON: for wait/gate, what's holding it
      duration_ms     INTEGER
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_run_steps_run ON workflow_run_steps (run_id, started_at)")

    # Trigger-detection state for poll/schedule triggers (and the
    # autonomous side of webhook delivery accounting). One row per
    # (org_id, workflow_id). The poller reads `last_cursor` to issue
    # the next "items since X" query, then writes the connector's
    # new cursor back. `last_fire_status` distinguishes a tick that
    # found new items (`ok`) from one that found nothing
    # (`no_new_items`) — useful for the dashboard's "last fired at"
    # display.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_trigger_state (
      org_id              TEXT NOT NULL,
      workflow_id         TEXT NOT NULL,
      last_cursor         TEXT,
      last_fired_at       INTEGER,
      last_fire_status    TEXT,                          -- 'ok' | 'error' | 'no_new_items'
      cursor_updated_at   INTEGER,
      PRIMARY KEY (org_id, workflow_id)
    )
    """)

    # Webhook event-id dedupe (replay protection). 24h retention via
    # the daily sweeper. Each incoming webhook is rejected with 200
    # OK if the (workflow_id, event_id) pair already exists.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS workflow_webhook_events (
      workflow_id   TEXT NOT NULL,
      event_id      TEXT NOT NULL,                       -- external system's idempotency key
      received_at   INTEGER NOT NULL,
      PRIMARY KEY (workflow_id, event_id)
    )
    """)

    query!(Repo,
      "CREATE INDEX IF NOT EXISTS idx_workflow_webhook_events_received ON workflow_webhook_events (received_at)")

    # Vector knowledge base — see specs/vector_kb.md.
    #
    # Per Primitive 0.1 (Hard scoping rule), the corpus splits into
    # two parallel halves:
    #
    #   KB side (org-shared, every employee in the org sees the same):
    #     kb_sources         — KB ingest registry, org-scoped.
    #     kb_chunks_meta     — chunk metadata for KB; rowid 1:1 to kb_vec_knowledge.
    #     kb_vec_knowledge   — vec0 virtual table holding org vectors.
    #     kb_fts             — FTS5 inverted index over KB chunk_text.
    #     kb_relearn_jobs    — dedup table for the background KB re-fetch supervisor.
    #
    #   Memo side (per-user-readable, org_id is audit context only):
    #     memo_sources       — memo ingest registry; carries org_id + user_id (both NOT NULL).
    #     memo_chunks_meta   — chunk metadata for memos; rowid 1:1 to kb_vec_memo.
    #     kb_vec_memo        — vec0 virtual table for memo vectors.
    #     memo_fts           — FTS5 inverted index over memo chunk_text.
    # `kb_sources` per Primitive 0.2:
    #   source_id              — stable normalised identifier (URL: lower-host no fragment;
    #                            file: sha256(org_id ‖ path); folder: connector-uri; text:
    #                            sha256(org_id ‖ title)). Unit of replace + removal.
    #   content_sha256         — sha256 over raw bytes; the idempotence gate.
    #   extracted_text_sha256  — sha256 over post-extractor text (PDF/docx extraction
    #                            normalised).
    #   chunker_config_version — pinned per source so a global default change can't
    #                            silently re-shape existing rows mid-corpus.
    #   embedder_model         — pinned per source for the same reason.
    #   parent_source_id       — set on folder member rows pointing at the containing
    #                            folder's source_id.
    #   last_seen_at           — bumped on every idempotent re-ingest (skip path).
    #   last_indexed_at        — bumped only when a re-ingest actually replaces chunks.
    #   last_check_at          — last BG refresh attempt timestamp (success or failure).
    #   last_check_failed_at   — null on success; set on upstream error.
    #   last_check_error       — short tag ('http_404' | 'connector_unauthorised' | 'timeout').
    #   created_by_user_id     — who ran /index to create the source.
    #   ingest_status          — 'queued'|'extracting'|'classified'|'structured'|'indexed'|'error'
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_sources (
      id                     INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id                 TEXT NOT NULL,
      source_id              TEXT NOT NULL,
      source_kind            TEXT NOT NULL,
      title                  TEXT,
      raw_text               TEXT,
      centroid               BLOB,
      tags                   TEXT,
      content_sha256         TEXT,
      extracted_text_sha256  TEXT,
      chunker_config_version TEXT,
      embedder_model         TEXT,
      parent_source_id       TEXT,
      -- Semantic classification of this source: JSON
      --   {"platform": "<connector-slug or null>", "category": "<category>"}
      -- where category ∈ "api-docs" | "sop" | "policy" | "workflow" | "spec" | "general".
      -- NULL = untagged ⇔ {platform: null, category: "general"}. Used by
      -- retrieval-time scope filters so a workflow-compile query
      -- doesn't latch onto third-party SaaS API docs. See
      -- arch_wiki/dmh_ai/knowledge.md §Source scope.
      source_scope           TEXT,
      last_seen_at           INTEGER,
      last_indexed_at        INTEGER,
      last_check_at          INTEGER,
      last_check_failed_at   INTEGER,
      last_check_error       TEXT,
      created_by_user_id     TEXT,
      ingest_status          TEXT NOT NULL DEFAULT 'indexed',
      indexed_at             INTEGER NOT NULL,
      UNIQUE(org_id, source_id)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_sources_org ON kb_sources (org_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_sources_parent ON kb_sources (parent_source_id)")

    # Admin "remove source" trail. Removed payload (chunks, vectors, FTS,
    # extracted_json, raw_text) is flushed by Ingest.remove_source!/2;
    # this table preserves the audit fact that a removal happened —
    # never the content itself.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_source_history (
      id                  INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id              TEXT NOT NULL,
      source_id           TEXT NOT NULL,
      source_kind         TEXT NOT NULL,
      removed_by_user_id  TEXT,
      reason              TEXT,
      removed_at          INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_source_history_org ON kb_source_history (org_id, removed_at)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_chunks_meta (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id       TEXT NOT NULL,
      source_id    INTEGER NOT NULL REFERENCES kb_sources(id) ON DELETE CASCADE,
      chunk_idx    INTEGER NOT NULL,
      chunk_text   TEXT NOT NULL,
      indexed_at   INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_source ON kb_chunks_meta (source_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_kb_chunks_meta_org ON kb_chunks_meta (org_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS memo_sources (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id       TEXT NOT NULL,                 -- audit context; the user's org at memo creation
      user_id      TEXT NOT NULL,                 -- the only reader; memo is encrypted per-user
      source_kind  TEXT NOT NULL,
      source_id    TEXT NOT NULL,                 -- natural key (sha256 of text)
      title        TEXT,
      raw_text     TEXT,
      centroid     BLOB,
      tags         TEXT,
      indexed_at   INTEGER NOT NULL,
      UNIQUE(user_id, source_id)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_memo_sources_user ON memo_sources (user_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_memo_sources_org ON memo_sources (org_id)")

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS memo_chunks_meta (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id       TEXT NOT NULL,
      user_id      TEXT NOT NULL,
      source_id    INTEGER NOT NULL REFERENCES memo_sources(id) ON DELETE CASCADE,
      chunk_idx    INTEGER NOT NULL,
      chunk_text   TEXT NOT NULL,
      indexed_at   INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_memo_chunks_meta_source ON memo_chunks_meta (source_id)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_memo_chunks_meta_user ON memo_chunks_meta (user_id)")

    # vec0 virtual tables. Dimension is hard-coded; distance metric
    # is cosine (semantic similarity, magnitude-invariant — see
    # specs/vector_kb.md). Distance metric is fixed at table creation.
    # `kb_vec_knowledge.rowid` mirrors `kb_chunks_meta.id`; `kb_vec_memo.rowid`
    # mirrors `memo_chunks_meta.id`.
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_knowledge USING vec0(embedding float[1024] distance_metric=cosine)")
    query!(Repo, "CREATE VIRTUAL TABLE IF NOT EXISTS kb_vec_memo      USING vec0(embedding float[1024] distance_metric=cosine)")

    # FTS5 inverted indexes over chunk_text — feed the BM25 leg of
    # hybrid search. Contentless tables (text not duplicated; we
    # already have it in *_chunks_meta); rowid mirrors the
    # corresponding chunks_meta.id. `contentless_delete=1` lets us
    # issue plain `DELETE FROM <fts> WHERE rowid=?` on chunk delete.
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
    CREATE VIRTUAL TABLE IF NOT EXISTS memo_fts USING fts5(
      chunk_text,
      content='',
      contentless_delete=1,
      tokenize='unicode61 remove_diacritics 2'
    )
    """)

    query!(Repo, """
    CREATE TABLE IF NOT EXISTS kb_relearn_jobs (
      source_ref   TEXT PRIMARY KEY,
      source_kind  TEXT NOT NULL,
      enqueued_at  INTEGER NOT NULL
    )
    """)

    # Audit log — every permission denial + cross-user / cross-org
    # access lands here. Per Primitive 0.1 (audit history visible to
    # managers) and Primitive 0.7 (per-org permission model).
    #
    #   action      — :read | :write | :invoke | :approve | :administer
    #   resource    — JSON-encoded resource tag, e.g.
    #                 {"kind":"verb","name":"hubspot.deal.create"}
    #   outcome     — 'allowed' | 'denied' (denials are the primary
    #                 use case; allowed-rows are written for
    #                 high-sensitivity actions only)
    #   reason      — short tag explaining a denial
    #                 ('role_too_low', 'missing_credentials', …)
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS audit_log (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id        TEXT NOT NULL,
      user_id       TEXT,
      action        TEXT NOT NULL,
      resource      TEXT NOT NULL,
      outcome       TEXT NOT NULL,
      reason        TEXT,
      created_at    INTEGER NOT NULL
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_audit_log_org_ts ON audit_log (org_id, created_at)")
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_audit_log_user_ts ON audit_log (user_id, created_at)")

    # Pools — model-routing registry. See arch_wiki/dmh_ai/integrations.md
    # §API Pools. A pool bundles endpoint config + account rotation,
    # addressed in canonical model strings as <pool>::<model>. The
    # `protocol` column drives wire-format dispatch in
    # `DmhAi.Agent.LLM.adapter_for/1`.
    query!(Repo, """
    CREATE TABLE IF NOT EXISTS pools (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      org_id           TEXT NOT NULL,           -- FK organizations.id; per-org pool catalog (Primitive 0.1)
      name             TEXT NOT NULL,
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
      updated_ts       INTEGER NOT NULL,
      UNIQUE(org_id, name)
    )
    """)
    query!(Repo, "CREATE INDEX IF NOT EXISTS idx_pools_org ON pools (org_id)")
  end
end
