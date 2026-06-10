# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Parser do
  @moduledoc """
  Slash-command tokenizer. Recognises:

    * `/index <input>` — save into the global index (runtime, no LLM round-trip).
    * `/memo <input>`  — save OR query the user's memo store; runtime
      classifies via Oracle (see `DmhAi.Commands.Memo`).
    * `/tts [text]`    — render `text` (and/or OCR'd text from any attached
      images) as a sentence-per-row Read-out-loud panel. `text` is
      optional: with image only → OCR; with text only → split + render the
      typed text; with both → OCR followed by the typed text. Confidant-mode.
    * `/duolang <full-lang-name> [text]` — same gathering as `/tts`, plus a
      translation of every sentence into `<full-lang-name>` rendered beneath
      its original. The leading language token is split out downstream by
      `DmhAi.Commands.Languages`; the arg here is everything after
      `/duolang `. Confidant-mode.

  Workflow intent is NOT a slash command. Natural-language phrasing
  ("build a workflow that …", "run &<slug>", "edit &<slug> at node N")
  flows through the assistant's `<workflow_authoring>` heuristic + the
  `&<slug>` reference resolution sidecar. See
  `arch_wiki/dmh_ai/sme/layer-W.md`.

  Everything after the first whitespace is the verbatim argument
  (preserves URLs with query strings, paths with spaces).
  """

  @type result ::
          {:index, String.t()}
          | {:memo, String.t()}
          | {:tts, String.t()}
          | {:duolang, String.t()}
          | :not_a_command

  @spec parse(String.t()) :: result()
  def parse(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "/index ") -> {:index, after_prefix(trimmed, "/index ")}
      trimmed == "/index"                     -> {:index, ""}

      String.starts_with?(trimmed, "/memo ")  -> {:memo, after_prefix(trimmed, "/memo ")}
      trimmed == "/memo"                      -> {:memo, ""}

      String.starts_with?(trimmed, "/tts ")   -> {:tts, after_prefix(trimmed, "/tts ")}
      trimmed == "/tts"                       -> {:tts, ""}

      String.starts_with?(trimmed, "/duolang ") -> {:duolang, after_prefix(trimmed, "/duolang ")}
      trimmed == "/duolang"                     -> {:duolang, ""}

      true                                     -> :not_a_command
    end
  end

  defp after_prefix(s, p) do
    s |> String.replace_prefix(p, "") |> String.trim_leading()
  end
end
