# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Data.Descriptions do
  @moduledoc """
  Per-asset user-authored descriptions for images + videos.

  CRUD against the `image_descriptions` and `video_descriptions`
  tables, scoped to a session the caller owns.
  """

  alias DmhAi.Repo
  alias DmhAi.Handlers.Data
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn, only: [read_body: 1]

  # GET /video-descriptions/:session_id
  def get_video_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
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

      Data.json(conn, 200, items)
    end
  end

  # GET /image-descriptions/:session_id
  def get_image_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
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

      Data.json(conn, 200, items)
    end
  end

  # POST /video-descriptions
  def post_video_description(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    session_id = d["sessionId"] || ""
    file_id = d["fileId"] || ""
    description = String.trim(d["description"] || "")

    if session_id == "" or file_id == "" or description == "" do
      Data.json(conn, 400, %{error: "Missing fields"})
    else
      owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

      if owns.rows == [] do
        Data.json(conn, 403, %{error: "Forbidden"})
      else
        now = :os.system_time(:millisecond)

        query!(Repo, """
        INSERT OR REPLACE INTO video_descriptions (session_id, file_id, name, description, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [session_id, file_id, d["name"] || "", description, now])

        Data.json(conn, 200, %{ok: true})
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
      Data.json(conn, 400, %{error: "Missing fields"})
    else
      owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

      if owns.rows == [] do
        Data.json(conn, 403, %{error: "Forbidden"})
      else
        now = :os.system_time(:millisecond)

        query!(Repo, """
        INSERT OR REPLACE INTO image_descriptions (session_id, file_id, name, description, created_at)
        VALUES (?, ?, ?, ?, ?)
        """, [session_id, file_id, d["name"] || "", description, now])

        Data.json(conn, 200, %{ok: true})
      end
    end
  end

  # DELETE /video-descriptions/:session_id
  def delete_video_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
    else
      query!(Repo, "DELETE FROM video_descriptions WHERE session_id=?", [session_id])
      Data.json(conn, 200, %{ok: true})
    end
  end

  # DELETE /image-descriptions/:session_id
  def delete_image_descriptions(conn, user, session_id) do
    owns = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user.id])

    if owns.rows == [] do
      Data.json(conn, 404, %{error: "Not found"})
    else
      query!(Repo, "DELETE FROM image_descriptions WHERE session_id=?", [session_id])
      Data.json(conn, 200, %{ok: true})
    end
  end
end
