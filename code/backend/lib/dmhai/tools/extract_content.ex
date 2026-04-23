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
        ext == ".pdf"                    -> parse_pdf(abs, ctx)
        MapSet.member?(@pandoc_exts, ext) -> run_pandoc(abs)
        MapSet.member?(@text_exts, ext)  -> read_text(abs)
        true                             -> try_pandoc_then_read(abs)
      end
    end
  end

  # Helper — safely pull progress_row_id from ctx (ctx may be nil for
  # non-session callers like media handlers).
  defp row_id(ctx) when is_map(ctx), do: Map.get(ctx, :progress_row_id)
  defp row_id(_), do: nil

  # Scan the most recent done tasks for the session and return the first
  # whose `task_spec` listed this path as an attachment and whose
  # `task_result` is non-empty. Cap is generous but bounded so we never
  # scan the whole task history.
  @prior_scan_limit 50
  defp find_prior_extraction(session_id, path) do
    Dmhai.Agent.Tasks.recent_done_for_session(session_id, @prior_scan_limit)
    |> Enum.find(fn t ->
      # Primary source: structured attachments column. Fallback: legacy
      # regex parse of task_spec (for pre-migration rows) so dedup keeps
      # working during the transition window.
      cols =
        case Map.get(t, :attachments) do
          list when is_list(list) and list != [] -> list
          _                                       -> Dmhai.Agent.ContextEngine.extract_attachments(Map.get(t, :task_spec) || "")
        end

      result = Map.get(t, :task_result) || ""
      path in cols and String.trim(result) != ""
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

  # PDF extraction path:
  #   1. pdftotext -layout → if meaningful text, done.
  #   2. Else the PDF is scanned / image-only. Skip pandoc (useless for
  #      PDFs) and go straight to OCR: render each page with pdftoppm,
  #      chunk by AgentSettings.ocr_pages_per_chunk/0, send each chunk to
  #      the image-describer vision model, concat results.
  #   3. If the page count exceeds AgentSettings.ocr_page_cap/0, refuse
  #      rather than blowing up on a book-length scan.
  defp parse_pdf(path, ctx) do
    pdftotext_output =
      try do
        case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
          {output, 0} -> output
          _           -> ""
        end
      rescue
        _ -> ""
      end

    if meaningful?(pdftotext_output) do
      truncate(pdftotext_output)
    else
      Logger.info("[ExtractContent] pdftotext returned non-meaningful output (#{byte_size(pdftotext_output)} bytes) — falling back to OCR")
      ocr_pdf(path, ctx)
    end
  end

  defp ocr_pdf(path, ctx) do
    cap = AgentSettings.ocr_page_cap()

    case count_pdf_pages(path) do
      {:error, reason} ->
        {:error, "Cannot OCR PDF: #{reason}"}

      {:ok, n} when n > cap ->
        {:error,
         "PDF has #{n} pages (>#{cap} OCR cap). OCR skipped — ask the user to split the file " <>
           "or provide a text-based version."}

      {:ok, n} ->
        render_and_ocr(path, n, ctx)
    end
  end

  defp count_pdf_pages(path) do
    try do
      case System.cmd("pdfinfo", [path], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/^Pages:\s+(\d+)/m, output) do
            [_, n_str] ->
              case Integer.parse(n_str) do
                {n, _} when n > 0 -> {:ok, n}
                _                 -> {:error, "pdfinfo returned unparseable page count"}
              end

            _ ->
              {:error, "pdfinfo output missing Pages field"}
          end

        {err, code} ->
          {:error, "pdfinfo exited #{code}: #{String.slice(err, 0, 200)}"}
      end
    rescue
      _ -> {:error, "pdfinfo is not installed"}
    end
  end

  defp render_and_ocr(path, n_pages, ctx) do
    dir = "/tmp/dmhai_ocr_#{System.unique_integer([:positive])}"
    File.mkdir_p!(dir)
    rid = row_id(ctx)

    try do
      # Surface the render step so the FE's rotating tool-row label
      # reflects actual sub-activity rather than sitting on a spinner.
      Dmhai.Agent.SessionProgress.append_sub_label(
        rid, "RenderPdf(\"#{n_pages} pages\")")

      case System.cmd(
             "pdftoppm",
             ["-r", "200", "-png", path, Path.join(dir, "page")],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {err, code} -> throw({:render_fail, "pdftoppm exited #{code}: #{String.slice(err, 0, 200)}"})
      end

      frames =
        1..n_pages
        |> Enum.map(fn i ->
          # pdftoppm zero-pads to match digit count of n_pages.
          width = n_pages |> Integer.digits() |> length()
          padded = i |> Integer.to_string() |> String.pad_leading(max(width, 1), "0")
          Path.join(dir, "page-#{padded}.png")
        end)
        |> Enum.map(fn p ->
          case File.read(p) do
            {:ok, bin} -> {:ok, Base.encode64(bin)}
            {:error, r} -> throw({:render_fail, "cannot read rendered page #{p}: #{inspect(r)}"})
          end
        end)
        |> Enum.map(fn {:ok, b64} -> b64 end)

      chunk_size = AgentSettings.ocr_pages_per_chunk()
      chunks     = Enum.chunk_every(frames, chunk_size)

      # Sequential — keeps pressure off the cloud-account pool.
      {texts, _offset} =
        Enum.reduce(chunks, {[], 0}, fn chunk, {acc, offset} ->
          start_page = offset + 1
          end_page   = offset + length(chunk)
          Dmhai.Agent.SessionProgress.append_sub_label(
            rid, "OcrPage(\"pages #{start_page}-#{end_page} of #{n_pages}\")")
          case describe_ocr_chunk(chunk, start_page) do
            {:ok, text} -> {[text | acc], offset + length(chunk)}
            {:error, r} -> throw({:ocr_fail, r})
          end
        end)

      combined = texts |> Enum.reverse() |> Enum.join("\n\n")
      truncate(combined)
    catch
      {:render_fail, r} -> {:error, "OCR render failed: #{r}"}
      {:ocr_fail, r}    -> {:error, "OCR vision call failed: #{inspect(r)}"}
    after
      File.rm_rf(dir)
    end
  end

  defp describe_ocr_chunk(frames, start_page) do
    prompt =
      "These are consecutive pages from a scanned PDF, starting at page #{start_page}. " <>
        "Transcribe every visible character VERBATIM. Prefix each page with a heading " <>
        "`## Page N` where N is its absolute page number. Preserve line breaks, paragraph " <>
        "structure, headings, bullets, and tables. Do NOT summarise, translate, or add " <>
        "commentary — only the exact text on the page."

    messages = [%{role: "user", content: prompt, images: frames}]
    trace = %{origin: "assistant", path: "ExtractContent.ocr_pdf", role: "OcrPdf", phase: "ocr"}

    case LLM.call(AgentSettings.image_describer_model(), messages, trace: trace) do
      {:ok, result} when is_binary(result) and result != "" -> {:ok, result}
      other ->
        Logger.warning("[ExtractContent] OCR chunk LLM call failed: #{inspect(other)}")
        {:error, "OCR vision call returned no content"}
    end
  end

  defp run_pandoc(path) do
    try do
      case System.cmd("pandoc", ["--to=markdown", "--wrap=none", path],
                      stderr_to_stdout: true) do
        {output, 0} ->
          if meaningful?(output) do
            truncate(output)
          else
            {:error,
             "pandoc returned no meaningful text from this file. " <>
               "It may be empty, corrupt, or in an unsupported format."}
          end

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
      {:ok, content} ->
        if meaningful?(content) do
          truncate(content)
        else
          {:error, "File is empty or contains no readable text."}
        end

      {:error, r} ->
        {:error, "Cannot read file: #{r}"}
    end
  end

  defp try_pandoc_then_read(path) do
    case run_pandoc(path) do
      {:ok, _} = ok -> ok
      _             ->
        case read_text(path) do
          {:ok, _} = ok -> ok
          {:error, _}   ->
            {:error,
             "Cannot extract text from this file format (ext=#{Path.extname(path)}). " <>
               "Pandoc failed and raw read returned no meaningful content."}
        end
    end
  end

  defp truncate(text) do
    if String.length(text) > @max_doc_chars do
      {:ok, String.slice(text, 0, @max_doc_chars) <> "\n\n[truncated: content exceeds #{@max_doc_chars} characters]"}
    else
      {:ok, text}
    end
  end

  # "Meaningful" == at least AgentSettings.min_extracted_text_chars/0 of non-
  # whitespace, non-form-feed content after trim. Guards against extractors
  # that succeed (exit 0) but return only `\n\x0c\n` — the scanned-PDF
  # failure mode that triggered this whole fix.
  defp meaningful?(text) when is_binary(text) do
    stripped =
      text
      |> String.replace(~r/[\s\f\x0c]+/u, "")
      |> String.trim()

    String.length(stripped) >= AgentSettings.min_extracted_text_chars()
  end
  defp meaningful?(_), do: false

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
