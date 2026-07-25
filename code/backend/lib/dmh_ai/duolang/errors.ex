# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Errors do
  @moduledoc """
  The error ledger, and the single takeaway a session ends on.
  Keyed by `(user_id, lang)`, like the rest of the vocabulary layer.

  Corrective feedback is the most durable thing this product does, and
  its effect *grows* between the session and a later test — but only when
  the learner can act on it. An exhaustive error dump is not actionable,
  so the session surfaces at most a handful live and everything else
  lands here to wait.

  `takeaway/1` then picks exactly one open error to close the session on:
  the one seen most often, oldest first among ties. One correction
  practised properly beats a list nobody works through.

  An error is retired when the learner gets its item right again — the
  ledger is a queue of open work, not a permanent record of failure.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Repo

  @type t :: %{
          id: integer(),
          kind: String.t(),
          detail: String.t(),
          fix: String.t(),
          item_id: integer() | nil,
          seen_count: non_neg_integer()
        }

  @doc """
  Record an error. Re-seeing the same `(kind, detail)` for a learner bumps
  its count rather than adding a duplicate, so the ledger ranks by how
  persistent a mistake is.
  """
  @spec record(String.t(), String.t(), map()) :: :ok
  def record(user_id, lang, %{kind: kind, detail: detail, fix: fix} = attrs) do
    now = System.system_time(:millisecond)

    case find_open(user_id, lang, kind, detail) do
      nil ->
        query!(
          Repo,
          """
          INSERT INTO duolang_errors (user_id, lang, kind, detail, fix, item_id, status, seen_count, created_at)
          VALUES (?, ?, ?, ?, ?, ?, 'open', 1, ?)
          """,
          [user_id, lang, kind, detail, fix, Map.get(attrs, :item_id), now]
        )

      id ->
        query!(
          Repo,
          "UPDATE duolang_errors SET seen_count = seen_count + 1, fix = ? WHERE id = ?",
          [fix, id]
        )
    end

    :ok
  end

  @doc "Open errors, most persistent first."
  @spec open(String.t(), String.t(), keyword()) :: [t()]
  def open(user_id, lang, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    %{rows: rows} =
      query!(
        Repo,
        """
        SELECT id, kind, detail, fix, item_id, seen_count
          FROM duolang_errors
         WHERE user_id = ? AND lang = ? AND status = 'open'
         ORDER BY seen_count DESC, created_at ASC
         LIMIT ?
        """,
        [user_id, lang, limit]
      )

    Enum.map(rows, &row_to_error/1)
  end

  @doc """
  The one thing to end the session on, or `nil` when the learner has no
  open errors — in which case the session says so rather than inventing
  a correction.
  """
  @spec takeaway(String.t(), String.t()) :: t() | nil
  def takeaway(user_id, lang) do
    case open(user_id, lang, limit: 1) do
      [error] -> error
      [] -> nil
    end
  end

  @doc "Retire an error the learner has since got right."
  @spec retire(String.t(), integer()) :: :ok
  def retire(user_id, error_id) do
    query!(
      Repo,
      "UPDATE duolang_errors SET status = 'retired', retired_at = ? WHERE user_id = ? AND id = ?",
      [System.system_time(:millisecond), user_id, error_id]
    )

    :ok
  end

  @doc """
  Retire every open error attached to `item_id`. Called when the learner
  answers that item correctly — the mistake is closed by evidence, not by
  the learner reading about it.
  """
  @spec retire_for_item(String.t(), integer()) :: :ok
  def retire_for_item(user_id, item_id) when is_binary(user_id) do
    query!(
      Repo,
      """
      UPDATE duolang_errors SET status = 'retired', retired_at = ?
       WHERE user_id = ? AND item_id = ? AND status = 'open'
      """,
      [System.system_time(:millisecond), user_id, item_id]
    )

    :ok
  end

  defp find_open(user_id, lang, kind, detail) do
    %{rows: rows} =
      query!(
        Repo,
        "SELECT id FROM duolang_errors WHERE user_id = ? AND lang = ? AND kind = ? AND detail = ? AND status = 'open' LIMIT 1",
        [user_id, lang, kind, detail]
      )

    case rows do
      [[id]] -> id
      _ -> nil
    end
  end

  defp row_to_error([id, kind, detail, fix, item_id, seen_count]) do
    %{id: id, kind: kind, detail: detail, fix: fix, item_id: item_id, seen_count: seen_count}
  end
end
