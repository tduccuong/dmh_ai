# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Profiler do
  @moduledoc """
  Deterministic difficulty measurement of a generated text. Pure — no
  model call, no DB read, no network. Callers pass the learner's
  known-word set in; `Duolang.KnownWords` owns loading it.

  A model asked to write at a named proficiency level lands on it only a
  small fraction of the time, and errs directionally — too easy at the
  bottom of the range, too hard at the top. So the level named in a
  generation prompt is a hint and this module is the authority. The model
  is never asked to grade its own output; that is circular.

  This module **measures**; `Duolang.Generator` **judges**. Three measures
  are always reported, and only the thresholds the caller supplies are
  enforced — which lets the choice of governing measure live in one place
  rather than being spread across both modules.

    * **token miss rate** — share of content tokens absent from the
      learner's known words. The right measure once a learner has a
      vocabulary to be measured against.
    * **new word count** — how many *distinct* unknown words the text
      introduces. The right measure before then, when a rate would be
      near 100% no matter what the model wrote.
    * **hardest sentence** — the longest sentence's word count. Text
      difficulty is governed by its worst sentence, not its mean;
      averaging hides the one sentence that stops the learner.

  `profile/3` returns a report either way; `acceptable?/1` reads the
  verdict off it. A rejected report carries the specific misses and the
  offending sentence so `Duolang.Generator` can repair rather than
  blindly reroll.
  """

  @typedoc "Per-sentence measurement, ordered as the sentence appears in the text."
  @type sentence :: %{
          text: String.t(),
          word_count: non_neg_integer(),
          missing: [String.t()]
        }

  @type failure :: :token_miss_rate | :new_words | :sentence_length

  @type report :: %{
          acceptable: boolean(),
          token_miss_rate: float(),
          new_word_count: non_neg_integer(),
          max_sentence_words: non_neg_integer(),
          missing_words: [String.t()],
          hardest_sentence: sentence() | nil,
          sentences: [sentence()],
          failures: [failure()]
        }

  # Sentence terminators, Unicode-aware so non-ASCII alphabets split the
  # same way as Latin. Mirrors the splitter in Commands.Pipelines.Sentences.
  @sentence_split ~r/(?<=[.!?])\s+/u

  # A "content token" for miss-rate purposes: letters, apostrophes and
  # internal hyphens, with surrounding punctuation and digits stripped.
  # Digits carry no vocabulary load, so they are not counted either way.
  @word_split ~r/[^\p{L}'\-]+/u

  @doc """
  Measure `text` against `known_words` and enforce whichever thresholds
  the caller supplies.

  `known_words` is a MapSet of normalised (downcased) words.

  Options — each optional; an omitted threshold is measured and reported
  but never fails the text:

    * `:max_token_miss_rate` — percent of content tokens that may be unknown.
    * `:max_new_words`       — distinct unknown words the text may introduce.
    * `:max_sentence_words`  — ceiling on the longest sentence.
  """
  @spec profile(String.t(), MapSet.t(String.t()), keyword()) :: report()
  def profile(text, known_words, opts \\ []) do
    sentences = Enum.map(split_sentences(text), &measure_sentence(&1, known_words))

    all_tokens = Enum.flat_map(sentences, & &1.word_count_tokens)
    missing = sentences |> Enum.flat_map(& &1.missing) |> Enum.uniq()

    miss_rate = percent(length(missing_tokens(all_tokens, known_words)), length(all_tokens))
    new_word_count = length(missing)
    hardest = Enum.max_by(sentences, & &1.word_count, fn -> nil end)
    max_sentence_words = if hardest, do: hardest.word_count, else: 0

    failures =
      []
      |> maybe_failure(exceeds?(miss_rate, opts[:max_token_miss_rate]), :token_miss_rate)
      |> maybe_failure(exceeds?(new_word_count, opts[:max_new_words]), :new_words)
      |> maybe_failure(exceeds?(max_sentence_words, opts[:max_sentence_words]), :sentence_length)

    %{
      acceptable: failures == [],
      token_miss_rate: miss_rate,
      new_word_count: new_word_count,
      max_sentence_words: max_sentence_words,
      missing_words: missing,
      hardest_sentence: strip_internals(hardest),
      sentences: Enum.map(sentences, &strip_internals/1),
      failures: failures
    }
  end

  @doc "True when the text cleared both thresholds."
  @spec acceptable?(report()) :: boolean()
  def acceptable?(%{acceptable: acceptable}), do: acceptable

  @doc """
  Split `text` into sentences. Exposed because the generator reports the
  offending sentence back to the model on a repair pass, and the session
  builds one speakable row per sentence — all three must agree on where
  the boundaries are.
  """
  @spec split_sentences(String.t()) :: [String.t()]
  def split_sentences(text) when is_binary(text) do
    text
    |> String.split(~r/\n+/, trim: true)
    |> Enum.flat_map(&String.split(&1, @sentence_split, trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Normalise `text` into the comparable word tokens the miss rate counts.
  `Duolang.KnownWords` uses the same function when ingesting met text, so
  the two sides of the comparison can never drift apart.
  """
  @spec words(String.t()) :: [String.t()]
  def words(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(@word_split, trim: true)
    |> Enum.map(&String.trim(&1, "-"))
    |> Enum.map(&String.trim(&1, "'"))
    |> Enum.reject(&(&1 == ""))
  end

  # ── internals ──────────────────────────────────────────────────────────

  # Comparison is case-insensitive, but the words reported back are the
  # surface forms from the text — a German noun shown lowercased reads as
  # a bug to anyone who speaks the language.
  defp measure_sentence(sentence, known_words) do
    tokens = words(sentence)
    surface = surface_forms(sentence)

    missing =
      tokens
      |> missing_tokens(known_words)
      |> Enum.uniq()
      |> Enum.map(&Map.get(surface, &1, &1))

    %{
      text: sentence,
      word_count: length(tokens),
      word_count_tokens: tokens,
      missing: missing
    }
  end

  # lowercase key -> first surface form seen for it
  defp surface_forms(sentence) do
    sentence
    |> String.split(@word_split, trim: true)
    |> Enum.map(&(&1 |> String.trim("-") |> String.trim("'")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn w, acc -> Map.put_new(acc, String.downcase(w), w) end)
  end

  defp missing_tokens(tokens, known_words), do: Enum.reject(tokens, &MapSet.member?(known_words, &1))

  # The report is a public contract; the token list is a working value.
  defp strip_internals(nil), do: nil
  defp strip_internals(sentence), do: Map.delete(sentence, :word_count_tokens)

  # An omitted threshold is measured but never enforced.
  defp exceeds?(_measured, nil), do: false
  defp exceeds?(measured, limit), do: measured > limit

  defp maybe_failure(list, true, reason), do: [reason | list]
  defp maybe_failure(list, false, _reason), do: list

  defp percent(_part, 0), do: 0.0
  defp percent(part, total), do: Float.round(part * 100 / total, 1)
end
