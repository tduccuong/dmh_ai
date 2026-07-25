# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Coverage do
  @moduledoc """
  What share of ordinary text in the target language the learner can
  actually read: the fraction of a reference frequency band their known
  words cover.

  This is the only progress number the product displays, and it is chosen
  because it cannot be farmed — it moves when the learner's vocabulary
  moves and at no other time. A raw known-word count is deliberately not
  shown: it counts sightings rather than competence, and rises whether or
  not anything was learned.

  Coverage is also the difficulty governor. `Duolang.Generator` reads it
  to decide how far a new text may reach beyond what the learner already
  has.

  ## The reference band

  Coverage is measured against a frequency list shipped per language at
  `priv/duolang/frequency/<code>.txt` — one word per line, most frequent
  first, already normalised to lowercase. Lines beginning `#` are
  comments.

  When no list is installed for a language, coverage is **unavailable**,
  never estimated. A fabricated denominator would produce a confident
  number describing nothing, which is worse than showing no number at
  all — so `for_user/2` returns `{:error, :no_reference}` and the FE
  omits the line entirely.
  """

  alias DmhAi.Duolang.KnownWords

  @frequency_dir "priv/duolang/frequency"

  @typedoc """
  `band_size` is how many reference words were considered — the whole
  list, or `:top` when the caller narrowed it.
  """
  @type report :: %{
          percent: float(),
          known_in_band: non_neg_integer(),
          band_size: pos_integer()
        }

  @doc """
  Coverage for `user_id` against `lang_code`'s reference band.

  Options:
    * `:top` — consider only the N most frequent words. Defaults to the
      whole list.
  """
  @spec for_user(String.t(), String.t(), keyword()) ::
          {:ok, report()} | {:error, :no_reference}
  def for_user(user_id, lang_code, opts \\ []) do
    case reference_band(lang_code, opts) do
      {:ok, band} -> {:ok, measure(KnownWords.load(user_id, lang_code), band)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Coverage of an already-loaded known-word set. Used by callers that
  already hold the set — the generator holds one per turn and should not
  re-read it.
  """
  @spec measure(MapSet.t(String.t()), [String.t()]) :: report()
  def measure(known_words, band) when is_list(band) do
    known_in_band = Enum.count(band, &MapSet.member?(known_words, &1))
    band_size = max(length(band), 1)

    %{
      percent: Float.round(known_in_band * 100 / band_size, 1),
      known_in_band: known_in_band,
      band_size: band_size
    }
  end

  @doc """
  The reference band for `lang_code`, most frequent first.

  Options:
    * `:top` — truncate to the N most frequent words.
  """
  @spec reference_band(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, :no_reference}
  def reference_band(lang_code, opts \\ []) do
    path = frequency_path(lang_code)

    case File.read(path) do
      {:ok, contents} ->
        band =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.map(&String.downcase/1)
          |> truncate(Keyword.get(opts, :top))

        if band == [], do: {:error, :no_reference}, else: {:ok, band}

      {:error, _} ->
        {:error, :no_reference}
    end
  end

  @doc """
  Whether a reference band is installed for `lang_code`. The onboarding
  flow checks this so it can say plainly that progress tracking is
  unavailable for a language rather than silently omitting it later.
  """
  @spec reference_available?(String.t()) :: boolean()
  def reference_available?(lang_code) do
    match?({:ok, _}, reference_band(lang_code, top: 1))
  end

  @doc "Absolute path of the frequency list for `lang_code`."
  @spec frequency_path(String.t()) :: String.t()
  def frequency_path(lang_code) do
    Application.app_dir(:dmh_ai, Path.join(@frequency_dir, "#{lang_code}.txt"))
  end

  defp truncate(band, nil), do: band
  defp truncate(band, top) when is_integer(top) and top > 0, do: Enum.take(band, top)
  defp truncate(band, _), do: band
end
