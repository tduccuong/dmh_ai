# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.TextSanitizer do
  @moduledoc """
  Scrubs pseudo-tool-call annotations some models tack onto their text
  output — things like:

      [used: complete_task({"task_id":"...","task_result":"..."})]
      [via: web_search]
      [called: extract_content]
      [tool: create_task]
      — via web_fetch(url)
      (used complete_task)

  The prompt forbids these (§No task bookkeeping in user-facing text)
  and Police rejects them at stream-end. This module is the belt-and-
  braces: it keeps the leak out of the user's view both during
  streaming and at persistence.

  Two entry points:

    * `strip_task_bookkeeping/1` — for final text at persistence time.
      Balanced-bracket scanner finds each `[TAG: ... ]` block (handles
      nested JSON brackets inside) and removes it, keeping surrounding
      text intact. Also strips trailing `— via <tool>(…)` / `(used …)`.

    * `truncate_at_bookkeeping/1` — for in-flight streaming. Partial
      annotations have no closing `]` yet; we can't balanced-match.
      Instead, truncate at the FIRST tag-opener so the user never
      sees the annotation begin to form. Called by StreamBuffer on
      every DB flush.

  `[` / `]` are ASCII → byte-level scanning is UTF-8-safe.
  """

  @bookkeeping_tag_regex ~r/\[(used|via|called|tool)\s*:/u

  @spec strip_task_bookkeeping(String.t() | any()) :: String.t() | any()
  def strip_task_bookkeeping(text) when is_binary(text) do
    text
    |> strip_bracket_annotations()
    |> strip_trailing_annotations()
    |> String.trim()
  end
  def strip_task_bookkeeping(other), do: other

  @spec truncate_at_bookkeeping(String.t() | any()) :: String.t() | any()
  def truncate_at_bookkeeping(text) when is_binary(text) do
    case Regex.run(@bookkeeping_tag_regex, text, return: :index) do
      nil -> text
      [{start, _} | _] ->
        text
        |> binary_part(0, start)
        |> String.trim_trailing()
    end
  end
  def truncate_at_bookkeeping(other), do: other

  # ── private ─────────────────────────────────────────────────────────────

  # Recursively strip the first `[used:` / `[via:` / `[called:` / `[tool:`
  # block by finding its matching `]` via depth counting. Unbalanced
  # (no closing `]`) → leave the text alone as a safety net.
  defp strip_bracket_annotations(text) do
    case Regex.run(@bookkeeping_tag_regex, text, return: :index) do
      nil -> text
      [{start, _} | _] ->
        case find_balanced_close(text, start + 1, 1) do
          nil -> text
          close ->
            before_part = binary_part(text, 0, start)
            after_part  = binary_part(text, close + 1, byte_size(text) - close - 1)
            strip_bracket_annotations(before_part <> after_part)
        end
    end
  end

  defp find_balanced_close(text, pos, depth) do
    cond do
      pos >= byte_size(text) -> nil
      true ->
        case binary_part(text, pos, 1) do
          "[" -> find_balanced_close(text, pos + 1, depth + 1)
          "]" when depth == 1 -> pos
          "]" -> find_balanced_close(text, pos + 1, depth - 1)
          _   -> find_balanced_close(text, pos + 1, depth)
        end
    end
  end

  # Conservative tail-only strips for dash / paren annotations.
  defp strip_trailing_annotations(text) do
    text
    |> (&Regex.replace(~r/\s*—\s*via\s+\w+(?:\([^)]*\))?\s*$/u, &1, "")).()
    |> (&Regex.replace(~r/\s*\(\s*used\s+\w+\s*\)\s*$/u, &1, "")).()
  end
end
