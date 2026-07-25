# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.KnownWords do
  @moduledoc """
  The learner's known-word set for one language — the one table two
  subsystems read. `Duolang.Profiler` spends it as a token-miss budget
  when levelling generated text; `Duolang.Coverage` spends it as the
  numerator of the displayed coverage percentage.

  Keyed by `(user_id, lang)`: a learner's German vocabulary is one store
  shared across every German course, because knowing a word in one course
  means knowing it in another. `lang` is the target-language code.

  A word is "known" once the learner has met it in comprehended material.
  Tokenisation is delegated to `Profiler.words/1` so the set can never
  drift from the text being measured against it.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]

  alias DmhAi.Duolang.Profiler
  alias DmhAi.Repo

  @doc "Every known word for `(user_id, lang)`, ready for `Profiler.profile/3`."
  @spec load(String.t(), String.t()) :: MapSet.t(String.t())
  def load(user_id, lang) do
    %{rows: rows} =
      query!(Repo, "SELECT word FROM duolang_known_words WHERE user_id = ? AND lang = ?", [user_id, lang])

    rows |> Enum.map(fn [word] -> word end) |> MapSet.new()
  end

  @doc "How many distinct words the learner has met in `lang`."
  @spec count(String.t(), String.t()) :: non_neg_integer()
  def count(user_id, lang) do
    %{rows: [[n]]} =
      query!(Repo, "SELECT COUNT(*) FROM duolang_known_words WHERE user_id = ? AND lang = ?", [user_id, lang])

    n
  end

  @doc """
  Record every word of `text` as met in `lang`. Called once the learner
  has worked through a text — not when it was merely generated for them.
  Returns the number of words newly known.
  """
  @spec record_met(String.t(), String.t(), String.t()) :: non_neg_integer()
  def record_met(user_id, lang, text) when is_binary(text) do
    now = System.system_time(:millisecond)
    words = text |> Profiler.words() |> Enum.uniq()
    before = count(user_id, lang)

    Enum.each(words, fn word ->
      query!(
        Repo,
        """
        INSERT INTO duolang_known_words (user_id, lang, word, met_count, first_at, last_at)
        VALUES (?, ?, ?, 1, ?, ?)
        ON CONFLICT(user_id, lang, word)
        DO UPDATE SET met_count = met_count + 1, last_at = excluded.last_at
        """,
        [user_id, lang, word, now, now]
      )
    end)

    count(user_id, lang) - before
  end
end
