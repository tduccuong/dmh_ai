# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.Assets do
  @moduledoc """
  Asset (file) up/down through the session data dir + the scaled-attachment
  upload to the session workspace.

  Endpoints:
  * GET  /assets/:session_id/*rest
  * POST /assets
  * POST /upload-session-attachment

  Owns multipart parsing + mime guessing — both are local to file I/O
  and have no other call sites.
  """

  import Plug.Conn
  require Logger

  alias DmhAi.Handlers.Data
  alias DmhAi.Handlers.Data.Sessions

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_exts ~w(.mp4 .webm .mov .avi .mkv .m4v .3gp .ogv)

  # Max size for original video uploads to <session>/data/ (permanent user storage).
  # Must match MEDIA_MAX_SIZE_BYTES on the frontend.
  @max_original_video_bytes 300_000_000

  # Max size for scaled attachments uploaded to the worker workspace.
  # Scaled videos at 800 kbps: ~6 MB/min → covers clips up to ~30 min.
  @max_workspace_attachment_bytes 200_000_000

  # GET /assets/:session_id/*rest
  # Serves files from <session_data_dir>. `rest` is the path under
  # data/ — typically `uploaded/<filename>` (POST /assets writes
  # here) or `published/<filename>` (mk_download_link writes here).
  # Workspace files (under user_workspaces/) are intentionally NOT
  # served here — the model surfaces those via mk_download_link,
  # which copies them into data/published/.
  def get_asset(conn, user, session_id, rest) when is_binary(rest) do
    data_dir       = DmhAi.Constants.session_data_dir(user.email, session_id)
    file_path      = Path.expand(Path.join(data_dir, rest))
    data_dir_real  = Path.expand(data_dir)
    basename       = Path.basename(file_path)

    cond do
      not (String.starts_with?(file_path, data_dir_real <> "/") or file_path == data_dir_real) ->
        Data.json(conn, 400, %{error: "Invalid path"})

      not File.regular?(file_path) ->
        Data.json(conn, 404, %{error: "Not found"})

      true ->
        mime = guess_mime(file_path)
        # Strip the random publish prefix (`<8hex>_<basename>`) when
        # naming the download. Uploads use a `<unix_ms>_` prefix; both
        # patterns get cleaned here so the user sees the original name.
        display_name = Regex.replace(~r/^[a-f0-9]{8,}_|^\d+_/, basename, "")
        data = File.read!(file_path)

        conn
        |> put_resp_content_type(mime)
        |> put_resp_header("content-disposition", "attachment; filename=\"#{display_name}\"")
        |> put_resp_header("content-length", to_string(byte_size(data)))
        |> send_resp(200, data)
    end
  end

  # POST /assets (multipart file upload)
  def post_asset(conn, user) do
    case parse_multipart(conn) do
      {:error, conn, :too_large} ->
        Data.json(conn, 413, %{error: "File too large"})

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
              Data.json(conn, 413, %{error: "Video too large — maximum supported size is #{max_mb} MB"})
            else
              uploaded_dir = DmhAi.Constants.session_uploaded_dir(user.email, session_id)
              File.mkdir_p!(uploaded_dir)

              ts = :os.system_time(:millisecond)
              safe_name = "#{ts}_#{Regex.replace(~r/[^\w.\-]/, filename, "_")}"
              File.write!(Path.join(uploaded_dir, safe_name), raw)

              # `id` is the path the FE/model uses to round-trip back via
              # GET /assets/<session>/<id>. Now that uploads live in a
              # subdir, the id includes the subdir prefix.
              upload_id = "uploaded/#{safe_name}"
              result = %{id: upload_id, name: filename, size: byte_size(raw)}

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

              Data.json(conn, 200, result)
            end

          :error ->
            Data.json(conn, 400, %{error: "No file field"})
        end
    end
  end

  # POST /upload-session-attachment
  # Saves a scaled-down attachment to the session workspace. The FE uploads
  # here at attach time (parallel with /assets original upload), so paths are
  # known and files are on disk well before the user hits Send.
  # Multipart fields: file, sessionId.
  def post_session_attachment(conn, user) do
    case parse_multipart(conn) do
      {:error, conn, :too_large} ->
        Data.json(conn, 413, %{error: "File too large"})

      {:ok, conn, parts} ->
        session_id = get_in(parts, ["sessionId", :data]) || ""
        session_id = String.trim(session_id)

        cond do
          session_id == "" ->
            Data.json(conn, 400, %{error: "Missing sessionId"})

          not Sessions.owns_session?(session_id, user.id) ->
            Data.json(conn, 403, %{error: "Forbidden"})

          true ->
            case Map.fetch(parts, "file") do
              {:ok, %{filename: filename, data: raw}} ->
                if byte_size(raw) > @max_workspace_attachment_bytes do
                  max_mb = div(@max_workspace_attachment_bytes, 1_000_000)
                  Data.json(conn, 413, %{error: "Attachment too large (max #{max_mb} MB)"})
                else
                  filename  = filename || "upload"
                  safe_name = Regex.replace(~r/[^\w.\-]/, filename, "_")
                  workspace = DmhAi.Constants.session_workspace_dir(user.email, session_id)
                  File.mkdir_p!(workspace)
                  File.write!(Path.join(workspace, safe_name), raw)
                  Logger.info("[Data] session attachment saved session=#{session_id} name=#{safe_name}")
                  Data.json(conn, 200, %{name: safe_name})
                end

              :error ->
                Data.json(conn, 400, %{error: "No file field"})
            end
        end
    end
  end

  # ─── Private helpers ────────────────────────────────────────────────────

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
end
