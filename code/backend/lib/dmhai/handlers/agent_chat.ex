defmodule Dmhai.Handlers.AgentChat do
  @moduledoc """
  POST /agent/chat — server-side LLM chat via the UserAgent pipeline.

  Request body (JSON):
    sessionId  — required
    content    — required, user's message text
    images     — optional, list of base64 strings (photos or video frames)
    imageNames — optional, list of filenames corresponding to each image
    files      — optional, list of %{"name", "content"} maps (extracted text)
    hasVideo   — optional bool, true when images are video frames

  Response: chunked NDJSON, same format as Ollama /api/chat stream.
  """

  import Plug.Conn
  alias Dmhai.Repo
  alias Dmhai.Adapters.Http
  import Ecto.Adapters.SQL, only: [query!: 3]
  # 50 MB — accommodates multiple base64-encoded images in a single request
  @max_body_bytes 52_428_800

  def post_chat(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")

    session_id  = String.trim(d["sessionId"] || "")
    content     = String.trim(d["content"] || "")
    images      = parse_images(d["images"])
    image_names = parse_string_list(d["imageNames"])
    files       = parse_files(d["files"])
    has_video   = d["hasVideo"] == true

    # Allow empty text when images or files are attached (image-only messages)
    has_payload = content != "" or images != [] or files != []

    cond do
      session_id == "" or not has_payload ->
        json(conn, 400, %{error: "Missing sessionId or content"})

      not owns_session?(session_id, user.id) ->
        json(conn, 403, %{error: "Forbidden"})

      true ->
        do_chat(conn, user.id, session_id, content, images, image_names, files, has_video)
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp do_chat(conn, user_id, session_id, content, images, image_names, files, has_video) do
    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("x-accel-buffering", "no")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    opts = [
      images:      images,
      image_names: image_names,
      files:       files,
      has_video:   has_video
    ]

    case Http.dispatch(user_id, session_id, content, self(), opts) do
      :ok ->
        Http.receive_stream(fn
          {:status, text} ->
            line = Jason.encode!(%{status: text})
            chunk(conn, line <> "\n")

          {:chunk, token} ->
            line = Jason.encode!(%{message: %{role: "assistant", content: token}, done: false})
            chunk(conn, line <> "\n")

          {:thinking, token} ->
            line = Jason.encode!(%{message: %{role: "assistant", thinking: token}, done: false})
            chunk(conn, line <> "\n")

          {:done, _result} ->
            line = Jason.encode!(%{message: %{role: "assistant", content: ""}, done: true})
            chunk(conn, line <> "\n")

          {:error, :busy} ->
            err = Jason.encode!(%{error: "Agent is busy, please wait", done: true})
            chunk(conn, err <> "\n")

          {:error, :interrupted} ->
            line = Jason.encode!(%{message: %{role: "assistant", content: ""}, done: true})
            chunk(conn, line <> "\n")

          {:error, reason} ->
            err = Jason.encode!(%{error: inspect(reason), done: true})
            chunk(conn, err <> "\n")
        end)

      {:error, :busy} ->
        err = Jason.encode!(%{error: "Agent is busy, please wait", done: true})
        chunk(conn, err <> "\n")

      {:error, reason} ->
        err = Jason.encode!(%{error: inspect(reason), done: true})
        chunk(conn, err <> "\n")
    end

    conn
  end

  defp owns_session?(session_id, user_id) do
    result = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])
    result.rows != []
  end

  # Validate that images is a list of non-empty base64 strings; drop invalid entries.
  defp parse_images(nil), do: []
  defp parse_images(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end
  defp parse_images(_), do: []

  # Validate a list of strings (used for imageNames); drop non-strings.
  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp parse_string_list(_), do: []

  # Validate that files is a list of maps with "name" and "content" strings.
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
