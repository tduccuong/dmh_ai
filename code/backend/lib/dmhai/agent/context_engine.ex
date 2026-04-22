# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.ContextEngine do
  @moduledoc """
  Server-side context engineering for LLM conversations.

  Responsibilities
  ----------------
  - Build the full message list for each LLM call — two separate entry points:
      build_confidant_messages/2  — Confidant pipeline (image/video descriptions, web context)
      build_assistant_messages/2  — Assistant pipeline (active task-list block)
    Both produce: [system] ++ [compaction prefix] ++ [history] ++ [snippets] ++ [current msg]
  - Decide when to compact (turn count or estimated token budget)
  - Run LLM-based compaction and persist the result to the session's `context` column
  - Retrieve keyword-relevant snippets from compacted (old) history
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias Dmhai.{Repo, Agent.AgentSettings, Agent.LLM, Agent.SystemPrompt}
  require Logger

  # ─── Constants ────────────────────────────────────────────────────────────

  # Simple token estimate: chars / 4 ≈ tokens.
  @chars_per_token 4
  @estimated_context_tokens 8_192     # conservative default (works for all models)

  # Number of the most-recent messages to leave untouched during compaction
  # so the model always has fresh context.
  @keep_recent 20

  # Keyword retrieval: top-K snippets injected before the current message.
  @top_k 4

  # Minimum keyword hit ratio (matching_keywords / total_keywords) for a
  # message pair to qualify as relevant.
  @min_relevance 0.25

  # Maximum characters shown per message inside a retrieved snippet.
  @snippet_preview_chars 500

  # Minimum keyword length — single/double-char words are stop-word noise.
  @min_keyword_len 3

  # ─── Public API ───────────────────────────────────────────────────────────

  @doc """
  Build the complete messages list for a Confidant LLM call.

  `session_data` — map with string keys loaded from the DB:
    %{"messages" => [...], "context" => %{"summary" => ..., "summary_up_to_index" => ...} | nil}

  opts:
    - `:profile`            — user profile text (injected silently into the system prompt)
    - `:has_video`          — true when the current request carries video frames
    - `:images`             — list of base64 strings for the current message
    - `:files`              — list of %{"name" => name, "content" => text} for the current message
    - `:image_descriptions` — list of %{name, description} from the image_descriptions table
    - `:video_descriptions` — list of %{name, description} from the video_descriptions table
    - `:web_context`        — formatted web search results
  """
  @spec build_confidant_messages(map(), keyword()) :: [map()]
  def build_confidant_messages(session_data, opts \\ []) do
    profile            = Keyword.get(opts, :profile, "")
    has_video          = Keyword.get(opts, :has_video, false)
    images             = Keyword.get(opts, :images, [])
    files              = Keyword.get(opts, :files, [])
    image_descriptions = Keyword.get(opts, :image_descriptions, [])
    video_descriptions = Keyword.get(opts, :video_descriptions, [])
    web_context        = Keyword.get(opts, :web_context)

    system_msg = %{role: "system",
                   content: SystemPrompt.generate_confidant(
                     profile:            profile,
                     has_video:          has_video,
                     image_descriptions: image_descriptions,
                     video_descriptions: video_descriptions
                   )}

    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, images, files, web_context)

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++ last_msgs
  end

  @doc """
  Build the complete messages list for the Assistant session turn.

  `session_data` — map with string keys loaded from the DB:
    %{"messages" => [...], "context" => %{"summary" => ..., "summary_up_to_index" => ...} | nil}

  opts:
    - `:profile`      — user profile text (injected silently into the system prompt)
    - `:active_tasks` — list of task maps from Tasks.active_for_session/1. Formatted
                       into an `[Active task list]` block injected right before the
                       current user message. Empty list → no block.
    - `:recent_done`  — list of recently completed/cancelled tasks for the `### done` subsection
    - `:files`        — list of %{"name" => name, "content" => text} for the current message
  """
  @spec build_assistant_messages(map(), keyword()) :: [map()]
  def build_assistant_messages(session_data, opts \\ []) do
    profile      = Keyword.get(opts, :profile, "")
    active_tasks = Keyword.get(opts, :active_tasks, [])
    recent_done  = Keyword.get(opts, :recent_done, [])
    files        = Keyword.get(opts, :files, [])

    system_msg = %{role: "system",
                   content: SystemPrompt.generate_assistant(profile: profile)}

    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, [], files, nil)

    # Assistant-mode only: rewrite `📎 ` lines in the LAST user message to
    # `📎 [newly attached] ` so the model can distinguish attachments the
    # user just re-posted (must be re-extracted) from older ones still
    # living in conversation history (do not re-extract). Purely ephemeral
    # — session.messages stays bare.
    last_msgs = mark_fresh_attachments(last_msgs)

    task_list_block = build_task_list_block(active_tasks, recent_done, base_level: 2)

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++ task_list_block ++ last_msgs
  end

  # Inject the `[newly attached]` transient marker on `📎 ` lines of the
  # last user message in the LLM input array. No effect on persisted
  # session.messages — the marker is purely a per-turn signal to the LLM.
  # The marker naturally expires on the next turn: whichever message is
  # "last" then gets the marker, and all others render bare.
  defp mark_fresh_attachments([]), do: []
  defp mark_fresh_attachments(msgs) do
    {prev, [last]} = Enum.split(msgs, -1)
    if (last[:role] || last["role"]) == "user" do
      content = last[:content] || last["content"] || ""
      marked  = String.replace(content, ~r/^📎\s+/mu, "📎 [newly attached] ")
      prev ++ [Map.put(last, :content, marked)]
    else
      msgs
    end
  end

  @doc """
  Render the hierarchical task-list block as a pair of user/assistant messages.

  `active_tasks` — list of non-terminal tasks (pending | ongoing | paused).
  `recent_done`  — list of done/cancelled tasks to show under `### done`.
  `base_level`   — heading level of the top `Task list` heading (default 2).
                   Type sub-sections are `base_level + 1`; task titles are
                   `base_level + 2`. Must leave `base_level + 2 ≤ 6` or the
                   generator raises (Markdown has no h7).

  Returns `[]` when both lists are empty (nothing to render).
  """
  @spec build_task_list_block([map()], [map()], keyword()) :: [map()]
  def build_task_list_block(active_tasks, recent_done \\ [], opts \\ [])
  def build_task_list_block([], [], _opts), do: []
  def build_task_list_block(active_tasks, recent_done, opts) do
    base_level = Keyword.get(opts, :base_level, 2)

    if base_level + 2 > 6 do
      raise ArgumentError,
        "task-list block base_level=#{base_level} would push task-title headings to level #{base_level + 2}, past Markdown h6"
    end

    top  = String.duplicate("#", base_level)
    sub  = String.duplicate("#", base_level + 1)
    task = String.duplicate("#", base_level + 2)

    {periodic, one_off, paused} = partition_active(active_tasks)

    sections =
      [
        render_type_section(periodic, "periodic", sub, task),
        render_type_section(one_off,  "one_off",  sub, task),
        render_paused_section(paused, sub, task),
        render_done_section(recent_done, sub)
      ]
      |> Enum.reject(&(&1 == nil))

    if sections == [] do
      []
    else
      body = "#{top} Task list\n\n" <> Enum.join(sections, "\n\n")

      [%{role: "user", content: body},
       %{role: "assistant", content: "Noted — task list acknowledged."}]
    end
  end

  # Split active_tasks into the three render buckets. Periodic and one_off
  # contain pending + ongoing; paused tasks get their own section regardless
  # of type so the user can see "what's been set aside".
  defp partition_active(tasks) do
    periodic = Enum.filter(tasks, &(&1.task_status != "paused" and &1.task_type == "periodic"))
    one_off  = Enum.filter(tasks, &(&1.task_status != "paused" and &1.task_type == "one_off"))
    paused   = Enum.filter(tasks, &(&1.task_status == "paused"))
    {periodic, one_off, paused}
  end

  defp render_type_section([], _label, _sub, _task), do: nil
  defp render_type_section(tasks, label, sub, task) do
    rendered = Enum.map_join(tasks, "\n\n", &render_task_block(&1, task))
    "#{sub} #{label}\n\n" <> rendered
  end

  defp render_paused_section([], _sub, _task), do: nil
  defp render_paused_section(tasks, sub, task) do
    rendered = Enum.map_join(tasks, "\n\n", &render_task_block(&1, task))
    "#{sub} paused\n\n" <> rendered
  end

  defp render_done_section([], _sub), do: nil
  defp render_done_section(tasks, sub) do
    lines =
      Enum.map_join(tasks, "\n", fn t ->
        "- `#{t.task_id}` — #{t.task_title}"
      end)
    "#{sub} done\n\n" <> lines
  end

  # Both active and done tasks render the same `task_id` format: a backticked
  # id immediately following the title marker. Active tasks use a Markdown
  # heading (`#### \`id\` — title`); done tasks use a bullet (`- \`id\` — title`).
  # The heading-level `task_id` keeps the identifier adjacent to the title
  # so the model can always reference it verbatim when calling update_task
  # / fetch_task — never needs to invent one.
  defp render_task_block(task, heading) do
    title_line = "#{heading} `#{task.task_id}` — #{task.task_title}"

    fields =
      [
        "**Description:** #{task.task_spec |> strip_attachment_lines() |> String.trim()}",
        "**Status:** #{task.task_status}",
        pickup_line(task),
        attachments_line(task)
      ]
      |> Enum.reject(&(&1 == nil))
      |> Enum.join("\n")

    title_line <> "\n" <> fields
  end

  defp pickup_line(%{task_status: "pending", task_type: "periodic", time_to_pickup: ts})
       when is_integer(ts),
       do: "**Pick up time:** " <> format_ts(ts)
  defp pickup_line(_), do: nil

  defp attachments_line(task) do
    case extract_attachments(task.task_spec) do
      [] -> nil
      paths ->
        "**Attachments:**\n" <>
          Enum.map_join(paths, "\n", fn p -> "- #{p}" end)
    end
  end

  @doc """
  Pull workspace paths out of a task_spec by scanning for 📎-prefixed lines.
  The 📎 is stripped from the returned paths. Used both by the task-list
  renderer and by fetch_task to surface a structured attachments field.
  """
  @spec extract_attachments(String.t() | nil) :: [String.t()]
  def extract_attachments(nil), do: []
  def extract_attachments(spec) when is_binary(spec) do
    spec
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)
      case Regex.run(~r/^📎\s+(.+)$/u, trimmed) do
        [_, path] -> [String.trim(path)]
        _         -> []
      end
    end)
  end

  # Remove 📎-prefixed lines from a spec so the "Description" field in the
  # task-list block shows only the prose description (attachments are
  # rendered separately as a bullet list).
  defp strip_attachment_lines(nil), do: ""
  defp strip_attachment_lines(spec) do
    spec
    |> String.split("\n")
    |> Enum.reject(fn line -> Regex.match?(~r/^\s*📎\s+/u, line) end)
    |> Enum.join("\n")
  end

  defp format_ts(ms) when is_integer(ms) do
    case DateTime.from_unix(div(ms, 1000)) do
      {:ok, dt} -> DateTime.to_iso8601(dt) |> String.slice(0, 16) |> Kernel.<>(" UTC")
      _ -> to_string(ms)
    end
  end
  defp format_ts(_), do: ""

  @doc "True when the session history is long enough to warrant compaction."
  @spec should_compact?(map()) :: boolean()
  def should_compact?(session_data) do
    ctx    = session_data["context"] || %{}
    cutoff = ctx["summary_up_to_index"] || -1
    msgs   = session_data["messages"] || []
    recent = Enum.drop(msgs, cutoff + 1)

    recent_turns = length(recent)
    recent_chars = estimate_chars(recent)
    token_budget = @estimated_context_tokens * @chars_per_token

    recent_turns > AgentSettings.master_compact_turn_threshold() or
      recent_chars > token_budget * AgentSettings.master_compact_fraction()
  end

  @doc """
  Summarise old messages with the compactor LLM and persist the result to
  the session's `context` column.  Safe to call in a background Task.
  """
  @spec compact!(String.t(), String.t(), map()) :: :ok
  def compact!(session_id, user_id, session_data) do
    ctx    = session_data["context"] || %{}
    cutoff = ctx["summary_up_to_index"] || -1
    msgs   = session_data["messages"] || []

    # Keep @keep_recent messages outside the summary so fresh context is intact
    keep_from = max(cutoff + 1, length(msgs) - @keep_recent)

    if keep_from <= cutoff + 1 do
      Logger.info("[ContextEngine] nothing new to compact session=#{session_id}")
      :ok
    else
      to_summarize = Enum.slice(msgs, (cutoff + 1)..(keep_from - 1))

      # Build the compaction input matching the original frontend ContextManager.compact:
      # - If a previous summary exists, inject it as a [Previous summary] / Understood. exchange
      # - Append all messages to summarize
      # - Append the summary instruction as the final user message
      compaction_messages =
        (if ctx["summary"] do
           [
             %{role: "user", content: "[Previous summary]\n#{ctx["summary"]}"},
             %{role: "assistant", content: "Understood."}
           ]
         else
           []
         end) ++
          Enum.map(to_summarize, fn msg ->
            %{role: msg["role"] || "user", content: msg["content"] || ""}
          end) ++
          [
            %{
              role: "user",
              content:
                "Write a concise but complete summary of this conversation. " <>
                  "Preserve: key facts, decisions made, user preferences, ongoing tasks, " <>
                  "and any code or technical details. Discard: repetitive exchanges, " <>
                  "clarifications of already-established facts, false starts, and " <>
                  "conversational filler. Be dense and factual."
            }
          ]

      trace = %{origin: "system", path: "ContextEngine.compact", role: "ContextCompactor", phase: "compact"}
      case LLM.call(AgentSettings.compactor_model(), compaction_messages, trace: trace) do
        {:ok, summary} when is_binary(summary) and summary != "" ->
          new_ctx = %{
            "summary"              => summary,
            "summary_up_to_index"  => keep_from - 1
          }
          save_context(session_id, user_id, new_ctx)

          Logger.info(
            "[ContextEngine] compacted session=#{session_id} " <>
              "up_to=#{keep_from - 1} summary_chars=#{String.length(summary)}"
          )

        other ->
          Logger.warning(
            "[ContextEngine] compaction failed session=#{session_id}: #{inspect(other)}"
          )
      end

      :ok
    end
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  # Shared message assembly used by both pipelines:
  # summary prefix + history + keyword snippets + current message.
  # web_context is nil for the Assistant path (no inline web search in master).
  defp build_core(session_data, images, files, web_context) do
    # Exclude archived messages (previous periodic-task cycles) — visible in FE
    # but not relevant to the LLM's context.
    messages = (session_data["messages"] || []) |> Enum.reject(&(&1["_archived"] == true))
    ctx      = session_data["context"] || %{}
    summary  = ctx["summary"]
    cutoff   = ctx["summary_up_to_index"] || -1

    # Messages after the compaction cutoff — sent in full to the LLM
    recent = Enum.drop(messages, cutoff + 1)
    # Messages before the cutoff — only used for keyword retrieval
    old    = Enum.take(messages, cutoff + 1)

    current_text  = last_user_content(recent)
    relevant_msgs = retrieve_relevant(old, current_text)

    # Compaction prefix: present the summary as a user→assistant exchange so
    # the model treats it as established context rather than a command.
    prefix =
      if summary do
        [
          %{role: "user",      content: "[Summary of our conversation so far]\n#{summary}"},
          %{role: "assistant", content: "Understood, I have the full context of our conversation."}
        ]
      else
        []
      end

    # Split recent history so we can inject relevant snippets just before the
    # last (current) user message. Web context is merged INTO the last user
    # message (replacing it).
    {history, last_msgs} =
      case Enum.split(recent, -1) do
        {h, [last]} -> {h, [build_current_msg(last, images, files, web_context)]}
        {h, []}     -> {h, []}
      end

    history_llm = Enum.map(history, &to_llm_msg/1)

    {prefix, history_llm, relevant_msgs, last_msgs}
  end

  # Build the last (current) user message, injecting images, file content,
  # and optionally web search results.
  # When web_context is present, the message is replaced with the original
  # frontend framing format:
  #   "User request: ...\n\nWeb search results (retrieved DATE):\n...\n\nUsing the..."
  defp build_current_msg(msg, images, files, web_context) do
    base = msg["content"] || msg[:content] || ""

    file_block =
      Enum.map_join(files, "\n\n", fn f ->
        "[File: #{f["name"]}]\n```\n#{f["content"]}\n```"
      end)

    content =
      if is_binary(web_context) and web_context != "" do
        today = Date.to_string(Date.utc_today())

        framed =
          "User request: #{base}\n\n" <>
            "Web search results (retrieved #{today}):\n#{web_context}\n\n" <>
            "Using the user request and the web search results above, answer the user. " <>
            "Draw on the sources — include specific facts, figures, and names rather than vague generalities. " <>
            "Ignore content that is clearly unrelated to the user request; focus only on relevant facts."

        [framed, file_block]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
      else
        [base, file_block]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
      end

    llm_msg = %{role: "user", content: content}
    if images != [], do: Map.put(llm_msg, :images, images), else: llm_msg
  end

  # Retrieve the top-K keyword-relevant user→assistant pairs from old messages.
  defp retrieve_relevant(_old, ""), do: []
  defp retrieve_relevant([], _query), do: []

  defp retrieve_relevant(old_msgs, query) do
    keywords =
      query
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= @min_keyword_len))
      |> Enum.uniq()

    if keywords == [] do
      []
    else
      old_msgs
      |> extract_pairs()
      |> Enum.map(fn pair ->
        combined = String.downcase("#{pair.user} #{pair.assistant}")
        hits     = Enum.count(keywords, &String.contains?(combined, &1))
        {hits / length(keywords), pair}
      end)
      |> Enum.filter(fn {score, _} -> score >= @min_relevance end)
      |> Enum.sort_by(fn {score, _} -> -score end)
      |> Enum.take(@top_k)
      |> build_snippet_msgs()
    end
  end

  defp build_snippet_msgs([]), do: []

  defp build_snippet_msgs(scored_pairs) do
    snippets =
      scored_pairs
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {{_score, pair}, i} ->
        assistant_part =
          if pair.assistant != "",
            do: "\n   Assistant: #{String.slice(pair.assistant, 0, @snippet_preview_chars)}",
            else: ""

        "#{i}. User: #{String.slice(pair.user, 0, @snippet_preview_chars)}#{assistant_part}"
      end)

    [
      %{role: "user",
        content: "[Potentially relevant excerpts from earlier in this conversation]\n\n#{snippets}"},
      %{role: "assistant",
        content: "Noted — I have those earlier exchanges in context."}
    ]
  end

  # Extract consecutive user→assistant message pairs from a list.
  defp extract_pairs(messages) do
    {pairs, pending} =
      Enum.reduce(messages, {[], nil}, fn msg, {pairs, pending} ->
        role    = msg["role"] || msg[:role] || ""
        content = msg["content"] || msg[:content] || ""

        case {role, pending} do
          {"user", nil} ->
            {pairs, %{user: content, assistant: ""}}

          {"assistant", %{} = pair} ->
            {pairs ++ [%{pair | assistant: content}], nil}

          {"user", %{} = pair} ->
            # Consecutive user messages — flush the unpaired one and start fresh
            {pairs ++ [pair], %{user: content, assistant: ""}}

          _ ->
            {pairs, pending}
        end
      end)

    if pending, do: pairs ++ [pending], else: pairs
  end

  defp to_llm_msg(%{"role" => r, "content" => c}), do: %{role: r, content: c}
  defp to_llm_msg(%{role: r, content: c}),          do: %{role: r, content: c}
  defp to_llm_msg(msg),                             do: msg

  # Find the last user message's text content in a list.
  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn msg ->
      role = msg["role"] || msg[:role]
      if role == "user", do: msg["content"] || msg[:content] || "", else: nil
    end)
  end

  # Rough character count across a list of messages.
  defp estimate_chars(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + String.length(to_string(msg["content"] || msg[:content] || ""))
    end)
  end

  defp save_context(session_id, user_id, ctx) do
    try do
      now     = System.os_time(:millisecond)
      encoded = Jason.encode!(ctx)
      query!(Repo, "UPDATE sessions SET context=?, updated_at=? WHERE id=? AND user_id=?",
             [encoded, now, session_id, user_id])
    rescue
      e -> Logger.error("[ContextEngine] save_context failed: #{Exception.message(e)}")
    end
  end
end
