# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ProfileExtractor do
  @moduledoc """
  Extracts personal facts from each conversation turn and merges them into the
  user's stored profile. Mirrors the frontend `UserProfile.extractAndMerge` logic.

  Called in a background Task after each LLM response — never blocks the reply.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias Dmhai.{Repo, Agent.AgentSettings, Agent.LLM}
  require Logger

  @condense_threshold 50

  @doc """
  Extract facts from one conversation turn and persist them into the user's profile.

  - `user_text`      — the user's message text
  - `assistant_text` — the assistant's reply text
  - `user_id`        — DB user ID for loading/saving the profile
  """
  @spec extract_and_merge(String.t(), String.t(), String.t()) :: :ok
  def extract_and_merge(user_text, assistant_text, user_id) do
    if user_text == "" or assistant_text == "" do
      :ok
    else
      model = AgentSettings.profile_extractor_model()
      existing = load_profile(user_id)

      already_known =
        if existing != "", do: "Already known:\n#{existing}\n\n", else: ""

      prompt =
        "[USER MESSAGE]\n\"#{user_text}\"\n[END USER MESSAGE]\n\n" <>
          already_known <>
          "Task: Analyse the USER MESSAGE and output TWO sections.\n\n" <>
          "[FACTS]\n" <>
          "Explicit personal facts the user stated about themselves (name, job, family, hobbies declared, preferences stated, health, location, events).\n" <>
          "Only extract from explicit self-descriptions: \"I am...\", \"I have...\", \"I like...\", \"I live in...\", etc.\n" <>
          "One bullet per category, comma-separated values. e.g. \"- Name: Carl\", \"- Hobbies: hiking, reading\"\n" <>
          "Never repeat a category key. Keep values short (a few words each).\n" <>
          "Do not duplicate anything already in \"Already known\".\n" <>
          "Write NONE if nothing qualifies.\n\n" <>
          "[CANDIDATES]\n" <>
          "Topics or subjects the user is asking about or showing curiosity in — even without explicit \"I like X\" statements.\n" <>
          "Rules:\n" <>
          "- Use the broadest, most general label possible: prefer \"gardening\" over \"indoor tomato cultivation\", \"blockchain\" over \"blockchain immutability\"\n" <>
          "- 1–2 words maximum. No qualifiers, adjectives, or specifics.\n" <>
          "- If the message covers multiple aspects of the same broad topic, output only ONE label for it.\n" <>
          "Write NONE if nothing qualifies.\n\n" <>
          "The user message may be in any language. Always write output in English. Plain text only, no markdown."

      case LLM.call(model, [%{role: "user", content: prompt}],
             options: %{temperature: 0, num_predict: 200}
           ) do
        {:ok, reply} when is_binary(reply) and reply != "" ->
          Logger.debug("[ProfileExtractor] extraction result=#{String.slice(reply, 0, 200)}")
          new_lines = parse_facts(reply)
          candidates = parse_candidates(reply)

          if new_lines != [] do
            merged = merge_facts(existing, new_lines)

            if merged != existing do
              all_lines = String.split(merged, "\n") |> Enum.filter(&String.starts_with?(&1, "-"))
              final = if length(all_lines) >= @condense_threshold,
                        do: condense(merged, model),
                        else: merged

              save_profile(user_id, final)
              Logger.info("[ProfileExtractor] merged #{length(new_lines)} fact(s) user=#{user_id}")
            end
          end

          if candidates != [] do
            Dmhai.Handlers.Auth.track_facts_for_user(user_id, candidates)
          end

        _ ->
          :ok
      end

      :ok
    end
  end

  # ─── Private ────────────────────────────────────────────────────────────────

  defp parse_candidates(reply) do
    case Regex.run(~r/\[CANDIDATES\]([\s\S]*?)$/i, reply) do
      [_, text] ->
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.downcase(&1) == "none"))
        |> Enum.map(fn line -> String.trim_leading(line, "- ") end)
        |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  defp parse_facts(reply) do
    # Extract only the [FACTS] section
    facts_text =
      case Regex.run(~r/\[FACTS\]([\s\S]*?)(?=\[CANDIDATES\]|$)/i, reply) do
        [_, text] -> text
        _ -> reply
      end

    facts_text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.replace(~r/\*{1,3}([^*]*)\*{1,3}/, "\\1")
      |> String.replace(~r/_{1,2}([^_]*)_{1,2}/, "\\1")
    end)
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.reject(fn line ->
      String.downcase(String.trim_leading(line, "- ")) == "none"
    end)
  end

  defp merge_facts(existing, new_lines) do
    # Build key → values map from existing facts
    existing_lines = if existing != "", do: String.split(existing, "\n"), else: []

    key_map =
      existing_lines
      |> Enum.filter(&String.starts_with?(&1, "-"))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [k_part, v_part] ->
            key = k_part |> String.trim_leading("-") |> String.trim()
            kl = String.downcase(key)
            existing_vals = Map.get(acc, kl, %{key: key, vals: []}).vals

            new_vals =
              v_part
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
              |> Enum.reduce(existing_vals, fn v, vs ->
                vl = String.downcase(v)
                if Enum.any?(vs, &(String.downcase(&1) == vl)), do: vs, else: vs ++ [v]
              end)

            Map.put(acc, kl, %{key: key, vals: new_vals})

          _ ->
            acc
        end
      end)

    key_order =
      existing_lines
      |> Enum.filter(&String.starts_with?(&1, "-"))
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k_part | _] -> k_part |> String.trim_leading("-") |> String.trim() |> String.downcase()
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {key_map, key_order} =
      Enum.reduce(new_lines, {key_map, key_order}, fn line, {km, ko} ->
        case String.split(line, ":", parts: 2) do
          [k_part, v_part] ->
            key = k_part |> String.trim_leading("-") |> String.trim()
            kl = String.downcase(key)
            existing_entry = Map.get(km, kl, %{key: key, vals: []})

            new_vals =
              v_part
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
              |> Enum.reduce(existing_entry.vals, fn v, vs ->
                vl = String.downcase(v)
                if Enum.any?(vs, &(String.downcase(&1) == vl)), do: vs, else: vs ++ [v]
              end)

            ko = if kl in ko, do: ko, else: ko ++ [kl]
            {Map.put(km, kl, %{key: existing_entry.key, vals: new_vals}), ko}

          _ ->
            {km, ko}
        end
      end)

    key_order
    |> Enum.map(fn kl ->
      case Map.get(key_map, kl) do
        %{key: k, vals: vs} when vs != [] -> "- #{k}: #{Enum.join(vs, ", ")}"
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp condense(current_facts, model) do
    all_lines = String.split(current_facts, "\n") |> Enum.filter(&String.starts_with?(&1, "-"))
    target = div(@condense_threshold, 2)

    prompt =
      "Below is a list of personal facts about a user, accumulated over many conversations.\n\n" <>
        Enum.join(all_lines, "\n") <>
        "\n\nTask: Condense and regroup this list to at most #{target} lines.\n" <>
        "Rules:\n" <>
        "- One line per category key. If multiple values share a key, merge them onto one line comma-separated.\n" <>
        "- Merge near-duplicate keys (e.g. \"Hobbies\" and \"Hobbies, interests\" → \"Hobbies\").\n" <>
        "- If a fact has been superseded by a newer one (e.g. old job vs new job), keep only the newer one.\n" <>
        "- Drop trivial or very low-signal values if over the limit.\n" <>
        "- Keep all facts in English.\n" <>
        "Output format: \"- Key: value1, value2\" — one bullet per category, no key repeated.\n" <>
        "Plain text only, no extra commentary."

    case LLM.call(model, [%{role: "user", content: prompt}],
           options: %{temperature: 0, num_predict: 600}
         ) do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        condensed =
          reply
          |> String.split("\n")
          |> Enum.map(fn l ->
            l
            |> String.trim()
            |> String.replace(~r/\*{1,3}([^*]*)\*{1,3}/, "\\1")
            |> String.replace(~r/_{1,2}([^_]*)_{1,2}/, "\\1")
          end)
          |> Enum.filter(&String.starts_with?(&1, "-"))
          |> Enum.join("\n")

        if condensed != "", do: condensed, else: current_facts

      _ ->
        current_facts
    end
  end

  defp load_profile(user_id) do
    try do
      result = query!(Repo, "SELECT profile FROM users WHERE id=?", [user_id])

      case result.rows do
        [[profile] | _] -> profile || ""
        _ -> ""
      end
    rescue
      _ -> ""
    end
  end

  defp save_profile(user_id, profile) do
    try do
      query!(Repo, "UPDATE users SET profile=? WHERE id=?", [profile, user_id])
    rescue
      _ -> :ok
    end

    :ok
  end
end
