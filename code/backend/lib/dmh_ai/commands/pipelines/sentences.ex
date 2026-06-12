# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Sentences do
  @moduledoc """
  Shared content-gathering for the Read-out-loud family of slash
  commands (`/tts`, `/duolang`). Resolves WHAT to read — typed text,
  vision-OCR'd image text, or (for a bare command) the session's most
  recent natural assistant reply. The command pipelines layer their own
  segmentation, payload, and render on top of the result.

  `gather/3` resolves the source and OCRs images, returning:

      %{
        text:            String.t(),   # raw resolved text (typed or prior reply); "" for image-only
        image_sentences: [String.t()], # OCR'd sentences (already clean), attachment order
        per_image:       [map()],      # per-image status rows for the FE
        source:          :typed | :image_only | :prior_reply | :no_input
      }

  Text is returned RAW. Callers segment it themselves so `/duolang` needs
  only one model call: `/tts` calls `segment/2` (clean → sentences);
  `/duolang` runs a single clean+segment+translate call (embedding the
  shared `clean_rules/0`). Both strip markdown scaffolding (rules like
  `***`, headings, bullet / emphasis markers) and drop trailing "go
  deeper / suggestion" sections, so neither `***` nor the model's
  follow-up prompts get read aloud. Image OCR uses one vision call per
  image; its sentences are already clean.

  `:no_input` (no typed arg, no images, no prior reply) short-circuits
  before any model call — the caller renders its own friendly hint.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM}

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
  # for the conversational text the user types at the command.
  @text_split_re ~r/(?<=[.!?])\s+(?=\p{Lu}|"|'|\(|„|»|«)/u

  @vision_prompt """
  Extract the prose from the image as complete, speakable sentences for
  Read-out-loud playback. Output STRICT JSON with one key:

    {"sentences": ["First sentence.", "Second sentence."]}

  Each array element is a sentence a person would naturally read aloud:
    - a self-contained thought with a clear subject and predicate, the
      kind a listener can follow without seeing the image
    - prose typography — the shape of body paragraphs, captions,
      dialogue, narration, or bulleted list items
    - the original language, preserved exactly
    - joined across line wraps so each element is one continuous
      sentence; split at terminal punctuation (. ! ?) or paragraph
      boundaries, not at commas, semicolons, or mid-sentence colons
    - each bulleted or numbered list item becomes one sentence in
      reading order

  Output rules:
    - The first character must be `{`. No commentary, no markdown
      fences, no preamble.
    - When the image holds no qualifying sentences, return
      {"sentences": []}.
  """

  # Shared clean-and-segment rules — embedded both in @segment_prompt
  # here (text → sentences for /tts) and in /duolang's single
  # clean+segment+translate prompt, so the two paths filter identically.
  @clean_rules """
  Each kept sentence is one a person would naturally read aloud:
    - substantive prose — the answer, story, or explanation itself
    - a self-contained thought in the original language, wording
      preserved exactly
    - joined across line wraps into one continuous sentence; split at
      terminal punctuation (. ! ?) or paragraph boundaries
    - plain text only: strip markdown markers (**, *, #, backticks,
      list bullets) while keeping the prose they wrapped

  Leave out everything that is not speakable prose:
    - horizontal rules and decorative lines (***, ---, ===)
    - headers, labels, and bullet scaffolding that carry no prose
    - trailing sections that suggest further topics, follow-up questions,
      or ways to explore deeper — navigation aids, not content
  """

  @segment_prompt """
  Break the text into complete, speakable sentences for Read-out-loud
  playback. Output STRICT JSON with one key:

    {"sentences": ["First sentence.", "Second sentence."]}

  #{@clean_rules}
  Output rules:
    - The first character must be `{`. No commentary, no markdown fences.
    - Preserve the original language exactly; never translate or rewrite.
    - When unsure whether a line is content, keep it.
    - When there is no speakable prose, return {"sentences": []}.
  """

  @doc """
  The shared clean-and-segment rules, embedded in `/duolang`'s combined
  clean+segment+translate prompt so both paths filter content identically.
  """
  @spec clean_rules() :: String.t()
  def clean_rules, do: @clean_rules

  @type result :: %{
          text: String.t(),
          image_sentences: [String.t()],
          per_image: [map()],
          source: :typed | :image_only | :prior_reply | :no_input
        }

  @doc """
  Resolve the speakable content for a Read-out-loud command: pick the
  source (typed text, OCR'd images, or the prior reply) and OCR any
  images. Text is returned RAW — the caller turns it into sentences
  (`segment/2` for /tts, a combined clean+segment+translate call for
  /duolang) so /duolang needs only one model call.

  `arg` is the text after the command (and, for `/duolang`, after the
  language token). `image_paths` are the absolute paths the chat handler
  resolved from the FE's `attachmentNames`. `session_id` is needed for
  the bare-command prior-reply fallback.
  """
  @spec gather(String.t(), [String.t()], String.t()) :: result()
  def gather(arg, image_paths, session_id) do
    image_paths = Enum.filter(image_paths || [], &image_path?/1)
    typed_text = String.trim(arg || "")

    {text, source} =
      cond do
        typed_text != "" -> {typed_text, :typed}
        image_paths != [] -> {"", :image_only}
        true ->
          case prior_assistant_reply(session_id) do
            {:ok, content} -> {content, :prior_reply}
            :none -> {"", :no_input}
          end
      end

    case source do
      :no_input ->
        %{text: "", image_sentences: [], per_image: [], source: :no_input}

      _ ->
        {per_image, image_sentences} =
          if image_paths == [], do: {[], []}, else: extract_per_image(image_paths)

        %{text: text, image_sentences: image_sentences, per_image: per_image, source: source}
    end
  end

  @doc """
  Decode an LLM reply that should be one JSON object, tolerating
  ```` ```json ```` fences a chatty model may emit. Shared by the
  vision-OCR parser here and the `/duolang` translation parser.
  """
  @spec decode_llm_json(String.t()) :: {:ok, term()} | {:error, term()}
  def decode_llm_json(raw) when is_binary(raw) do
    raw |> strip_fences() |> Jason.decode()
  end

  # ── path helpers ───────────────────────────────────────────────────────

  defp image_path?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_exts
  end

  defp image_path?(_), do: false

  # ── prior assistant reply lookup ───────────────────────────────────────
  # A bare command (no image, no typed arg) means "speak the model's
  # last natural reply." Looking up the message log here keeps the
  # runtime path consistent with the typed/image paths — same render,
  # same sentence-split, same controls.

  defp prior_assistant_reply(session_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    case query!(DmhAi.Repo, "SELECT messages FROM sessions WHERE id=?", [session_id]) do
      %{rows: [[json]]} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, msgs} when is_list(msgs) ->
            msgs
            |> Enum.reverse()
            |> Enum.find(&natural_assistant_reply?/1)
            |> case do
              nil ->
                :none

              %{"content" => content} when is_binary(content) and content != "" ->
                {:ok, content}

              _ ->
                :none
            end

          _ ->
            :none
        end

      _ ->
        :none
    end
  end

  # A natural assistant reply is the model's prose — not a runtime
  # marker (`command_ack`, `tts`, `duolang`, `form_response`, etc.).
  # Speaking those out loud either loops on the user's own prior command
  # or reads back `Saved.` from /memo — never what they meant.
  defp natural_assistant_reply?(%{"role" => "assistant"} = m) do
    kind = m["kind"]
    kind in [nil, ""]
  end

  defp natural_assistant_reply?(_), do: false

  # ── text clean + segmentation ──────────────────────────────────────────
  # One Swift-tier call turns raw text into speakable prose sentences,
  # stripping markdown scaffolding and dropping "go deeper / suggestion"
  # meta sections (so `***` and the model's follow-up prompts never get
  # read aloud). An empty result is trusted only for derived sources
  # (prior reply / OCR) where the content may be all scaffolding; for
  # user-typed text it degrades to the regex splitter instead, so a short
  # word list the model doesn't see as a "sentence" is still read. An LLM
  # failure always degrades to the splitter, so a flaky model never
  # strands the user with no output.

  @doc """
  Clean and segment raw text into speakable prose sentences (markdown
  scaffolding stripped, "go deeper / suggestion" sections dropped). Used
  by `/tts`.

  `source` decides what an empty LLM result means. For derived sources
  (`:prior_reply`, `:image_only`) a valid empty list is trusted — the
  content was all scaffolding, so there is genuinely nothing to read. For
  `:typed` the user handed over exactly what they want spoken, so an empty
  result degrades to the regex splitter rather than silently dropping
  their text. An LLM failure always degrades to the splitter.
  """
  @spec segment(String.t(), atom()) :: [String.t()]
  def segment("", _source), do: []

  def segment(text, source) when is_binary(text) do
    case llm_segment(text) do
      {:ok, []} -> if source == :typed, do: split_text(text), else: []
      {:ok, sentences} -> sentences
      :error -> split_text(text)
    end
  end

  defp llm_segment(text) do
    messages = [
      %{role: "system", content: @segment_prompt},
      %{role: "user", content: text}
    ]

    case LLM.call(AgentSettings.swift_model(), messages,
           options: %{temperature: 0}, trace: segment_trace()) do
      {:ok, raw} when is_binary(raw) and raw != "" ->
        case decode_llm_json(raw) do
          {:ok, %{"sentences" => list}} when is_list(list) ->
            {:ok, list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    e ->
      Logger.warning("[Sentences] llm_segment raised: #{Exception.message(e)}")
      :error
  end

  # ── regex fallback segmentation ────────────────────────────────────────

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
            Logger.warning("[Sentences] image=#{name} err=#{inspect(reason)}")
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

  defp parse_vision_sentences(raw) do
    case decode_llm_json(raw) do
      {:ok, %{"sentences" => list}} when is_list(list) ->
        cleaned =
          list
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if cleaned == [], do: {:empty, "no_text"}, else: {:ok, cleaned}

      _ ->
        {:error, "vision_json_invalid: " <> String.slice(strip_fences(raw), 0, 200)}
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

  # ── trace ──────────────────────────────────────────────────────────────

  defp vision_trace do
    %{
      origin: "confidant",
      path: "Commands.Pipelines.Sentences.extract_one",
      role: "Sentences",
      phase: "vision_ocr",
      session_id: nil,
      user_id: nil,
      tier: :vision
    }
  end

  defp segment_trace do
    %{
      origin: "confidant",
      path: "Commands.Pipelines.Sentences.llm_segment",
      role: "Sentences",
      phase: "segment",
      session_id: nil,
      user_id: nil,
      tier: :swift
    }
  end
end
