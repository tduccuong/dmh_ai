# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Tts do
  @moduledoc """
  `/tts [text]` runtime: turn an image (vision-OCR'd), a typed text
  argument, the previous assistant reply, or a mix into a
  sentence-per-row Read-out-loud panel. The assistant message carries
  the structured payload on its `tts.sentences` field (the FE renders
  each sentence with its own speaker / settings controls).

  Sentence gathering — which text to read and how it's segmented —
  lives in `DmhAi.Commands.Pipelines.Sentences`. This module owns only
  the `/tts`-specific payload shape, fallback copy, and persistence.

  Inputs (resolved by `Sentences.gather/3`):

    * Image(s) only          → OCR each image, sentences in attachment order.
    * Text only              → split the typed text into sentences.
    * Image(s) + text        → OCR first, then the typed text appended.
    * Bare `/tts`            → the session's most recent natural reply.
    * Nothing of the above   → friendly hint, no LLM round-trip.

  Confidant-mode only — Assistant mode is intercepted upstream with a
  short hint redirecting the user to switch modes.
  """

  alias DmhAi.Agent.UserAgentMessages
  alias DmhAi.Commands.Pipelines.Sentences

  @doc """
  Public entry. Returns `{:handled, user_ts}` for the chat HTTP entry.

  Arguments:
    * `original_content` — verbatim user message (`/tts <text>` or
       `/tts`). Persisted as the user's stored message.
    * `arg`              — the text after `/tts ` (may be empty).
    * `image_paths`      — absolute file paths the agent_chat handler
       resolved from the FE's `attachmentNames`.
  """
  @spec run(String.t(), String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()}
  def run(original_content, arg, session_id, user_id, _lang, image_paths \\ []) do
    %{text: text, image_sentences: image_sentences, per_image: per_image, source: source} =
      Sentences.gather(arg, image_paths, session_id)

    case source do
      :no_input ->
        finalize_with_payload(session_id, user_id, original_content,
          %{sentences: [], images: [], error: "no_input"},
          "Attach an image, type some text after `/tts`, or send `/tts` alone after I've replied — I'll render it as a sentence-per-row Read-out-loud panel.")

      _ ->
        sentences = image_sentences ++ Sentences.segment(text)

        tts_payload = %{
          sentences: sentences,
          images: per_image,
          typed_chars: String.length(text),
          source: Atom.to_string(source)
        }

        fallback = compose_fallback_text(per_image, sentences, text, source)
        finalize_with_payload(session_id, user_id, original_content, tts_payload, fallback)
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
  defp compose_fallback_text(per_image, sentences, typed_text, source) do
    ok_count = Enum.count(per_image, &(&1.status == "ok"))
    err_count = Enum.count(per_image, &(&1.status == "error"))
    n = length(sentences)
    has_typed = typed_text != ""

    cond do
      n == 0 and err_count > 0 ->
        "Couldn't extract text from #{err_count} image(s)."

      n == 0 ->
        "Nothing to read."

      source == :prior_reply ->
        "Rendered #{n} sentence(s) from the previous reply."

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
end
