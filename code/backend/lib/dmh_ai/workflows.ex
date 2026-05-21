# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows do
  @moduledoc """
  DB-layer for the workflow store + run-state. Four tables:

    * `workflows`           — one row per logical workflow.
                              `created_by` is the OWNER (immutable).
                              Runtime executor uses this for caller_ctx.
    * `workflow_versions`   — append-only version history. Full IR.
    * `workflow_run_state`  — per-run state for the deterministic
                              executor. One row per invocation.
    * `workflow_run_waits`  — open `wait` predicates for a run.

  See `arch_wiki/dmh_ai/sme/layer-W.md` for the spec.

  This module is the ONLY writer to the four tables; the compiler,
  the executor, and the admin handlers all go through here.
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @type workflow :: %{
          id:              String.t(),
          org_id:          String.t(),
          display_name:    String.t(),
          description:     String.t(),
          created_by:      String.t(),
          current_version: integer(),
          active_version:  integer() | nil,
          created_at:      integer(),
          updated_at:      integer()
        }

  @type version :: %{
          workflow_id:          String.t(),
          org_id:               String.t(),
          version:              integer(),
          ir:                   map(),
          description:          String.t(),
          change_note:          String.t() | nil,
          compiled_at:          integer(),
          compiled_in_session:  String.t(),
          compiled_by_user_id:  String.t()
        }

  @type run_state :: %{
          id:               String.t(),
          workflow_id:      String.t(),
          workflow_version: integer(),
          org_id:           String.t(),
          task_id:          String.t(),
          owner_user_id:    String.t(),
          trigger_payload:  map(),
          bindings:         map(),
          current_node:     integer() | nil,
          status:           String.t(),
          paused:           boolean(),
          last_error:       map() | nil,
          started_at:       integer(),
          updated_at:       integer(),
          completed_at:     integer() | nil
        }

  @type step_row :: %{
          id:             integer(),
          run_id:         String.t(),
          node_id:        integer(),
          started_at:     integer(),
          completed_at:   integer() | nil,
          status:         String.t(),
          resolved_input: any(),
          output:         any(),
          error:          map() | nil,
          waiting_on:     map() | nil,
          duration_ms:    integer() | nil
        }

  # ─── Workflow lookup ──────────────────────────────────────────────────
  #
  # The picker (`Handlers.Workflows.list`) shows each workflow's
  # LATEST description. Every read joins `workflow_versions` on
  # `current_version` so a single SQL call returns workflow header
  # + current description in one row. Older versions' descriptions
  # are still readable via `get_version/3`.

  @workflow_select """
  SELECT w.id, w.org_id, w.display_name, COALESCE(v.description, ''),
         w.created_by, w.current_version, w.active_version,
         w.created_at, w.updated_at
  FROM workflows w
  LEFT JOIN workflow_versions v
    ON v.org_id=w.org_id AND v.workflow_id=w.id AND v.version=w.current_version
  """

  @spec get_workflow(String.t(), String.t()) :: workflow() | nil
  def get_workflow(org_id, id) when is_binary(org_id) and is_binary(id) do
    case query!(Repo, @workflow_select <> " WHERE w.org_id=? AND w.id=?",
                 [org_id, id]).rows do
      [row] -> row_to_workflow(row)
      _     -> nil
    end
  end

  @spec list_workflows(String.t()) :: [workflow()]
  def list_workflows(org_id) when is_binary(org_id) do
    %{rows: rows} = query!(Repo,
      @workflow_select <> " WHERE w.org_id=? ORDER BY w.updated_at DESC",
      [org_id])

    Enum.map(rows, &row_to_workflow/1)
  end

  @spec list_armed(String.t()) :: [workflow()]
  def list_armed(org_id) when is_binary(org_id) do
    %{rows: rows} = query!(Repo,
      @workflow_select <> " WHERE w.org_id=? AND w.active_version IS NOT NULL",
      [org_id])

    Enum.map(rows, &row_to_workflow/1)
  end

  @doc """
  Substring-search workflows for the picker. Returns the workflow
  header plus the latest version's trigger_inputs (extracted from
  the IR) so the model can translate prose into a typed inputs map.

  Match is case-insensitive against `display_name` AND `description`.
  Empty `prefix` returns everything (capped). Ordered by
  `updated_at DESC` so the most-recently-edited workflow lands first.
  """
  @spec search(String.t(), String.t()) :: [map()]
  def search(org_id, prefix) when is_binary(org_id) and is_binary(prefix) do
    like = "%" <> normalise_prefix(prefix) <> "%"

    %{rows: rows} = query!(Repo, @workflow_select <> """
     WHERE w.org_id=?
       AND (lower(w.display_name) LIKE ? OR lower(COALESCE(v.description, '')) LIKE ?)
     ORDER BY w.updated_at DESC
     LIMIT 50
    """, [org_id, like, like])

    rows
    |> Enum.map(&row_to_workflow/1)
    |> Enum.map(fn wf ->
      {ti, kind} = trigger_meta_for(org_id, wf.id, wf.current_version)
      wf |> Map.put(:trigger_inputs, ti) |> Map.put(:trigger_kind, kind)
    end)
  end

  @spec get_version(String.t(), String.t(), integer()) :: version() | nil
  def get_version(org_id, workflow_id, version)
      when is_binary(org_id) and is_binary(workflow_id) and is_integer(version) do
    case query!(Repo, """
    SELECT workflow_id, org_id, version, ir_json, description, change_note, compiled_at,
           compiled_in_session, compiled_by_user_id
    FROM workflow_versions WHERE org_id=? AND workflow_id=? AND version=?
    """, [org_id, workflow_id, version]).rows do
      [row] -> row_to_version(row)
      _     -> nil
    end
  end

  # Returns `{trigger_inputs, trigger_kind}` for a workflow version —
  # the metadata the picker + sidecar + LLM prompt all need to
  # disambiguate "run" semantics on poll/schedule/webhook vs manual.
  defp trigger_meta_for(org_id, workflow_id, version) do
    case get_version(org_id, workflow_id, version) do
      nil ->
        {[], "manual"}

      %{ir: ir} ->
        ir
        |> Map.get("nodes", [])
        |> Enum.find(fn n -> n["kind"] == "trigger" end)
        |> case do
          nil -> {[], "manual"}
          t   -> {Map.get(t, "inputs", []), Map.get(t, "trigger_kind", "manual")}
        end
    end
  end

  defp normalise_prefix(prefix) do
    prefix
    |> String.downcase()
    |> String.replace(~r/[%_]/, "")
  end

  # ─── Upsert ───────────────────────────────────────────────────────────

  @doc """
  Atomic upsert. First save creates the `workflows` row at v0 with
  `created_by = user_id` (immutable); each subsequent save inserts
  a new `workflow_versions` row at `current_version + 1` and bumps
  `workflows.current_version`. The workflow's `created_by` is
  read from the existing row on edits — never overwritten.

  If the workflow is currently armed, the upsert auto-bumps
  `active_version` to the new `current_version` so the poller
  always fires the latest shape — only-current-is-runnable holds
  for armed triggers too.

  Returns `{:ok, %{id, version, display_name, url, created_by}}`.
  """
  @spec upsert(map()) :: {:ok, map()} | {:error, term()}
  def upsert(%{
        org_id:       org_id,
        id:           id,
        display_name: display_name,
        description:  description,
        ir:           ir,
        change_note:  change_note,
        session_id:   session_id,
        user_id:      user_id
      })
      when is_binary(org_id) and is_binary(id) and is_binary(display_name) and
             is_binary(description) and description != "" and
             is_map(ir) and is_binary(session_id) and is_binary(user_id) do
    now = System.os_time(:millisecond)
    ir_json = Jason.encode!(ir)

    case get_workflow(org_id, id) do
      nil ->
        # First save → owner = caller. Immutable thereafter.
        query!(Repo, """
        INSERT INTO workflows
          (id, org_id, display_name, created_by, current_version, active_version,
           created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, NULL, ?, ?)
        """, [id, org_id, display_name, user_id, now, now])

        query!(Repo, """
        INSERT INTO workflow_versions
          (workflow_id, org_id, version, ir_json, description, change_note,
           compiled_at, compiled_in_session, compiled_by_user_id)
        VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
        """, [id, org_id, ir_json, description, change_note, now, session_id, user_id])

        Logger.info("[Workflows] created slug=#{id} org=#{org_id} owner=#{user_id} v0")

        {:ok, build_result(id, display_name, user_id, 0)}

      %{current_version: cv, created_by: owner, active_version: av} ->
        new_version = cv + 1

        query!(Repo, """
        INSERT INTO workflow_versions
          (workflow_id, org_id, version, ir_json, description, change_note,
           compiled_at, compiled_in_session, compiled_by_user_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [id, org_id, new_version, ir_json, description, change_note,
              now, session_id, user_id])

        # If armed, auto-bump active_version to the new latest so the
        # autonomous trigger fires the just-saved shape — never an
        # older snapshot.
        new_active = if is_integer(av), do: new_version, else: nil

        query!(Repo, """
        UPDATE workflows
           SET current_version=?, active_version=?, display_name=?, updated_at=?
         WHERE org_id=? AND id=?
        """, [new_version, new_active, display_name, now, org_id, id])

        Logger.info("[Workflows] upserted slug=#{id} org=#{org_id} owner=#{owner} editor=#{user_id} v#{new_version}")

        {:ok, build_result(id, display_name, owner, new_version)}
    end
  rescue
    e in Exqlite.Error ->
      {:error, {:db_error, Exception.message(e)}}
  end

  # ─── Arming ───────────────────────────────────────────────────────────
  #
  # Arming always pins to `current_version`. There is no choice
  # of which version to arm — only the latest is runnable, and
  # the autonomous trigger should fire the shape the operator
  # last saved. On a subsequent upsert, `active_version` is
  # bumped in lockstep (see `upsert/1`).

  @spec arm(String.t(), String.t()) :: :ok | {:error, term()}
  def arm(org_id, id) when is_binary(org_id) and is_binary(id) do
    case get_workflow(org_id, id) do
      nil ->
        {:error, :workflow_not_found}

      %{current_version: cv} ->
        now = System.os_time(:millisecond)
        query!(Repo, """
        UPDATE workflows SET active_version=?, updated_at=?
        WHERE org_id=? AND id=?
        """, [cv, now, org_id, id])
        Logger.info("[Workflows] armed slug=#{id} org=#{org_id} v#{cv}")
        :ok
    end
  end

  @spec disarm(String.t(), String.t()) :: :ok
  def disarm(org_id, id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    UPDATE workflows SET active_version=NULL, updated_at=?
    WHERE org_id=? AND id=?
    """, [now, org_id, id])
    :ok
  end

  # ─── Run state ────────────────────────────────────────────────────────

  @doc """
  Open a new `workflow_run_state` row at start-of-run. Caller
  supplies `trigger_payload`; the executor seeds `bindings` from
  that and walks node 1.
  """
  @spec create_run(map()) :: {:ok, run_state()} | {:error, term()}
  def create_run(%{
        workflow_id:      wid,
        workflow_version: ver,
        org_id:           org_id,
        task_id:          task_id,
        owner_user_id:    owner,
        trigger_payload:  payload
      })
      when is_binary(wid) and is_integer(ver) and is_binary(org_id) and
             is_binary(task_id) and is_binary(owner) and is_map(payload) do
    id  = run_id()
    now = System.os_time(:millisecond)
    bindings = %{"trigger" => payload, "emits" => %{}}

    query!(Repo, """
    INSERT INTO workflow_run_state
      (id, workflow_id, workflow_version, org_id, task_id, owner_user_id,
       trigger_payload, bindings, current_node, status, paused, last_error,
       started_at, updated_at, completed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, 'running', 0, NULL, ?, ?, NULL)
    """, [id, wid, ver, org_id, task_id, owner,
          Jason.encode!(payload), Jason.encode!(bindings), now, now])

    {:ok, get_run!(id)}
  rescue
    e -> {:error, {:db_error, Exception.message(e)}}
  end

  @spec get_run(String.t()) :: run_state() | nil
  def get_run(id) when is_binary(id) do
    case query!(Repo, """
    SELECT id, workflow_id, workflow_version, org_id, task_id, owner_user_id,
           trigger_payload, bindings, current_node, status, paused, last_error,
           started_at, updated_at, completed_at
    FROM workflow_run_state WHERE id=?
    """, [id]).rows do
      [row] -> row_to_run(row)
      _     -> nil
    end
  end

  @spec get_run!(String.t()) :: run_state()
  def get_run!(id) do
    case get_run(id) do
      nil -> raise ArgumentError, "workflow_run_state: no row id=#{id}"
      r   -> r
    end
  end

  @doc """
  Persist the executor's progress after a step. Bindings and
  current_node update on every step boundary so a crash mid-node
  resumes at the last successful step.
  """
  @spec update_run(String.t(), map()) :: :ok
  def update_run(run_id, fields) when is_binary(run_id) and is_map(fields) do
    now = System.os_time(:millisecond)

    # Encode every field exactly once, then unzip into parallel column
    # and value lists. Critical that the two lists are emitted in the
    # SAME order — using Enum.map preserves the iteration order so the
    # `?` placeholders bind to the right column. (A previous reduce-
    # and-prepend pattern silently swapped column ↔ value on multi-
    # field updates because the `sets` and `args` lists were assembled
    # in opposite orders.)
    encoded =
      Enum.map(fields, fn {k, v} ->
        {col, val} = encode_run_field(k, v)
        {"#{col}=?", val}
      end)

    {sets, args} = Enum.unzip(encoded)

    sql = "UPDATE workflow_run_state SET " <>
          Enum.join(["updated_at=?" | sets], ", ") <>
          " WHERE id=?"

    query!(Repo, sql, [now] ++ args ++ [run_id])
    :ok
  end

  @spec complete_run(String.t(), :completed | :failed | :timed_out | :cancelled, map() | nil) :: :ok
  def complete_run(run_id, status, last_error \\ nil)
      when status in [:completed, :failed, :timed_out, :cancelled] do
    now = System.os_time(:millisecond)

    query!(Repo, """
    UPDATE workflow_run_state
       SET status=?, last_error=?, completed_at=?, updated_at=?
     WHERE id=?
    """, [to_string(status), maybe_json(last_error), now, now, run_id])

    :ok
  end

  # ─── Lifecycle controls (instance-level) ──────────────────────────────
  #
  # These verbs operate on a single instance. The spec-level verbs
  # (arm/disarm/upsert) sit on the workflow row and don't touch
  # in-flight instances. See layer-W.md §Instance lifecycle.

  @doc """
  Set a run's `paused` flag. The executor reads this before walking
  the next node — pause halts AFTER the current step completes,
  never mid-step.
  """
  @spec set_paused(String.t(), boolean()) :: :ok | {:error, term()}
  def set_paused(run_id, true_or_false) when is_binary(run_id) and is_boolean(true_or_false) do
    case get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      %{status: s} when s in ["completed", "failed", "cancelled", "timed_out"] ->
        {:error, {:terminal_status, s}}

      _ ->
        now = System.os_time(:millisecond)
        flag = if true_or_false, do: 1, else: 0
        query!(Repo,
          "UPDATE workflow_run_state SET paused=?, updated_at=? WHERE id=?",
          [flag, now, run_id])
        :ok
    end
  end

  @doc """
  Cancel a run. Mark terminal regardless of current status (unless
  already terminal — then a no-op). The executor sees this on its
  next status read and stops the walk; mid-step calls finish
  naturally.
  """
  @spec cancel_run(String.t()) :: :ok | {:error, term()}
  def cancel_run(run_id) when is_binary(run_id) do
    case get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      %{status: s} when s in ["completed", "failed", "cancelled", "timed_out"] ->
        {:error, {:terminal_status, s}}

      _ ->
        complete_run(run_id, :cancelled,
          %{error: :cancelled_by_user, at: System.os_time(:millisecond)})
        :ok
    end
  end

  # ─── Step trace (workflow_run_steps) ──────────────────────────────────

  @doc """
  Open a step trace row at the start of a step. Returns the row id
  so the caller can update it on completion.
  """
  @spec open_step(String.t(), integer(), any()) :: integer()
  def open_step(run_id, node_id, resolved_input)
      when is_binary(run_id) and is_integer(node_id) do
    now = System.os_time(:millisecond)
    %{rows: [[id]]} =
      query!(Repo, """
      INSERT INTO workflow_run_steps
        (run_id, node_id, started_at, status, resolved_input)
      VALUES (?, ?, ?, 'running', ?)
      RETURNING id
      """, [run_id, node_id, now, maybe_json(resolved_input)])

    id
  end

  @doc """
  Close a step trace row to a terminal status. Computes
  `duration_ms` from `started_at` to now.
  """
  @spec close_step(integer(),
                   :completed | :failed | :skipped | :waiting,
                   keyword()) :: :ok
  def close_step(step_id, status, opts \\ [])
      when is_integer(step_id) and status in [:completed, :failed, :skipped, :waiting] do
    now = System.os_time(:millisecond)
    output     = Keyword.get(opts, :output)
    error      = Keyword.get(opts, :error)
    waiting_on = Keyword.get(opts, :waiting_on)

    query!(Repo, """
    UPDATE workflow_run_steps
       SET completed_at = ?,
           duration_ms  = ? - started_at,
           status       = ?,
           output       = COALESCE(?, output),
           error        = COALESCE(?, error),
           waiting_on   = COALESCE(?, waiting_on)
     WHERE id = ?
    """, [now, now, to_string(status),
          maybe_json(output), maybe_json(error), maybe_json(waiting_on),
          step_id])

    :ok
  end

  @doc "Fetch every step row for a run, ordered by start time."
  @spec list_steps(String.t()) :: [step_row()]
  def list_steps(run_id) when is_binary(run_id) do
    %{rows: rows} = query!(Repo, """
    SELECT id, run_id, node_id, started_at, completed_at, status,
           resolved_input, output, error, waiting_on, duration_ms
    FROM workflow_run_steps WHERE run_id=? ORDER BY started_at ASC, id ASC
    """, [run_id])

    Enum.map(rows, &row_to_step/1)
  end

  defp row_to_step([id, run_id, node_id, started, completed, status,
                   resolved_input, output, error, waiting_on, duration_ms]) do
    %{
      id:             id,
      run_id:         run_id,
      node_id:        node_id,
      started_at:     started,
      completed_at:   completed,
      status:         status,
      resolved_input: decode_maybe(resolved_input),
      output:         decode_maybe(output),
      error:          decode_maybe(error),
      waiting_on:     decode_maybe(waiting_on),
      duration_ms:    duration_ms
    }
  end

  # ─── Trigger state (cursor + last-fired metadata) ─────────────────────

  @doc "Get the trigger state row for a workflow (nil if never polled yet)."
  @spec get_trigger_state(String.t(), String.t()) :: map() | nil
  def get_trigger_state(org_id, workflow_id)
      when is_binary(org_id) and is_binary(workflow_id) do
    case query!(Repo, """
    SELECT last_cursor, last_fired_at, last_fire_status, cursor_updated_at
    FROM workflow_trigger_state WHERE org_id=? AND workflow_id=?
    """, [org_id, workflow_id]).rows do
      [[cursor, fired_at, status, updated_at]] ->
        %{
          last_cursor:       cursor,
          last_fired_at:     fired_at,
          last_fire_status:  status,
          cursor_updated_at: updated_at
        }

      _ ->
        nil
    end
  end

  @doc """
  Upsert trigger state for a workflow. Caller passes the new cursor +
  fire status from the poll cycle.
  """
  @spec upsert_trigger_state(String.t(), String.t(),
                              cursor :: String.t() | nil,
                              status :: String.t()) :: :ok
  def upsert_trigger_state(org_id, workflow_id, cursor, status)
      when is_binary(org_id) and is_binary(workflow_id) and
             (is_binary(cursor) or is_nil(cursor)) and is_binary(status) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT INTO workflow_trigger_state
      (org_id, workflow_id, last_cursor, last_fired_at, last_fire_status, cursor_updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(org_id, workflow_id) DO UPDATE SET
      last_cursor       = excluded.last_cursor,
      last_fired_at     = excluded.last_fired_at,
      last_fire_status  = excluded.last_fire_status,
      cursor_updated_at = excluded.cursor_updated_at
    """, [org_id, workflow_id, cursor, now, status, now])

    :ok
  end

  # ─── Webhook event dedupe ─────────────────────────────────────────────

  @doc """
  Atomically check + record a webhook event. Returns `:new` if this
  is the first time we've seen `(workflow_id, event_id)`, or
  `:duplicate` if it's already been processed (within retention).
  """
  @spec record_webhook_event(String.t(), String.t()) :: :new | :duplicate
  def record_webhook_event(workflow_id, event_id)
      when is_binary(workflow_id) and is_binary(event_id) do
    now = System.os_time(:millisecond)

    try do
      query!(Repo, """
      INSERT INTO workflow_webhook_events (workflow_id, event_id, received_at)
      VALUES (?, ?, ?)
      """, [workflow_id, event_id, now])

      :new
    rescue
      Exqlite.Error -> :duplicate
    end
  end

  # ─── Waits ────────────────────────────────────────────────────────────

  @spec add_wait(String.t(), integer(), atom(), map(), integer() | nil) :: :ok
  def add_wait(run_id, node_id, kind, predicate, expires_at \\ nil)
      when is_binary(run_id) and is_integer(node_id) and is_atom(kind) and is_map(predicate) do
    query!(Repo, """
    INSERT INTO workflow_run_waits (run_id, node_id, kind, predicate, expires_at)
    VALUES (?, ?, ?, ?, ?)
    """, [run_id, node_id, to_string(kind), Jason.encode!(predicate), expires_at])

    update_run(run_id, %{status: "waiting"})
    :ok
  end

  @spec delete_wait(String.t(), integer()) :: :ok
  def delete_wait(run_id, node_id) do
    query!(Repo, "DELETE FROM workflow_run_waits WHERE run_id=? AND node_id=?",
           [run_id, node_id])
    :ok
  end

  @doc """
  Return the open wait row for a given `(run_id, node_id)`, or `nil`
  if no wait is recorded there. Used by the executor's resume path
  to discover the wait's `kind` — gate / wait / reauth_pause — and
  route resume accordingly (skip-to-next vs retry-the-same).
  """
  @spec get_wait(String.t(), integer()) :: map() | nil
  def get_wait(run_id, node_id) when is_binary(run_id) and is_integer(node_id) do
    case query!(Repo, """
    SELECT run_id, node_id, kind, predicate, expires_at
    FROM workflow_run_waits
    WHERE run_id=? AND node_id=?
    LIMIT 1
    """, [run_id, node_id]).rows do
      [[rid, nid, k, pred_json, exp]] ->
        %{run_id: rid, node_id: nid, kind: k,
          predicate: Jason.decode!(pred_json), expires_at: exp}

      _ ->
        nil
    end
  end

  @spec list_waits(atom()) :: [map()]
  def list_waits(kind) when is_atom(kind) do
    %{rows: rows} = query!(Repo, """
    SELECT run_id, node_id, kind, predicate, expires_at
    FROM workflow_run_waits WHERE kind=?
    """, [to_string(kind)])

    Enum.map(rows, fn [rid, nid, k, pred_json, exp] ->
      %{run_id: rid, node_id: nid, kind: k,
        predicate: Jason.decode!(pred_json), expires_at: exp}
    end)
  end

  # ─── Helpers ──────────────────────────────────────────────────────────

  defp encode_run_field(:bindings, m) when is_map(m), do: {"bindings", Jason.encode!(m)}
  defp encode_run_field(:current_node, v),            do: {"current_node", v}
  defp encode_run_field(:status, v) when is_atom(v),  do: {"status", to_string(v)}
  defp encode_run_field(:status, v) when is_binary(v),do: {"status", v}
  defp encode_run_field(:last_error, m),              do: {"last_error", maybe_json(m)}

  defp maybe_json(nil),               do: nil
  defp maybe_json(m) when is_map(m),  do: Jason.encode!(m)
  defp maybe_json(s) when is_binary(s), do: s

  defp run_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> binary_part(0, 24)
  end

  defp row_to_workflow([id, org_id, display_name, description, created_by,
                       current_version, active_version, created_at, updated_at]) do
    %{
      id:              id,
      org_id:          org_id,
      display_name:    display_name,
      description:     description || "",
      created_by:      created_by,
      current_version: current_version,
      active_version:  active_version,
      created_at:      created_at,
      updated_at:      updated_at
    }
  end

  defp row_to_version([workflow_id, org_id, version, ir_json, description,
                      change_note, compiled_at, compiled_in_session,
                      compiled_by_user_id]) do
    %{
      workflow_id:          workflow_id,
      org_id:               org_id,
      version:              version,
      ir:                   Jason.decode!(ir_json),
      description:          description || "",
      change_note:          change_note,
      compiled_at:          compiled_at,
      compiled_in_session:  compiled_in_session,
      compiled_by_user_id:  compiled_by_user_id
    }
  end

  defp row_to_run([id, wid, ver, org_id, task_id, owner, payload_json, bindings_json,
                  current_node, status, paused, last_error, started, updated, completed]) do
    %{
      id:               id,
      workflow_id:      wid,
      workflow_version: ver,
      org_id:           org_id,
      task_id:          task_id,
      owner_user_id:    owner,
      trigger_payload:  Jason.decode!(payload_json),
      bindings:         Jason.decode!(bindings_json),
      current_node:     current_node,
      status:           status,
      paused:           paused == 1,
      last_error:       decode_maybe(last_error),
      started_at:       started,
      updated_at:       updated,
      completed_at:     completed
    }
  end

  defp decode_maybe(nil),                do: nil
  defp decode_maybe(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, v} -> v
      _ -> %{raw: s}
    end
  end

  defp build_result(id, display_name, created_by, version) do
    %{
      id:           id,
      display_name: display_name,
      created_by:   created_by,
      version:      version,
      url:          "/workflows/#{URI.encode(id)}/#{version}"
    }
  end

  @doc """
  Derive a stable URL-safe slug from a display name. Every slug
  begins with `workflow_` so a workflow reference (`&<slug>`) reads
  unambiguously as a workflow handle — not as a task description
  the LLM might anchor on. If the caller supplies a slug that
  already starts with `workflow_`, it's left alone; otherwise the
  prefix is prepended.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(s) when is_binary(s) do
    normalised =
      s
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    body =
      case normalised do
        ""    -> "untitled"
        other -> other
      end

    # `workflow_` prefix is mandatory. Avoid double-prefixing if the
    # caller already supplied it.
    prefixed =
      if String.starts_with?(body, "workflow_") do
        body
      else
        "workflow_" <> body
      end

    String.slice(prefixed, 0, 64)
  end
end
