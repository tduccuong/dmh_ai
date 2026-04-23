# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ModelBehaviorStats do
  @moduledoc """
  Counter store for model misbehaviors. Increments on every Police
  rejection (and on every escalation). Primary data source for the
  "which models misbehave most often" dev-phase decision.

  Schema: see `Dmhai.DB.Init` — one row per unique
  `(role, model, issue_type, tool_name)`, `UNIQUE` constraint enforced
  so repeated misbehaviors upsert into a single counter row.

  Writes are gated by `AgentSettings.model_behavior_telemetry_enabled/0`
  so operators can kill recording cheaply.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @doc """
  Record one misbehavior occurrence. Upserts into the counter row:

    * fresh (no prior row)    — INSERT with `count = 1`, both timestamps = now.
    * existing                 — `count += 1`, `last_seen_at = now`,
                                 `first_seen_at` preserved.

  No-op when telemetry is disabled via `AgentSettings`.
  Returns `:ok` regardless of success so callers never need to handle failure.
  """
  @spec record(String.t(), String.t(), String.t() | atom(), String.t() | nil) :: :ok
  def record(role, model, issue_type, tool_name \\ "") do
    if Dmhai.Agent.AgentSettings.model_behavior_telemetry_enabled() do
      do_record(to_string(role), to_string(model), to_string(issue_type), to_string(tool_name || ""))
    end
    :ok
  end

  @doc """
  List all counter rows sorted by `count` descending. Stub for a
  future admin UI surface — no pagination yet (cardinality is low:
  roles × models × issue_types × tool_names stays small in practice).
  """
  @spec list_all() :: [map()]
  def list_all do
    try do
      r = query!(Repo, """
      SELECT role, model, issue_type, tool_name, count, first_seen_at, last_seen_at
      FROM model_behavior_stats
      ORDER BY count DESC, last_seen_at DESC
      """, [])

      Enum.map(r.rows, fn [role, model, issue_type, tool_name, count, first_seen_at, last_seen_at] ->
        %{
          role:          role,
          model:         model,
          issue_type:    issue_type,
          tool_name:     tool_name,
          count:         count,
          first_seen_at: first_seen_at,
          last_seen_at:  last_seen_at
        }
      end)
    rescue
      e ->
        Logger.warning("[ModelBehaviorStats] list_all failed: #{Exception.message(e)}")
        []
    end
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp do_record(role, model, issue_type, tool_name) do
    now = System.os_time(:millisecond)

    try do
      # Atomic upsert via SQLite's ON CONFLICT clause — safe under
      # concurrent callers (only one row can exist per composite key
      # because of the UNIQUE constraint).
      query!(Repo, """
      INSERT INTO model_behavior_stats
        (role, model, issue_type, tool_name, count, first_seen_at, last_seen_at)
      VALUES (?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(role, model, issue_type, tool_name) DO UPDATE
        SET count        = count + 1,
            last_seen_at = excluded.last_seen_at
      """, [role, model, issue_type, tool_name, now, now])
    rescue
      e ->
        Logger.warning("[ModelBehaviorStats] record failed: #{Exception.message(e)}")
    end
  end
end
