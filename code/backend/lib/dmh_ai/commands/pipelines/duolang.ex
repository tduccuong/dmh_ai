# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Duolang do
  @moduledoc """
  `/duolang <full-lang-name> [text]` runtime: the `/tts` Read-out-loud
  panel plus a translation of every sentence into the target language,
  rendered beneath its original (each row keeps its own speaker /
  settings controls — the translation speaks in the target language).

  Flow:

    1. Peel the leading language name off the argument
       (`DmhAi.Commands.Languages.split_leading/1`). Unknown → usage hint.
    2. Resolve the source via `Sentences.gather/3`: raw text (typed or
       the previous reply) plus any image-OCR sentences.
    3. Text → ONE Swift-tier call that cleans, segments, and translates
       in a single round-trip (embedding the shared `Sentences.clean_rules/0`
       so junk like `***` and "go deeper" sections never appear). Image
       OCR sentences are already clean, so they're only translated. On
       failure the text path degrades to segment-then-translate.

  The assistant message carries the structured payload on its
  `duolang` field (`kind="duolang"`); the FE renders the bilingual
  rows. Confidant-mode only.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM, UserAgentMessages}
  alias DmhAi.Commands.Languages
  alias DmhAi.Commands.Pipelines.Sentences

  @translate_system """
  You are a translation engine. You receive a JSON object with a target
  language and an ordered array of sentences. Translate every sentence
  into the target language.

  Output STRICT JSON with one key:

    {"translations": ["…", "…"]}

  Rules:
    - One translation per input sentence, in the same order, same count.
    - Preserve meaning, tone, and register; keep proper nouns and
      code-like tokens as-is.
    - The first character must be `{`. No commentary, no markdown fences.
  """

  @doc """
  Public entry. Returns `{:handled, user_ts}` for the chat HTTP entry.

  Arguments mirror `Tts.run/6`: `arg` is everything after `/duolang `
  (the leading language token is split out here).
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()}
  def run(original_content, arg, session_id, user_id, _lang, image_paths \\ []) do
    case Languages.split_leading(arg || "") do
      :no_match ->
        finalize_with_payload(session_id, user_id, original_content,
          %{items: [], error: "unknown_language"},
          "I didn't catch the language. Supported: #{Languages.names_hint()}. Try `/duolang <language> <text>`.")

      {lang, rest} ->
        %{text: text, image_sentences: image_sentences, per_image: per_image, source: source} =
          Sentences.gather(rest, image_paths, session_id)

        case source do
          :no_input ->
            finalize_with_payload(session_id, user_id, original_content,
              base_payload([], lang) |> Map.put(:error, "no_input"),
              "Type some text after the language, attach an image, or send `/duolang #{lang.english}` alone after I've replied — I'll translate each sentence into #{lang.english} beneath the original.")

          _ ->
            meta = %{session_id: session_id, user_id: user_id}

            # Text → one clean+segment+translate call. Image OCR sentences
            # are already clean, so they only need translating.
            text_items = if text == "", do: [], else: segment_and_translate(text, lang, meta, source)
            image_items = translate_items(image_sentences, lang, meta)
            items = image_items ++ text_items

            payload =
              base_payload(items, lang)
              |> Map.merge(%{
                images: per_image,
                typed_chars: String.length(text),
                source: Atom.to_string(source)
              })

            fallback = compose_fallback_text(per_image, items, text, source, lang)
            finalize_with_payload(session_id, user_id, original_content, payload, fallback)
        end
    end
  end

  defp base_payload(items, lang) do
    %{
      items: items,
      target_lang_name: lang.english,
      target_lang_code: lang.code,
      target_bcp47: lang.bcp47
    }
  end

  # ── text: clean + segment + translate in one call ──────────────────────

  # The whole point of the combined prompt: /duolang spends a SINGLE model
  # call on text (typed or the prior reply) — cleaning, segmenting, and
  # translating together — instead of a segment call followed by a
  # translate call. An empty result is trusted for derived sources (all
  # scaffolding); for typed text it degrades to segment-then-translate so
  # the user's own words are never silently dropped. An LLM failure also
  # degrades to that two-call path (rare).
  defp segment_and_translate(text, lang, meta, source) do
    case combined_call(text, lang, meta) do
      {:ok, []} when source == :typed -> translate_items(Sentences.segment(text, source), lang, meta)
      {:ok, items} -> items
      :error -> translate_items(Sentences.segment(text, source), lang, meta)
    end
  end

  defp combined_call(text, lang, meta) do
    msgs = [%{role: "system", content: combined_prompt(lang)}, %{role: "user", content: text}]

    case LLM.call(AgentSettings.swift_model(), msgs,
           options: %{temperature: 0}, trace: translate_trace(meta)) do
      {:ok, raw} when is_binary(raw) and raw != "" ->
        case Sentences.decode_llm_json(raw) do
          {:ok, %{"pairs" => list}} when is_list(list) ->
            {:ok, list |> Enum.map(&pair/1) |> Enum.reject(&(&1.original == ""))}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    e ->
      Logger.warning("[Duolang] combined_call raised: #{Exception.message(e)}")
      :error
  end

  defp pair(%{} = p) do
    %{
      original: p |> Map.get("original", "") |> to_string() |> String.trim(),
      translation: p |> Map.get("translation", "") |> to_string() |> String.trim()
    }
  end

  defp pair(_), do: %{original: "", translation: ""}

  defp combined_prompt(lang) do
    """
    You prepare text to be read aloud in two languages. First clean and
    segment the text into speakable sentences, then translate each into
    #{lang.english}.

    Output STRICT JSON with one key:

      {"pairs": [{"original": "…", "translation": "…"}]}

    #{Sentences.clean_rules()}
    For each kept sentence, `translation` is its faithful #{lang.english}
    rendering — meaning, tone, and register preserved; proper nouns and
    code-like tokens left as-is.

    Output rules:
      - The first character must be `{`. No commentary, no markdown fences.
      - `original` stays in its source language exactly; only `translation`
        is in #{lang.english}.
      - When unsure whether a line is content, keep it.
      - When there is no speakable prose, return {"pairs": []}.
    """
  end

  # ── translating already-segmented sentences (image OCR + degrade path) ──

  # One batched call aligns translations to originals by index. A count
  # mismatch or a failed/unparseable reply falls back to per-sentence
  # calls so a single bad row never drops the whole panel; an empty
  # translation (total failure) leaves the original alone on the FE.
  defp translate_items([], _lang, _meta), do: []

  defp translate_items(sentences, lang, meta) do
    case translate_batch(sentences, lang, meta) do
      {:ok, translations} when length(translations) == length(sentences) ->
        Enum.zip_with(sentences, translations, fn o, t -> %{original: o, translation: t} end)

      _ ->
        Enum.map(sentences, fn s -> %{original: s, translation: translate_one(s, lang, meta)} end)
    end
  end

  defp translate_batch(sentences, lang, meta) do
    payload = Jason.encode!(%{"target" => lang.english, "sentences" => sentences})
    msgs = [%{role: "system", content: @translate_system}, %{role: "user", content: payload}]

    case LLM.call(AgentSettings.swift_model(), msgs,
           options: %{temperature: 0}, trace: translate_trace(meta)) do
      {:ok, raw} when is_binary(raw) ->
        case Sentences.decode_llm_json(raw) do
          {:ok, %{"translations" => list}} when is_list(list) ->
            {:ok, list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    e ->
      Logger.warning("[Duolang] translate_batch raised: #{Exception.message(e)}")
      :error
  end

  defp translate_one(sentence, lang, meta) do
    case translate_batch([sentence], lang, meta) do
      {:ok, [t]} when t != "" -> t
      _ -> ""
    end
  end

  # ── persistence ────────────────────────────────────────────────────────

  defp finalize_with_payload(session_id, user_id, original_content, payload, fallback_text) do
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
        kind: "duolang",
        duolang: payload
      })

    {:handled, user_ts}
  end

  # Fallback `content` text — what shows when a FE renderer doesn't know
  # the `duolang:` field (old polling clients). The structured FE
  # replaces this with the bilingual per-sentence layout.
  defp compose_fallback_text(per_image, items, typed_text, source, lang) do
    ok_count = Enum.count(per_image, &(&1.status == "ok"))
    err_count = Enum.count(per_image, &(&1.status == "error"))
    n = length(items)
    has_typed = typed_text != ""
    target = lang.english

    cond do
      n == 0 and err_count > 0 ->
        "Couldn't extract text from #{err_count} image(s)."

      n == 0 ->
        "Nothing to read."

      source == :prior_reply ->
        "Rendered #{n} sentence(s) with #{target} translations from the previous reply."

      ok_count == 0 and has_typed ->
        "Rendered #{n} sentence(s) with #{target} translations from the typed text."

      ok_count > 0 and not has_typed ->
        "Extracted #{n} sentence(s) from #{ok_count} image(s) with #{target} translations." <>
          if(err_count > 0, do: " (#{err_count} image(s) errored.)", else: "")

      true ->
        "Rendered #{n} sentence(s) with #{target} translations (#{ok_count} image(s) + typed text)." <>
          if(err_count > 0, do: " (#{err_count} image(s) errored.)", else: "")
    end
  end

  defp translate_trace(meta) do
    %{
      origin: "confidant",
      path: "Commands.Pipelines.Duolang.translate_batch",
      role: "Duolang",
      phase: "translate",
      session_id: Map.get(meta, :session_id),
      user_id: Map.get(meta, :user_id),
      tier: :swift
    }
  end
end
