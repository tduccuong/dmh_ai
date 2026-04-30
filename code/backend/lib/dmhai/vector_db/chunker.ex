# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.VectorDB.Chunker do
  @moduledoc """
  Recursive text splitter for the vector KB ingestion pipeline.

  Targets `kb_chunk_tokens` per chunk with `kb_chunk_overlap_tokens` of
  overlap between adjacent chunks (preserves context across boundary
  for dense retrieval). Splits on the cheapest separator that breaks
  the input into multiple parts: paragraph → line → sentence → word.
  Last-resort hard-cut on token count for whitespace-free strings.

  Token counting is a byte-pair approximation (`div(byte_size, 4)`) —
  qwen-family BPE averages ~4 chars/token, fine for chunking
  decisions. If recall ever proves weak, swap in a real tokenizer NIF
  here without touching call sites.
  """

  alias Dmhai.Agent.AgentSettings

  @doc """
  Split `text` into chunks with overlap. Returns a list of strings.
  Empty / blank input returns `[]`.
  """
  @spec split(String.t()) :: [String.t()]
  @spec split(String.t(), keyword()) :: [String.t()]
  def split(text, opts \\ []) when is_binary(text) do
    max_tokens     = Keyword.get(opts, :max_tokens,     AgentSettings.kb_chunk_tokens())
    overlap_tokens = Keyword.get(opts, :overlap_tokens, AgentSettings.kb_chunk_overlap_tokens())

    text = String.trim(text)
    if text == "" do
      []
    else
      do_split(text, max_tokens, overlap_tokens)
    end
  end

  @doc "Approximate token count for `text` using the BPE-byte heuristic."
  @spec token_count(String.t()) :: non_neg_integer()
  def token_count(text) when is_binary(text), do: div(byte_size(text), 4)

  # ─── Private ──────────────────────────────────────────────────────────────

  @separators ["\n\n", "\n", ". ", " "]

  defp do_split(text, max_tokens, overlap_tokens) do
    if token_count(text) <= max_tokens do
      [text]
    else
      case find_separator_split(text) do
        {:ok, parts, sep} ->
          greedy_pack(parts, sep, max_tokens, overlap_tokens)

        :no_separator ->
          hard_split(text, max_tokens, overlap_tokens)
      end
    end
  end

  defp find_separator_split(text) do
    Enum.reduce_while(@separators, :no_separator, fn sep, _ ->
      parts = String.split(text, sep)
      if length(parts) > 1 do
        {:halt, {:ok, parts, sep}}
      else
        {:cont, :no_separator}
      end
    end)
  end

  # Pack parts into chunks ≤ max_tokens. When a chunk fills, emit it,
  # then seed the next chunk with the last `overlap_tokens` worth of
  # parts from the chunk just emitted (preserves cross-boundary
  # context).
  defp greedy_pack(parts, sep, max_tokens, overlap_tokens) do
    do_pack(parts, sep, max_tokens, overlap_tokens, [], [], 0, [])
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp do_pack([], _sep, _max, _ov, current_parts, _last_emit, _curr_tokens, acc) do
    finished =
      case current_parts do
        []      -> acc
        ps      -> [join_parts(Enum.reverse(ps), :no_sep) | acc]
      end
    finished
  end

  defp do_pack([part | rest], sep, max, ov, current_parts, last_emit, curr_tokens, acc) do
    part_tokens = token_count(part)
    sep_tokens  = token_count(sep)

    cond do
      # First part of a chunk that's bigger than max all by itself: hard
      # split it and emit each fragment as its own chunk; restart packing
      # with what's left.
      current_parts == [] and part_tokens > max ->
        fragments = hard_split(part, max, ov)
        new_acc   = Enum.reverse(fragments) ++ acc
        # Use the LAST fragment as the seed for overlap on the next chunk
        seed = List.last(fragments) || ""
        seed_parts = if seed == "", do: [], else: [seed]
        do_pack(rest, sep, max, ov, seed_parts, [seed], token_count(seed), new_acc)

      # Adding this part would overflow: emit current chunk, seed with
      # tail-overlap, continue.
      #
      # Forward-progress guarantee: if the chosen seed plus the next
      # part would STILL overflow (rare but happens when a single
      # part is close to max_tokens), drop the seed entirely. The next
      # iteration then either fits part fresh or hits the hard-split
      # branch — either way the caller advances.
      current_parts != [] and curr_tokens + part_tokens + sep_tokens > max ->
        chunk = join_parts(Enum.reverse(current_parts), sep)
        seed_parts = take_tail_for_overlap(current_parts, ov)
        seed_tokens = sum_tokens(seed_parts) + max(length(seed_parts) - 1, 0) * sep_tokens

        {final_seed, final_tokens} =
          if seed_parts != [] and seed_tokens + sep_tokens + part_tokens > max do
            {[], 0}
          else
            {seed_parts, seed_tokens}
          end

        do_pack([part | rest], sep, max, ov, final_seed, current_parts, final_tokens, [chunk | acc])

      true ->
        new_parts  = [part | current_parts]
        new_tokens = curr_tokens + part_tokens + (if current_parts == [], do: 0, else: sep_tokens)
        do_pack(rest, sep, max, ov, new_parts, last_emit, new_tokens, acc)
    end
  end

  defp join_parts(parts, :no_sep), do: parts |> Enum.join("")
  defp join_parts(parts, sep) when is_binary(sep), do: Enum.join(parts, sep)

  # Take the trailing parts whose summed token count fits in
  # `overlap_tokens`. `current_parts` is reverse-order (most-recent
  # first), so we walk from head until the budget runs out, then
  # return chronological order.
  #
  # Hard cap: never include a part that ON ITS OWN exceeds the
  # overlap budget. The previous version always included at least one
  # part, which produced infinite-loop overflow when a single part
  # was already >= max_tokens (the seed equalled the just-emitted
  # chunk and the next iteration re-emitted it forever).
  defp take_tail_for_overlap(current_parts_reversed, overlap_tokens) do
    {taken, _} =
      Enum.reduce_while(current_parts_reversed, {[], 0}, fn part, {acc, tokens} ->
        new_tokens = tokens + token_count(part)

        if new_tokens > overlap_tokens do
          {:halt, {acc, tokens}}
        else
          {:cont, {[part | acc], new_tokens}}
        end
      end)

    taken
  end

  defp sum_tokens(parts), do: Enum.reduce(parts, 0, fn p, acc -> acc + token_count(p) end)

  # No whitespace at all: hard-cut on byte boundaries. Conservative:
  # cuts at `max_tokens * 4` bytes, which respects the BPE ratio.
  # Avoids splitting mid-codepoint by trimming back to a UTF-8 boundary.
  defp hard_split(text, max_tokens, overlap_tokens) do
    bytes_per_chunk   = max_tokens * 4
    bytes_per_overlap = overlap_tokens * 4
    do_hard_split(text, bytes_per_chunk, bytes_per_overlap, [])
  end

  defp do_hard_split("", _, _, acc), do: Enum.reverse(acc)
  defp do_hard_split(text, chunk_bytes, overlap_bytes, acc) do
    if byte_size(text) <= chunk_bytes do
      Enum.reverse([text | acc])
    else
      take = trim_to_codepoint_boundary(binary_part(text, 0, chunk_bytes))
      consumed = byte_size(take)
      step = max(consumed - overlap_bytes, 1)
      rest = binary_part(text, step, byte_size(text) - step)
      do_hard_split(rest, chunk_bytes, overlap_bytes, [take | acc])
    end
  end

  # If the byte slice ends mid-multibyte UTF-8 sequence, trim back until
  # it ends on a valid boundary. At most 3 trim iterations (max UTF-8
  # encoding length is 4 bytes — first byte plus up to 3 continuations).
  defp trim_to_codepoint_boundary(bin), do: trim_loop(bin, 3)

  defp trim_loop(bin, 0), do: bin
  defp trim_loop(bin, retries) do
    if String.valid?(bin) do
      bin
    else
      sz = byte_size(bin)
      if sz <= 1, do: bin, else: trim_loop(binary_part(bin, 0, sz - 1), retries - 1)
    end
  end
end
