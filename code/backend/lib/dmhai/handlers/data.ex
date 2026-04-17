# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Handlers.Data do
  import Plug.Conn
  alias Dmhai.{Repo, Agent.LLM, Agent.TokenTracker, Agent.UserAgent}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # Dedicated model for session naming; fast, cheap, 1M context.
  @namer_model "ollama::cloud::gemini-3-flash-preview:cloud"

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_exts ~w(.mp4 .webm .mov .avi .mkv .m4v .3gp .ogv)

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /assets/:session_id/:file_id
  # Serves user-uploaded files from <session_root>/data/. Worker-scratch files
  # under <session_root>/<origin>/jobs/<job>/ are intentionally not served —
  # the worker should persist anything user-facing via signal(result) or by
  # writing to the data/ subdir explicitly.
  def get_asset(conn, user, session_id, file_id) do
    data_dir    = Dmhai.Constants.session_data_dir(user.email, session_id)
    file_path   = Path.expand(Path.join(data_dir, file_id))
    assets_real = Path.expand(Dmhai.Constants.assets_dir())

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

  # GET /notifications?since=<unix_millis>
  def get_notifications(conn, user) do
    params = URI.decode_query(conn.query_string)
    since = String.to_integer(params["since"] || "0")
    entries = Dmhai.Agent.MasterBuffer.fetch_notifications(user.id, since)
    json(conn, 200, entries)
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
            data_dir = Dmhai.Constants.session_data_dir(user.email, session_id)
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

  # POST /sessions/:id/name — call LLM to generate and persist a session name
  def post_name_session(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      json(conn, 403, %{error: "Forbidden"})
    else
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=?", [session_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          # Use up to last 6 messages for naming context
          excerpt_msgs = Enum.take(msgs, -6)

          excerpt =
            Enum.map_join(excerpt_msgs, "\n", fn msg ->
              role    = msg["role"] || "user"
              content = msg["content"] || ""
              prefix  = if role == "user", do: "User: ", else: "Assistant: "
              prefix <> String.slice(to_string(content), 0, 200)
            end)

          if String.trim(excerpt) == "" do
            json(conn, 200, %{name: nil})
          else
            messages = [%{
              role: "user",
              content:
                "Give a short title (3-5 words) for this conversation:\n\n#{excerpt}\n\n" <>
                "Use the language that dominates the conversation. " <>
                "Reply with only the title, no quotes, no explanation."
            }]

            case LLM.call(@namer_model, messages) do
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

  # PUT /sessions/:id
  def put_session(conn, user, session_id) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    now = :os.system_time(:millisecond)
    messages = d["messages"] || []

    # When messages are cleared (session reset), also wipe server-owned context
    # so the compaction summary doesn't bleed into the fresh conversation.
    if messages == [] do
      query!(Repo, """
      UPDATE sessions SET name=?, messages=?, context=NULL, updated_at=?
      WHERE id=? AND user_id=?
      """, [sanitize_session_name(d["name"]), "[]", now, session_id, user.id])
      query!(Repo, "DELETE FROM session_token_stats WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM worker_token_stats WHERE session_id=?", [session_id])
    else
      query!(Repo, """
      UPDATE sessions SET name=?, messages=?, updated_at=?
      WHERE id=? AND user_id=?
      """, [
        sanitize_session_name(d["name"]),
        Jason.encode!(messages),
        now,
        session_id,
        user.id
      ])
    end

    json(conn, 200, d)
  end

  # DELETE /sessions/:id
  def delete_session(conn, user, session_id) do
    # Stop any in-flight workers for this session before cleaning up
    UserAgent.cancel_session_workers(user.id, session_id)

    query!(Repo, "DELETE FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])
    query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM master_buffer WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM session_token_stats WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM worker_token_stats WHERE session_id=?", [session_id])

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

  defp user_asset_dir(email, session_id) do
    Dmhai.Constants.session_root(email, session_id)
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

  defp log(msg), do: Dmhai.SysLog.log(msg)
end
