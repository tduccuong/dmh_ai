# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data do
  import Plug.Conn
  alias DmhAi.{Repo, Agent.AgentSettings, Agent.LLM, Agent.TokenTracker, Agent.UserAgent}
  alias DmhAi.Commands.Parser, as: CommandParser
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_exts ~w(.mp4 .webm .mov .avi .mkv .m4v .3gp .ogv)

  # Max size for original video uploads to <session>/data/ (permanent user storage).
  # Must match MEDIA_MAX_SIZE_BYTES on the frontend.
  @max_original_video_bytes 300_000_000

  # Max size for scaled attachments uploaded to the worker workspace.
  # Scaled videos at 800 kbps: ~6 MB/min → covers clips up to ~30 min.
  @max_workspace_attachment_bytes 200_000_000

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /assets/:session_id/:file_id
  # Serves user-uploaded files from <session_root>/data/. Worker-scratch files
  # under <session_root>/workspace/ are intentionally not served —
  # the worker should persist anything user-facing via signal(result) or by
  # writing to the data/ subdir explicitly.
  def get_asset(conn, user, session_id, file_id) do
    data_dir    = DmhAi.Constants.session_data_dir(user.email, session_id)
    file_path   = Path.expand(Path.join(data_dir, file_id))
    assets_real = Path.expand(DmhAi.Constants.assets_dir())

    if String.starts_with?(file_path, assets_real) and File.regular?(file_path) do
      mime = guess_mime(file_path)
      display_name = Regex.replace(~r/^\d+_/, file_id, "")
      data = File.read!(file_path)

      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("content-disposition", "attachment; filename=\"#{display_name}\"")
      |> put_resp_header("content-length", to_string(byte_size(data)))
      |> send_resp(200, data)
    else
      json(conn, 404, %{error: "Not found"})
    end
  end

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
    json(conn, 200, sessions)
  end

  # GET /sessions/current
  def get_current_session(conn, user) do
    key = "current_session_#{user.id}"
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", [key])

    id =
      case result.rows do
        [[v] | _] -> v
        _ -> nil
      end

    json(conn, 200, %{id: id})
  end

  # GET /sessions/:id
  def get_session(conn, user, session_id) do
    result =
      query!(Repo, """
      SELECT id, name, messages, context, created_at, updated_at, mode
      FROM sessions WHERE id=? AND user_id=?
      """, [session_id, user.id])

    case result.rows do
      [row | _] -> json(conn, 200, parse_session_row(row))
      _ -> json(conn, 404, %{error: "Not found"})
    end
  end

  @doc """
  POST /tasks/:task_id/cancel — user clicks the stop button on a task
  row in the sidebar. Verifies ownership via the task → session → user
  chain, then `Tasks.mark_cancelled/2` which flips the task to
  `cancelled` (for periodics: also cancels the armed pickup timer via
  `TaskRuntime.cancel_pickup`). An in-flight silent turn for this task
  is NOT interrupted — the model may finish its current pickup and
  produce one last output; no future pickups fire. Idempotent: a
  second click on an already-cancelled task is a no-op that still
  returns 200.
  """
  def cancel_task(conn, user, task_id) do
    # Ownership check: task must belong to a session owned by this user.
    owns = query!(Repo, """
    SELECT t.task_id
    FROM tasks t
    JOIN sessions s ON s.id = t.session_id
    WHERE t.task_id = ? AND s.user_id = ?
    """, [task_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      DmhAi.Agent.Tasks.mark_cancelled(task_id, "Stopped by user")
      json(conn, 200, %{ok: true})
    end
  end

  # GET /sessions/:id/tasks
  # Returns all tasks for the session, newest first. The FE's task-list
  # sidebar polls this at ~3s cadence while tasks are active.
  def get_session_tasks(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      tasks =
        session_id
        |> DmhAi.Agent.Tasks.list_for_session()
        |> Enum.map(&Map.take(&1, [:task_id, :task_num, :task_title, :task_type, :task_status,
                                    :intvl_sec, :task_spec, :task_result,
                                    :time_to_pickup, :language,
                                    :created_at, :updated_at]))
      json(conn, 200, %{tasks: tasks})
    end
  end

  # GET /sessions/:id/progress?since=<id>
  # Returns the session's progress rows after the given id (delta-load).
  # The FE polls this at its own cadence while a task is active; when no tasks
  # are running it can back off to a slower cadence (or skip entirely).
  def get_session_progress(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      conn = fetch_query_params(conn)
      since_id =
        case conn.query_params["since"] do
          nil -> 0
          s ->
            case Integer.parse(to_string(s)) do
              {n, _} -> n
              _      -> 0
            end
        end

      rows = DmhAi.Agent.SessionProgress.fetch_for_session(session_id, since_id)
      json(conn, 200, %{progress: rows})
    end
  end

  # GET /sessions/:id/poll?msg_since=<ts>&prog_since=<id>
  # Unified delta endpoint for the FE's polling loop.
  # Returns:
  #   - messages:      new session.messages entries with ts > msg_since
  #   - progress:      new session_progress rows with id > prog_since
  #   - stream_buffer: partial final-answer text currently being streamed, or nil
  #   - is_working:    true when a turn is in flight (buffer non-null OR ongoing task)
  def poll_session(conn, user, session_id) do
    result =
      query!(Repo,
             "SELECT messages, stream_buffer, thinking_buffer FROM sessions WHERE id=? AND user_id=?",
             [session_id, user.id])

    case result.rows do
      [[msgs_json, stream_buffer, thinking_buffer]] ->
        conn = fetch_query_params(conn)

        msg_since =
          case conn.query_params["msg_since"] do
            nil -> 0
            s ->
              case Integer.parse(to_string(s)) do
                {n, _} -> n
                _      -> 0
              end
          end

        prog_since =
          case conn.query_params["prog_since"] do
            nil -> 0
            s ->
              case Integer.parse(to_string(s)) do
                {n, _} -> n
                _      -> 0
              end
          end

        all_msgs = Jason.decode!(msgs_json || "[]")
        new_msgs = Enum.filter(all_msgs, fn m -> (m["ts"] || 0) > msg_since end)
        progress = DmhAi.Agent.SessionProgress.fetch_for_session(session_id, prog_since)

        # `is_working` drives the FE's poll cadence (true → 500 ms,
        # false → 5 s idle) AND the status-bar phrase ("Assistant is
        # thinking..." / "Assistant is streaming the answer..."). Five
        # conditions feed it:
        #   (1) stream_buffer non-null — assistant mid-turn emitting text.
        #   (2) Last session.messages entry is role="user" — the user's
        #       message hasn't been answered yet, so a chain is (or is
        #       about to be) in flight. Covers: the 500 ms window between
        #       POST /agent/chat and the BE starting the chain, AND page
        #       reload mid-chain where the FE loses its isStreaming flag
        #       but the BE is still working.
        #   (3) Pending session_progress rows exist — a tool_call is
        #       currently running (progress rows are inserted at
        #       tool-start with status='pending', flipped to 'done' when
        #       the tool returns). Covers multi-turn tool chains where
        #       stream_buffer stays empty across tool-only rounds.
        #   (4) fetch_next_due hit — a task is due NOW (past pickup).
        #   (5) Periodic task armed for the FUTURE — a pickup is coming.
        # Without (5), a long-interval periodic task would give the FE
        # a quiet window between firings, letting fresh assistant
        # messages wait up to 5 s before rendering. With (5) the FE
        # stays on 500 ms while periodic rotation is active.
        has_due_task       = DmhAi.Agent.Tasks.fetch_next_due(session_id) != nil
        has_armed_periodic = DmhAi.Agent.Tasks.has_pending_periodic_for_session(session_id)
        has_unanswered_user_msg? = case List.last(all_msgs) do
          %{"role" => "user"} -> true
          _                    -> false
        end
        # Orphan-cleanup: a `session_progress` row stays `pending`
        # only while a tool is actively running. If the chain isn't
        # iterating any more (chain_in_flight=false) AND a pending
        # row is older than 30 s AND it isn't backed by a live
        # `RunningTools` entry, the chain almost certainly died and
        # the row is stale. Auto-flip to `done` with an
        # `[orphan-cleanup]` marker so:
        #   • the FE's spinner on that row stops spinning
        #   • `has_pending_progress?` stops keeping `is_working` true
        # Without this, a one-time chain crash leaves a stuck
        # spinner + perpetual "thinking..." status across reloads.
        chain_in_flight? = DmhAi.Agent.ChainInFlight.in_flight?(session_id)
        bg_pipeline_active? = DmhAi.Agent.BackgroundPipelines.active?(session_id)

        # Skip cleanup while a chain is iterating OR a background
        # pipeline (e.g. /wiki URL crawl) is registered. Each
        # crawl-emitted row stays pending much longer than the
        # 30-s threshold while the cloud embedder works through
        # the page's chunks — without this guard, the sweeper
        # would tag every legitimate in-flight row with
        # `[orphan-cleanup]`.
        if not chain_in_flight? and not bg_pipeline_active? do
          DmhAi.Agent.SessionProgress.cleanup_stale_pending(session_id, 30_000)
        end

        has_pending_progress? = DmhAi.Agent.SessionProgress.has_pending?(session_id)
        is_working =
          is_binary(stream_buffer)
          or has_due_task
          or has_armed_periodic
          or has_unanswered_user_msg?
          or has_pending_progress?

        running_tool_call =
          case DmhAi.Agent.RunningTools.lookup(session_id) do
            %{tool_call_id: tcid, started_at_ms: started} = entry ->
              %{
                tool_call_id:    tcid,
                progress_row_id: Map.get(entry, :progress_row_id),
                started_at_ms:   started
              }

            _ ->
              nil
          end

        # Per-session Stop button gate. The Stop call cancels whichever
        # turn the user has in flight (only one inline turn is allowed
        # per UserAgent — Registry-keyed by user_id, not session_id),
        # so the FE shows the button only on the session that actually
        # owns the in-flight turn. The agent-side session_id wins over
        # `is_working`, which can be true for ambient reasons (queued
        # user message about to be picked up, periodic task armed) that
        # don't yet have a Task to kill.
        agent_busy_session_id = DmhAi.Agent.UserAgent.current_turn_session_id(user.id)
        agent_busy = agent_busy_session_id == session_id

        json(conn, 200, %{
          messages:          new_msgs,
          progress:          progress,
          stream_buffer:     stream_buffer,
          thinking_buffer:   thinking_buffer,
          is_working:        is_working,
          chain_in_flight:   chain_in_flight?,
          running_tool_call: running_tool_call,
          agent_busy:        agent_busy
        })

      _ ->
        json(conn, 404, %{error: "Not found"})
    end
  end

  # GET /video-descriptions/:session_id
  def get_video_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      result =
        query!(Repo, """
        SELECT file_id, name, description, created_at
        FROM video_descriptions WHERE session_id=?
        """, [session_id])

      items =
        Enum.map(result.rows, fn [file_id, name, description, created_at] ->
          %{file_id: file_id, name: name, description: description, created_at: created_at}
        end)

      json(conn, 200, items)
    end
  end

  # GET /image-descriptions/:session_id
  def get_image_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      result =
        query!(Repo, """
        SELECT file_id, name, description, created_at
        FROM image_descriptions WHERE session_id=?
        """, [session_id])

      items =
        Enum.map(result.rows, fn [file_id, name, description, created_at] ->
          %{file_id: file_id, name: name, description: description, created_at: created_at}
        end)

      json(conn, 200, items)
    end
  end

  # POST /log
  def post_log(conn) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    msg = d["msg"] || ""
    log(msg)
    json(conn, 200, %{ok: true})
  end

  # POST /video-descriptions
  def post_video_description(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    session_id = d["sessionId"] || ""
    file_id = d["fileId"] || ""
    description = String.trim(d["description"] || "")

    if session_id == "" or file_id == "" or description == "" do
      json(conn, 400, %{error: "Missing fields"})
    else
      owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

      if owns.rows == [] do
        json(conn, 403, %{error: "Forbidden"})
      else
        now = :os.system_time(:millisecond)

        query!(Repo, """
        INSERT OR REPLACE INTO video_descriptions (session_id, file_id, name, description, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [session_id, file_id, d["name"] || "", description, now])

        json(conn, 200, %{ok: true})
      end
    end
  end

  # POST /image-descriptions
  def post_image_description(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    session_id = d["sessionId"] || ""
    file_id = d["fileId"] || ""
    description = String.trim(d["description"] || "")

    if session_id == "" or file_id == "" or description == "" do
      json(conn, 400, %{error: "Missing fields"})
    else
      owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

      if owns.rows == [] do
        json(conn, 403, %{error: "Forbidden"})
      else
        now = :os.system_time(:millisecond)

        query!(Repo, """
        INSERT OR REPLACE INTO image_descriptions (session_id, file_id, name, description, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [session_id, file_id, d["name"] || "", description, now])

        json(conn, 200, %{ok: true})
      end
    end
  end

  # POST /sessions
  def post_create_session(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    now = :os.system_time(:millisecond)

    mode = if d["mode"] in ["confidant", "assistant"], do: d["mode"], else: "confidant"

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
      mode
    ])

    json(conn, 200, d)
  end

  # POST /assets (multipart file upload)
  def post_asset(conn, user) do
    case parse_multipart(conn) do
      {:error, conn, :too_large} ->
        json(conn, 413, %{error: "File too large"})

      {:ok, conn, parts} ->
        case Map.fetch(parts, "file") do
          {:ok, %{filename: filename, data: raw}} ->
            filename = filename || "upload"
            session_id =
              case Map.get(parts, "sessionId") do
                %{data: sid} -> sid
                _ -> "default"
              end

            ext = Path.extname(filename) |> String.downcase()

            if ext in @video_exts and byte_size(raw) > @max_original_video_bytes do
              max_mb = div(@max_original_video_bytes, 1_000_000)
              json(conn, 413, %{error: "Video too large — maximum supported size is #{max_mb} MB"})
            else
              data_dir = DmhAi.Constants.session_data_dir(user.email, session_id)
              File.mkdir_p!(data_dir)

              ts = :os.system_time(:millisecond)
              safe_name = "#{ts}_#{Regex.replace(~r/[^\w.\-]/, filename, "_")}"
              File.write!(Path.join(data_dir, safe_name), raw)

              result = %{id: safe_name, name: filename, size: byte_size(raw)}

              result =
                cond do
                  ext in @image_exts ->
                    mime = guess_mime(filename)
                    Map.merge(result, %{
                      type: "image",
                      mime: mime,
                      base64: Base.encode64(raw)
                    })

                  ext in @video_exts ->
                    Map.merge(result, %{type: "video"})

                  true ->
                    content =
                      case :unicode.characters_to_binary(raw, :utf8) do
                        str when is_binary(str) -> str
                        _ -> raw |> :binary.bin_to_list() |> List.to_string()
                      end

                    Map.merge(result, %{type: "text", content: content})
                end

              json(conn, 200, result)
            end

          :error ->
            json(conn, 400, %{error: "No file field"})
        end
    end
  end

  # PUT /sessions/current
  def put_current_session(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    key = "current_session_#{user.id}"
    query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [key, d["id"]])
    json(conn, 200, d)
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
      json(conn, 403, %{error: "Forbidden"})
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

                # /memo and /wiki are user intent for the KB layer, not
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
            json(conn, 200, %{name: nil})
          else
            messages = [%{role: "user", content: build_namer_prompt(recent_user_msgs, current_name, first_rename?)}]
            trace = %{origin: "system", path: "Handlers.Data.name_session", role: "SessionNamer", phase: "name"}

            case LLM.call(AgentSettings.swift_model(), messages, trace: trace) do
              {:ok, name} when is_binary(name) and name != "" ->
                sanitized = sanitize_session_name(name)

                if sanitized && sanitized != "" do
                  now = :os.system_time(:millisecond)
                  query!(Repo, "UPDATE sessions SET name=?, updated_at=? WHERE id=? AND user_id=?",
                         [sanitized, now, session_id, user.id])
                  json(conn, 200, %{name: sanitized})
                else
                  json(conn, 200, %{name: nil})
                end

              _ ->
                json(conn, 200, %{name: nil})
            end
          end

        _ ->
          json(conn, 404, %{error: "Not found"})
      end
    end
  end

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

  # PUT /sessions/:id
  # Metadata-only: updates name (and wipes messages + context when the FE
  # sends `messages: []` as a session-reset signal). Regular message writes
  # are BE-only via /agent/chat — FE MUST NOT push message-shaped state
  # back here (CLAUDE.md rule #9). Incoming `messages` arrays with content
  # are ignored; only the empty-array "reset" case has effect.
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
      query!(Repo, "DELETE FROM worker_token_stats WHERE session_id=?", [session_id])
    else
      query!(Repo, """
      UPDATE sessions SET name=?, updated_at=?
      WHERE id=? AND user_id=?
      """, [name, now, session_id, user.id])
    end

    json(conn, 200, d)
  end

  # DELETE /sessions/:id
  def delete_session(conn, user, session_id) do
    # Stop any in-flight workers for this session before cleaning up
    UserAgent.cancel_session_tasks(user.id, session_id)

    query!(Repo, "DELETE FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])
    query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM session_token_stats WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM worker_token_stats WHERE session_id=?", [session_id])
    # Cascade task + session_progress rows so deleted sessions don't
    # leave orphans in the sidebar or DB (Tasks.delete_for_session/1
    # wipes both tables for this session_id).
    DmhAi.Agent.Tasks.delete_for_session(session_id)

    session_dir = user_asset_dir(user.email, session_id)
    if File.dir?(session_dir) do
      File.rm_rf!(session_dir)
    end

    json(conn, 200, %{ok: true})
  end

  # DELETE /video-descriptions/:session_id
  def delete_video_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])
      json(conn, 200, %{ok: true})
    end
  end

  # DELETE /image-descriptions/:session_id
  def delete_image_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 404, %{error: "Not found"})
    else
      query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
      json(conn, 200, %{ok: true})
    end
  end

  # GET /sessions/:session_id/token-stats (admin only)
  def get_token_stats(conn, user, session_id) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      stats = TokenTracker.get_session_stats(session_id)
      global = TokenTracker.get_global_stats(user.id)
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{session: stats, global: global}))
    end
  end

  # Private helpers

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
    |> String.trim_leading("\u201C")   # "
    |> String.trim_leading("\u2018")   # '
    |> String.trim_leading("'")
    |> String.trim_trailing("\"")
    |> String.trim_trailing("\u201D")  # "
    |> String.trim_trailing("\u2019")  # '
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

  # POST /upload-session-attachment
  # Saves a scaled-down attachment to the session workspace. The FE uploads
  # here at attach time (parallel with /assets original upload), so paths are
  # known and files are on disk well before the user hits Send.
  # Multipart fields: file, sessionId.
  def post_session_attachment(conn, user) do
    case parse_multipart(conn) do
      {:error, conn, :too_large} ->
        json(conn, 413, %{error: "File too large"})

      {:ok, conn, parts} ->
        session_id = get_in(parts, ["sessionId", :data]) || ""
        session_id = String.trim(session_id)

        cond do
          session_id == "" ->
            json(conn, 400, %{error: "Missing sessionId"})

          not owns_session?(session_id, user.id) ->
            json(conn, 403, %{error: "Forbidden"})

          true ->
            case Map.fetch(parts, "file") do
              {:ok, %{filename: filename, data: raw}} ->
                if byte_size(raw) > @max_workspace_attachment_bytes do
                  max_mb = div(@max_workspace_attachment_bytes, 1_000_000)
                  json(conn, 413, %{error: "Attachment too large (max #{max_mb} MB)"})
                else
                  filename  = filename || "upload"
                  safe_name = Regex.replace(~r/[^\w.\-]/, filename, "_")
                  workspace = DmhAi.Constants.session_workspace_dir(user.email, session_id)
                  File.mkdir_p!(workspace)
                  File.write!(Path.join(workspace, safe_name), raw)
                  Logger.info("[Data] session attachment saved session=#{session_id} name=#{safe_name}")
                  json(conn, 200, %{name: safe_name})
                end

              :error ->
                json(conn, 400, %{error: "No file field"})
            end
        end
    end
  end

  defp owns_session?(session_id, user_id) do
    result = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])
    result.rows != []
  end

  # GET /oauth/callback?code=…&state=…
  #
  # Unauthenticated — invoked by the user's browser after they
  # authorize at the provider. The state token (single-use, TTL-
  # bounded; minted in `Auth.OAuth2.init_flow/1`) ties the request
  # back to a specific user_id + session_id + connection alias.
  #
  # On success: exchanges code for tokens, persists them at
  # `target="mcp:<canonical_resource>"`, runs the MCP handshake +
  # tools/list, registers the connection, appends a synthetic
  # `service_connected` user-role message, and dispatches
  # `auto_resume_assistant` so the in-flight chain picks up the
  # newly-attached tools.
  def oauth_callback(conn) do
    conn  = fetch_query_params(conn)
    code  = conn.query_params["code"]  || ""
    state = conn.query_params["state"] || ""
    err   = conn.query_params["error"] || conn.query_params["error_description"]

    cond do
      err && err != "" ->
        oauth_html_response(conn, 400, "Authorization server returned an error: #{err}")

      code == "" or state == "" ->
        oauth_html_response(conn, 400, "Missing `code` or `state` query param.")

      true ->
        do_oauth_callback(conn, state, code)
    end
  end

  defp do_oauth_callback(conn, state, code) do
    DmhAi.SysLog.log("[OAUTH] callback hit state=#{shorten(state)} code=#{shorten(code)}")
    Logger.info("[OAuth.callback] state=#{shorten(state)} code=#{shorten(code)}")

    case DmhAi.Auth.OAuth2.complete_flow(state, code) do
      {:ok, %{
        user_id:            user_id,
        session_id:         session_id,
        anchor_task_id:     anchor_task_id,
        alias:              alias_,
        canonical_resource: resource,
        server_url:         server_url,
        asm:                asm,
        tokens:             tokens,
        flow_kind:          flow_kind
      }} ->
        DmhAi.SysLog.log("[OAUTH] callback exchange OK flow_kind=#{flow_kind} alias=#{alias_} user=#{user_id} session=#{session_id}")

        case flow_kind do
          "oauth_service" ->
            finalize_oauth_service(user_id, session_id, alias_, resource, server_url, asm, tokens)

          _ ->
            finalize_connection(user_id, session_id, anchor_task_id, alias_, resource, server_url, asm, tokens)
        end

        oauth_html_response(conn, 200, "✓ Authorized — return to your chat.")

      {:error, :not_found} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=not_found (state row gone)")
        oauth_html_response(conn, 404, "Unknown or already-used state. Start the authorization again from chat.")

      {:error, :expired} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=expired (state TTL elapsed)")
        oauth_html_response(conn, 410, "The authorization request expired. Start again from chat.")

      {:error, reason} when is_binary(reason) ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=#{reason}")
        oauth_html_response(conn, 500, "Authorization failed: #{reason}")

      {:error, reason} ->
        DmhAi.SysLog.log("[OAUTH] callback FAIL state=#{shorten(state)} reason=#{inspect(reason)}")
        oauth_html_response(conn, 500, "Authorization failed: #{inspect(reason)}")
    end
  end

  defp shorten(s) when is_binary(s) and byte_size(s) > 12, do: String.slice(s, 0, 8) <> "…"
  defp shorten(s), do: s

  defp finalize_connection(user_id, session_id, anchor_task_id, alias_, resource, server_url, asm, tokens) do
    cred_payload = %{
      "access_token"        => tokens.access_token,
      "refresh_token"       => tokens.refresh_token,
      "scope"               => tokens.scope,
      "token_type"          => tokens.token_type,
      "server_url"          => server_url,
      "alias"               => alias_,
      "canonical_resource"  => resource,
      "asm_json"            => Jason.encode!(asm),
      "client_id"           => nil,
      "client_secret"       => nil
    }

    # Pull client identifiers from the AS-scoped row and fold them
    # into the token credential's payload so the refresh hook has
    # everything it needs without an extra DB hit per refresh.
    client_target =
      "oauth_client:" <> (asm[:issuer] || asm[:authorization_endpoint] || "")

    cred_payload =
      case DmhAi.Auth.Credentials.lookup(user_id, client_target) do
        %{payload: %{"client_id" => cid} = cp} ->
          Map.merge(cred_payload, %{
            "client_id"     => cid,
            "client_secret" => cp["client_secret"]
          })

        _ ->
          cred_payload
      end

    DmhAi.Auth.Credentials.save(
      user_id,
      "mcp:" <> resource,
      "oauth2_mcp",
      cred_payload,
      notes: "MCP connection: #{alias_}",
      expires_at: tokens.expires_at
    )

    handshake_ctx = %{
      server_url:         server_url,
      canonical_resource: resource,
      access_token:       tokens.access_token
    }

    tools =
      with {:ok, _server_info, sid} <- DmhAi.MCP.Client.initialize(handshake_ctx),
           {:ok, tools}              <- DmhAi.MCP.Client.list_tools(handshake_ctx, sid) do
        tools
      else
        _ -> []
      end

    DmhAi.MCP.Registry.authorize(user_id, alias_, resource, server_url, asm)
    DmhAi.MCP.Registry.set_authorized_tools(user_id, alias_, tools)
    DmhAi.MCP.Registry.attach(anchor_task_id, user_id, alias_)

    append_service_connected_message(session_id, user_id, alias_, length(tools))

    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} -> send(pid, {:auto_resume_assistant, session_id})
      _          -> :ok
    end
  end

  # Finalizer for generic-service OAuth (flow_kind = "oauth_service").
  # Same callback URL as MCP, different shape after token exchange:
  # store at oauth:<host_match>, kind oauth2_service, no MCP Registry
  # attach. The model picks tokens up via lookup_creds and uses them
  # in run_script + curl. `resource` here carries the catalog's
  # host_match (the unique key the runtime uses for lookups).
  defp finalize_oauth_service(user_id, session_id, alias_, host_match, server_url, asm, tokens) do
    # The catalog row is the source of truth for client_id /
    # client_secret AND the per-provider extra_token_params
    # (refresh-time quirks like Auth0's `audience`). Stash both on
    # the credential so the refresh hook (`OAuth2.do_refresh`) has
    # everything it needs without re-querying the catalog mid-refresh.
    catalog_row = DmhAi.OAuth.Catalog.get_by_host(host_match)

    {client_id, client_secret, extra_token_params} =
      case catalog_row do
        %{client_id: cid, client_secret: csec, extra_token_params: etp} ->
          {cid, csec, (if is_map(etp), do: etp, else: %{})}

        _ ->
          DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: catalog miss for host=#{host_match} — refresh will likely fail without client credentials")
          {nil, nil, %{}}
      end

    cred_payload = %{
      "access_token"       => tokens.access_token,
      "refresh_token"      => tokens.refresh_token,
      "scope"              => tokens.scope,
      "token_type"         => tokens.token_type,
      "server_url"         => server_url,
      "alias"              => alias_,
      "host_match"         => host_match,
      "asm_json"           => Jason.encode!(asm),
      "extra_token_params" => extra_token_params,
      "client_id"          => client_id,
      "client_secret"      => client_secret
    }

    DmhAi.Auth.Credentials.save(
      user_id,
      "oauth:" <> host_match,
      "oauth2_service",
      cred_payload,
      notes: "OAuth connection: #{alias_}",
      expires_at: tokens.expires_at
    )

    DmhAi.SysLog.log("[OAUTH] finalize_oauth_service: stored cred user=#{user_id} target=oauth:#{host_match} expires_at=#{inspect(tokens.expires_at)}")

    append_oauth_service_connected_message(session_id, user_id, alias_, host_match)

    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} ->
        send(pid, {:auto_resume_assistant, session_id})
        DmhAi.SysLog.log("[OAUTH] auto_resume dispatched session=#{session_id}")

      _ ->
        :ok
    end
  end

  defp append_oauth_service_connected_message(session_id, user_id, alias_, host_match) do
    cred_target = "oauth:" <> host_match

    # The content tells the model EXACTLY where its access_token
    # lives. Without this hint the model often reaches for
    # `lookup_creds(target: "oauth:<alias>")` (slug-keyed) on its
    # first try and gets nothing back, then has to re-run
    # authorize_service to discover that targets are host-keyed.
    # Naming the cred_target here saves a wasted round-trip.
    content =
      "[#{alias_} authorized] Access token is now stored at " <>
      "`#{cred_target}`. Call `lookup_creds(target: \"#{cred_target}\")` " <>
      "to read it, then use it as `Authorization: Bearer <access_token>` " <>
      "in your `run_script` curl."

    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")

        msg = %{
          "role"    => "user",
          "content" => content,
          "ts"      => System.os_time(:millisecond),
          "kind"    => "service_connected",
          "service_connected" => %{
            "alias"       => alias_,
            "host_match"  => host_match,
            "cred_target" => cred_target
          }
        }

        new_msgs = msgs ++ [msg]
        now = System.os_time(:millisecond)

        query!(Repo,
          "UPDATE sessions SET messages=?, updated_at=? WHERE id=? AND user_id=?",
          [Jason.encode!(new_msgs), now, session_id, user_id])

      _ -> :ok
    end
  end

  defp append_service_connected_message(session_id, user_id, alias_, tools_count) do
    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")

        msg = %{
          "role"              => "user",
          "content"           => "[#{alias_} connected — #{tools_count} tools available]",
          "ts"                => System.os_time(:millisecond),
          "kind"              => "service_connected",
          "service_connected" => %{"alias" => alias_, "tools_count" => tools_count}
        }

        new_msgs = msgs ++ [msg]

        query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
               [Jason.encode!(new_msgs), session_id, user_id])
        :ok

      _ ->
        :ok
    end
  end

  defp oauth_html_response(conn, status, body_text) do
    html = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>OAuth</title>
    <style>
      body{font-family:system-ui,sans-serif;background:#0a0810;color:#e8d8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;text-align:center;padding:24px;}
      .box{padding:32px 40px;background:#1a1428;border:1px solid #2c2238;border-radius:8px;max-width:480px;}
      h1{margin:0 0 12px;font-size:18px;color:#60c080;}
      p{margin:0;font-size:13px;color:#b098b8;line-height:1.5;}
    </style></head>
    <body><div class="box">
      <h1>#{Plug.HTML.html_escape_to_iodata(body_text)}</h1>
      <p>You can close this tab and return to your chat session.</p>
    </div></body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  # POST /sessions/:session_id/inputs/:token
  # Submission endpoint for `request_input` forms. Body: {"values":
  # {field_name: value, ...}}. Validates the token resolves to a
  # pending form on this session, enforces single-use, expiry, and
  # field-shape, then:
  #   1. Marks the assistant message's `form` as submitted (stores
  #      `values_meta` only — no plaintext on the assistant message).
  #   2. Appends a synthetic user-role message carrying the structured
  #      payload, which the model sees on the next chain.
  #   3. Auto-resumes the session's chain via the same plumbing as a
  #      regular mid-chain user message.
  def submit_input(conn, user, session_id, token) do
    case parse_input_submission(conn) do
      {:error, status, msg} ->
        json(conn, status, %{error: msg})

      {:ok, values} ->
        cond do
          not owns_session?(session_id, user.id) ->
            json(conn, 403, %{error: "Forbidden"})

          true ->
            case do_submit_input(session_id, user.id, token, values) do
              {:ok, :sync, _ts} ->
                # request_input form_response — the synth user message
                # is already in session.messages; auto-resume the chain
                # immediately so the model sees the values.
                _ = trigger_auto_resume(user.id, session_id)
                json(conn, 200, %{ok: true})

              {:ok, :async, _ts} ->
                # connect_mcp_setup — the spawned Task owns the
                # service_connected message append and auto-resume
                # dispatch (after the MCP handshake completes). No
                # auto-resume from here.
                json(conn, 200, %{ok: true})

              {:error, :not_found} ->
                json(conn, 404, %{error: "No pending form for that token"})

              {:error, :already_submitted} ->
                json(conn, 409, %{error: "Form already submitted"})

              {:error, :expired} ->
                json(conn, 410, %{error: "Form expired"})

              {:error, :schema_mismatch} ->
                json(conn, 400, %{error: "Submitted values don't match form schema"})
            end
        end
    end
  end

  defp parse_input_submission(conn) do
    case read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, %{"values" => values}} when is_map(values) -> {:ok, values}
          _ -> {:error, 400, "Body must be JSON {\"values\": {...}}"}
        end

      _ ->
        {:error, 400, "Empty body"}
    end
  end

  defp do_submit_input(session_id, user_id, token, values) do
    result =
      query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
             [session_id, user_id])

    case result.rows do
      [[msgs_json]] ->
        msgs = Jason.decode!(msgs_json || "[]")
        now = System.os_time(:millisecond)

        case find_form(msgs, token) do
          nil ->
            {:error, :not_found}

          {idx, msg, form} ->
            cond do
              form["submitted"] == true ->
                {:error, :already_submitted}

              is_integer(form["expires_at"]) and form["expires_at"] < now ->
                {:error, :expired}

              not values_match_schema?(form["fields"] || [], values) ->
                {:error, :schema_mismatch}

              true ->
                meta = build_values_meta(form["fields"] || [], values)
                updated_form =
                  form
                  |> Map.put("submitted", true)
                  |> Map.put("submitted_at", now)
                  |> Map.put("values_meta", meta)

                updated_msg = Map.put(msg, "form", updated_form)

                case form["kind"] do
                  "connect_mcp_setup" ->
                    # Persist the form-submitted state synchronously so
                    # the FE optimistic re-render matches what the next
                    # poll returns. Then hand the slow work (MCP
                    # handshake + tools/list) off to a Task so the POST
                    # returns immediately. Append a pending progress
                    # row so polling sees `is_working=true` and the
                    # status bar shows activity during the handshake.
                    new_msgs = List.replace_at(msgs, idx, updated_msg)

                    query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
                           [Jason.encode!(new_msgs), session_id, user_id])

                    spawn_connect_mcp_setup(session_id, user_id, form, values)
                    {:ok, :async, now}

                  _ ->
                    synth_msg = build_form_response_msg(form, values, token, now)

                    new_msgs =
                      msgs
                      |> List.replace_at(idx, updated_msg)
                      |> Kernel.++([synth_msg])

                    query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
                           [Jason.encode!(new_msgs), session_id, user_id])

                    {:ok, :sync, now}
                end
            end
        end

      _ ->
        {:error, :not_found}
    end
  end

  # `request_input` form — synth a user-role message carrying the
  # submitted values so the model sees them on the next chain. LLM
  # chat-completion APIs forward only `role` + `content`; custom
  # fields drop silently on serialisation, so the values must live
  # in `content`.
  defp build_form_response_msg(form, values, token, now) do
    content =
      "[input submitted via request_input form]\n" <>
        Enum.map_join(form["fields"] || [], "\n", fn f ->
          name = f["name"] || f[:name]
          "#{name}: #{Map.get(values, name, "")}"
        end)

    %{
      "role"          => "user",
      "content"       => content,
      "ts"            => now,
      "kind"          => "form_response",
      "form_response" => %{"token" => token, "values" => values}
    }
  end

  # `connect_mcp_setup` form. Heavy work (MCP handshake +
  # tools/list, ~3 s) runs in a fire-and-forget Task so the POST
  # returns fast. A pending session_progress row appears in the chat
  # immediately so the FE polling shows "Assistant is …" status
  # during the handshake; the Task flips it to done and appends the
  # `service_connected` synthetic user message + auto-resumes when
  # the work finishes.
  defp spawn_connect_mcp_setup(session_id, user_id, form, values) do
    setup = form["setup_payload"] || %{}
    alias_ = setup["alias"] || "service"

    {:ok, prog_row} =
      DmhAi.Agent.SessionProgress.append_tool_pending(
        %{session_id: session_id, user_id: user_id, task_id: nil},
        "Connecting #{alias_}…"
      )

    Task.Supervisor.start_child(DmhAi.Agent.TaskSupervisor, fn ->
      do_connect_mcp_setup(session_id, user_id, form, values, prog_row.id)
    end)

    :ok
  end

  defp do_connect_mcp_setup(session_id, user_id, form, values, prog_id) do
    setup = form["setup_payload"] || %{}

    # The only setup form `connect_mcp` emits today is the api_key
    # form (single-field paste-your-key + auth-header dropdown). The
    # BYO-OAuth setup form is gone — admin catalog curation is the
    # path for in-house servers needing manual OAuth endpoints.
    result =
      case setup["auth_method"] do
        "api_key" -> finalize_api_key_setup(setup, values, user_id)
        other     -> {:error, "auth_method '#{inspect(other)}' not supported"}
      end

    DmhAi.Agent.SessionProgress.mark_tool_done(prog_id)

    msg = build_service_connected_msg(setup, result)
    append_session_user_msg(session_id, user_id, msg)

    trigger_auto_resume(user_id, session_id)
    :ok
  rescue
    e ->
      DmhAi.Agent.SessionProgress.mark_tool_done(prog_id)

      msg = build_service_connected_msg(form["setup_payload"] || %{},
              {:error, "internal error: #{inspect(e)}"})
      append_session_user_msg(session_id, user_id, msg)

      trigger_auto_resume(user_id, session_id)
      :ok
  end

  # Map dropdown option values (set in `connect_mcp`'s api_key
  # form) to the actual header name + optional value prefix. Keeping
  # this small table in one place lets the form options stay
  # human-friendly while the BE knows exactly what bytes to send.
  @auth_header_choices %{
    "Authorization"      => {"Authorization",      "Bearer "},
    "x-api-key"          => {"x-api-key",          ""},
    "x-consumer-api-key" => {"x-consumer-api-key", ""}
  }

  defp finalize_api_key_setup(setup, values, user_id) do
    alias_         = setup["alias"]
    server_url     = setup["server_url"]
    anchor_task_id = setup["anchor_task_id"]
    canonical      = server_url
    api_key        = (values["api_key"] || "") |> String.trim()
    choice         = (values["auth_header"] || "Authorization") |> String.trim()

    cond do
      api_key == "" ->
        {:error, "API key is empty"}

      not Map.has_key?(@auth_header_choices, choice) ->
        {:error, "Unknown auth header choice: #{inspect(choice)}"}

      not is_binary(anchor_task_id) ->
        {:error, "setup payload missing anchor_task_id"}

      true ->
        {header, prefix} = Map.fetch!(@auth_header_choices, choice)
        value = prefix <> api_key

        handshake_ctx = %{
          server_url:         server_url,
          canonical_resource: canonical,
          auth: %{
            type:               "api_key",
            header:             header,
            key:                value,
            canonical_resource: canonical
          }
        }

        with {:ok, _info, sid} <- DmhAi.MCP.Client.initialize(handshake_ctx),
             {:ok, tools}       <- DmhAi.MCP.Client.list_tools(handshake_ctx, sid) do
          cred_payload = %{
            "api_key"            => value,
            "api_key_header"     => header,
            "server_url"         => server_url,
            "alias"              => alias_,
            "canonical_resource" => canonical
          }

          DmhAi.Auth.Credentials.save(
            user_id,
            "mcp:" <> canonical,
            "api_key_mcp",
            cred_payload,
            notes: "API-key MCP connection: #{alias_} (header: #{header})"
          )

          DmhAi.MCP.Registry.authorize(user_id, alias_, canonical, server_url, nil)
          DmhAi.MCP.Registry.set_authorized_tools(user_id, alias_, tools)
          DmhAi.MCP.Registry.attach(anchor_task_id, user_id, alias_)
          {:ok, %{alias: alias_, tools_count: length(tools)}}
        else
          {:error, reason} ->
            {:error, format_handshake_error(choice, reason)}
        end
    end
  end

  defp format_handshake_error(choice, {:status, 401, body}) do
    server_msg =
      case body do
        %{"error" => msg} when is_binary(msg) -> msg
        _ -> inspect(body)
      end

    other_choices =
      @auth_header_choices
      |> Map.keys()
      |> Enum.reject(&(&1 == choice))
      |> Enum.join(" / ")

    "Server returned 401 with the `#{choice}` auth header. Server says: #{server_msg}. " <>
      "If the URL is right, retry connect_mcp and pick a different header (#{other_choices}). " <>
      "If that still 401s, the URL is probably not a real MCP endpoint."
  end

  defp format_handshake_error(choice, {:status, status, body}),
    do: "Server returned HTTP #{status} with the `#{choice}` header. Body: #{inspect(body)}."

  defp format_handshake_error(choice, reason),
    do: "MCP handshake failed (header: `#{choice}`): #{inspect(reason)}. The URL may not be a real MCP endpoint."

  @doc false
  # Public for unit testing in `itgr_oauth_manual_setup.exs`. Not
  # part of the module's user-facing API; subject to change without
  # notice.
  #
  # ── oauth (manual) form finalization ──────────────────────────────────
  #
  # The form was filled with the AS endpoints + client credentials the
  # user copied from the provider's dashboard (used when the AS does
  # NOT publish RFC 8414 metadata or RFC 7591 DCR). We synthesise the
  # ASM map the rest of the pipeline expects, save the manual
  # `oauth_client` row keyed by auth_endpoint (so the callback can
  # fold client identifiers into the token payload), and feed
  # everything through the same `Auth.OAuth2.init_flow/1` the auto
  # path uses. Returns `{:ok, %{alias, auth_url}}` on success — the
  # caller renders the auth_url to the user; the OAuth callback at
  # `/oauth/callback` finishes the token exchange + handshake.

  defp build_service_connected_msg(_setup, {:ok, %{alias: alias_, tools_count: n}}) do
    %{
      "role"              => "user",
      "content"           => "[#{alias_} connected — #{n} tools available]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_connected",
      "service_connected" => %{"alias" => alias_, "tools_count" => n, "error" => nil}
    }
  end

  # Manual OAuth path: form was submitted, init_flow succeeded, and we
  # now have an authorization URL the user must visit to grant access.
  # The connection completes asynchronously when the OAuth callback
  # fires — `finalize_connection` runs the MCP handshake there and
  # auto-resumes the assistant. The message here renders the auth_url
  # inline as a clickable markdown link so the user can act without
  # an extra assistant turn relaying it.
  defp build_service_connected_msg(_setup, {:ok, %{alias: alias_, auth_url: auth_url}}) do
    %{
      "role"              => "user",
      "content"           =>
        "[#{alias_} authorization step — please visit this URL to authorize, then your task will resume:\n\n" <>
          auth_url <>
          "\n]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_setup_authorize",
      "service_setup_authorize" => %{"alias" => alias_, "auth_url" => auth_url}
    }
  end

  defp build_service_connected_msg(setup, {:error, reason}) do
    alias_ = setup["alias"] || "service"

    %{
      "role"              => "user",
      "content"           => "[#{alias_} connection error — #{reason}]",
      "ts"                => System.os_time(:millisecond),
      "kind"              => "service_connected",
      "service_connected" => %{"alias" => alias_, "tools_count" => 0, "error" => reason}
    }
  end

  defp append_session_user_msg(session_id, user_id, msg) do
    case query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [session_id, user_id]) do
      %{rows: [[msgs_json]]} ->
        msgs = Jason.decode!(msgs_json || "[]")
        new_msgs = msgs ++ [msg]

        query!(Repo, "UPDATE sessions SET messages=? WHERE id=? AND user_id=?",
               [Jason.encode!(new_msgs), session_id, user_id])
        :ok

      _ ->
        :ok
    end
  end

  defp trigger_auto_resume(user_id, session_id) do
    case DmhAi.Agent.Supervisor.ensure_started(user_id) do
      {:ok, pid} -> send(pid, {:auto_resume_assistant, session_id})
      _          -> :ok
    end
  end

  defp find_form(msgs, token) do
    msgs
    |> Enum.with_index()
    |> Enum.find_value(fn {m, idx} ->
      with %{"role" => "assistant", "form" => %{"token" => ^token} = form} <- m do
        {idx, m, form}
      else
        _ -> nil
      end
    end)
  end

  defp values_match_schema?(fields, values) when is_list(fields) and is_map(values) do
    Enum.all?(fields, fn f ->
      name = f["name"] || f[:name]
      Map.has_key?(values, name) and is_binary(values[name])
    end)
  end

  defp values_match_schema?(_, _), do: false

  # Build a per-field [{name, secret, length}] list to persist on the
  # assistant message — gives the FE enough to render a "✓ Submitted"
  # summary without ever holding the plaintext value after submit.
  defp build_values_meta(fields, values) do
    Enum.map(fields, fn f ->
      name   = f["name"]   || f[:name]
      secret = f["secret"] || f[:secret] || false
      val    = Map.get(values, name) || ""
      %{"name" => name, "secret" => secret, "length" => String.length(val)}
    end)
  end

  defp user_asset_dir(email, session_id) do
    DmhAi.Constants.session_root(email, session_id)
  end

  defp guess_mime(filename_or_path) do
    ext = Path.extname(filename_or_path) |> String.downcase()

    case ext do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      ".pdf" -> "application/pdf"
      ".txt" -> "text/plain"
      ".html" -> "text/html"
      ".json" -> "application/json"
      _ -> "application/octet-stream"
    end
  end

  defp parse_multipart(conn) do
    content_type = get_req_header(conn, "content-type") |> List.first() || ""

    case read_body(conn, length: 350_000_000) do
      {:ok, body, conn} ->
        parts = parse_multipart_body(body, content_type)
        {:ok, conn, parts}

      {:more, _body, conn} ->
        {:error, conn, :too_large}
    end
  end

  defp parse_multipart_body(data, content_type) do
    boundary =
      content_type
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.find_value(fn part ->
        if String.starts_with?(part, "boundary=") do
          part |> String.slice(9..-1//1) |> String.trim("\"") |> String.trim("'")
        end
      end)

    if is_nil(boundary) do
      %{}
    else
      sep = "--" <> boundary
      sep_bin = :binary.bin_to_list(sep) |> :binary.list_to_bin()

      data
      |> :binary.split(sep_bin, [:global])
      |> Enum.drop(1)
      |> Enum.reduce(%{}, fn chunk, acc ->
        chunk = String.trim_trailing(chunk, "--")

        if :binary.match(chunk, "\r\n\r\n") == :nomatch do
          acc
        else
          [head, body_part] = :binary.split(chunk, "\r\n\r\n")
          body_part = String.trim_trailing(body_part, "\r\n")

          {name, filename} =
            head
            |> String.split("\r\n")
            |> Enum.find_value({nil, nil}, fn line ->
              if String.downcase(line) |> String.contains?("content-disposition") do
                parts = String.split(line, ";") |> Enum.map(&String.trim/1)

                name =
                  Enum.find_value(parts, fn p ->
                    if String.starts_with?(String.downcase(p), "name=") do
                      p |> String.slice(5..-1//1) |> String.trim("\"") |> String.trim("'")
                    end
                  end)

                filename =
                  Enum.find_value(parts, fn p ->
                    if String.starts_with?(String.downcase(p), "filename=") do
                      p |> String.slice(9..-1//1) |> String.trim("\"") |> String.trim("'")
                    end
                  end)

                {name, filename}
              end
            end)

          if name do
            Map.put(acc, name, %{filename: filename, data: body_part})
          else
            acc
          end
        end
      end)
    end
  end

  defp log(msg), do: DmhAi.SysLog.log(msg)
end
