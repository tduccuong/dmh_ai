# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ProfileExtractor do
  @moduledoc """
  Builds the per-user `users.profile` bullet-list from the user's own
  messages. Runs as a background Task after each user-message persist;
  never blocks a reply.

  Batched, watermark-driven. On every fire it walks `sessions.messages`
  for ALL of this user's sessions and counts user-role entries with
  `ts > users.last_profile_extracted_msg_ts`. Below
  `AgentSettings.profile_extract_batch_size/0` (default 4) → no-op.
  At or above → one LLM call against the OLDEST N unprocessed
  messages (chronological), then bump the watermark to the Nth
  message's ts. Forward-progress guarantee: any message above the
  watermark eventually gets processed; nothing is dropped.

  `/memo` and `/wiki` slash commands are excluded from the batch
  contents but still count toward the watermark — otherwise a
  long-tail of slash-only activity would block the trigger forever.

  Two LLM calls live here:

    * `extract` — single user-role prompt, `temperature=0`,
      `num_predict=200`. Asked to emit `[FACTS]` (explicit
      self-statements) and `[CANDIDATES]` (broad topical interests)
      against an "Already known" block of the existing profile.
      FACTS merge directly via `merge_facts/2`; CANDIDATES feed the
      promotion-by-vote mechanism in `Auth.track_facts_for_user/2`.

    * `condense` — fired only when the merged profile crosses
      `profile_condense_threshold` (default 50) bullet lines. Asks
      the model to compress the profile to ~half that count, merge
      near-dup keys, drop superseded facts.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias DmhAi.{Repo, Agent.AgentSettings, Agent.LLM}
  alias DmhAi.Commands.Parser, as: CommandParser
  require Logger

  @doc """
  Trigger the batched extractor for `user_id`. Runs synchronously
  inside whatever Task the caller spawned — call sites use
  `Task.start(fn -> ProfileExtractor.extract_and_merge(user_id) end)`
  so this never blocks a reply.

  Returns `:ok` regardless of outcome (no-op on under-threshold,
  silent on LLM failure — the watermark stays put and the same
  batch retries on the next user message).
  """
  @spec extract_and_merge(String.t()) :: :ok
  def extract_and_merge(user_id) when is_binary(user_id) do
    batch_size = AgentSettings.profile_extract_batch_size()
    watermark = load_watermark(user_id)

    case collect_unprocessed(user_id, watermark) do
      [] ->
        :ok

      msgs when length(msgs) < batch_size ->
        :ok

      msgs ->
        # Always take the OLDEST N. Excess waits for the next call.
        # Cap the leftover at 2× batch_size to avoid a flood after a
        # long extraction outage — past that we'd still process N per
        # call but the queue would shrink one batch at a time.
        batch = Enum.take(msgs, batch_size)
        run_batch(user_id, batch)
    end

    :ok
  end

  # ─── Batch collection ──────────────────────────────────────────────────────

  defp collect_unprocessed(user_id, watermark) do
    result =
      query!(
        Repo,
        "SELECT messages FROM sessions WHERE user_id=? AND messages IS NOT NULL AND messages != ''",
        [user_id]
      )

    result.rows
    |> Enum.flat_map(fn [json] -> decode_user_msgs(json) end)
    |> Enum.filter(fn %{ts: ts} -> ts > watermark end)
    |> Enum.sort_by(fn %{ts: ts} -> ts end)
  end

  defp decode_user_msgs(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.flat_map(list, fn
          %{"role" => "user", "content" => content, "ts" => ts}
          when is_binary(content) and is_integer(ts) ->
            [%{ts: ts, content: content}]

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  defp decode_user_msgs(_), do: []

  # ─── Batch processing ──────────────────────────────────────────────────────

  defp run_batch(user_id, batch) do
    last_ts = batch |> List.last() |> Map.fetch!(:ts)

    # Filter out slash commands from the LLM input but still bump the
    # watermark past them — slash-only activity must not block the
    # extractor forever.
    extractable =
      batch
      |> Enum.reject(fn %{content: c} ->
        CommandParser.parse(c) != :not_a_command
      end)
      |> Enum.map(& &1.content)
      |> Enum.reject(&(&1 == ""))

    if extractable == [] do
      save_watermark(user_id, last_ts)
    else
      do_extract_and_merge(user_id, extractable, last_ts)
    end

    :ok
  end

  defp do_extract_and_merge(user_id, msgs, last_ts) do
    model = AgentSettings.oracle_model()
    existing = load_profile(user_id)

    already_known =
      if existing != "", do: "Already known:\n#{existing}\n\n", else: ""

    numbered =
      msgs
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> "#{i}. \"#{m}\"" end)
      |> Enum.join("\n")

    prompt =
      "[USER MESSAGES — most recent across this user's conversations]\n" <>
        numbered <>
        "\n[END USER MESSAGES]\n\n" <>
        already_known <>
        "Task: Analyse the USER MESSAGES collectively and output TWO sections.\n\n" <>
        "[FACTS]\n" <>
        "Explicit personal facts the user stated about themselves (name, job, family, hobbies declared, preferences stated, health, location, events).\n" <>
        "Only extract from explicit self-descriptions: \"I am...\", \"I have...\", \"I like...\", \"I live in...\", etc.\n" <>
        "Cross-message inference is allowed: if message 2 says \"I have two kids\" and message 4 says \"my older one starts school\", that's one fact about a school-age child.\n" <>
        "One bullet per category, comma-separated values. e.g. \"- Name: Carl\", \"- Hobbies: hiking, reading\"\n" <>
        "Never repeat a category key. Keep values short (a few words each).\n" <>
        "Do not duplicate anything already in \"Already known\".\n" <>
        "Write NONE if nothing qualifies.\n\n" <>
        "[CANDIDATES]\n" <>
        "Topics or subjects the user is asking about or showing curiosity in across these messages — even without explicit \"I like X\" statements.\n" <>
        "Rules:\n" <>
        "- Use the broadest, most general label possible: prefer \"gardening\" over \"indoor tomato cultivation\", \"blockchain\" over \"blockchain immutability\"\n" <>
        "- 1–2 words maximum. No qualifiers, adjectives, or specifics.\n" <>
        "- If multiple messages cover aspects of the same broad topic, output only ONE label for it.\n" <>
        "Write NONE if nothing qualifies.\n\n" <>
        "User messages may be in any language. Always write output in English. Plain text only, no markdown."

    trace = %{origin: "system", path: "ProfileExtractor.extract", role: "ProfileExtractor", phase: "extract"}

    case LLM.call(model, [%{role: "user", content: prompt}],
           options: %{temperature: 0, num_predict: 200},
           trace: trace
         ) do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        Logger.debug("[ProfileExtractor] extraction result=#{String.slice(reply, 0, 200)}")
        new_lines = parse_facts(reply)
        candidates = parse_candidates(reply)

        if new_lines != [] do
          merged = merge_facts(existing, new_lines)

          if merged != existing do
            all_lines = String.split(merged, "\n") |> Enum.filter(&String.starts_with?(&1, "-"))
            threshold = AgentSettings.profile_condense_threshold()

            final =
              if length(all_lines) >= threshold,
                do: condense(merged, model),
                else: merged

            save_profile(user_id, final)
            Logger.info(
              "[ProfileExtractor] merged #{length(new_lines)} fact(s) user=#{user_id} batch=#{length(msgs)}"
            )
          end
        end

        if candidates != [] do
          DmhAi.Handlers.Auth.track_facts_for_user(user_id, candidates)
        end

        # Watermark bump only on successful LLM round-trip — a failure
        # leaves the watermark in place so the same batch retries on
        # the next user message.
        save_watermark(user_id, last_ts)

      _ ->
        :ok
    end

    :ok
  end

  # ─── Parsing ───────────────────────────────────────────────────────────────

  defp parse_candidates(reply) do
    case Regex.run(~r/\[CANDIDATES\]([\s\S]*?)$/i, reply) do
      [_, text] ->
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.downcase(&1) == "none"))
        |> Enum.map(fn line -> String.trim_leading(line, "- ") end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_facts(reply) do
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

  # ─── Merge ─────────────────────────────────────────────────────────────────

  defp merge_facts(existing, new_lines) do
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

  # ─── Condense ──────────────────────────────────────────────────────────────

  defp condense(current_facts, model) do
    all_lines = String.split(current_facts, "\n") |> Enum.filter(&String.starts_with?(&1, "-"))
    target = div(AgentSettings.profile_condense_threshold(), 2)

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

    trace = %{origin: "system", path: "ProfileExtractor.condense", role: "ProfileCondenser", phase: "condense"}

    case LLM.call(model, [%{role: "user", content: prompt}],
           options: %{temperature: 0, num_predict: 600},
           trace: trace
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

  # ─── DB ────────────────────────────────────────────────────────────────────

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

  defp load_watermark(user_id) do
    try do
      result = query!(Repo, "SELECT last_profile_extracted_msg_ts FROM users WHERE id=?", [user_id])

      case result.rows do
        [[ts] | _] when is_integer(ts) -> ts
        _ -> 0
      end
    rescue
      _ -> 0
    end
  end

  defp save_watermark(user_id, ts) when is_integer(ts) do
    try do
      query!(Repo, "UPDATE users SET last_profile_extracted_msg_ts=? WHERE id=?", [ts, user_id])
    rescue
      _ -> :ok
    end

    :ok
  end
end
