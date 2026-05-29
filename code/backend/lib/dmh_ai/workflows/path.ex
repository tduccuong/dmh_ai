# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Path do
  @moduledoc """
  Single-pass parser for the workflow IR's reference grammar.

  Grammar (BNF):

      ref         = root ("." segment | "[" int "]")*
      root        = "T" | "owner" | "org" | time | int
      time        = ("now" | "today") offset?     ; carries no path
      offset      = ("+" | "-") int ("m" | "h" | "d" | "w")
      segment     = ident | int
      ident       = [A-Za-z_][A-Za-z0-9_]*
      int         = [0-9]+

  Examples and what they parse to:

      "T.deal.contact.email"
      → %{root: :trigger, path: [{:key,"deal"}, {:key,"contact"}, {:key,"email"}]}

      "0.messages[0].sender"
      → %{root: {:node, 0}, path: [{:key,"messages"}, {:index,0}, {:key,"sender"}]}

      "0.api.data.items[5].user.profile.emails[0].address"
      → 8 accessors after the {:node, 0} root, all typed correctly.

      "owner.email"
      → %{root: :owner, path: [{:key,"email"}]}

      "now"
      → %{root: :now, path: []}

      "now-7d"   (offset form: seven days before now)
      → %{root: {:now, -604_800}, path: []}

      "0.foo[0][1].bar"  (list-of-lists indexing)
      → %{root: {:node,0}, path: [{:key,"foo"}, {:index,0}, {:index,1}, {:key,"bar"}]}

  Anything outside the grammar is rejected with a position-aware
  error. The parser is the SPEC of what's supported; extending the
  grammar means adding a state, not tweaking a regex.

  Companion: `walk/2` takes a parsed path and walks a data structure
  with the accessors. Used at validation time (against declared-emit
  metadata) and at run time (against live node-output data).
  """

  @typedoc "A single step of the parsed path."
  @type accessor :: {:key, String.t()} | {:index, non_neg_integer()}

  @typedoc """
  The root binding namespace. `:local` is the catch-all for refs
  whose leading token doesn't match a known workflow-binding root —
  those are TEMPLATE-LOCAL placeholders (e.g. `{{name}}` inside an
  `llm.compose` template, resolved by the synthetic primitive at run
  time against its own `context` map). The validator skips them; the
  executor returns `:passthrough` so the literal `{{…}}` survives
  into the synthetic's args.
  """
  @type root ::
          :trigger
          | :owner
          | :org
          | :now
          | :today
          | {:now, integer()}
          | {:today, integer()}
          | :local
          | {:node, non_neg_integer()}

  @typedoc "The parsed reference."
  @type ref :: %{root: root(), path: [accessor()]}

  # Offset units for the relative-time forms (`now-7d`, `today+2w`).
  # Values are physical second-counts per unit — not operator config.
  @offset_unit_seconds %{"m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800}

  @doc """
  Parse a ref body (the content between `{{` and `}}`, already trimmed).
  Returns `{:ok, ref}` or `{:error, reason}` with the byte offset of
  the problem character.
  """
  @spec parse(String.t()) :: {:ok, ref()} | {:error, String.t()}
  def parse(s) when is_binary(s) do
    with {:ok, root, rest, offset} <- parse_root(s) do
      case rest do
        "" -> {:ok, %{root: root, path: []}}
        _  ->
          case parse_path(rest, offset) do
            {:ok, path}   -> {:ok, %{root: root, path: path}}
            {:error, why} -> {:error, why}
          end
      end
    end
  end

  # ── root ────────────────────────────────────────────────────────────

  defp parse_root(s) do
    {head, rest, head_len} = take_root_token(s, "", 0)

    case head do
      "" ->
        {:error, "empty ref"}

      "T" ->
        case rest do
          "" -> {:ok, :trigger, "", head_len}
          "." <> tail -> {:ok, :trigger, tail, head_len + 1}
          _   -> {:error, "expected `.` or end after root `T` at offset #{head_len}"}
        end

      "owner" ->
        consume_dot_or_end(rest, :owner, head_len)

      "org" ->
        consume_dot_or_end(rest, :org, head_len)

      "now" ->
        if rest == "", do: {:ok, :now, "", head_len},
          else: {:error, "unexpected content after `now` at offset #{head_len}"}

      "today" ->
        if rest == "", do: {:ok, :today, "", head_len},
          else: {:error, "unexpected content after `today` at offset #{head_len}"}

      other ->
        case parse_time_offset(other) do
          {:ok, time_root} ->
            # `now`/`today` (offset form) are scalar — they take an
            # offset and nothing else, no `.`/`[` sub-path.
            if rest == "",
              do: {:ok, time_root, "", head_len},
              else:
                {:error,
                 "`now`/`today` take a relative offset only (e.g. `now-7d`), " <>
                   "no `.`/`[` path, at offset #{head_len}"}

          :error ->
            parse_node_or_local(other, rest, head_len, s)
        end
    end
  end

  defp parse_node_or_local(other, rest, head_len, original) do
    case Integer.parse(other) do
      {n, ""} when n >= 0 ->
        case rest do
          ""          -> {:ok, {:node, n}, "", head_len}
          "." <> tail -> {:ok, {:node, n}, tail, head_len + 1}
          "[" <> _    -> {:ok, {:node, n}, rest, head_len}
          _           -> {:error, "expected `.`, `[`, or end after node id `#{other}` at offset #{head_len}"}
        end

      _ ->
        # Unknown leading token. NOT a grammar error — this is a
        # template-local placeholder (e.g. `{{name}}` referring to
        # a key in `llm.compose`'s context map). Push the entire
        # original string back into `parse_path` so the first
        # token becomes the first :key accessor.
        {:ok, :local, original, 0}
    end
  end

  # Relative-time offset on `now` / `today` — `now-7d`, `today+2w`.
  # Returns the root tuple carrying the offset in SECONDS, or `:error`
  # when `head` isn't an offset form (so the caller falls through to
  # node-id / local-placeholder parsing). Sign + integer count + unit.
  defp parse_time_offset(head) do
    case Regex.run(~r/^(now|today)([+-])(\d+)([mhdw])$/, head) do
      [_, base, sign, count, unit] ->
        magnitude = String.to_integer(count) * Map.fetch!(@offset_unit_seconds, unit)
        seconds   = if sign == "-", do: -magnitude, else: magnitude
        root      = if base == "now", do: {:now, seconds}, else: {:today, seconds}
        {:ok, root}

      _ ->
        :error
    end
  end

  defp consume_dot_or_end(rest, atom, head_len) do
    case rest do
      ""          -> {:ok, atom, "", head_len}
      "." <> tail -> {:ok, atom, tail, head_len + 1}
      "[" <> _    -> {:ok, atom, rest, head_len}
      _           -> {:error, "expected `.`, `[`, or end after root `#{atom}` at offset #{head_len}"}
    end
  end

  # Consume a leading ident-or-int run, stopping at `.` or `[` or end.
  defp take_root_token(<<>>, buf, n), do: {buf, <<>>, n}
  defp take_root_token(<<".", _::binary>> = s, buf, n), do: {buf, s, n}
  defp take_root_token(<<"[", _::binary>> = s, buf, n), do: {buf, s, n}
  defp take_root_token(<<c::utf8, rest::binary>>, buf, n) do
    take_root_token(rest, buf <> <<c::utf8>>, n + 1)
  end

  # ── path ────────────────────────────────────────────────────────────

  # State machine over the remaining string. Tracks the byte offset
  # ONLY for error messages; success path doesn't care.
  defp parse_path(s, offset0), do: do_parse_path(s, offset0, :after_separator, "", [])

  # state ∈
  #   :after_separator   — expecting a fresh ident or int (segment start),
  #                        or `[int]` for bracket index
  #   :in_ident          — accumulating an ident segment
  #   :in_index_int      — accumulating a numeric segment (dot-form)
  #   :in_bracket        — accumulating digits inside `[...]`
  #   :expect_sep_or_end — just closed a bracket; next must be `.`, `[`,
  #                        or end-of-input
  #
  # buf is the byte buffer of the segment-in-progress.
  # path is the reverse-ordered accessor list.

  defp do_parse_path(<<>>, _o, state, buf, path) do
    case state do
      :after_separator   -> {:error, "expected segment after `.` but ref ended"}
      :in_ident          -> {:ok, Enum.reverse([{:key, buf} | path])}
      :in_index_int      -> {:ok, Enum.reverse([{:index, String.to_integer(buf)} | path])}
      :in_bracket        -> {:error, "unclosed `[` — expected `]` before end of ref"}
      :expect_sep_or_end -> {:ok, Enum.reverse(path)}
    end
  end

  # ── :after_separator ──
  defp do_parse_path(<<c::utf8, rest::binary>>, o, :after_separator, _buf, path)
       when c in ?A..?Z or c in ?a..?z or c == ?_ do
    do_parse_path(rest, o + 1, :in_ident, <<c::utf8>>, path)
  end

  defp do_parse_path(<<c::utf8, rest::binary>>, o, :after_separator, _buf, path)
       when c in ?0..?9 do
    do_parse_path(rest, o + 1, :in_index_int, <<c::utf8>>, path)
  end

  defp do_parse_path(<<"[", _::binary>>, o, :after_separator, _buf, _path),
    do: {:error, "expected segment after `.` at offset #{o} but got `[`"}

  defp do_parse_path(<<c::utf8, _rest::binary>>, o, :after_separator, _buf, _path) do
    {:error, "unexpected character `#{<<c::utf8>>}` at offset #{o} — expected a segment"}
  end

  # ── :in_ident ──
  defp do_parse_path(<<c::utf8, rest::binary>>, o, :in_ident, buf, path)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ do
    do_parse_path(rest, o + 1, :in_ident, buf <> <<c::utf8>>, path)
  end

  defp do_parse_path(<<".", rest::binary>>, o, :in_ident, buf, path) do
    do_parse_path(rest, o + 1, :after_separator, "", [{:key, buf} | path])
  end

  defp do_parse_path(<<"[", rest::binary>>, o, :in_ident, buf, path) do
    do_parse_path(rest, o + 1, :in_bracket, "", [{:key, buf} | path])
  end

  defp do_parse_path(<<c::utf8, _rest::binary>>, o, :in_ident, _buf, _path) do
    {:error, "unexpected character `#{<<c::utf8>>}` at offset #{o} inside ident"}
  end

  # ── :in_index_int ──  (numeric segment in dot-form, e.g. `messages.0.sender`)
  defp do_parse_path(<<c::utf8, rest::binary>>, o, :in_index_int, buf, path)
       when c in ?0..?9 do
    do_parse_path(rest, o + 1, :in_index_int, buf <> <<c::utf8>>, path)
  end

  defp do_parse_path(<<".", rest::binary>>, o, :in_index_int, buf, path) do
    do_parse_path(rest, o + 1, :after_separator, "",
      [{:index, String.to_integer(buf)} | path])
  end

  defp do_parse_path(<<"[", rest::binary>>, o, :in_index_int, buf, path) do
    do_parse_path(rest, o + 1, :in_bracket, "",
      [{:index, String.to_integer(buf)} | path])
  end

  defp do_parse_path(<<c::utf8, _rest::binary>>, o, :in_index_int, _buf, _path) do
    {:error, "unexpected character `#{<<c::utf8>>}` at offset #{o} inside numeric segment"}
  end

  # ── :in_bracket ──
  defp do_parse_path(<<c::utf8, rest::binary>>, o, :in_bracket, buf, path)
       when c in ?0..?9 do
    do_parse_path(rest, o + 1, :in_bracket, buf <> <<c::utf8>>, path)
  end

  defp do_parse_path(<<"]", _rest::binary>>, o, :in_bracket, "", _path),
    do: {:error, "empty `[]` at offset #{o} — bracket must contain a non-negative integer"}

  defp do_parse_path(<<"]", rest::binary>>, o, :in_bracket, buf, path) do
    do_parse_path(rest, o + 1, :expect_sep_or_end, "",
      [{:index, String.to_integer(buf)} | path])
  end

  defp do_parse_path(<<c::utf8, _rest::binary>>, o, :in_bracket, _buf, _path) do
    {:error, "unexpected character `#{<<c::utf8>>}` at offset #{o} inside `[…]` — only digits allowed"}
  end

  # ── :expect_sep_or_end ──
  defp do_parse_path(<<".", rest::binary>>, o, :expect_sep_or_end, _buf, path),
    do: do_parse_path(rest, o + 1, :after_separator, "", path)

  defp do_parse_path(<<"[", rest::binary>>, o, :expect_sep_or_end, _buf, path),
    do: do_parse_path(rest, o + 1, :in_bracket, "", path)

  defp do_parse_path(<<c::utf8, _rest::binary>>, o, :expect_sep_or_end, _buf, _path) do
    {:error, "unexpected character `#{<<c::utf8>>}` at offset #{o} after `]` — expected `.`, `[`, or end"}
  end

  # ── walker ──────────────────────────────────────────────────────────

  @doc """
  Walk `data` following `accessors`. Returns the value or
  `:not_found` (missing key / out-of-range index / type mismatch).

  Map accessors that name a key try both string-keyed and atom-keyed
  lookups so the runtime can feed in either shape without conversion.
  Numeric accessors against a list use `Enum.at/2`.
  """
  @typedoc """
  Walk result. The `:index_miss` shape is load-bearing: when a step's
  arg resolves through `{{N.<list>[I].field}}` and `<list>` was empty
  (or had < I+1 entries), the executor MUST fail the step with a
  `:lookup_miss` error class rather than silently passing `""` to the
  vendor — the workflow's `on_failure` then decides whether to pause
  for operator intervention or take a recovery branch.
  """
  @type walk_result :: any() | :not_found | {:index_miss, non_neg_integer()}

  @spec walk(any(), [accessor()]) :: walk_result()
  def walk(data, []), do: data

  def walk(map, [{:key, k} | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil ->
        # try atom key — some runtime data has atom keys (e.g. structs decoded
        # from internal calls before re-encoding for the model).
        case Map.get(map, safe_atom(k)) do
          nil -> :not_found
          v   -> walk(v, rest)
        end

      v ->
        walk(v, rest)
    end
  end

  def walk(list, [{:index, i} | rest]) when is_list(list) and i >= 0 do
    case Enum.at(list, i, :__index_miss__) do
      :__index_miss__ -> {:index_miss, i}
      v               -> walk(v, rest)
    end
  end

  def walk(_data, _accessors), do: :not_found

  # `safe_atom` only succeeds on already-known atoms, so an attacker
  # supplying arbitrary keys can't blow up the atom table.
  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :__no_such_atom__
  end
end
