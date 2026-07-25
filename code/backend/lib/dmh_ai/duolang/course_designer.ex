# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Duolang.CourseDesigner do
  @moduledoc """
  One model call that turns a learner's brief into a course: an evocative
  name and a per-level syllabus across the CEFR ladder.

  The name is what the learner sees in the topbar, so it is short and
  memorable, never the raw topic string. The syllabus gives each level a
  theme and a can-do goal, which the generator later reads to keep A1
  passages elementary and C1 passages nuanced on the same topic.

  On any failure the design degrades to a plain name (the topic) and an
  empty syllabus — the generator still works from the topic alone, just
  without per-level shaping.
  """

  require Logger

  alias DmhAi.Agent.{AgentSettings, LLM}
  alias DmhAi.Commands.Languages
  alias DmhAi.Commands.Pipelines.Sentences
  alias DmhAi.Duolang.Course

  @type design :: %{name: String.t(), syllabus: %{optional(String.t()) => map()}}

  @doc """
  Design a course from `brief` (the onboarding form). `brief` carries at
  least `target_lang`, `source_lang`, `topic`; optionally `motivation`,
  `style`, `focus`, `intensity`.
  """
  @spec design(map(), keyword()) :: design()
  def design(brief, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})
    topic = to_string(brief["topic"] || brief[:topic] || "")

    messages = [
      %{role: "system", content: system_prompt(brief)},
      %{role: "user", content: user_prompt(brief)}
    ]

    case LLM.call(AgentSettings.confidant_model(), messages,
           options: %{temperature: 0.6},
           trace: trace(meta)
         ) do
      {:ok, raw} when is_binary(raw) and raw != "" ->
        parse(raw, topic)

      other ->
        Logger.warning("[Duolang.CourseDesigner] design failed: #{inspect(other)}")
        %{name: fallback_name(topic), syllabus: %{}}
    end
  end

  defp parse(raw, topic) do
    with {:ok, %{"name" => name, "syllabus" => syllabus}} when is_binary(name) and is_list(syllabus) <-
           Sentences.decode_llm_json(raw) do
      %{
        name: name |> String.trim() |> fallback_if_blank(topic),
        syllabus: index_syllabus(syllabus)
      }
    else
      _ -> %{name: fallback_name(topic), syllabus: %{}}
    end
  end

  # `[{level, theme, can_do}]` → `%{level => %{theme, can_do}}`, keeping
  # only rungs on the real ladder.
  defp index_syllabus(list) do
    ladder = Course.ladder()

    list
    |> Enum.reduce(%{}, fn
      %{"level" => level} = row, acc ->
        lv = level |> to_string() |> String.upcase() |> String.trim()

        if lv in ladder do
          Map.put(acc, lv, %{
            "theme" => to_string(row["theme"] || ""),
            "can_do" => to_string(row["can_do"] || "")
          })
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp system_prompt(brief) do
    target = language_name(brief["target_lang"] || brief[:target_lang])
    ladder = Enum.join(Course.ladder(), ", ")

    """
    You are designing a personal #{target} course for one learner, from the
    brief they filled in. Plan the whole course, then name it.

    The course runs across the CEFR ladder: #{ladder}. For each level, give a
    theme within the learner's topic and one concrete can-do goal — what they
    will be able to do at that level. Keep A1 elementary and each rung a real
    step up in demand.

    Then give the course a short, evocative NAME — the kind that would sit well
    as a title. Not the raw topic; something a person would be glad to see.

    Output STRICT JSON, first character `{`, no commentary, no markdown fences:

      {"name": "<the course name>",
       "syllabus": [{"level": "A1", "theme": "...", "can_do": "..."}, ...]}

    One entry per level, in ladder order.
    """
  end

  defp user_prompt(brief) do
    [
      {"Topic", brief["topic"] || brief[:topic]},
      {"Why they want it", brief["motivation"] || brief[:motivation]},
      {"How they like to learn", brief["style"] || brief[:style]},
      {"What to focus on", brief["focus"] || brief[:focus]},
      {"How intensively", brief["intensity"] || brief[:intensity]}
    ]
    |> Enum.map(fn {label, val} -> {label, to_string(val || "") |> String.trim()} end)
    |> Enum.reject(fn {_l, v} -> v == "" end)
    |> Enum.map_join("\n", fn {label, val} -> "#{label}: #{val}" end)
  end

  defp fallback_if_blank("", topic), do: fallback_name(topic)
  defp fallback_if_blank(name, _topic), do: name

  defp fallback_name(""), do: "My course"
  defp fallback_name(topic), do: topic

  defp language_name(code) do
    case Languages.by_code(to_string(code || "")) do
      %{english: name} -> name
      _ -> to_string(code)
    end
  end

  defp trace(meta) do
    %{
      origin: "duolang",
      path: "Duolang.CourseDesigner.design",
      role: "Duolang",
      phase: "design",
      session_id: Map.get(meta, :session_id),
      user_id: Map.get(meta, :user_id),
      tier: :master
    }
  end
end
