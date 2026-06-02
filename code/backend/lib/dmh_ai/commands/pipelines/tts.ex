# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Tts do
  @moduledoc """
  `/tts [text]` runtime: turn an image (vision-OCR'd), a typed text
  argument, or both into a sentence-per-row Read-out-loud panel. The
  assistant message carries the structured payload on its `tts.sentences`
  field (the FE renders each sentence with its own speaker / settings
  controls).

  Inputs:

    * Image(s) only          → OCR each image, concatenate the
                                 resulting sentences in attachment order.
    * Text only              → split the user's typed text into sentences.
    * Image(s) + text        → OCR first, then the typed text appended.
    * Neither                → friendly "attach an image or type text"
                                 hint, no LLM round-trip.

  Confidant-mode only — Assistant mode is intercepted upstream with a
  short hint redirecting the user to switch modes.

  At most one vision call per attached image (the typed text is
  segmented locally with a Unicode-aware regex; no LLM call needed).
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM, UserAgentMessages}

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp)

  # Magick resize ceiling — same value ExtractContent uses for its
  # image-describer path. Vision tokens are dominated by pixel count;
  # 1568 px is the published Anthropic guidance for Claude vision and
  # works fine across the gemma / Llava family too.
  @resize_max_dim 1568

  # Sentence-terminator + uppercase-next regex for splitting plain text.
  # Unicode-aware so non-ASCII alphabets (German, French, Cyrillic…) get
  # the same treatment as Latin. Catches `." ?` ?(` openings too so the
  # next sentence starts with a delimiter rather than the punctuation
  # itself. Imperfect for abbreviations (Dr., Mr., etc.) — good enough
  # for the v1 conversational text the user types at `/tts`.
  @text_split_re ~r/(?<=[.!?])\s+(?=\p{Lu}|"|'|\(|„|»|«)/u

  @vision_prompt """
  Extract every readable piece of human text from the image, in reading
  order. Output STRICT JSON with one key:

    {"sentences": ["First sentence.", "Second sentence."]}

  Rules:
    - One sentence per array element. Split on terminal punctuation
      (. ! ?), line breaks that clearly end a thought, and paragraph
      boundaries. Don't split on commas, semicolons, or mid-sentence
      colons.
    - Preserve the original language exactly — do NOT translate.
    - If the image has bullet points or list items, each item is its
      own sentence.
    - If the image has no readable text, return {"sentences": []}.
    - Do NOT add commentary, explanation, or markdown fences around
      the JSON. The first character must be `{`.
  """

  @doc """
  Public entry. Returns `{:handled, user_ts}` for the chat HTTP entry.

  Arguments:
    * `original_content` — verbatim user message (`/tts <text>` or
       `/tts`). Persisted as the user's stored message.
    * `arg`              — the text after `/tts ` (may be empty).
    * `image_paths`      — absolute file paths the agent_chat handler
       resolved from the FE's `attachmentNames`.

  Output sentences = (per-image OCR sentences, in attachment order)
                  ++ (typed-text sentences, in reading order).
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()}
  def run(original_content, arg, session_id, user_id, _lang, image_paths \\ []) do
    image_paths = Enum.filter(image_paths || [], &image_path?/1)
    typed_text = String.trim(arg || "")

    cond do
      image_paths == [] and typed_text == "" ->
        finalize_with_payload(session_id, user_id, original_content,
          %{sentences: [], images: [], error: "no_input"},
          "Attach an image or type some text after `/tts` — I'll render it as a sentence-per-row Read-out-loud panel.")

      true ->
        {per_image, image_sentences} =
          if image_paths == [], do: {[], []}, else: extract_per_image(image_paths)

        text_sentences = split_text(typed_text)
        all_sentences = image_sentences ++ text_sentences

        tts_payload = %{
          sentences: all_sentences,
          images: per_image,
          typed_chars: String.length(typed_text)
        }

        fallback = compose_fallback_text(per_image, all_sentences, typed_text)
        finalize_with_payload(session_id, user_id, original_content, tts_payload, fallback)
    end
  end

  # ── path helpers ───────────────────────────────────────────────────────

  defp image_path?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_exts
  end

  defp image_path?(_), do: false

  # ── text-only sentence segmentation ────────────────────────────────────

  defp split_text(""), do: []

  defp split_text(text) when is_binary(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.flat_map(fn paragraph ->
      paragraph
      |> String.replace(~r/\n+/, " ")
      |> String.split(@text_split_re, trim: true)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ── per-image extraction ───────────────────────────────────────────────

  defp extract_per_image(image_paths) do
    {per_image_rev, all_rev} =
      Enum.reduce(image_paths, {[], []}, fn path, {imgs, acc} ->
        # Strip the `<unix_ms>_` prefix /assets adds, for display in the
        # per-image status row. Vision call uses the absolute path directly.
        name = path |> Path.basename() |> String.replace(~r/^\d+_/, "")
        case extract_one(path) do
          {:ok, sentences} ->
            entry = %{name: name, status: "ok", count: length(sentences)}
            {[entry | imgs], Enum.reverse(sentences) ++ acc}

          {:empty, _} ->
            {[%{name: name, status: "empty", count: 0} | imgs], acc}

          {:error, reason} ->
            Logger.warning("[Tts] image=#{name} err=#{inspect(reason)}")
            {[%{name: name, status: "error", error: to_string(reason), count: 0} | imgs], acc}
        end
      end)

    {Enum.reverse(per_image_rev), Enum.reverse(all_rev)}
  end

  defp extract_one(path) do
    case scale_and_encode(path) do
      {:ok, b64} ->
        messages = [%{role: "user", content: @vision_prompt, images: [b64]}]
        case LLM.call(AgentSettings.vision_model(), messages, trace: vision_trace()) do
          {:ok, raw} when is_binary(raw) and raw != "" ->
            parse_vision_sentences(raw)

          other ->
            {:error, "vision_call_failed: #{inspect(other)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── vision JSON parsing ────────────────────────────────────────────────

  # Strip ``` fences a chatty model may emit even when told not to.
  defp parse_vision_sentences(raw) do
    body = strip_fences(raw)

    case Jason.decode(body) do
      {:ok, %{"sentences" => list}} when is_list(list) ->
        cleaned =
          list
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if cleaned == [], do: {:empty, "no_text"}, else: {:ok, cleaned}

      _ ->
        {:error, "vision_json_invalid: " <> String.slice(body, 0, 200)}
    end
  end

  defp strip_fences(s) do
    s
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/```\z/, "")
    |> String.trim()
  end

  # ── image encode (inlined; mirrors ExtractContent.scale_and_encode/1) ──

  defp scale_and_encode(path) do
    cond do
      not File.exists?(path) ->
        {:error, "image_missing: " <> Path.basename(path)}

      true ->
        tmp = "/tmp/dmh_ai_tts_#{System.unique_integer([:positive])}.jpg"

        try do
          {_, code} =
            System.cmd("magick",
              [path, "-resize", "#{@resize_max_dim}x#{@resize_max_dim}>", "-quality", "85", tmp],
              stderr_to_stdout: true)

          if code == 0 and File.exists?(tmp) do
            case File.read(tmp) do
              {:ok, data} -> {:ok, Base.encode64(data)}
              {:error, r} -> {:error, "resize_read_failed: #{r}"}
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
  end

  defp fallback_read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, Base.encode64(data)}
      {:error, r} -> {:error, "image_read_failed: #{r}"}
    end
  end

  # ── persistence ────────────────────────────────────────────────────────

  defp finalize_with_payload(session_id, user_id, original_content, tts_payload, fallback_text) do
    {:ok, user_ts} =
      UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

    {:ok, _} =
      UserAgentMessages.append(session_id, user_id, %{
        role: "assistant",
        content: fallback_text,
        kind: "tts",
        tts: tts_payload
      })

    {:handled, user_ts}
  end

  # Fallback `content` text — what shows when a FE renderer doesn't
  # know the `tts:` field (old polling clients). The structured FE
  # replaces this with the per-sentence layout.
  defp compose_fallback_text(per_image, sentences, typed_text) do
    ok_count = Enum.count(per_image, &(&1.status == "ok"))
    err_count = Enum.count(per_image, &(&1.status == "error"))
    n = length(sentences)
    has_typed = typed_text != ""

    cond do
      n == 0 and err_count > 0 ->
        "Couldn't extract text from #{err_count} image(s)."

      n == 0 ->
        "Nothing to read."

      ok_count == 0 and has_typed ->
        "Rendered #{n} sentence(s) from the typed text."

      ok_count > 0 and not has_typed ->
        "Extracted #{n} sentence(s) from #{ok_count} image(s)." <>
          if(err_count > 0, do: " (#{err_count} image(s) errored.)", else: "")

      true ->
        "Rendered #{n} sentence(s) (#{ok_count} image(s) + typed text)." <>
          if(err_count > 0, do: " (#{err_count} image(s) errored.)", else: "")
    end
  end

  # ── trace + small utilities ────────────────────────────────────────────

  defp vision_trace do
    %{
      origin: "confidant",
      path: "Commands.Pipelines.Tts.extract_one",
      role: "Tts",
      phase: "vision_ocr",
      session_id: nil,
      user_id: nil,
      tier: :vision
    }
  end
end
