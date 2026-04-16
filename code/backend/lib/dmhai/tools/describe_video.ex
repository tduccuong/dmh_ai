# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.DescribeVideo do
  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{LLM, AgentSettings}
  require Logger

  @sandbox_root "/tmp/dmhai-sandbox"
  @assets_root  "/data/user_assets"
  @frame_count  8
  @max_dim      1024

  @impl true
  def name, do: "describe_video"

  @impl true
  def description,
    do: "Describe the visual content of a video file. Extracts frames and returns a comprehensive " <>
        "description covering timeline, subjects, setting, and key moments. Requires ffmpeg."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          path: %{
            type: "string",
            description: "Path to the video file (.mp4, .webm, .mov, .avi, .mkv, etc.). " <>
                         "Resolved within your sandbox or uploaded assets."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path}, context) do
    user_id  = get_in(context, [:user, :id]) || "anon"
    resolved = resolve_path(path, user_id)

    with :ok           <- check_access(resolved, user_id),
         {:ok, frames} <- extract_frames(resolved) do
      messages = [%{role: "user", content: prompt(), images: frames}]

      case LLM.call(AgentSettings.video_describer_model(), messages) do
        {:ok, desc} when is_binary(desc) and desc != "" ->
          {:ok, desc}

        other ->
          Logger.warning("[DescribeVideo] LLM call failed: #{inspect(other)}")
          {:error, "Video description failed"}
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path"}

  # ── private ────────────────────────────────────────────────────────────────

  defp resolve_path(path, user_id) do
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    if String.starts_with?(path, "/"),
      do:   Path.expand(path),
      else: Path.expand(Path.join(sandbox, path))
  end

  defp check_access(resolved, user_id) do
    sandbox = Path.expand(Path.join(@sandbox_root, to_string(user_id)))
    assets  = Path.expand(Path.join(@assets_root,  to_string(user_id)))

    cond do
      not (String.starts_with?(resolved, sandbox) or String.starts_with?(resolved, assets)) ->
        {:error, "Access denied: path is outside allowed directories"}
      not File.exists?(resolved) ->
        {:error, "File not found: #{resolved}"}
      true ->
        :ok
    end
  end

  defp extract_frames(video_path) do
    dir = "/tmp/dmhai_frames_#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)

    try do
      interval = compute_interval(video_path)

      System.cmd("ffmpeg", [
        "-i",        video_path,
        "-vf",       "fps=1/#{interval},scale=#{@max_dim}:-2",
        "-frames:v", to_string(@frame_count),
        "-q:v",      "2",
        "-y",
        Path.join(dir, "frame%03d.jpg")
      ], stderr_to_stdout: true)

      frames =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jpg"))
        |> Enum.sort()
        |> Enum.flat_map(fn f ->
          case File.read(Path.join(dir, f)) do
            {:ok, data} -> [Base.encode64(data)]
            _           -> []
          end
        end)

      if frames == [] do
        {:error, "No frames extracted — check that ffmpeg is installed and the file is a valid video"}
      else
        {:ok, frames}
      end
    rescue
      e -> {:error, "Frame extraction failed: #{Exception.message(e)}"}
    after
      File.rm_rf(dir)
    end
  end

  # Use ffprobe to get duration and compute a uniform frame interval.
  # Falls back to 1.0s interval if ffprobe is unavailable or fails.
  defp compute_interval(video_path) do
    try do
      {dur_str, 0} = System.cmd("ffprobe", [
        "-v",            "error",
        "-show_entries", "format=duration",
        "-of",           "default=noprint_wrappers=1:nokey=1",
        video_path
      ], stderr_to_stdout: false)

      case Float.parse(String.trim(dur_str)) do
        {duration, _} when duration > 0 ->
          (duration / @frame_count) |> max(0.5) |> Float.round(2)

        _ ->
          1.0
      end
    rescue
      _ -> 1.0
    end
  end

  defp prompt do
    "These are frames extracted from a video. Describe the video content comprehensively:\n\n" <>
    "1. OVERVIEW: What type of video is this? What is the main subject or activity?\n" <>
    "2. TIMELINE: Describe what happens across the frames in chronological order.\n" <>
    "3. SUBJECTS: All people (count, appearance, actions), animals, or notable objects — " <>
        "give each a numbered entry with details.\n" <>
    "4. SETTING: Location, environment, time of day if visible.\n" <>
    "5. TEXT & SYMBOLS: Any visible text, signs, labels, or timestamps — quote exactly.\n" <>
    "6. KEY MOMENTS: Notable events, changes, or transitions visible across frames.\n\n" <>
    "Be concise but complete. A person who has not seen the video must understand its full content from your description alone."
  end
end
