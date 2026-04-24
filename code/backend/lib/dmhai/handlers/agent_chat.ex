# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Handlers.AgentChat do
  @moduledoc """
  POST /agent/chat — fire-and-forget entry point for a chat turn.

  The handler persists the user message with a BE-stamped `ts`, dispatches
  the turn to the UserAgent (which runs it asynchronously in a supervised
  Task), and immediately returns `{user_ts}` as JSON. All subsequent
  output (progress rows, streaming-buffer tokens for the final answer,
  the assistant message itself) lands in DB tables and reaches the FE via
  polling (`GET /sessions/:id/poll`). See specs/architecture.md
  §Polling-based delivery.

  Strict path separation
  ----------------------
  This handler looks up `session.mode` FIRST and branches into either the
  Confidant handler or the Assistant handler. The two paths share no
  command type and no dispatcher; body fields that belong to one path are
  not even parsed by the other.

  Request body (JSON) — Confidant mode:
    sessionId   — required
    content     — required
    images      — optional, list of base64 strings (photos or video frames)
    imageNames  — optional, list of filenames for each image
    files       — optional, list of %{"name", "content"} maps (extracted text)
    hasVideo    — optional bool, true when images are video frames

  Request body (JSON) — Assistant mode:
    sessionId        — required
    content          — required (empty allowed when attachmentNames is non-empty)
    attachmentNames  — optional, list of filenames already uploaded to
                       <session>/workspace/ at attach time. Paths are
                       inlined into the persisted user message.
    files            — optional, list of %{"name", "content"} maps

  Response: `{"user_ts": <int>}` on success (HTTP 202 Accepted).
  """

  import Plug.Conn
  alias Dmhai.Repo
  alias Dmhai.Adapters.Http
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # 50 MB — accommodates multiple base64-encoded images in a Confidant request.
  @max_body_bytes 52_428_800
  # Guard against excessively large attachment lists.
  @max_attachments 20
  # Safety net — uploads almost always finish before send. If the FE raced
  # us we poll briefly before giving up.
  @attachment_wait_timeout_ms 30_000
  @attachment_poll_ms 200

  def post_chat(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")

    session_id = String.trim(d["sessionId"] || "")

    cond do
      session_id == "" ->
        json(conn, 400, %{error: "Missing sessionId"})

      true ->
        case lookup_session_mode(session_id, user.id) do
          :not_found ->
            json(conn, 403, %{error: "Forbidden"})

          {:ok, "assistant"} ->
            handle_assistant_chat(conn, user, d, session_id)

          {:ok, _confidant_or_default} ->
            handle_confidant_chat(conn, user, d, session_id)
        end
    end
  end

  # ─── Assistant path ───────────────────────────────────────────────────────

  defp handle_assistant_chat(conn, user, d, session_id) do
    content = String.trim(d["content"] || "")
    files   = parse_files(d["files"])

    # FE-supplied idempotency key. Persisted alongside the message so a
    # lost POST response + FE retry (or a BE crash + FE poll-based
    # recovery) resolves to the same canonical row instead of creating
    # a duplicate. See architecture.md §Mid-chain user message
    # injection. Optional — legacy clients and non-FE POSTs may omit it.
    client_msg_id =
      case d["client_msg_id"] do
        s when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 128 -> s
        _ -> nil
      end

    attachment_names =
      d["attachmentNames"]
      |> parse_string_list()
      |> Enum.take(@max_attachments)
      |> Enum.map(&sanitize_filename/1)

    has_payload = content != "" or files != [] or attachment_names != []

    if not has_payload do
      json(conn, 400, %{error: "Missing content"})
    else
      # Safety net: attach-time uploads should already be on disk; wait a
      # bounded window if they're not.
      if attachment_names != [] do
        workspace = Dmhai.Constants.session_workspace_dir(user.email, session_id)
        case wait_for_attachments(workspace, attachment_names) do
          :ok -> :ok
          :timeout ->
            Logger.warning("[AgentChat] attachment wait timed out session=#{session_id}")
        end
      end

      # Build and persist the user message ourselves (CLAUDE.md rule #9).
      # FE no longer PUTs session.messages; the BE is the sole writer from
      # this entry point on. Attachment paths are inlined into content so the
      # stored message is canonical.
      stored_content =
        if attachment_names == [] do
          content
        else
          paths = Enum.map_join(attachment_names, "\n", fn name -> "📎 workspace/" <> name end)
          if content == "", do: paths, else: content <> "\n\n" <> paths
        end

      message = %{role: "user", content: stored_content}
      message = if client_msg_id, do: Map.put(message, :client_msg_id, client_msg_id), else: message

      # Phase 3: tag the incoming user message with the current anchor's
      # task_num (if any). Persists alongside role/content/ts so the
      # per-task archive can partition correctly when compaction fires.
      # No anchor → no tag (pure-chat / pre-task-creation messages). See
      # architecture.md §Per-message task tag.
      message =
        case Dmhai.Agent.Anchor.task_num_for(session_id) do
          n when is_integer(n) -> Map.put(message, :task_num, n)
          _                     -> message
        end

      case Dmhai.Agent.UserAgentMessages.append(session_id, user.id, message) do
        {:ok, user_ts} ->
          fire_and_forget(conn, user_ts, fn ->
            Http.dispatch_assistant(user.id, session_id, content, self(),
              attachment_names: attachment_names,
              files:            files
            )
          end)

        {:error, reason} ->
          json(conn, 500, %{error: "Failed to persist message: #{inspect(reason)}"})
      end
    end
  end

  # ─── Confidant path ───────────────────────────────────────────────────────

  defp handle_confidant_chat(conn, user, d, session_id) do
    content     = String.trim(d["content"] || "")
    images      = parse_images(d["images"])
    image_names = parse_string_list(d["imageNames"])
    files       = parse_files(d["files"])
    has_video   = d["hasVideo"] == true

    has_payload = content != "" or images != [] or files != []

    if not has_payload do
      json(conn, 400, %{error: "Missing content"})
    else
      # BE-owned writes (CLAUDE.md rule #9). Store text only — image base64
      # payloads flow through the current request and feed the LLM inline;
      # they are not persisted on the stored message.
      case Dmhai.Agent.UserAgentMessages.append(session_id, user.id,
              %{role: "user", content: content}) do
        {:ok, user_ts} ->
          fire_and_forget(conn, user_ts, fn ->
            Http.dispatch_confidant(user.id, session_id, content, self(),
              images:      images,
              image_names: image_names,
              files:       files,
              has_video:   has_video
            )
          end)

        {:error, reason} ->
          json(conn, 500, %{error: "Failed to persist message: #{inspect(reason)}"})
      end
    end
  end

  # Dispatch the turn and return immediately. The pipeline runs in a
  # Task.Supervisor-supervised process; its output flows to DB tables
  # (session.messages, session_progress, sessions.stream_buffer) and the
  # FE polls `/sessions/:id/poll` for updates. No chunked response here.
  #
  # For Assistant mode, busy is NOT an error: the user message has
  # already been persisted to `session.messages` before we get here,
  # so it's queued by definition. The UserAgent's chain-complete hook
  # (and the mid-chain splice inside `session_chain_loop`) picks it up.
  # See architecture.md §Mid-chain user message injection.
  #
  # For Confidant mode, there is no chain to fold into — the pipeline is
  # a one-shot streaming reply. Busy stays a 409 so the FE surfaces
  # "please wait" to the user (matches pre-Phase-2 behaviour for
  # Confidant specifically).
  defp fire_and_forget(conn, user_ts, dispatch_fun) do
    case dispatch_fun.() do
      :ok ->
        json(conn, 202, %{user_ts: user_ts})

      {:error, :queued} ->
        json(conn, 202, %{user_ts: user_ts, queued: true})

      {:error, :busy} ->
        json(conn, 409, %{error: "Agent is busy, please wait", user_ts: user_ts})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason), user_ts: user_ts})
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp lookup_session_mode(session_id, user_id) do
    result = query!(Repo, "SELECT mode FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])

    case result.rows do
      [[mode]] -> {:ok, mode || "confidant"}
      _        -> :not_found
    end
  end

  defp wait_for_attachments(workspace, names) do
    deadline = System.os_time(:millisecond) + @attachment_wait_timeout_ms
    do_wait_attachments(workspace, names, deadline)
  end

  defp do_wait_attachments(workspace, names, deadline) do
    missing = Enum.reject(names, &File.exists?(Path.join(workspace, &1)))

    cond do
      missing == [] ->
        :ok

      System.os_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@attachment_poll_ms)
        do_wait_attachments(workspace, names, deadline)
    end
  end

  # Match the server-side sanitization in post_session_attachment so names align.
  defp sanitize_filename(name) when is_binary(name),
    do: Regex.replace(~r/[^\w.\-]/, name, "_")

  defp parse_images(nil), do: []
  defp parse_images(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end
  defp parse_images(_), do: []

  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp parse_string_list(_), do: []

  defp parse_files(nil), do: []
  defp parse_files(list) when is_list(list) do
    Enum.filter(list, fn f ->
      is_map(f) and is_binary(f["name"]) and is_binary(f["content"])
    end)
  end
  defp parse_files(_), do: []

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
