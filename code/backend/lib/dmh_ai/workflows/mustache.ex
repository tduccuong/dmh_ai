# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Mustache do
  @moduledoc """
  Single-pass scanner for the workflow IR's `{{ref}}` syntax. Splits a
  string into an ordered list of `{:literal, str}` and `{:ref, body}`
  chunks. No regex, no `String.split` — a four-state automaton walks
  the string once, byte by byte.

  Grammar:

      template = (literal | "{{" ref-body "}}")*
      literal  = any chars except "{{" / "}}"
      ref-body = anything that is NOT "}}"

  The scanner does NOT parse the ref body itself; that is
  `DmhAi.Workflows.Path.parse/1`. This module's only job is the outer
  template structure.

  Two consumers:

    * **Validator** — scans each string in the IR args, collects
      `{:ref, body}` chunks, hands the bodies to `Path.parse/1` to
      check they reference declared emits.
    * **Executor** — scans each string at runtime, replaces each ref
      with its resolved value (via `render/2`). For "bare" strings —
      a single ref with only whitespace around it — `render/2` returns
      the typed value (map / list / int / …) instead of a stringified
      form, so downstream consumers (e.g. `llm.compose`'s context map)
      keep the original shape.
  """

  @typedoc "A scanned chunk."
  @type chunk :: {:literal, String.t()} | {:ref, String.t()}

  @typedoc "Result of `scan/1`."
  @type scan_result :: {:ok, [chunk]} | {:error, String.t()}

  @doc """
  Walk the string once, emit chunks. Returns `{:ok, chunks}` on
  success and `{:error, reason}` if a `{{` is opened but never
  closed by `}}`. Stray single `{` / `}` characters are passed
  through as literal text — only doubled `{{` / `}}` are
  significant.
  """
  @spec scan(String.t()) :: scan_result()
  def scan(s) when is_binary(s), do: do_scan(s, :outside, "", [])

  # ── automaton ────────────────────────────────────────────────────────

  # state ∈ :outside | :saw_open1 | :inside | :saw_close1
  # buffer accumulates literal text OR ref body depending on state
  # out is the reverse-ordered list of chunks emitted so far

  defp do_scan(<<>>, :outside, buf, out) do
    {:ok, finalize(out, {:literal, buf})}
  end

  defp do_scan(<<>>, :saw_open1, buf, out) do
    # Single trailing "{" — passes through as literal.
    {:ok, finalize(out, {:literal, buf <> "{"})}
  end

  defp do_scan(<<>>, :inside, _buf, _out) do
    {:error, "unclosed `{{` — expected `}}` before end of input"}
  end

  defp do_scan(<<>>, :saw_close1, _buf, _out) do
    {:error, "unclosed `{{` — saw one `}` but second `}` missing before end of input"}
  end

  defp do_scan(<<"{", rest::binary>>, :outside, buf, out) do
    do_scan(rest, :saw_open1, buf, out)
  end

  defp do_scan(<<c::utf8, rest::binary>>, :outside, buf, out) do
    do_scan(rest, :outside, buf <> <<c::utf8>>, out)
  end

  defp do_scan(<<"{", rest::binary>>, :saw_open1, buf, out) do
    # Confirmed "{{" — flush literal so far, enter ref body.
    out = if buf == "", do: out, else: [{:literal, buf} | out]
    do_scan(rest, :inside, "", out)
  end

  defp do_scan(<<c::utf8, rest::binary>>, :saw_open1, buf, out) do
    # Was a stray "{" — fold it back into the literal.
    do_scan(rest, :outside, buf <> "{" <> <<c::utf8>>, out)
  end

  defp do_scan(<<"}", rest::binary>>, :inside, buf, out) do
    do_scan(rest, :saw_close1, buf, out)
  end

  defp do_scan(<<c::utf8, rest::binary>>, :inside, buf, out) do
    do_scan(rest, :inside, buf <> <<c::utf8>>, out)
  end

  defp do_scan(<<"}", rest::binary>>, :saw_close1, buf, out) do
    # Confirmed "}}" — flush ref, back to literal mode.
    do_scan(rest, :outside, "", [{:ref, String.trim(buf)} | out])
  end

  defp do_scan(<<c::utf8, rest::binary>>, :saw_close1, buf, out) do
    # Was a stray "}" inside the ref — fold it back into the body.
    do_scan(rest, :inside, buf <> "}" <> <<c::utf8>>, out)
  end

  defp finalize(out, {:literal, ""}), do: Enum.reverse(out)
  defp finalize(out, last_chunk),     do: Enum.reverse([last_chunk | out])

  # ── render ───────────────────────────────────────────────────────────

  @doc """
  Substitute every ref in `s` using `resolver`. Two cases:

    * **Bare ref** — `s` is a single `{{ref}}` (possibly with surrounding
      whitespace and nothing else). `render/2` returns the resolver's
      TYPED return value as-is (could be any term). This preserves the
      shape of refs used as full args, e.g. `args.recipient: "{{0.user}}"`
      where `0.user` is an object.

    * **Template** — `s` contains literal text mixed with refs.
      `render/2` returns a STRING with each ref's resolved value
      stringified and concatenated with the literals.

  The resolver receives the trimmed ref body (the inner part between
  `{{` and `}}`) and returns the resolved value, or `:passthrough` to
  signal "I can't resolve this; keep the original `{{…}}` in the
  output". Useful for synthetic primitives (`llm.compose`) whose
  template arg holds refs the executor must NOT pre-substitute — the
  primitive resolves them against its own `context` map at run time.
  """
  @spec render(String.t(), (String.t() -> any() | :passthrough)) :: any()
  def render(s, resolver) when is_binary(s) and is_function(resolver, 1) do
    case scan(s) do
      {:error, _reason} ->
        # Malformed template — keep the original string untouched so
        # downstream code (or logs) can flag it.
        s

      {:ok, chunks} ->
        case classify(chunks) do
          {:bare, body} ->
            case resolver.(body) do
              :passthrough -> s
              value        -> value
            end

          :template ->
            chunks
            |> Enum.map(fn
              {:literal, lit} ->
                lit

              {:ref, body} ->
                case resolver.(body) do
                  :passthrough -> "{{" <> body <> "}}"
                  value        -> to_string(value)
                end
            end)
            |> IO.iodata_to_binary()
        end
    end
  end

  # A chunk list is "bare" iff it contains exactly one :ref and every
  # :literal is whitespace-only.
  defp classify(chunks) do
    refs = for {:ref, body} <- chunks, do: body
    lits = for {:literal, lit} <- chunks, do: lit

    case refs do
      [body] ->
        if Enum.all?(lits, &(String.trim(&1) == "")) do
          {:bare, body}
        else
          :template
        end

      _ ->
        :template
    end
  end
end
