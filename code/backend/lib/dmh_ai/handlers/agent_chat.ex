# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.AgentChat do
  @moduledoc """
  POST /agent/chat — fire-and-forget entry point for a chat turn.

  The handler persists the user message with a BE-stamped `ts`, dispatches
  the turn to the UserAgent (which runs it asynchronously in a supervised
  Task), and immediately returns `{user_ts}` as JSON. All subsequent
  output (progress rows, streaming-buffer tokens for the final answer,
  the assistant message itself) lands in DB tables and reaches the FE via
  polling (`GET /sessions/:id/poll`). See specs/architecture.md
  §Polling-based delivery.

  Request body (JSON):
    sessionId   — required
    content     — required (or attachments present)
    images      — optional, list of base64 strings (photos or video frames)
    imageNames  — optional, list of filenames for each image
    files       — optional, list of %{"name", "content"} maps (extracted text)
    hasVideo    — optional bool, true when images are video frames

  Response: `{"user_ts": <int>}` on success (HTTP 202 Accepted).
  """

  import Plug.Conn
  alias DmhAi.Repo
  alias DmhAi.Adapters.Http
  import Ecto.Adapters.SQL, only: [query!: 3]

  # 50 MB — accommodates multiple base64-encoded images in a request.
  @max_body_bytes 52_428_800
  # Guard against excessively large attachment lists.
  @max_attachments 20

  def post_chat(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")

    session_id = String.trim(d["sessionId"] || "")

    cond do
      session_id == "" ->
        json(conn, 400, %{error: "Missing sessionId"})

      not session_owned?(session_id, user.id) ->
        json(conn, 403, %{error: "Forbidden"})

      true ->
        handle_chat(conn, user, d, session_id)
    end
  end

  defp handle_chat(conn, user, d, session_id) do
    content     = String.trim(d["content"] || "")
    images      = parse_images(d["images"])
    image_names = parse_string_list(d["imageNames"])
    files       = parse_files(d["files"])
    has_video   = d["hasVideo"] == true

    # Attachments live in `<session>/data/uploaded/<unix_ms>_<name>` — the
    # FE sends the `/assets`-returned id (`"uploaded/<unix_ms>_<name>"`) in
    # `attachmentNames`. We resolve each id to an absolute path; runtime
    # slash commands (`/tts`, `/duolang`) read those paths directly. The
    # persisted user message stays clean (no path markers).
    attachment_ids = d["attachmentNames"] |> parse_string_list() |> Enum.take(@max_attachments)
    image_paths = resolve_uploaded_paths(user.email, session_id, attachment_ids)

    has_payload = content != "" or images != [] or files != [] or image_paths != []

    if not has_payload do
      json(conn, 400, %{error: "Missing content"})
    else
      # Slash-command intercept. Two outcomes:
      #   * `{:handled, _}` — runtime took it.
      #   * `:not_a_command` — plain user message, continue.
      command_result =
        DmhAi.Commands.dispatch(content, session_id, user.id, request_lang(d), image_paths)

      case command_result do
        {:handled, user_ts} ->
          json(conn, 200, %{user_ts: user_ts, handled: true})

        :not_a_command ->
          # BE owns every persisted message write. Store the user's
          # literal text (no augmentation); image base64 payloads flow
          # through the current request and feed the LLM inline, but are
          # not persisted on the stored message.
          {tz, local_date} = client_tz(conn)
          case DmhAi.Agent.UserAgentMessages.append(session_id, user.id,
                  %{role: "user", content: content}) do
            {:ok, user_ts} ->
              fire_and_forget(conn, user_ts, fn ->
                Http.dispatch_confidant(user.id, session_id, content, self(),
                  images:      images,
                  image_names: image_names,
                  files:       files,
                  has_video:   has_video,
                  timezone:    tz,
                  local_date:  local_date
                )
              end)

            {:error, reason} ->
              json(conn, 500, %{error: "Failed to persist message: #{inspect(reason)}"})
          end
      end
    end
  end

  # Dispatch the turn and return immediately. The pipeline runs in a
  # Task.Supervisor-supervised process; its output flows to DB tables
  # (session.messages, session_progress, sessions.stream_buffer) and the
  # FE polls `/sessions/:id/poll` for updates. The pipeline is a one-shot
  # streaming reply — busy stays a 409 so the FE surfaces "please wait".
  defp fire_and_forget(conn, user_ts, dispatch_fun) do
    case dispatch_fun.() do
      :ok ->
        json(conn, 202, %{user_ts: user_ts})

      {:error, :busy} ->
        json(conn, 409, %{error: "Agent is busy, please wait", user_ts: user_ts})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason), user_ts: user_ts})
    end
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────

  defp session_owned?(session_id, user_id) do
    case query!(Repo, "SELECT 1 FROM sessions WHERE id=? AND user_id=?", [session_id, user_id]) do
      %{rows: [[_]]} -> true
      _ -> false
    end
  end

  # Resolve `attachmentNames` (path-shaped /assets ids like
  # `"uploaded/<unix_ms>_<safe_name>"`) to absolute paths under
  # `<session>/data/<id>`. The `/assets` POST has already returned by the
  # time the FE sends, so the file is on disk; no wait needed. We
  # path-validate to keep an attacker-controlled id from climbing out of
  # the per-session uploaded directory.
  defp resolve_uploaded_paths(_email, _session_id, []), do: []
  defp resolve_uploaded_paths(email, session_id, ids) do
    data_dir = DmhAi.Constants.session_data_dir(email, session_id) |> Path.expand()

    ids
    |> Enum.map(fn id -> Path.expand(Path.join(data_dir, id)) end)
    |> Enum.filter(fn abs ->
      (abs == data_dir or String.starts_with?(abs, data_dir <> "/")) and File.regular?(abs)
    end)
  end

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

  # Read the FE-supplied locale (`I18n._lang`) from the request body.
  # Used by the slash-command runtime (e.g. /memo's static-i18n ack) to
  # render in the user's language without an LLM round-trip. Falls back to
  # "en" if absent or malformed; downstream `normalize_lang/1` in
  # `Commands.Memo` validates against the supported set.
  defp request_lang(%{"lang" => l}) when is_binary(l) and l != "", do: l
  defp request_lang(_), do: "en"

  # Read the client's timezone + locally-computed date from the
  # `X-Timezone` and `X-Local-Date` request headers. Both come from
  # `apiFetch` in `core.js`. Returns `{tz, local_date}` with `nil` for any
  # header the FE didn't send; the system prompt builder treats nils as
  # "fall back to UTC."
  defp client_tz(conn) do
    tz =
      case get_req_header(conn, "x-timezone") do
        [s | _] when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 64 -> s
        _ -> nil
      end

    local_date =
      case get_req_header(conn, "x-local-date") do
        [s | _] ->
          if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, s), do: s, else: nil
        _ ->
          nil
      end

    {tz, local_date}
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
