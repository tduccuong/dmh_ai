defmodule Dmhai.Handlers.Media do
  @moduledoc """
  Media capability and description endpoints.

  GET  /video-frame-count — how many frames to extract (based on video describer model capacity)
  POST /describe-video    — run video describer LLM, store and return description
  POST /describe-image    — run image describer LLM, store and return description

  The frontend calls /video-frame-count before extracting frames, then fires
  /describe-video or /describe-image in the background (non-blocking).  When
  the chat message arrives the UserAgent checks the DB: if a description is
  already there it uses that; otherwise it falls back to passing raw images
  directly to the master model.
  """

  import Plug.Conn
  alias Dmhai.{Repo, Agent.AgentSettings, Agent.LLM}
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @max_body_bytes 52_428_800

  # GET /video-frame-count
  def get_video_frame_count(conn) do
    model = AgentSettings.video_describer_model()
    base = if cloud_model?(model), do: 8, else: 16
    multiplier = %{"low" => 0.5, "medium" => 0.75, "high" => 1.0}[AgentSettings.video_detail()] || 0.75
    count = max(2, round(base * multiplier))
    json(conn, 200, %{count: count})
  end

  # POST /describe-video
  def post_describe_video(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")
    session_id = String.trim(d["sessionId"] || "")
    name       = String.trim(d["name"] || "video")
    frames     = parse_base64_list(d["frames"])

    cond do
      session_id == "" or frames == [] ->
        json(conn, 400, %{error: "Missing sessionId or frames"})

      not owns_session?(session_id, user.id) ->
        json(conn, 403, %{error: "Forbidden"})

      true ->
        file_id  = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
        messages = [%{role: "user", content: video_prompt(), images: frames}]

        case LLM.call(AgentSettings.video_describer_model(), messages) do
          {:ok, desc} when is_binary(desc) and desc != "" ->
            store_video_description(session_id, file_id, name, desc)
            Logger.info("[Media] video description stored session=#{session_id} name=#{name}")
            json(conn, 200, %{description: desc})

          other ->
            Logger.warning("[Media] video description failed: #{inspect(other)}")
            json(conn, 500, %{error: "Description failed"})
        end
    end
  end

  # POST /describe-image
  def post_describe_image(conn, user) do
    {:ok, body, conn} = read_body(conn, length: @max_body_bytes)
    d = Jason.decode!(body || "{}")
    session_id = String.trim(d["sessionId"] || "")
    name       = String.trim(d["name"] || "image")
    image      = d["image"] || ""

    cond do
      session_id == "" or image == "" ->
        json(conn, 400, %{error: "Missing sessionId or image"})

      not owns_session?(session_id, user.id) ->
        json(conn, 403, %{error: "Forbidden"})

      true ->
        file_id  = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
        messages = [%{role: "user", content: image_prompt(), images: [image]}]

        case LLM.call(AgentSettings.image_describer_model(), messages) do
          {:ok, desc} when is_binary(desc) and desc != "" ->
            store_image_description(session_id, file_id, name, desc)
            Logger.info("[Media] image description stored session=#{session_id} name=#{name}")
            json(conn, 200, %{description: desc})

          other ->
            Logger.warning("[Media] image description failed: #{inspect(other)}")
            json(conn, 500, %{error: "Description failed"})
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp video_prompt do
    "These are frames extracted from a video. Describe the video content comprehensively:\n\n" <>
    "1. OVERVIEW: What type of video is this? What is the main subject or activity?\n" <>
    "2. TIMELINE: Describe what happens across the frames in chronological order.\n" <>
    "3. SUBJECTS: All people (count, appearance, actions), animals, or notable objects — " <>
        "give each a numbered entry with details.\n" <>
    "4. SETTING: Location, environment, time of day if visible.\n" <>
    "5. TEXT & SYMBOLS: Any visible text, signs, labels, or timestamps — quote exactly.\n" <>
    "6. KEY MOMENTS: Notable events, changes, or transitions visible across frames.\n\n" <>
    "Be concise but complete. A person who has not seen the video must understand " <>
    "its full content from your description alone."
  end

  defp image_prompt do
    "Describe this image using the following structure:\n\n" <>
    "1. COUNTING RULE (apply to every section below): For every countable category — " <>
        "people, animals, objects — state the exact number. Never write \"several\", \"some\", " <>
        "\"a few\", or \"many\". Always write \"1 cat\", \"3 fish\", \"2 chairs\", etc.\n\n" <>
    "2. SUBJECTS: For every individual person, animal, and notable object — give each one " <>
        "its own numbered entry. Do NOT group them. Each entry must include: species/type, " <>
        "color(s), size, texture, position in the scene, and any distinguishing features.\n\n" <>
    "3. LAYOUT: Describe spatial positions — foreground, center, background, left, right.\n\n" <>
    "4. SETTING: Location, environment, surface the objects rest on.\n\n" <>
    "5. LIGHTING: Light source direction, brightness, shadow presence.\n\n" <>
    "6. TEXT & SYMBOLS: Any visible text, numbers, logos, timestamps — quote exactly.\n\n" <>
    "7. ACTIONS & MOTION: What is happening, any movement or poses.\n\n" <>
    "8. MOOD: Overall atmosphere and tone.\n\n" <>
    "Be precise and exhaustive. A person who has never seen this image must be able " <>
    "to reconstruct it accurately from your description alone."
  end

  defp store_video_description(session_id, file_id, name, description) do
    try do
      now = System.os_time(:millisecond)
      query!(Repo, """
      INSERT OR REPLACE INTO video_descriptions (session_id, file_id, name, description, created_at)
      VALUES (?, ?, ?, ?, ?)
      """, [session_id, file_id, name, description, now])
    rescue
      e -> Logger.error("[Media] store_video_description failed: #{Exception.message(e)}")
    end
  end

  defp store_image_description(session_id, file_id, name, description) do
    try do
      now = System.os_time(:millisecond)
      query!(Repo, """
      INSERT OR REPLACE INTO image_descriptions (session_id, file_id, name, description, created_at)
      VALUES (?, ?, ?, ?, ?)
      """, [session_id, file_id, name, description, now])
    rescue
      e -> Logger.error("[Media] store_image_description failed: #{Exception.message(e)}")
    end
  end

  defp owns_session?(session_id, user_id) do
    result = query!(Repo, "SELECT id FROM sessions WHERE id=? AND user_id=?", [session_id, user_id])
    result.rows != []
  end

  # Cloud models use the "::cloud::" routing prefix.
  defp cloud_model?(model), do: String.contains?(model, "::cloud::")

  defp parse_base64_list(nil), do: []
  defp parse_base64_list(list) when is_list(list) do
    Enum.filter(list, &(is_binary(&1) and &1 != ""))
  end
  defp parse_base64_list(_), do: []

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
