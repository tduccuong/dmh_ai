# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Languages do
  @moduledoc """
  Canonical table of the languages the runtime can translate into and
  speak. The set mirrors the product UI locales (`code/js/core.js`):
  English, Vietnamese, German, Spanish, French.

  Each entry carries:

    * `:code`    — the locale code shared with the FE i18n layer.
    * `:english` — the full English name the user types as the
      `/duolang <full-lang-name>` token (single token, robust to parse).
    * `:native`  — the endonym shown in the FE language picker.
    * `:bcp47`   — the speech-synthesis locale the FE uses to pick a
      voice for the translated row's Read-out-loud control.

  `split_leading/1` peels a leading language name (English or native,
  case-insensitive) off the `/duolang` argument so the pipeline can
  separate "which language" from "what to translate".
  """

  @type lang :: %{code: String.t(), english: String.t(), native: String.t(), bcp47: String.t()}

  @languages [
    %{code: "en", english: "English", native: "English", bcp47: "en-US"},
    %{code: "vi", english: "Vietnamese", native: "Tiếng Việt", bcp47: "vi-VN"},
    %{code: "de", english: "German", native: "Deutsch", bcp47: "de-DE"},
    %{code: "es", english: "Spanish", native: "Español", bcp47: "es-ES"},
    %{code: "fr", english: "French", native: "Français", bcp47: "fr-FR"}
  ]

  @doc "The full language table, in display order."
  @spec all() :: [lang()]
  def all, do: @languages

  @doc "Comma-joined English names — used in the unknown-language usage hint."
  @spec names_hint() :: String.t()
  def names_hint, do: @languages |> Enum.map(& &1.english) |> Enum.join(", ")

  @doc """
  Resolve a language NAME (English or native, case-insensitive, whitespace
  tolerant) to its table entry. Used by the natural-language `/duolang`
  route to map the model's chosen `source_lang` / `target_lang` strings to
  the entry carrying the code + BCP-47 voice. Returns `nil` for any name
  outside the supported set.
  """
  @spec by_name(String.t()) :: lang() | nil
  def by_name(name) when is_binary(name) do
    down = name |> String.trim() |> String.downcase()
    Enum.find(@languages, fn l ->
      String.downcase(l.english) == down or String.downcase(l.native) == down
    end)
  end

  def by_name(_), do: nil

  @doc """
  Resolve a language CODE to its table entry. Duolang persists the
  learner's language pair as codes, so every read path back to a display
  name or BCP-47 voice goes through here. Returns `nil` for any code
  outside the supported set.
  """
  @spec by_code(String.t()) :: lang() | nil
  def by_code(code) when is_binary(code) do
    down = code |> String.trim() |> String.downcase()
    Enum.find(@languages, &(&1.code == down))
  end

  def by_code(_), do: nil

  @doc """
  Split a leading language name off `text`. Matches the longest
  English-or-native name (case-insensitive) that sits at the start of
  the string and is followed by whitespace or end-of-string, so
  `"Germany ..."` never matches `"German"`.

  Returns `{lang, rest}` with `rest` the remaining argument (trimmed),
  or `:no_match` when no known language leads the string.
  """
  @spec split_leading(String.t()) :: {lang(), String.t()} | :no_match
  def split_leading(text) when is_binary(text) do
    trimmed = String.trim_leading(text)
    down = String.downcase(trimmed)

    @languages
    # Both names per language, longest first so a longer name wins over
    # a shorter one that happens to be its prefix.
    |> Enum.flat_map(fn lang -> [{lang.english, lang}, {lang.native, lang}] end)
    |> Enum.sort_by(fn {name, _} -> -String.length(name) end)
    |> Enum.find_value(:no_match, fn {name, lang} ->
      dn = String.downcase(name)

      cond do
        down == dn ->
          {lang, ""}

        String.starts_with?(down, dn <> " ") ->
          rest = trimmed |> String.slice(String.length(name)..-1//1) |> String.trim_leading()
          {lang, rest}

        true ->
          nil
      end
    end)
  end

  def split_leading(_), do: :no_match
end
