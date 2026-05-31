# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.Sessions do
  @moduledoc """
  Session CRUD + auto-naming.

  * GET /sessions, /sessions/current, /sessions/:id
  * POST /sessions, /sessions/:id/stop, /sessions/:id/name
  * PUT  /sessions/current, /sessions/:id
  * DELETE /sessions/:id

  Also owns `owns_session?/2` — the shared "does this user own this
  session id" check used by `Assets` and `FormSubmission`.
  """

  import Plug.Conn
  require Logger

  alias DmhAi.{Repo, Agent.AgentSettings, Agent.LLM}
  alias DmhAi.Commands.Parser, as: CommandParser
  alias DmhAi.Handlers.Data
  alias DmhAi.Handlers.Data.Settings
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Default mode for a brand-new user with no persisted preference. Mode is a
  # top-level FE/BE preference (assistant ↔ confidant) — never inferred from a
  # session's `mode` column, never seeded from a hardcoded fallback at a
  # write-site.
  @default_mode "assistant"
  @valid_modes ["confidant", "assistant"]

  # GET /sessions
  def get_sessions(conn, user) do
    result =
      query!(Repo, """
      SELECT id, name, messages, context, created_at, updated_at, mode
      FROM sessions WHERE user_id=?
      ORDER BY COALESCE(updated_at, created_at) DESC
      """, [user.id])

    sessions = Enum.map(result.rows, &parse_session_row/1)
    ids = Enum.map(sessions, & &1["id"])
    Logger.info("[SESSIONS] GET user=#{user.id} count=#{length(sessions)} ids=#{inspect(ids)}")
    Data.json(conn, 200, sessions)
  end

  # GET /sessions/current — returns the user's top-level mode preference AND
  # the last-active session id PER mode. Two modes (confidant / assistant) are
  # fully separate surfaces: switching modes restores that mode's own last
  # session, not the other mode's.
  def get_current_session(conn, user) do
    mode = Settings.read_setting("current_mode_#{user.id}") || @default_mode
    conf = Settings.read_setting("current_session_#{user.id}_confidant")
    asst = Settings.read_setting("current_session_#{user.id}_assistant")
    Data.json(conn, 200, %{mode: mode, sessions: %{confidant: conf, assistant: asst}})
  end

  # GET /sessions/:id
  def get_session(conn, user, session_id) do
    result =
      query!(Repo, """
      SELECT id, name, messages, context, created_at, updated_at, mode
      FROM sessions WHERE id=? AND user_id=?
      """, [session_id, user.id])

    case result.rows do
      [row | _] -> Data.json(conn, 200, parse_session_row(row))
      _ -> Data.json(conn, 404, %{error: "Not found"})
    end
  end

  @doc """
  POST /sessions/:id/stop — user clicks the stop button on a session.
  Verifies ownership, then stamps `sessions.cancelled_at` so the
  chain loop aborts on its next iteration. Idempotent.
  """
  def stop_session(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
    else
      now = System.os_time(:millisecond)
      query!(Repo, "UPDATE sessions SET cancelled_at=? WHERE id=? AND cancelled_at IS NULL",
             [now, session_id])
      Data.json(conn, 200, %{ok: true})
    end
  end

  # POST /sessions
  def post_create_session(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    now = :os.system_time(:millisecond)

    cond do
      not (is_binary(d["id"]) and byte_size(d["id"]) > 0) ->
        Data.json(conn, 400, %{error: "id missing or empty — session id must be a non-empty string"})

      d["mode"] not in @valid_modes ->
        Data.json(conn, 400, %{error: "invalid mode", valid: @valid_modes})

      true ->
        query!(Repo, """
        INSERT INTO sessions (id, name, messages, created_at, updated_at, user_id, mode)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
          d["id"],
          d["name"],
          Jason.encode!(d["messages"] || []),
          d["createdAt"],
          now,
          user.id,
          d["mode"]
        ])

        Data.json(conn, 200, d)
    end
  end

  # PUT /sessions/current — writes BOTH the mode preference and (optionally)
  # the last-active session id for that mode. Accepts `{mode}` to switch mode
  # only, or `{mode, id}` to also pin a session as last-active for that mode.
  def put_current_session(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    mode = d["mode"]

    unless mode in @valid_modes do
      Data.json(conn, 400, %{error: "invalid mode", valid: @valid_modes})
    else
      Settings.write_setting("current_mode_#{user.id}", mode)
      if is_binary(d["id"]) do
        Settings.write_setting("current_session_#{user.id}_#{mode}", d["id"])
      end
      Data.json(conn, 200, d)
    end
  end

  # POST /sessions/:id/name — call LLM to generate and persist a session name.
  #
  # Two prompt shapes:
  #   * first_rename — session is still on its default title. Standard
  #     "give a short title for this conversation" instruction.
  #   * refresh-rename — session has a real title. Bridge prompt: pass
  #     the current title alongside the recent user messages and ask
  #     for a refreshed title that preserves continuity where the topic
  #     still applies, leans toward new content when it has clearly
  #     shifted, and captures the bridge when the conversation is in
  #     the gray area between old and new.
  #
  # The FE supplies `first_rename: true|false` in the POST body — it
  # already knows whether the current title is one of the locale-keyed
  # defaults ("New chat", "New session", ...).
  def post_name_session(conn, user, session_id) do
    {:ok, body, conn} = read_body(conn)
    flags = Jason.decode!(body || "{}")
    first_rename? = flags["first_rename"] == true

    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 403, %{error: "Forbidden"})
    else
      result = query!(Repo, "SELECT name, messages FROM sessions WHERE id=?", [session_id])

      case result.rows do
        [[current_name, msgs_json]] ->
          recent_user_msgs =
            (msgs_json || "[]")
            |> Jason.decode!()
            |> Enum.flat_map(fn
              %{"role" => "user", "content" => content} when is_binary(content) ->
                trimmed = String.trim(content)

                # /memo and /index are user intent for the KB layer, not
                # conversation about a topic. Skip them so they don't
                # bias the title.
                if trimmed == "" or CommandParser.parse(content) != :not_a_command do
                  []
                else
                  [String.slice(content, 0, 200)]
                end

              _ ->
                []
            end)
            |> Enum.take(-AgentSettings.session_namer_user_msg_count())

          if recent_user_msgs == [] do
            Data.json(conn, 200, %{name: nil})
          else
            messages = [%{role: "user", content: build_namer_prompt(recent_user_msgs, current_name, first_rename?)}]
            trace = %{
              origin: "system", path: "Handlers.Data.name_session",
              role: "SessionNamer", phase: "name",
              session_id: session_id, user_id: user.id, tier: :swift
            }

            case LLM.call(AgentSettings.swift_model(), messages, trace: trace) do
              {:ok, name} when is_binary(name) and name != "" ->
                sanitized = sanitize_session_name(name)

                if sanitized && sanitized != "" do
                  now = :os.system_time(:millisecond)
                  query!(Repo, "UPDATE sessions SET name=?, updated_at=? WHERE id=? AND user_id=?",
                         [sanitized, now, session_id, user.id])
                  Data.json(conn, 200, %{name: sanitized})
                else
                  Data.json(conn, 200, %{name: nil})
                end

              _ ->
                Data.json(conn, 200, %{name: nil})
            end
          end

        _ ->
          Data.json(conn, 404, %{error: "Not found"})
      end
    end
  end

  # PUT /sessions/:id
  # Metadata-only: updates name (and wipes messages + context when the FE
  # sends `messages: []` as a session-reset signal). Regular message writes
  # are BE-only via /agent/chat — FE MUST NOT push message-shaped state
  # back here. Incoming `messages` arrays with content are ignored; only
  # the empty-array "reset" case has effect.
  def put_session(conn, user, session_id) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    now = :os.system_time(:millisecond)
    name = sanitize_session_name(d["name"])
    reset? = Map.get(d, "messages") == []

    if reset? do
      query!(Repo, """
      UPDATE sessions SET name=?, messages=?, context=NULL, updated_at=?
      WHERE id=? AND user_id=?
      """, [name, "[]", now, session_id, user.id])
      query!(Repo, "DELETE FROM session_token_stats WHERE session_id=?", [session_id])
    else
      query!(Repo, """
      UPDATE sessions SET name=?, updated_at=?
      WHERE id=? AND user_id=?
      """, [name, now, session_id, user.id])
    end

    Data.json(conn, 200, d)
  end

  # DELETE /sessions/:id
  def delete_session(conn, user, session_id) do
    # Stamp `cancelled_at` so any in-flight chain aborts on its next
    # iteration before we cascade-delete the row.
    now = System.os_time(:millisecond)
    query!(Repo, "UPDATE sessions SET cancelled_at=? WHERE id=? AND user_id=? AND cancelled_at IS NULL",
           [now, session_id, user.id])

    query!(Repo, "DELETE FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])
    query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM session_token_stats WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM session_services WHERE session_id=?", [session_id])

    session_dir = DmhAi.Constants.session_root(user.email, session_id)
    if File.dir?(session_dir) do
      File.rm_rf!(session_dir)
    end

    Data.json(conn, 200, %{ok: true})
  end

  # ─── Shared helpers ─────────────────────────────────────────────────────

  @doc """
  Does the given session belong to the given user? Used by `Assets`
  (`/upload-session-attachment`) and `FormSubmission` (`/sessions/:id/inputs/:token`)
  to gate writes before doing any heavy work.
  """
  def owns_session?(session_id, user_id) do
    result = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])
    result.rows != []
  end

  # ─── Private helpers ────────────────────────────────────────────────────

  # First-rename: simple "give a title" shape.
  # Refresh-rename: bridge prompt that carries the old title forward
  # and asks the model to balance continuity against drift.
  defp build_namer_prompt(user_msgs, current_name, first_rename?) do
    numbered =
      user_msgs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. \"#{m}\"" end)

    if first_rename? or current_name in [nil, ""] do
      "Give a short title (3-5 words) for this conversation. " <>
        "Use the language that dominates the user messages. " <>
        "Reply with only the title — no quotes, no explanation, no leading or trailing punctuation.\n\n" <>
        "User messages (newest last):\n" <> numbered
    else
      "Current session title: \"#{current_name}\"\n\n" <>
        "User messages since the title was last set (newest last):\n" <> numbered <> "\n\n" <>
        "Produce a refreshed title — 3 to 5 words, in the dominant language of the messages — " <>
        "that bridges the old title and the new direction:\n" <>
        "- If the recent messages still circle the same topic as the old title, lean toward continuity — keep the through-line, refine the wording.\n" <>
        "- If the conversation has clearly moved on to a different topic, lean toward the new content.\n" <>
        "- When the two overlap (the conversation is in a gray area between them), the title should capture the bridge between the old framing and the new — not snap to either side.\n\n" <>
        "Reply with only the refreshed title — no quotes, no explanation, no leading or trailing punctuation."
    end
  end

  # Strip LLM formatting artifacts from session names so double-quotes,
  # bold markers, and heading prefixes can't leak in from auto-naming.
  defp sanitize_session_name(nil), do: nil
  defp sanitize_session_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> strip_markdown_bold()
    |> strip_surrounding_quotes()
    |> String.trim()
  end

  # Remove **bold**, *italic*, ***bold-italic*** wrappers
  defp strip_markdown_bold(s), do: Regex.replace(~r/\*{1,3}([^*]*)\*{1,3}/, s, "\\1")

  # Remove leading/trailing straight and curly quote characters
  defp strip_surrounding_quotes(s) do
    s
    |> String.trim_leading("\"")
    |> String.trim_leading("“")   # "
    |> String.trim_leading("‘")   # '
    |> String.trim_leading("'")
    |> String.trim_trailing("\"")
    |> String.trim_trailing("”")  # "
    |> String.trim_trailing("’")  # '
    |> String.trim_trailing("'")
  end

  defp parse_session_row([id, name, messages, context, created_at, updated_at]) do
    parse_session_row([id, name, messages, context, created_at, updated_at, "confidant"])
  end

  defp parse_session_row([id, name, messages, context, created_at, updated_at, mode]) do
    %{
      "id" => id,
      "name" => name,
      "messages" => Jason.decode!(messages || "[]"),
      "context" => Jason.decode!(context || "null"),
      "createdAt" => created_at,
      "updatedAt" => updated_at,
      "mode" => mode || "confidant"
    }
  end
end
