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
  `AgentSettings.profile_extract_batch_size/0` (default 5) → no-op.
  At or above → one LLM call against the OLDEST N unprocessed
  messages (chronological), then bump the watermark to the Nth
  message's ts. Forward-progress guarantee: any message above the
  watermark eventually gets processed; nothing is dropped.

  `/memo` and `/index` slash commands are excluded from the batch
  contents but still count toward the watermark — otherwise a
  long-tail of slash-only activity would block the trigger forever.

  One LLM call per fire, returning two sections:

    * `[PROFILE]` — the COMPLETE updated `users.profile`. The prompt
      gives the LLM the existing profile + the batch of new user
      messages and asks for the merged result: new explicit facts
      added, contradicted old facts replaced, everything else
      preserved word-for-word. Replaces `users.profile` verbatim.
      No separate condense pass — the merge happens inside this same
      call. A soft size cap (`profile_max_bullets`, default 42) is
      injected into the prompt when the existing profile is at the
      cap.

    * `[CANDIDATES]` — broad topical interests (1-2 word labels) the
      user is curious about WITHOUT explicit "I like X" claims. Feeds
      `Auth.track_facts_for_user/2`'s vote-counter; topics promote to
      an "Interests" bullet on the profile once they cross
      `@fact_threshold` mentions.
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

    numbered =
      msgs
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> "#{i}. \"#{m}\"" end)
      |> Enum.join("\n")

    existing_bullets = count_bullets(existing)
    max_bullets = AgentSettings.profile_max_bullets()

    size_hint =
      if existing_bullets >= max_bullets do
        "- The CURRENT PROFILE is at the soft cap (#{max_bullets} bullets). " <>
          "When merging, ALSO collapse near-duplicate keys and drop the lowest-signal " <>
          "values so the OUTPUT profile stays at or under #{max_bullets} bullets.\n"
      else
        ""
      end

    prompt =
      "[USER MESSAGES — most recent across this user's conversations]\n" <>
        numbered <>
        "\n[END USER MESSAGES]\n\n" <>
        "[CURRENT PROFILE]\n" <>
        (if existing == "", do: "(empty)", else: existing) <>
        "\n[END CURRENT PROFILE]\n\n" <>
        "Task: Apply any new EXPLICIT personal facts the USER stated about themself to " <>
        "the CURRENT PROFILE, emit the COMPLETE updated profile, plus a candidate-topics list.\n\n" <>
        "[PROFILE]\n" <>
        "Rules for editing the profile:\n" <>
        "- Extract ONLY from EXPLICIT self-descriptions: \"I am…\", \"I have…\", \"I like…\", " <>
        "\"I live in…\", \"I work as…\", \"my children are X, Y\", events the user reports about themself, etc.\n" <>
        "- Do NOT extract topics the user merely asked or was curious about (those belong in CANDIDATES below).\n" <>
        "- Do NOT extract third-party facts (\"my friend likes X\", \"the article says Y\"). " <>
        "Only facts the user stated about THEMSELF or their immediate family.\n" <>
        "- Cross-message inference is allowed: if message 2 says \"I have two kids\" and message 4 says " <>
        "\"my older one starts school\", merge into one fact about a school-age child.\n" <>
        "- If a new statement SUPERSEDES an existing fact (corrected family count, new job, " <>
        "moved location, updated preference), REPLACE the old line. Do NOT keep both.\n" <>
        "- Otherwise PRESERVE existing facts WORD-FOR-WORD. Do not rephrase, reorder, or " <>
        "shorten values that aren't being superseded.\n" <>
        "- One bullet per category key. Never repeat a category key.\n" <>
        "- Keep values short (a few words each), comma-separated when multiple share a key.\n" <>
        "- Output ONLY the bullet lines under this section, no headers, no commentary.\n" <>
        "- If no facts apply and the CURRENT PROFILE is empty, write NONE.\n" <>
        size_hint <>
        "\n[CANDIDATES]\n" <>
        "Topics or subjects the user is asking about or showing curiosity in across these messages — " <>
        "even WITHOUT explicit \"I like X\" statements.\n" <>
        "Rules:\n" <>
        "- Use the broadest, most general label possible: prefer \"gardening\" over " <>
        "\"indoor tomato cultivation\", \"blockchain\" over \"blockchain immutability\".\n" <>
        "- 1–2 words maximum. No qualifiers, adjectives, or specifics.\n" <>
        "- If multiple messages cover aspects of the same broad topic, output only ONE label for it.\n" <>
        "- Write NONE if nothing qualifies.\n\n" <>
        "User messages may be in any language. Always write output in English. Plain text only, no markdown."

    trace = %{origin: "system", path: "ProfileExtractor.extract", role: "ProfileExtractor", phase: "extract"}

    case LLM.call(model, [%{role: "user", content: prompt}],
           options: %{temperature: 0, num_predict: 600},
           trace: trace
         ) do
      {:ok, reply} when is_binary(reply) and reply != "" ->
        Logger.debug("[ProfileExtractor] extraction result=#{String.slice(reply, 0, 200)}")
        new_profile = parse_profile_block(reply)
        candidates = parse_candidates(reply)

        cond do
          new_profile == "" ->
            # LLM returned an empty / malformed [PROFILE] section. Keep
            # the existing profile intact rather than wiping it; the
            # watermark still advances so we don't loop on the same
            # bad batch.
            Logger.warning(
              "[ProfileExtractor] empty PROFILE block in LLM output user=#{user_id} — keeping existing profile"
            )

          new_profile != existing ->
            save_profile(user_id, new_profile)

            Logger.info(
              "[ProfileExtractor] rewrote profile user=#{user_id} batch=#{length(msgs)} " <>
                "bullets=#{count_bullets(new_profile)}"
            )

          true ->
            :ok
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

  defp count_bullets(profile) when is_binary(profile) do
    profile
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "-"))
  end

  defp count_bullets(_), do: 0

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

  # Parse the bullet lines under `[PROFILE]` (up to `[CANDIDATES]` or
  # end of reply). Returns the bullet block as a single newline-joined
  # string, or `""` if the section is missing / empty / contains only
  # NONE. Strips stray markdown bold/italic markers the LLM sometimes
  # adds around values.
  defp parse_profile_block(reply) do
    section =
      case Regex.run(~r/\[PROFILE\]([\s\S]*?)(?=\[CANDIDATES\]|$)/i, reply) do
        [_, text] -> text
        _ -> ""
      end

    section
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
    |> Enum.join("\n")
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
