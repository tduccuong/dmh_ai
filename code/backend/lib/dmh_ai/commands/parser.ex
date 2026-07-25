# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Parser do
  @moduledoc """
  Slash-command tokenizer. Recognises:

    * `/memo <input>`  — save into the user's memo store
      (see `DmhAi.Commands.Memo`).
    * `/tts [text]`    — render `text` (and/or OCR'd text from any attached
      images, or the previous reply) as a sentence-per-row Read-out-loud
      panel.

  Everything after the first whitespace is the verbatim argument
  (preserves text with spaces).
  """

  @type result ::
          {:memo, String.t()}
          | {:tts, String.t()}
          | :not_a_command

  @spec parse(String.t()) :: result()
  def parse(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "/memo ")  -> {:memo, after_prefix(trimmed, "/memo ")}
      trimmed == "/memo"                      -> {:memo, ""}

      String.starts_with?(trimmed, "/tts ")   -> {:tts, after_prefix(trimmed, "/tts ")}
      trimmed == "/tts"                       -> {:tts, ""}

      true                                     -> :not_a_command
    end
  end

  defp after_prefix(s, p) do
    s |> String.replace_prefix(p, "") |> String.trim_leading()
  end
end
