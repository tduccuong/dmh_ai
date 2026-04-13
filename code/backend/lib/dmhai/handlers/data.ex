defmodule Dmhai.Handlers.Data do
  import Plug.Conn
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @assets_dir "/data/user_assets"
  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_exts ~w(.mp4 .webm .mov .avi .mkv .m4v .3gp .ogv)

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /assets/:session_id/:file_id
  def get_asset(conn, user, session_id, file_id) do
    session_dir = user_asset_dir(user.email, session_id)
    file_path = Path.expand(Path.join(session_dir, file_id))
    assets_real = Path.expand(@assets_dir)

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
      SELECT id, name, model, messages, context, created_at, updated_at
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
      SELECT id, name, model, messages, context, created_at, updated_at
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

    query!(Repo, """
    INSERT INTO sessions (id, name, model, messages, context, created_at, updated_at, user_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, [
      d["id"],
      d["name"],
      d["model"] || "",
      Jason.encode!(d["messages"] || []),
      Jason.encode!(d["context"]),
      d["createdAt"],
      now,
      user.id
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
            session_dir = user_asset_dir(user.email, session_id)
            File.mkdir_p!(session_dir)

            ts = :os.system_time(:millisecond)
            safe_name = "#{ts}_#{Regex.replace(~r/[^\w.\-]/, filename, "_")}"
            File.write!(Path.join(session_dir, safe_name), raw)

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

  # PUT /sessions/:id
  def put_session(conn, user, session_id) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    now = :os.system_time(:millisecond)

    query!(Repo, """
    UPDATE sessions SET name=?, model=?, messages=?, context=?, updated_at=?
    WHERE id=? AND user_id=?
    """, [
      d["name"],
      d["model"] || "",
      Jason.encode!(d["messages"] || []),
      Jason.encode!(d["context"]),
      now,
      session_id,
      user.id
    ])

    json(conn, 200, d)
  end

  # DELETE /sessions/:id
  def delete_session(conn, user, session_id) do
    query!(Repo, "DELETE FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])
    query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
    query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])

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

  # Private helpers

  defp parse_session_row([id, name, model, messages, context, created_at, updated_at]) do
    %{
      "id" => id,
      "name" => name,
      "model" => model,
      "messages" => Jason.decode!(messages || "[]"),
      "context" => Jason.decode!(context || "null"),
      "createdAt" => created_at,
      "updatedAt" => updated_at
    }
  end

  defp user_asset_dir(email, session_id) do
    safe_session = Regex.replace(~r/[^\w\-]/, session_id, "_")
    Path.join([@assets_dir, email, safe_session])
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

  defp log(msg) do
    log_file = "/data/system_logs/system.log"
    File.mkdir_p!(Path.dirname(log_file))
    ts = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
    line = "[#{ts}] #{msg}\n"
    File.write!(log_file, line, [:append])
  end
end
