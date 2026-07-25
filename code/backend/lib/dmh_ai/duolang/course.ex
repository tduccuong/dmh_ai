# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Course do
  @moduledoc """
  A course is the unit a learner navigates: one topic, one target language,
  organised as a CEFR ladder. This module owns course rows, the ladder, the
  learner's position within a course, and which course is active.

  The active course per user is pinned as a setting (mirroring the way a
  Confidant session is pinned), so a page reload lands the learner back
  where they were.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Commands.Languages
  alias DmhAi.Handlers.Data.Settings
  alias DmhAi.Repo

  @ladder ~w(A1 A2 B1 B2 C1 C2)

  @type t :: %{
          id: String.t(),
          user_id: String.t(),
          name: String.t(),
          topic: String.t(),
          target_lang: String.t(),
          source_lang: String.t(),
          brief: map(),
          syllabus: map(),
          current_level: String.t(),
          current_beat: String.t() | nil
        }

  @doc "The CEFR ladder, in order."
  @spec ladder() :: [String.t()]
  def ladder, do: @ladder

  @doc "Create a course from a designed plan. Returns the course id."
  @spec create(String.t(), map()) :: String.t()
  def create(user_id, attrs) do
    now = System.system_time(:millisecond)
    id = "course-#{user_id}-#{now}"

    query!(
      Repo,
      """
      INSERT INTO duolang_courses
        (id, user_id, name, topic, target_lang, source_lang, brief, syllabus,
         current_level, current_beat, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'A1', NULL, ?, ?)
      """,
      [
        id,
        user_id,
        Map.fetch!(attrs, :name),
        Map.fetch!(attrs, :topic),
        Map.fetch!(attrs, :target_lang),
        Map.fetch!(attrs, :source_lang),
        Jason.encode!(Map.get(attrs, :brief, %{})),
        Jason.encode!(Map.get(attrs, :syllabus, %{})),
        now,
        now
      ]
    )

    set_active(user_id, id)
    id
  end

  @doc "Every course for `user_id`, newest first."
  @spec list(String.t()) :: [t()]
  def list(user_id) do
    %{rows: rows} =
      query!(Repo, select_sql() <> " WHERE user_id = ? ORDER BY updated_at DESC", [user_id])

    Enum.map(rows, &row_to_course/1)
  end

  @doc "One course by id, scoped to its owner, or `nil`."
  @spec get(String.t(), String.t()) :: t() | nil
  def get(user_id, course_id) do
    %{rows: rows} =
      query!(Repo, select_sql() <> " WHERE user_id = ? AND id = ?", [user_id, course_id])

    case rows do
      [row] -> row_to_course(row)
      _ -> nil
    end
  end

  @doc "The learner's active course, or `nil` when they have none."
  @spec active(String.t()) :: t() | nil
  def active(user_id) do
    case Settings.read_setting(active_key(user_id)) do
      id when is_binary(id) and id != "" ->
        get(user_id, id) || first(user_id)

      _ ->
        first(user_id)
    end
  end

  @doc "Pin `course_id` as the learner's active course."
  @spec set_active(String.t(), String.t()) :: :ok
  def set_active(user_id, course_id) do
    Settings.write_setting(active_key(user_id), course_id)
    :ok
  end

  @doc "Delete a course. Vocabulary is language-scoped and survives."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(user_id, course_id) do
    query!(Repo, "DELETE FROM duolang_courses WHERE user_id = ? AND id = ?", [user_id, course_id])

    if Settings.read_setting(active_key(user_id)) == course_id do
      case first(user_id) do
        %{id: id} -> set_active(user_id, id)
        _ -> Settings.write_setting(active_key(user_id), "")
      end
    end

    :ok
  end

  @doc "Set the beat the course is currently on (null between lessons)."
  @spec set_beat(String.t(), String.t(), String.t() | nil) :: :ok
  def set_beat(user_id, course_id, beat) do
    query!(
      Repo,
      "UPDATE duolang_courses SET current_beat = ?, updated_at = ? WHERE user_id = ? AND id = ?",
      [beat, System.system_time(:millisecond), user_id, course_id]
    )

    :ok
  end

  @doc """
  Advance to the next CEFR level. Completing a lesson's six beats moves the
  course up a rung; the top rung stays put. Returns the new level.
  """
  @spec advance(String.t(), String.t()) :: String.t()
  def advance(user_id, course_id) do
    case get(user_id, course_id) do
      %{current_level: level} ->
        next = next_level(level)

        query!(
          Repo,
          "UPDATE duolang_courses SET current_level = ?, updated_at = ? WHERE user_id = ? AND id = ?",
          [next, System.system_time(:millisecond), user_id, course_id]
        )

        next

      _ ->
        "A1"
    end
  end

  @doc "The next rung above `level`, clamped at the top."
  @spec next_level(String.t()) :: String.t()
  def next_level(level) do
    idx = Enum.find_index(@ladder, &(&1 == level)) || 0
    Enum.at(@ladder, min(idx + 1, length(@ladder) - 1))
  end

  @doc "The theme + can-do goal the syllabus sets for a level, if any."
  @spec level_plan(t(), String.t()) :: %{optional(String.t()) => String.t()}
  def level_plan(%{syllabus: syllabus}, level) when is_map(syllabus) do
    case Map.get(syllabus, level) do
      %{} = plan -> plan
      _ -> %{}
    end
  end

  def level_plan(_course, _level), do: %{}

  @doc "The target language's table entry (display name + BCP-47 voice)."
  @spec target_language(t()) :: Languages.lang() | nil
  def target_language(%{target_lang: code}), do: Languages.by_code(code)

  @doc "The learner's own language table entry."
  @spec source_language(t()) :: Languages.lang() | nil
  def source_language(%{source_lang: code}), do: Languages.by_code(code)

  # ── internals ──────────────────────────────────────────────────────────

  defp first(user_id) do
    case list(user_id) do
      [course | _] -> course
      _ -> nil
    end
  end

  defp active_key(user_id), do: "duolang_course_#{user_id}"

  defp select_sql do
    """
    SELECT id, user_id, name, topic, target_lang, source_lang, brief, syllabus, current_level, current_beat
      FROM duolang_courses
    """
  end

  defp row_to_course([id, user_id, name, topic, target, source, brief, syllabus, level, beat]) do
    %{
      id: id,
      user_id: user_id,
      name: name,
      topic: topic,
      target_lang: target,
      source_lang: source,
      brief: decode(brief),
      syllabus: decode(syllabus),
      current_level: level,
      current_beat: beat
    }
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}
end
