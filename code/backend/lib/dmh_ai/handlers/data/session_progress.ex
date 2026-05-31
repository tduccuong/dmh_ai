# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.SessionProgress do
  @moduledoc """
  Progress-row reads + the unified polling endpoint.

  * GET /sessions/:id/progress?since=<id>
  * GET /sessions/:id/poll?msg_since=<ts>&prog_since=<id>

  The poll endpoint is the FE's main heartbeat: it fans out message
  delta + progress delta + the in-memory stream / thinking buffers and
  computes the `is_working` / `agent_busy` flags driving the FE's
  poll cadence and "Assistant is …" status bar.
  """

  import Plug.Conn

  alias DmhAi.Repo
  alias DmhAi.Handlers.Data
  import Ecto.Adapters.SQL, only: [query!: 3]

  # GET /sessions/:id/progress?since=<id>
  # Returns the session's progress rows after the given id (delta-load).
  # The FE polls this at its own cadence while a task is active; when no tasks
  # are running it can back off to a slower cadence (or skip entirely).
  def get_session_progress(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
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
      Data.json(conn, 200, %{progress: rows})
    end
  end

  # GET /sessions/:id/poll?msg_since=<ts>&prog_since=<id>
  # Unified delta endpoint for the FE's polling loop.
  # Returns:
  #   - messages:      new session.messages entries with ts > msg_since
  #   - progress:      new session_progress rows with id > prog_since
  #   - stream_buffer: partial final-answer text currently being streamed
  #                    (read from EphemeralCache ETS, NOT the DB), or "" / nil
  #   - is_working:    true when a turn is in flight (buffer non-null OR ongoing task)
  def poll_session(conn, user, session_id) do
    result =
      query!(Repo,
             "SELECT messages FROM sessions WHERE id=? AND user_id=?",
             [session_id, user.id])

    case result.rows do
      [[msgs_json]] ->
        # Streaming state lives in ETS (DmhAi.Agent.EphemeralCache),
        # NOT the `sessions` table — per-token DB writes monopolised
        # SQLite's single-writer slot. See architecture.md
        # §Streaming state lives in ETS, not the DB.
        #
        # Preserve the FE contract: `nil` when no active stream, the
        # text string when streaming. ETS returns `""` for missing
        # keys; remap to `nil` so `is_binary(stream_buffer)` continues
        # to mean "active stream".
        stream_buffer =
          case DmhAi.Agent.StreamBuffer.read(session_id, user.id) do
            "" -> nil
            s  -> s
          end

        thinking_buffer =
          case DmhAi.Agent.ThinkingBuffer.read(session_id, user.id) do
            "" -> nil
            s  -> s
          end
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
        # thinking..." / "Assistant is streaming the answer..."). Three
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
        # pipeline (e.g. /index URL crawl) is registered. Each
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
        # `is_working`, which can be true for ambient reasons (a queued
        # user message about to be picked up) that don't yet have a
        # Task to kill.
        agent_busy_session_id = DmhAi.Agent.UserAgent.current_turn_session_id(user.id)
        agent_busy = agent_busy_session_id == session_id

        Data.json(conn, 200, %{
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
        Data.json(conn, 404, %{error: "Not found"})
    end
  end
end
