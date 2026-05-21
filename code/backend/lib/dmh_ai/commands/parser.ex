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

  Workflow intent is NOT a slash command. Natural-language phrasing
  ("build a workflow that …", "run &<slug>", "edit &<slug> at node N")
  flows through the assistant's `<workflow_authoring>` heuristic + the
  `&<slug>` reference resolution sidecar. See
  `arch_wiki/dmh_ai/sme/layer-W.md`.

  Everything after the first whitespace is the verbatim argument
  (preserves URLs with query strings, paths with spaces).
  """

  @type result :: {:index, String.t()} | {:memo, String.t()} | :not_a_command

  @spec parse(String.t()) :: result()
  def parse(content) when is_binary(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "/index ") -> {:index, after_prefix(trimmed, "/index ")}
      trimmed == "/index"                     -> {:index, ""}

      String.starts_with?(trimmed, "/memo ")  -> {:memo, after_prefix(trimmed, "/memo ")}
      trimmed == "/memo"                      -> {:memo, ""}

      true                                     -> :not_a_command
    end
  end

  defp after_prefix(s, p) do
    s |> String.replace_prefix(p, "") |> String.trim_leading()
  end
end
