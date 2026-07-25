# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Generator do
  @moduledoc """
  Produces the lesson text, at a difficulty the runtime has verified
  rather than merely requested.

  A model told to write at a named proficiency level lands on it only a
  small fraction of the time, and misses directionally — too easy at the
  bottom of the range, too hard at the top. Naming a level in the prompt
  is therefore a hint, and `Duolang.Profiler` is the authority. The model
  is never asked to grade its own output; that is circular.

  The loop is generate → profile → repair. Each repair pass carries the
  *specific* failure back — which words the learner does not have, which
  sentence ran long — so the model corrects rather than rerolls. On
  exhaustion the best candidate seen (lowest miss rate) is returned with
  `accepted: false`, so the session degrades to slightly-off material
  instead of stranding the learner with nothing.

  Two constraints this module enforces that the profiler cannot see:

    * **The topic comes from the learner**, never the model. Left to
      choose, a model collapses to a narrow band of subjects that tracks
      the requested difficulty.
    * **Recent texts are not repeated.** Recycling the runtime intends is
      pedagogy; recycling it did not ask for is a stale corpus.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM}
  alias DmhAi.Commands.Languages
  alias DmhAi.Commands.Pipelines.Sentences
  alias DmhAi.Duolang.{KnownWords, Profiler}

  @typedoc """
  `:cold_start` while the learner's vocabulary is below the floor,
  `:established` after. The stage decides which measure governs and how
  the passage is asked for.
  """
  @type stage :: :cold_start | :established

  @type result :: %{
          text: String.t(),
          topic: String.t(),
          title: String.t(),
          sentences: [String.t()],
          items: [%{text: String.t(), translation: String.t(), kind: String.t()}],
          report: Profiler.report(),
          stage: stage(),
          accepted: boolean(),
          attempts: pos_integer()
        }

  @typedoc """
  What the generator needs to produce a passage: who it is for, the two
  languages, the topic (course topic, narrowed by the level's theme), and
  the CEFR level. Decoupled from any store — `Duolang.Session` fills it
  from the active course.
  """
  @type ctx :: %{
          user_id: String.t(),
          target_lang: String.t(),
          source_lang: String.t(),
          topic: String.t(),
          level: String.t(),
          theme: String.t() | nil,
          can_do: String.t() | nil
        }

  @doc """
  Generate a lesson passage for `ctx`.

  Options:
    * `:avoid`        — recent texts to avoid echoing.
    * `:known_words`  — pre-loaded known-word set, to save a read.
    * `:meta`         — `%{session_id:, user_id:}` for the LLM trace.
  """
  @spec generate(ctx(), keyword()) :: {:ok, result()} | {:error, term()}
  def generate(ctx, opts \\ []) do
    known =
      Keyword.get_lazy(opts, :known_words, fn -> KnownWords.load(ctx.user_id, ctx.target_lang) end)

    topic = pick_topic(ctx)
    avoid = Keyword.get(opts, :avoid, [])
    meta = Keyword.get(opts, :meta, %{})

    stage = stage_for(MapSet.size(known))
    attempt(ctx, topic, avoid, known, stage, thresholds(stage), meta, 1, nil)
  end

  @doc """
  Which stage a learner with `known_count` words is in.

  Below the floor a miss *rate* cannot be satisfied — there is not yet a
  vocabulary for a passage to be familiar against, so every candidate
  would be rejected and every early session would run on unverified text,
  which is the exact failure the profiler exists to prevent.
  """
  @spec stage_for(non_neg_integer()) :: stage()
  def stage_for(known_count) do
    if known_count < AgentSettings.duolang_vocabulary_floor(), do: :cold_start, else: :established
  end

  # Cold start bounds how much new arrives at once; established bounds how
  # much of the passage is unfamiliar. Both bound the hardest sentence.
  defp thresholds(:cold_start) do
    [
      max_new_words: AgentSettings.duolang_cold_start_new_words(),
      max_sentence_words: AgentSettings.duolang_max_sentence_words()
    ]
  end

  defp thresholds(:established) do
    [
      max_token_miss_rate: AgentSettings.duolang_max_token_miss_rate(),
      max_sentence_words: AgentSettings.duolang_max_sentence_words()
    ]
  end

  @doc """
  The passage topic: the level's syllabus theme when the designer set one,
  otherwise the course topic. Never asks the model to invent one.
  """
  @spec pick_topic(ctx()) :: String.t()
  def pick_topic(%{theme: theme}) when is_binary(theme) and theme != "", do: theme
  def pick_topic(%{topic: topic}) when is_binary(topic) and topic != "", do: topic
  def pick_topic(_), do: "everyday life"

  # ── the loop ───────────────────────────────────────────────────────────

  defp attempt(ctx, topic, avoid, known, stage, thresholds, meta, n, best) do
    max_attempts = AgentSettings.duolang_generate_attempts()

    case call_model(ctx, topic, avoid, stage, meta, best) do
      {:ok, %{text: text} = payload} ->
        report = Profiler.profile(text, known, thresholds)
        candidate = build_result(payload, topic, report, stage, n)

        cond do
          report.acceptable ->
            {:ok, %{candidate | accepted: true}}

          n >= max_attempts ->
            settled = better_of(best, candidate, stage)

            Logger.info(
              "[Duolang.Generator] settled after #{n} attempts stage=#{stage} " <>
                "miss=#{settled.report.token_miss_rate}% new=#{settled.report.new_word_count} " <>
                "failures=#{inspect(settled.report.failures)}"
            )

            # `attempts` counts what the loop spent, not which candidate
            # won — the winner may be from an earlier pass.
            {:ok, %{settled | accepted: false, attempts: n}}

          true ->
            attempt(
              ctx,
              topic,
              avoid,
              known,
              stage,
              thresholds,
              meta,
              n + 1,
              better_of(best, candidate, stage)
            )
        end

      {:error, reason} when n >= max_attempts ->
        if best, do: {:ok, %{best | accepted: false}}, else: {:error, reason}

      {:error, _reason} ->
        attempt(ctx, topic, avoid, known, stage, thresholds, meta, n + 1, best)
    end
  end

  # Rank by whatever governs the stage — fewest new words in cold start,
  # lowest miss rate after — with the hardest sentence breaking ties.
  defp better_of(nil, candidate, _stage), do: candidate

  defp better_of(best, candidate, stage) do
    key = fn r ->
      case stage do
        :cold_start -> {r.report.new_word_count, r.report.max_sentence_words}
        :established -> {r.report.token_miss_rate, r.report.max_sentence_words}
      end
    end

    if key.(candidate) < key.(best), do: candidate, else: best
  end

  defp build_result(payload, topic, report, stage, attempts) do
    %{
      text: payload.text,
      topic: topic,
      # Falls back to the topic when the model omits a title, so the card
      # header is never blank.
      title: if(payload.title == "", do: topic, else: payload.title),
      sentences: Profiler.split_sentences(payload.text),
      items: payload.items,
      report: report,
      stage: stage,
      accepted: false,
      attempts: attempts
    }
  end

  # ── the model call ─────────────────────────────────────────────────────

  defp call_model(ctx, topic, avoid, stage, meta, previous) do
    messages = [
      %{role: "system", content: system_prompt(ctx, stage)},
      %{role: "user", content: user_prompt(ctx, topic, avoid, previous)}
    ]

    case LLM.call(AgentSettings.confidant_model(), messages,
           options: %{temperature: 0.7},
           trace: trace(meta)
         ) do
      {:ok, raw} when is_binary(raw) and raw != "" -> decode(raw)
      {:ok, _} -> {:error, :unexpected_reply}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(raw) do
    with {:ok, %{"text" => text} = decoded} when is_binary(text) <- Sentences.decode_llm_json(raw),
         trimmed when trimmed != "" <- String.trim(text) do
      {:ok,
       %{
         text: trimmed,
         title: decoded["title"] |> to_string() |> String.trim(),
         items: decode_items(decoded["items"])
       }}
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_items(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"text" => t, "translation" => tr} when is_binary(t) and is_binary(tr) ->
        %{text: String.trim(t), translation: String.trim(tr), kind: "word"}

      _ ->
        nil
    end)
    |> Enum.reject(&(is_nil(&1) or &1.text == ""))
  end

  defp decode_items(_), do: []

  defp system_prompt(ctx, stage) do
    target = language_name(ctx.target_lang)
    source = language_name(ctx.source_lang)

    """
    You write short reading passages for one adult learning #{target}. Their own
    language is #{source}. They are at CEFR level #{ctx.level} — pitch the language
    to that level.#{can_do_line(ctx)}

    Write natural, connected prose a person would actually say or read — a small
    scene, a short account, a piece of practical writing. Keep sentences short and
    concrete. Every sentence must be one the learner could hear spoken aloud.

    #{stage_guidance(stage, target)}

    Output STRICT JSON with three keys:

      {"title": "<a short plain description of the passage, in #{source}>",
       "text": "the passage in #{target}",
       "items": [{"text": "<word or phrase in #{target}>", "translation": "<#{source}>"}]}

    `title` names what the passage is about in a few words, the way you would
    head a page — a small statement, not a label.

    `items` are the handful of words or phrases from the passage most worth
    keeping — the ones that carry the meaning. Give each its #{source} rendering.

    Output rules:
      - The first character must be `{`. No commentary, no markdown fences.
      - `text` is #{target} only. Translations belong in `items`.
      - Write the passage as flowing prose, not a word list or a numbered exercise.
    """
  end

  defp can_do_line(%{can_do: can_do}) when is_binary(can_do) and can_do != "",
    do: " The goal at this level: #{can_do}."

  defp can_do_line(_ctx), do: ""

  # A beginner has no vocabulary for a passage to stay inside, so the ask
  # is the opposite one: build the passage AROUND a few new words and
  # repeat them, giving several encounters in one sitting.
  defp stage_guidance(:cold_start, target) do
    count = AgentSettings.duolang_cold_start_new_words()

    """
    This learner is at the very beginning of #{target}. Build the passage around
    at most #{count} different new words, and use each of them more than once, in
    slightly different sentences, so the passage itself teaches them. Reuse the
    same small set of words rather than reaching for variety.
    """
  end

  defp stage_guidance(:established, _target) do
    """
    Stay within everyday, high-frequency wording. A few unfamiliar words are
    welcome; a passage full of them is not.
    """
  end

  defp user_prompt(ctx, topic, avoid, previous) do
    sentence_count = AgentSettings.duolang_text_sentence_count()

    [
      "Topic: #{topic}",
      "CEFR level: #{ctx.level}",
      "Write about #{sentence_count} sentences.",
      avoid_block(avoid),
      repair_block(previous)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp avoid_block([]), do: ""

  defp avoid_block(avoid) do
    recent = avoid |> Enum.take(3) |> Enum.map_join("\n", &"- #{String.slice(&1, 0, 160)}")
    "You wrote these recently. Write something different in wording and situation:\n#{recent}"
  end

  # The repair pass names the exact failure. A bare "try again" produces a
  # reroll; naming the unknown words and the long sentence produces a fix.
  defp repair_block(nil), do: ""

  defp repair_block(%{report: report, text: text}) do
    problems =
      []
      |> add_problem(
        :token_miss_rate in report.failures,
        fn ->
          words = report.missing_words |> Enum.take(12) |> Enum.join(", ")
          "These words are outside what the learner knows — replace them with simpler wording: #{words}"
        end
      )
      |> add_problem(
        :new_words in report.failures,
        fn ->
          limit = AgentSettings.duolang_cold_start_new_words()
          words = report.missing_words |> Enum.take(20) |> Enum.join(", ")

          "The passage introduces #{report.new_word_count} new words, and the limit is #{limit}. " <>
            "Choose a few of these to keep and repeat, and remove the rest: #{words}"
        end
      )
      |> add_problem(
        :sentence_length in report.failures,
        fn ->
          limit = AgentSettings.duolang_max_sentence_words()
          longest = if report.hardest_sentence, do: report.hardest_sentence.text, else: ""
          "This sentence runs too long (#{report.max_sentence_words} words, limit #{limit}) — split it:\n\"#{longest}\""
        end
      )

    """
    Your previous attempt was too difficult. Rewrite it, keeping the same topic
    and situation.

    #{Enum.join(problems, "\n\n")}

    Previous attempt:
    #{text}
    """
  end

  defp add_problem(list, true, build), do: list ++ [build.()]
  defp add_problem(list, false, _build), do: list

  defp language_name(code) do
    case Languages.by_code(code) do
      %{english: name} -> name
      _ -> code
    end
  end

  defp trace(meta) do
    %{
      origin: "duolang",
      path: "Duolang.Generator.generate",
      role: "Duolang",
      phase: "generate",
      session_id: Map.get(meta, :session_id),
      user_id: Map.get(meta, :user_id),
      tier: :master
    }
  end
end
