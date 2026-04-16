# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.WorkerState do
  @moduledoc """
  DB persistence for worker loop state. Enables crash recovery and rolling-summary storage.

  State is checkpointed after every tool-call iteration so restarts lose at most one step.

  Status lifecycle:
    'running'    — set on initial start; the worker process is alive
    'recovering' — set when fetch_and_claim picks it up after a crash; the worker is
                   being re-spawned. updated_at is refreshed on every checkpoint (heartbeat).
                   If updated_at goes stale (> @orphan_ms), the recovery process itself
                   died and the worker is eligible for re-claim.
    'done'       — terminal: worker completed normally
    'cancelled'  — terminal: worker was explicitly cancelled

  Two separate write paths exist to avoid clobbering the status:
    upsert/9     — used on initial start only; sets status='running'
    checkpoint/5 — used in the agentic loop; updates messages/iter/summary + updated_at
                   WITHOUT touching status, so 'recovering' stays 'recovering' and cannot
                   be double-claimed by a concurrent UserAgent restart.
  """

  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # If a 'recovering' worker's updated_at is older than this, assume the recovery
  # process died and allow re-claim.
  @orphan_ms :timer.minutes(10)

  @doc """
  Insert the initial worker record with status='running'.
  Only called once when a fresh worker starts.
  """
  def upsert(worker_id, session_id, user_id, task, messages, iter, periodic, rolling_summary, status) do
    now           = System.os_time(:millisecond)
    messages_json = Jason.encode!(messages)
    periodic_int  = if periodic, do: 1, else: 0

    query!(Repo,
      """
      INSERT INTO worker_state
        (worker_id, session_id, user_id, task, messages, rolling_summary, iter, periodic, status, created_at, updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(worker_id) DO UPDATE SET
        messages        = excluded.messages,
        rolling_summary = excluded.rolling_summary,
        iter            = excluded.iter,
        periodic        = excluded.periodic,
        status          = excluded.status,
        updated_at      = excluded.updated_at
      """,
      [worker_id, session_id, user_id, task, messages_json, rolling_summary,
       iter, periodic_int, status, now, now])
    :ok
  rescue e ->
    Logger.error("[WorkerState] upsert failed worker=#{worker_id}: #{Exception.message(e)}")
    :ok
  end

  @doc """
  Save loop progress WITHOUT changing status. Called after every tool-call iteration.
  updated_at acts as a liveness heartbeat for recovery detection.
  """
  def checkpoint(worker_id, messages, iter, periodic, rolling_summary) do
    now           = System.os_time(:millisecond)
    messages_json = Jason.encode!(messages)
    periodic_int  = if periodic, do: 1, else: 0

    query!(Repo,
      """
      UPDATE worker_state
      SET messages=?, rolling_summary=?, iter=?, periodic=?, updated_at=?
      WHERE worker_id=?
      """,
      [messages_json, rolling_summary, iter, periodic_int, now, worker_id])
    :ok
  rescue e ->
    Logger.error("[WorkerState] checkpoint failed worker=#{worker_id}: #{Exception.message(e)}")
    :ok
  end

  @doc "Mark a worker as done (completed normally)."
  def mark_done(worker_id) do
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE worker_state SET status='done', updated_at=? WHERE worker_id=?", [now, worker_id])
    :ok
  rescue _ -> :ok
  end

  @doc "Mark a worker as cancelled."
  def mark_cancelled(worker_id) do
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE worker_state SET status='cancelled', updated_at=? WHERE worker_id=?", [now, worker_id])
    :ok
  rescue _ -> :ok
  end

  @doc """
  Atomically claim workers that need recovery and return their checkpoints.

  Returns workers where:
  - status='running'  — crashed before any recovery attempt
  - status='recovering' AND updated_at older than @orphan_ms — recovery process itself died

  Claimed workers are immediately set to status='recovering' so a concurrent
  UserAgent restart (e.g. after idle-timeout) cannot double-claim the same worker.

  Since UserAgent is registered by name (one per user), concurrent calls for the
  same user are impossible. The guard still protects against the idle-timeout
  restart scenario where a second init runs while a recovery task is still live.
  """
  def fetch_and_claim(user_id) do
    try do
      stale_cutoff = System.os_time(:millisecond) - @orphan_ms

      r = query!(Repo,
        """
        SELECT worker_id, session_id, task, messages, rolling_summary, iter, periodic
        FROM worker_state
        WHERE user_id=?
          AND (status='running'
               OR (status='recovering' AND updated_at < ?))
        ORDER BY updated_at ASC
        """,
        [user_id, stale_cutoff])

      if r.rows != [] do
        worker_ids   = Enum.map(r.rows, fn [wid | _] -> wid end)
        placeholders = Enum.map_join(worker_ids, ",", fn _ -> "?" end)
        now          = System.os_time(:millisecond)

        query!(Repo,
          "UPDATE worker_state SET status='recovering', updated_at=? WHERE worker_id IN (#{placeholders})",
          [now | worker_ids])
      end

      Enum.map(r.rows, fn [wid, sid, task, messages_json, rolling_summary, iter, periodic_int] ->
        messages =
          case Jason.decode(messages_json || "[]") do
            {:ok, msgs} when is_list(msgs) -> msgs
            _                              -> []
          end

        %{
          worker_id:       wid,
          session_id:      sid,
          user_id:         user_id,
          task:            task            || "",
          messages:        messages,
          rolling_summary: rolling_summary,
          iter:            iter            || 0,
          periodic:        periodic_int == 1
        }
      end)
    rescue e ->
      Logger.error("[WorkerState] fetch_and_claim failed user=#{user_id}: #{Exception.message(e)}")
      []
    end
  end
end
