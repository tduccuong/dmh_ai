# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Tools.ExtractContent do
  @moduledoc """
  Unified content-extraction tool for Assistant-path attachments.

  Routes by file extension:
    - Images (.jpg, .png, .webp, .gif, .bmp, .tiff) — scale via ImageMagick,
      ask LLM to produce a Description + Verbatim Content section.
    - Video (.mp4, .webm, .mov, .avi, .mkv) — extract frames via ffmpeg,
      ask LLM for the same two-section response.
    - Documents (.pdf, .docx, .odt, .pptx, .txt, .md, .csv, etc.) — parse
      text with pdftotext / pandoc / direct read; no LLM call needed.
  """

  @behaviour Dmhai.Tools.Behaviour

  alias Dmhai.Agent.{LLM, AgentSettings}
  alias Dmhai.Util.Path, as: SafePath
  require Logger

  @max_dim        1024
  @max_raw_bytes  3_000_000
  @frame_count    8
  @max_doc_chars  200_000

  @image_exts MapSet.new([".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tiff", ".tif"])
  @video_exts MapSet.new([".mp4", ".webm", ".mov", ".avi", ".mkv", ".m4v", ".flv", ".wmv"])
  @pandoc_exts MapSet.new([".docx", ".odt", ".odp", ".pptx", ".rtf", ".epub", ".html", ".htm", ".rst"])
  @text_exts  MapSet.new([".txt", ".md", ".csv", ".tsv", ".log", ".json", ".xml",
                          ".yaml", ".yml", ".toml", ".ini", ".cfg"])

  @impl true
  def name, do: "extract_content"

  @impl true
  def description,
    do: "Extract content from a task attachment. Images/video → description + embedded text; documents → parsed text."

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
            description: "Path to the uploaded file. Use 'workspace/<filename>' for task attachments."
          }
        },
        required: ["path"]
      }
    }
  end

  @impl true
  def execute(%{"data" => frames, "has_video" => true}, _ctx) when is_list(frames) and frames != [] do
    describe_base64_frames(frames)
  end

  def execute(%{"data" => b64}, _ctx) when is_binary(b64) and b64 != "" do
    describe_base64_image(b64)
  end

  def execute(%{"path" => path}, ctx) when is_binary(path) do
    # Dedup: if the path is a historical attachment (not in this turn's
    # fresh list) and a prior done task in the same session already
    # extracted it, reuse that task's result instead of running the
    # pipeline again. Freshly re-attached files (`[newly attached]`)
    # always take the fresh path — the user re-uploaded for a reason.
    fresh = Map.get(ctx, :fresh_attachment_paths, []) || []
    session_id = Map.get(ctx, :session_id)

    if path in fresh or session_id == nil do
      do_extract(path, ctx)
    else
      case find_prior_extraction(session_id, path) do
        {:ok, prior} -> reuse_prior(prior)
        :none        -> do_extract(path, ctx)
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: path or data"}

  # ── dedup for historical attachments ─────────────────────────────────────

  defp do_extract(path, ctx) do
    with {:ok, abs} <- SafePath.resolve(path, ctx),
         :ok        <- exists_check(abs) do
      ext = abs |> Path.extname() |> String.downcase()

      cond do
        MapSet.member?(@image_exts, ext) -> extract_image(abs)
        MapSet.member?(@video_exts, ext) -> extract_video(abs)
        ext == ".pdf"                    -> parse_pdf(abs)
        MapSet.member?(@pandoc_exts, ext) -> run_pandoc(abs)
        MapSet.member?(@text_exts, ext)  -> read_text(abs)
        true                             -> try_pandoc_then_read(abs)
      end
    end
  end

  # Scan the most recent done tasks for the session and return the first
  # whose `task_spec` listed this path as an attachment and whose
  # `task_result` is non-empty. Cap is generous but bounded so we never
  # scan the whole task history.
  @prior_scan_limit 50
  defp find_prior_extraction(session_id, path) do
    Dmhai.Agent.Tasks.recent_done_for_session(session_id, @prior_scan_limit)
    |> Enum.find(fn t ->
      spec   = Map.get(t, :task_spec) || ""
      result = Map.get(t, :task_result) || ""
      path in Dmhai.Agent.ContextEngine.extract_attachments(spec) and
        String.trim(result) != ""
    end)
    |> case do
      nil  -> :none
      task -> {:ok, task}
    end
  end

  defp reuse_prior(task) do
    tid    = Map.get(task, :task_id)
    title  = Map.get(task, :task_title) || "(untitled)"
    result = Map.get(task, :task_result) || ""

    Logger.info("[ExtractContent] dedup hit — reusing task=#{tid}")

    body =
      "This file was already extracted on a prior task in this session. " <>
        "Reusing the earlier summary rather than re-running the extractor.\n\n" <>
        "**Prior task:** `#{tid}` — #{title}\n\n" <>
        "**Prior task_result:**\n\n#{result}\n\n" <>
        "If this summary isn't enough to answer the user's follow-up, " <>
        "rely on your own earlier reply in the conversation; only " <>
        "re-extract if the user explicitly asks you to re-read the file."

    {:ok, body}
  end

  # ── base64 input (Confidant fallback path) ────────────────────────────────

  defp describe_base64_image(b64) do
    messages = [%{role: "user", content: image_prompt(), images: [b64]}]
    trace = %{origin: "assistant", path: "ExtractContent.describe_image", role: "ImageDescriber", phase: "describe"}
    case LLM.call(AgentSettings.image_describer_model(), messages, trace: trace) do
      {:ok, result} when is_binary(result) and result != "" ->
        {:ok, result}

      other ->
        Logger.warning("[ExtractContent] base64 image LLM call failed: #{inspect(other)}")
        {:error, "Image content extraction failed"}
    end
  end

  defp describe_base64_frames(frames) do
    messages = [%{role: "user", content: video_prompt(), images: frames}]
    trace = %{origin: "assistant", path: "ExtractContent.describe_video", role: "VideoDescriber", phase: "describe"}
    case LLM.call(AgentSettings.video_describer_model(), messages, trace: trace) do
      {:ok, result} when is_binary(result) and result != "" ->
        {:ok, result}

      other ->
        Logger.warning("[ExtractContent] base64 frames LLM call failed: #{inspect(other)}")
        {:error, "Video content extraction failed"}
    end
  end

  # ── image ──────────────────────────────────────────────────────────────────

  defp extract_image(abs) do
    with {:ok, b64} <- scale_and_encode(abs) do
      messages = [%{role: "user", content: image_prompt(), images: [b64]}]
      trace = %{origin: "assistant", path: "ExtractContent.extract_image", role: "ImageDescriber", phase: "describe"}
      case LLM.call(AgentSettings.image_describer_model(), messages, trace: trace) do
        {:ok, result} when is_binary(result) and result != "" ->
          {:ok, result}

        other ->
          Logger.warning("[ExtractContent] image LLM call failed: #{inspect(other)}")
          {:error, "Image content extraction failed"}
      end
    end
  end

  defp scale_and_encode(path) do
    tmp = "/tmp/dmhai_ec_#{System.unique_integer([:positive])}.jpg"

    try do
      {_, code} = System.cmd(
        "magick",
        [path, "-resize", "#{@max_dim}x#{@max_dim}>", "-quality", "85", tmp],
        stderr_to_stdout: true
      )

      if code == 0 and File.exists?(tmp) do
        case File.read(tmp) do
          {:ok, data} -> {:ok, Base.encode64(data)}
          {:error, r} -> {:error, "Cannot read resized image: #{r}"}
        end
      else
        fallback_read(path)
      end
    rescue
      _ -> fallback_read(path)
    after
      File.rm(tmp)
    end
  end

  defp fallback_read(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_raw_bytes ->
        {:error, "Image too large (#{size} bytes) and resize failed — install ImageMagick"}

      _ ->
        case File.read(path) do
          {:ok, data} -> {:ok, Base.encode64(data)}
          {:error, r} -> {:error, "Cannot read image: #{r}"}
        end
    end
  end

  # ── video ──────────────────────────────────────────────────────────────────

  defp extract_video(abs) do
    with {:ok, frames} <- extract_frames(abs) do
      messages = [%{role: "user", content: video_prompt(), images: frames}]
      trace = %{origin: "assistant", path: "ExtractContent.extract_video", role: "VideoDescriber", phase: "describe"}
      case LLM.call(AgentSettings.video_describer_model(), messages, trace: trace) do
        {:ok, result} when is_binary(result) and result != "" ->
          {:ok, result}

        other ->
          Logger.warning("[ExtractContent] video LLM call failed: #{inspect(other)}")
          {:error, "Video content extraction failed"}
      end
    end
  end

  defp extract_frames(video_path) do
    dir = "/tmp/dmhai_ec_frames_#{System.unique_integer([:positive])}"
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

  # ── documents ──────────────────────────────────────────────────────────────

  defp parse_pdf(path) do
    try do
      case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
        {output, 0} when output != "" -> truncate(output)
        _                             -> run_pandoc(path)
      end
    rescue
      _ -> run_pandoc(path)
    end
  end

  defp run_pandoc(path) do
    try do
      case System.cmd("pandoc", ["--to=markdown", "--wrap=none", path],
                      stderr_to_stdout: true) do
        {output, 0} ->
          truncate(output)

        {err, code} ->
          Logger.warning("[ExtractContent] pandoc exited #{code}: #{String.slice(err, 0, 200)}")
          {:error, "pandoc failed (exit #{code}): #{String.slice(err, 0, 200)}"}
      end
    rescue
      _ -> {:error, "pandoc is not installed — cannot parse this document format"}
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, content} -> truncate(content)
      {:error, r}    -> {:error, "Cannot read file: #{r}"}
    end
  end

  defp try_pandoc_then_read(path) do
    case run_pandoc(path) do
      {:ok, _} = ok -> ok
      _             -> read_text(path)
    end
  end

  defp truncate(text) do
    if String.length(text) > @max_doc_chars do
      {:ok, String.slice(text, 0, @max_doc_chars) <> "\n\n[truncated: content exceeds #{@max_doc_chars} characters]"}
    else
      {:ok, text}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp exists_check(abs) do
    if File.exists?(abs), do: :ok, else: {:error, "File not found: #{abs}"}
  end

  defp image_prompt do
    "Analyze this image and respond with exactly two sections:\n\n" <>
    "## Description\n" <>
    "Describe all visual content: subjects (count each category exactly — never use 'several' or 'some'), " <>
    "layout (foreground/background/positions), setting, lighting, actions, and mood. " <>
    "Every person, animal, and notable object gets its own numbered entry with species/type, color(s), " <>
    "size, and distinguishing features.\n\n" <>
    "## Verbatim Content\n" <>
    "Transcribe every piece of text visible in the image exactly as it appears — signs, labels, " <>
    "captions, watermarks, printed text, handwriting. If there is no text, write: (none)"
  end

  defp video_prompt do
    "These are frames from a video. Respond with exactly two sections:\n\n" <>
    "## Description\n" <>
    "Describe the video content: overview/type, chronological timeline across frames, " <>
    "subjects (count each category exactly — people, animals, objects with numbered entries), " <>
    "setting, and key moments or transitions.\n\n" <>
    "## Verbatim Content\n" <>
    "Transcribe every piece of text visible across all frames — titles, subtitles, on-screen text, " <>
    "signs, labels, timestamps — exactly as they appear. If there is no text, write: (none)"
  end
end
