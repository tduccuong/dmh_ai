# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.Check do
  @moduledoc """
  Did the learner understand the passage?

  Two probes, deliberately chosen over a multiple-choice quiz:

    * **Prompted retell, in the learner's OWN language.** Retelling
      agrees with comprehension only moderately when unprompted, and
      materially better with several prompts — so the runtime always
      asks more than one. Recall in the target language would measure
      production ability as much as understanding and would understate
      what the learner grasped, so the retell is in their own language.

    * **Translation probes** on the passage's target items, which are a
      more sensitive probe than free recall because they do not make the
      learner hold the whole passage in memory to demonstrate anything.

  Scoring is holistic semantic coverage, not proposition matching. Fine
  grained matching buys no measurable accuracy over a holistic judgement,
  so the runtime asks for a verdict rather than building a matcher.

  Both probes are also retrieval practice: the check is itself the
  learning, not merely a measurement of it.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM}
  alias DmhAi.Commands.Languages
  alias DmhAi.Commands.Pipelines.Sentences

  @type retell_verdict :: %{
          understood: boolean(),
          covered: [String.t()],
          missed: [String.t()],
          comment: String.t()
        }

  @type probe_verdict :: %{item: String.t(), correct: boolean(), expected: String.t()}

  @retell_system """
  You judge whether a language learner understood a passage they read.

  You receive the passage and the learner's answers, given in their own language.
  Judge understanding of the passage's MEANING. Wording, style, grammar and
  spelling in their answers are irrelevant — they are recounting in a language
  they already speak.

  Treat the learner as having understood when they convey the substance, even
  partially and even in loose terms. Reserve a negative verdict for answers that
  contradict the passage or show they missed what it was about.

  Output STRICT JSON:

    {"understood": true|false,
     "covered": ["points they conveyed"],
     "missed": ["points they left out or got wrong"],
     "comment": "one short sentence to the learner"}

  The first character must be `{`. No commentary, no markdown fences. Write
  `comment` in the language the learner used.
  """

  @probes_system """
  You mark a language learner's translations.

  For each probe you receive the item, a reference translation, and what the
  learner gave. Mark it correct when their answer carries the same meaning as the
  reference — a synonym, a different word order, a more natural phrasing, or a
  minor spelling slip all still count. Mark it incorrect only when the meaning is
  wrong or missing.

  An empty answer is incorrect.

  Output STRICT JSON:

    {"results": [{"item": "…", "correct": true|false, "expected": "…"}]}

  One result per probe, in the order given. The first character must be `{`. No
  commentary, no markdown fences.
  """

  @doc """
  Build the retell prompts for `text`. The count is a setting because the
  number of prompts is the single biggest lever on how well a retell
  reflects comprehension.
  """
  @spec retell_prompts(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def retell_prompts(text, opts \\ []) do
    count = AgentSettings.duolang_retell_prompts()
    meta = Keyword.get(opts, :meta, %{})
    source_lang = Keyword.get(opts, :source_lang, "en")

    messages = [
      %{role: "system", content: prompts_system(count, language_name(source_lang))},
      %{role: "user", content: text}
    ]

    case LLM.call(AgentSettings.swift_model(), messages,
           options: %{temperature: 0},
           trace: trace(meta, "retell_prompts")
         ) do
      {:ok, raw} when is_binary(raw) ->
        case Sentences.decode_llm_json(raw) do
          {:ok, %{"prompts" => list}} when is_list(list) ->
            prompts = list |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.take(count)
            if prompts == [], do: {:error, :no_prompts}, else: {:ok, prompts}

          _ ->
            {:error, :invalid_json}
        end

      _ ->
        {:error, :llm_failed}
    end
  end

  @doc """
  Score a retell against the source passage. `answers` pairs each prompt
  with what the learner said, in their own language.
  """
  @spec score_retell(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, retell_verdict()} | {:error, term()}
  def score_retell(text, answers, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})

    body =
      Jason.encode!(%{
        "passage" => text,
        "answers" => Enum.map(answers, fn {q, a} -> %{"prompt" => q, "answer" => a} end)
      })

    messages = [
      %{role: "system", content: @retell_system},
      %{role: "user", content: body}
    ]

    case LLM.call(AgentSettings.swift_model(), messages,
           options: %{temperature: 0},
           trace: trace(meta, "score_retell")
         ) do
      {:ok, raw} when is_binary(raw) ->
        case Sentences.decode_llm_json(raw) do
          {:ok, %{"understood" => understood} = d} ->
            {:ok,
             %{
               understood: understood == true,
               covered: string_list(d["covered"]),
               missed: string_list(d["missed"]),
               comment: to_string(d["comment"] || "")
             }}

          _ ->
            {:error, :invalid_json}
        end

      _ ->
        {:error, :llm_failed}
    end
  end

  @doc """
  Score translation probes. `responses` pairs each item with what the
  learner offered. Matching is semantic — a correct answer phrased
  differently still counts.
  """
  @spec score_probes([%{item: String.t(), expected: String.t(), given: String.t()}], keyword()) ::
          {:ok, [probe_verdict()]} | {:error, term()}
  def score_probes(responses, opts \\ [])

  def score_probes([], _opts), do: {:ok, []}

  def score_probes(responses, opts) do
    meta = Keyword.get(opts, :meta, %{})

    body =
      Jason.encode!(%{
        "probes" =>
          Enum.map(responses, fn r ->
            %{"item" => r.item, "expected" => r.expected, "given" => r.given}
          end)
      })

    messages = [
      %{role: "system", content: @probes_system},
      %{role: "user", content: body}
    ]

    case LLM.call(AgentSettings.swift_model(), messages,
           options: %{temperature: 0},
           trace: trace(meta, "score_probes")
         ) do
      {:ok, raw} when is_binary(raw) ->
        case Sentences.decode_llm_json(raw) do
          {:ok, %{"results" => list}} when is_list(list) ->
            {:ok, Enum.map(list, &probe_verdict/1)}

          _ ->
            {:error, :invalid_json}
        end

      _ ->
        {:error, :llm_failed}
    end
  end

  # ── prompts ────────────────────────────────────────────────────────────

  defp prompts_system(count, source_language) do
    """
    You prepare comprehension prompts for a language learner who has just read a
    passage.

    Write #{count} prompts that ask the learner to say back what the passage was
    about, in #{source_language}. Together the prompts should cover the whole
    passage — what happened, who was involved, and any detail that carries the
    meaning.

    Ask the learner to recount, not to analyse. Each prompt stands alone.

    Output STRICT JSON with one key:

      {"prompts": ["…", "…"]}

    The first character must be `{`. No commentary, no markdown fences. Write the
    prompts in #{source_language}.
    """
  end

  
  
  # ── helpers ────────────────────────────────────────────────────────────

  defp probe_verdict(%{"item" => item} = d) do
    %{
      item: to_string(item),
      correct: d["correct"] == true,
      expected: to_string(d["expected"] || "")
    }
  end

  defp probe_verdict(_), do: %{item: "", correct: false, expected: ""}

  defp string_list(list) when is_list(list), do: list |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1)
  defp string_list(_), do: []

  defp language_name(code) do
    case Languages.by_code(code) do
      %{english: name} -> name
      _ -> code
    end
  end

  defp trace(meta, phase) do
    %{
      origin: "duolang",
      path: "Duolang.Check.#{phase}",
      role: "Duolang",
      phase: phase,
      session_id: Map.get(meta, :session_id),
      user_id: Map.get(meta, :user_id),
      tier: :swift
    }
  end
end
