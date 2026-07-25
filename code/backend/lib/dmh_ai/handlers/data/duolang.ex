# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.Duolang do
  @moduledoc """
  HTTP surface for Duolang mode: course status, the course list, designing
  a new course, switching between them, and starting a lesson.

  A lesson's beats flow through the ordinary message path — `POST
  /agent/chat` advances a conversational beat and the FE reads panels from
  `/sessions/:id/poll`, where the session id is the active course id. These
  endpoints cover what sits *outside* a lesson.
  """

  import Plug.Conn

  alias DmhAi.Commands.Languages
  alias DmhAi.Duolang.{Coverage, Course, CourseDesigner, Items, Session, Workspace}
  alias DmhAi.Handlers.Data

  @doc """
  GET /duolang/status — everything the topbar needs, plus whether the
  learner has any course yet (drives the onboarding form vs. a lesson).
  """
  def get_status(conn, user) do
    case Course.active(user.id) do
      nil ->
        Data.json(conn, 200, %{onboarded: false, languages: Languages.all()})

      course ->
        # `languages` is always present so the "New course" form can render
        # even for a learner who already has courses.
        Data.json(conn, 200, %{
          onboarded: true,
          languages: Languages.all(),
          course: course_view(user.id, course, :full)
        })
    end
  end

  @doc "GET /duolang/courses — the course list for the switcher modal."
  def get_courses(conn, user) do
    active = Course.active(user.id)

    courses =
      user.id
      |> Course.list()
      |> Enum.map(fn c -> course_view(user.id, c, :summary, active) end)

    Data.json(conn, 200, %{courses: courses})
  end

  @doc """
  POST /duolang/courses — design and create a course from the brief, then
  make it active. `brief` carries the onboarding form.
  """
  def post_course(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")

    with {:ok, target} <- known_language(d["target_lang"]),
         {:ok, source} <- known_language(d["source_lang"]),
         :ok <- distinct_languages(target, source),
         topic when is_binary(topic) and topic != "" <- String.trim(d["topic"] || "") do
      brief =
        d
        |> Map.take(~w(motivation style focus intensity))
        |> Map.merge(%{"topic" => topic, "target_lang" => target, "source_lang" => source})

      design = CourseDesigner.design(brief, meta: %{user_id: user.id})

      course_id =
        Course.create(user.id, %{
          name: design.name,
          topic: topic,
          target_lang: target,
          source_lang: source,
          brief: brief,
          syllabus: design.syllabus
        })

      Workspace.ensure(user.id, course_id)
      get_status(conn, user)
    else
      {:error, :unknown_language} ->
        Data.json(conn, 400, %{error: "unsupported language", supported: Languages.all()})

      {:error, :same_language} ->
        Data.json(conn, 400, %{error: "target and source languages must differ"})

      _ ->
        Data.json(conn, 400, %{error: "a topic is required"})
    end
  end

  @doc "POST /duolang/courses/:id/activate — switch the active course."
  def post_activate(conn, user, course_id) do
    case Course.get(user.id, course_id) do
      nil ->
        Data.json(conn, 404, %{error: "no such course"})

      _ ->
        Course.set_active(user.id, course_id)
        get_status(conn, user)
    end
  end

  @doc "DELETE /duolang/courses/:id — remove a course. Vocabulary survives."
  def delete_course(conn, user, course_id) do
    Course.delete(user.id, course_id)
    get_courses(conn, user)
  end

  @doc "GET /duolang/items — the Words & phrases for the active course's language."
  def get_items(conn, user) do
    now = System.system_time(:millisecond)

    items =
      case Course.active(user.id) do
        nil ->
          []

        course ->
          user.id
          |> Items.all(course.target_lang)
          |> Enum.map(fn i ->
            %{
              id: i.id,
              text: i.text,
              translation: i.translation,
              context: i.context,
              due_in_days: Float.round((i.due_at - now) / 86_400_000, 1),
              attempts: i.attempts,
              lapses: i.lapses
            }
          end)
      end

    Data.json(conn, 200, %{items: items})
  end

  @doc "POST /duolang/start — begin a lesson in the active course."
  def post_start(conn, user) do
    case Session.start(user.id) do
      {:ok, beat} ->
        course = Course.active(user.id)
        Data.json(conn, 200, %{started: true, beat: beat, course_id: course && course.id})

      {:error, :no_course} ->
        Data.json(conn, 409, %{error: "no course"})

      {:error, reason} ->
        Data.json(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc """
  POST /duolang/advance — move past a beat that asks for no answer (read,
  speak, takeaway). Writes nothing to the transcript.
  """
  def post_advance(conn, user) do
    case Course.active(user.id) do
      nil ->
        Data.json(conn, 409, %{error: "no course"})

      course ->
        case Session.advance(user.id, course.id, "") do
          {:ok, beat} -> Data.json(conn, 200, %{beat: beat})
          {:error, reason} -> Data.json(conn, 409, %{error: to_string(reason)})
        end
    end
  end

  # ── views ──────────────────────────────────────────────────────────────

  defp course_view(user_id, course, detail, active \\ nil) do
    base = %{
      id: course.id,
      name: course.name,
      topic: course.topic,
      target_lang: course.target_lang,
      source_lang: course.source_lang,
      target_lang_name: name_of(course.target_lang),
      level: course.current_level,
      beat: course.current_beat
    }

    case detail do
      :summary ->
        Map.put(base, :active, active != nil and active.id == course.id)

      :full ->
        Map.merge(base, %{
          can_do: Course.level_plan(course, course.current_level)["can_do"],
          coverage: coverage(user_id, course.target_lang),
          item_count: length(Items.all(user_id, course.target_lang))
        })
    end
  end

  defp coverage(user_id, lang_code) do
    case Coverage.for_user(user_id, lang_code) do
      {:ok, report} -> %{percent: report.percent}
      {:error, :no_reference} -> nil
    end
  end

  defp distinct_languages(same, same), do: {:error, :same_language}
  defp distinct_languages(_target, _source), do: :ok

  defp known_language(code) do
    case Languages.by_code(to_string(code || "")) do
      %{code: c} -> {:ok, c}
      nil -> {:error, :unknown_language}
    end
  end

  defp name_of(code) do
    case Languages.by_code(code) do
      %{english: name} -> name
      _ -> code
    end
  end
end
