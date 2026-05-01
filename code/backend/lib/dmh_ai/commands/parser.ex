# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Parser do
  @moduledoc """
  Slash-command tokenizer. Recognises:

    * `/wiki <input>`  — save into the global wiki (runtime, no LLM round-trip)
    * `/memo <input>`  — save OR query the user's memo store; runtime
      classifies via Oracle (see `DmhAi.Commands.Memo`).

  Everything after the first whitespace is the verbatim argument
  (preserves URLs with query strings, paths with spaces).

  See specs/commands.md.
  """

  @type result ::
          {:wiki, String.t()}
          | {:memo, String.t()}
          | :not_a_command

  @spec parse(String.t()) :: result()
  def parse(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "/wiki ") -> {:wiki, after_prefix(trimmed, "/wiki ")}
      trimmed == "/wiki"                     -> {:wiki, ""}
      String.starts_with?(trimmed, "/memo ") -> {:memo, after_prefix(trimmed, "/memo ")}
      trimmed == "/memo"                     -> {:memo, ""}
      true                                    -> :not_a_command
    end
  end

  defp after_prefix(s, p) do
    s |> String.replace_prefix(p, "") |> String.trim_leading()
  end
end
