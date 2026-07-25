# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Workspace do
  @moduledoc """
  The learner's single Duolang transcript surface.

  There is one transcript per course, and its `sessions` row id IS the
  course id — so `session_id == course_id` everywhere downstream, and the
  course's current-beat can be updated without a second lookup. Starting a
  lesson clears the transcript and begins again; what survives a lesson is
  the item store, not the transcript.

  It reuses the `sessions` table because that is what the message-append,
  polling and context machinery already reads. `mode='duolang'` keeps it
  out of `GET /sessions`, which is a Confidant surface.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Repo

  @id_prefix "course-"

  @doc "The transcript id for a course — the course id itself."
  @spec id_for(String.t()) :: String.t()
  def id_for(course_id), do: course_id

  @doc "True when `session_id` is a Duolang workspace."
  @spec workspace?(String.t()) :: boolean()
  def workspace?(session_id) when is_binary(session_id),
    do: String.starts_with?(session_id, @id_prefix)

  def workspace?(_), do: false

  @doc "The transcript row for `course_id`, creating it on first use."
  @spec ensure(String.t(), String.t()) :: String.t()
  def ensure(user_id, course_id) do
    now = System.system_time(:millisecond)

    query!(
      Repo,
      """
      INSERT INTO sessions (id, name, mode, messages, created_at, updated_at, user_id)
      VALUES (?, 'Duolang', 'duolang', '[]', ?, ?, ?)
      ON CONFLICT(id) DO NOTHING
      """,
      [course_id, now, now, user_id]
    )

    course_id
  end

  @doc """
  Clear a course's transcript and beat state, ready for a new lesson.
  Returns the transcript id (the course id).
  """
  @spec reset(String.t(), String.t()) :: String.t()
  def reset(user_id, course_id) do
    ensure(user_id, course_id)

    query!(
      Repo,
      "UPDATE sessions SET messages = '[]', context = NULL, updated_at = ? WHERE id = ? AND user_id = ?",
      [System.system_time(:millisecond), course_id, user_id]
    )

    query!(Repo, "DELETE FROM session_progress WHERE session_id = ?", [course_id])

    course_id
  end
end
