# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Refs do
  @moduledoc """
  Recursive helpers that compose `Mustache` + `Path` over arbitrary
  args values (maps, lists, strings, scalars). Both validator and
  executor consume this surface — the engines below it (Mustache,
  Path) are shared verbatim.

  Two operations:

    * `extract/1` — depth-first traversal returns every parsed ref
      found in the value tree. Used at validate time to enumerate
      what each node references, so the validator can confirm the
      ref's root + leading-key match a declared emit.

    * `substitute/2` — depth-first traversal applies `resolver`
      (`%Path.ref{}` → value | `:passthrough`) to every ref in the
      value tree, returning a new value with refs replaced. Used at
      run time by the executor.

  Bare-ref vs template handling is the responsibility of `Mustache`.
  The runtime semantics:

    * a string that is JUST `"{{ref}}"` (possibly with whitespace)
      becomes the TYPED return of `resolver` — could be a map / list /
      number, not just a string.
    * a string with mixed literals and refs is rendered as a string
      with each ref's resolved value stringified.

  Synthetic primitives (`llm.compose`, `llm.summarise`) hold templates
  whose refs the executor MUST NOT pre-substitute — the primitive
  resolves against its own `context` map. Those callers iterate the
  primitive's args themselves; this module is for the generic
  pre-execute substitution path.
  """

  alias DmhAi.Workflows.{Mustache, Path}

  @typedoc "Source of a ref + the parsed structure."
  @type extracted_ref :: %{raw: String.t(), parsed: Path.ref()} | %{raw: String.t(), error: String.t()}

  # ── extract ─────────────────────────────────────────────────────────

  @doc """
  Walk `value` depth-first and return every `{{ref}}` found inside
  any string at any depth. Each entry carries the raw ref body and
  either the parsed structure or a parser error so the validator
  can surface a precise message.
  """
  @spec extract(any()) :: [extracted_ref()]
  def extract(value), do: do_extract(value, [])

  defp do_extract(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> do_extract(v, a) end)
  end

  defp do_extract(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_extract/2)
  end

  defp do_extract(s, acc) when is_binary(s) do
    case Mustache.scan(s) do
      {:ok, chunks} ->
        Enum.reduce(chunks, acc, fn
          {:ref, body}, a ->
            case Path.parse(body) do
              {:ok, parsed}    -> [%{raw: body, parsed: parsed} | a]
              {:error, reason} -> [%{raw: body, error: reason} | a]
            end

          {:literal, _}, a ->
            a
        end)

      {:error, reason} ->
        # Malformed template — surface as a structured "error" ref so the
        # validator can flag it without trying to walk a half-parsed thing.
        [%{raw: s, error: reason} | acc]
    end
  end

  defp do_extract(_other, acc), do: acc

  # ── substitute ──────────────────────────────────────────────────────

  @doc """
  Walk `value` depth-first; for every string, run it through
  `Mustache.render/2` using `resolver`. Maps + lists recurse;
  scalars pass through.

  `resolver` receives the trimmed ref body (a string) and returns
  the resolved value, or `:passthrough` to leave the `{{…}}`
  in place.
  """
  @spec substitute(any(), (String.t() -> any() | :passthrough)) :: any()
  def substitute(map, resolver) when is_map(map) and is_function(resolver, 1) do
    Enum.into(map, %{}, fn {k, v} -> {k, substitute(v, resolver)} end)
  end

  def substitute(list, resolver) when is_list(list) and is_function(resolver, 1) do
    Enum.map(list, &substitute(&1, resolver))
  end

  def substitute(s, resolver) when is_binary(s) and is_function(resolver, 1) do
    Mustache.render(s, resolver)
  end

  def substitute(other, _resolver), do: other
end
