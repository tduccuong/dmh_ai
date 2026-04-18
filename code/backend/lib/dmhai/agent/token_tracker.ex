# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.TokenTracker do
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  def add_master(session_id, user_id, rx, tx) when rx > 0 or tx > 0 do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO session_token_stats (session_id, user_id, master_rx_tokens, master_tx_tokens, updated_at)
       VALUES (?,?,?,?,?)
       ON CONFLICT(session_id) DO UPDATE SET
         master_rx_tokens = master_rx_tokens + excluded.master_rx_tokens,
         master_tx_tokens = master_tx_tokens + excluded.master_tx_tokens,
         updated_at = excluded.updated_at",
      [session_id, user_id, rx, tx, now])
    :ok
  end
  def add_master(_, _, _, _), do: :ok

  def add_worker(session_id, user_id, worker_id, job_id, description, rx, tx) when rx > 0 or tx > 0 do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO worker_token_stats (session_id, job_id, worker_id, user_id, description, rx_tokens, tx_tokens, updated_at)
       VALUES (?,?,?,?,?,?,?,?)
       ON CONFLICT(session_id, job_id, worker_id) DO UPDATE SET
         rx_tokens = rx_tokens + excluded.rx_tokens,
         tx_tokens = tx_tokens + excluded.tx_tokens,
         description = excluded.description,
         updated_at = excluded.updated_at",
      [session_id, job_id || "", worker_id, user_id, description, rx, tx, now])
    :ok
  end
  def add_worker(_, _, _, _, _, _, _), do: :ok

  def get_session_stats(session_id) do
    master = try do
      r = query!(Repo, "SELECT master_rx_tokens, master_tx_tokens FROM session_token_stats WHERE session_id=?", [session_id])
      case r.rows do
        [[rx, tx]] -> %{rx: rx, tx: tx}
        _ -> %{rx: 0, tx: 0}
      end
    rescue _ -> %{rx: 0, tx: 0} end

    workers = try do
      r = query!(Repo, """
        SELECT job_id, description, SUM(rx_tokens), SUM(tx_tokens)
        FROM worker_token_stats
        WHERE session_id=?
        GROUP BY job_id
        ORDER BY MAX(updated_at) ASC
      """, [session_id])
      Enum.map(r.rows, fn [jid, desc, rx, tx] -> %{job_id: jid, description: desc, rx: rx, tx: tx} end)
    rescue _ -> [] end

    %{master: master, workers: workers}
  end

  def get_global_stats(user_id) do
    master = try do
      r = query!(Repo, "SELECT COALESCE(SUM(master_rx_tokens),0), COALESCE(SUM(master_tx_tokens),0) FROM session_token_stats WHERE user_id=?", [user_id])
      case r.rows do
        [[rx, tx]] -> %{rx: rx, tx: tx}
        _ -> %{rx: 0, tx: 0}
      end
    rescue _ -> %{rx: 0, tx: 0} end

    worker = try do
      r = query!(Repo, "SELECT COALESCE(SUM(rx_tokens),0), COALESCE(SUM(tx_tokens),0) FROM worker_token_stats WHERE user_id=?", [user_id])
      case r.rows do
        [[rx, tx]] -> %{rx: rx, tx: tx}
        _ -> %{rx: 0, tx: 0}
      end
    rescue _ -> %{rx: 0, tx: 0} end

    %{master: master, worker: worker}
  end
end
