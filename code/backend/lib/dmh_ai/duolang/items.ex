# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Items do
  @moduledoc """
  The durable unit of Duolang mode. Items are addressable and permanent
  and this module owns their whole lifecycle — creation, due selection,
  and the interval ladder they move along.

  Keyed by `(user_id, lang)`: a learner's vocabulary in one language is one
  store, shared across every course in that language. `lang` is the
  target-language code.

  ## Scheduling

  A fixed ladder of intervals in days. A correct answer advances one step
  and schedules the next review; an incorrect answer resets to step 0 and
  increments `lapses`. The ladder is fixed on purpose: expanding and equal
  schedules perform equivalently, so an adaptive per-item scheduler would
  buy complexity and no measured gain.

  Due items are computed lazily at lesson start; there is no scheduler
  process and none is needed.

  ## Absence

  `session_draw/3` never surfaces a backlog. It takes a fixed count no
  matter how many items are overdue, and after a long gap it takes fewer
  still and marks them for re-introduction rather than testing.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Repo

  @day_ms 86_400_000

  @type item :: %{
          id: integer(),
          kind: String.t(),
          text: String.t(),
          translation: String.t(),
          context: String.t() | nil,
          due_at: integer(),
          interval_step: non_neg_integer(),
          attempts: non_neg_integer(),
          lapses: non_neg_integer(),
          last_result: String.t() | nil
        }

  @type draw :: %{items: [item()], reintroduce: boolean()}

  @doc """
  Add an item the learner has just met. Idempotent per `(user_id, lang,
  text)` — meeting the same word again keeps its existing schedule.
  """
  @spec upsert(String.t(), String.t(), map()) :: :ok
  def upsert(user_id, lang, %{text: text, translation: translation} = attrs) do
    now = System.system_time(:millisecond)

    query!(
      Repo,
      """
      INSERT INTO duolang_items
        (user_id, lang, kind, text, translation, context, due_at, interval_step, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
      ON CONFLICT(user_id, lang, text) DO UPDATE SET
        translation = excluded.translation,
        context     = COALESCE(excluded.context, duolang_items.context),
        updated_at  = excluded.updated_at
      """,
      [user_id, lang, Map.get(attrs, :kind, "word"), text, translation, Map.get(attrs, :context), now, now, now]
    )

    :ok
  end

  @doc "Every item for `(user_id, lang)`, newest first. Backs the Words & phrases surface."
  @spec all(String.t(), String.t()) :: [item()]
  def all(user_id, lang) do
    %{rows: rows} =
      query!(Repo, select_sql() <> " WHERE user_id = ? AND lang = ? ORDER BY created_at DESC", [user_id, lang])

    Enum.map(rows, &row_to_item/1)
  end

  @doc """
  Items due at `now`, oldest-due first, ties broken by lapse count.
  `limit` caps the result; the remainder stays in the queue, unmentioned.
  """
  @spec due(String.t(), String.t(), keyword()) :: [item()]
  def due(user_id, lang, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    limit = Keyword.get(opts, :limit, AgentSettings.duolang_session_recall_items())

    %{rows: rows} =
      query!(
        Repo,
        select_sql() <>
          " WHERE user_id = ? AND lang = ? AND due_at <= ? ORDER BY due_at ASC, lapses DESC LIMIT ?",
        [user_id, lang, now, limit]
      )

    Enum.map(rows, &row_to_item/1)
  end

  @doc """
  What the recall beat should present, backlog never surfaced. After an
  absence the draw shrinks and is flagged `reintroduce: true`.
  """
  @spec session_draw(String.t(), String.t(), keyword()) :: draw()
  def session_draw(user_id, lang, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    full = AgentSettings.duolang_session_recall_items()
    away? = absent?(user_id, lang, now)

    limit =
      if away?,
        do: max(div(full * AgentSettings.duolang_reentry_scale_percent(), 100), 1),
        else: full

    %{items: due(user_id, lang, now: now, limit: limit), reintroduce: away?}
  end

  @doc """
  Record the outcome of a retrieval and reschedule. `:skipped` records the
  attempt and leaves the schedule alone (re-introduction draws).
  """
  @spec record_result(String.t(), String.t(), integer(), :correct | :incorrect | :skipped, String.t()) ::
          :ok
  def record_result(user_id, lang, item_id, result, beat) do
    now = System.system_time(:millisecond)
    log_attempt(user_id, lang, item_id, beat, result, now)

    case result do
      :skipped ->
        :ok

      _ ->
        ladder = AgentSettings.duolang_interval_ladder_days()
        step = next_step(current_step(user_id, item_id), result, length(ladder))
        due_at = now + Enum.at(ladder, step) * @day_ms
        lapse_delta = if result == :incorrect, do: 1, else: 0

        query!(
          Repo,
          """
          UPDATE duolang_items
             SET due_at = ?, interval_step = ?, attempts = attempts + 1,
                 lapses = lapses + ?, last_result = ?, updated_at = ?
           WHERE user_id = ? AND id = ?
          """,
          [due_at, step, lapse_delta, to_string(result), now, user_id, item_id]
        )

        :ok
    end
  end

  @doc "The next rung for `step` given `result`."
  @spec next_step(non_neg_integer(), :correct | :incorrect, pos_integer()) :: non_neg_integer()
  def next_step(step, :correct, ladder_size), do: min(step + 1, ladder_size - 1)
  def next_step(_step, :incorrect, _ladder_size), do: 0

  # ── internals ──────────────────────────────────────────────────────────

  # "Absent" is measured from the last recorded attempt, not the last due
  # date — the question is when the learner last showed up.
  defp absent?(user_id, lang, now) do
    %{rows: rows} =
      query!(Repo, "SELECT MAX(ts) FROM duolang_attempts WHERE user_id = ? AND lang = ?", [user_id, lang])

    case rows do
      [[ts]] when is_integer(ts) -> now - ts > AgentSettings.duolang_reentry_gap_days() * @day_ms
      _ -> false
    end
  end

  defp current_step(user_id, item_id) do
    %{rows: rows} =
      query!(Repo, "SELECT interval_step FROM duolang_items WHERE user_id = ? AND id = ?", [user_id, item_id])

    case rows do
      [[step]] when is_integer(step) -> step
      _ -> 0
    end
  end

  defp log_attempt(user_id, lang, item_id, beat, result, now) do
    query!(
      Repo,
      "INSERT INTO duolang_attempts (user_id, lang, item_id, beat, result, ts) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, lang, item_id, beat, to_string(result), now]
    )
  end

  defp select_sql do
    """
    SELECT id, kind, text, translation, context, due_at,
           interval_step, attempts, lapses, last_result
      FROM duolang_items
    """
  end

  defp row_to_item([id, kind, text, translation, context, due_at, step, attempts, lapses, last]) do
    %{
      id: id,
      kind: kind,
      text: text,
      translation: translation,
      context: context,
      due_at: due_at,
      interval_step: step,
      attempts: attempts,
      lapses: lapses,
      last_result: last
    }
  end
end
