# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ContextEngine do
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
  alias DmhAi.{Repo, Agent.AgentSettings, Agent.LLM, Agent.SystemPrompt}
  require Logger

  # ─── Constants ────────────────────────────────────────────────────────────

  # Simple token estimate: chars / 4 ≈ tokens.
  @chars_per_token 4
  # Usable context-window size in tokens — now pulled from AgentSettings
  # (setting `estimatedContextTokens`, default 64_000) so operators can
  # tune for the actual model in use without a code change.

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
    - `:memo_context`       — body for the `<augmented_facts type="memo">` block;
                              prepended to the current user message at build
                              time, NEVER persisted to session.messages.
                              See specs/commands.md §Confidant memo auto-retrieve.
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
    memo_context       = Keyword.get(opts, :memo_context)
    timezone           = Keyword.get(opts, :timezone)
    local_date         = Keyword.get(opts, :local_date)

    system_msg = %{role: "system",
                   content: SystemPrompt.generate_confidant(
                     profile:            profile,
                     has_video:          has_video,
                     image_descriptions: image_descriptions,
                     video_descriptions: video_descriptions,
                     timezone:           timezone,
                     local_date:         local_date
                   )}

    # Confidant has no indexed auto-fetch (memo + web only).
    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, images, files, web_context, memo_context, nil, :confidant)

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
    profile         = Keyword.get(opts, :profile, "")
    active_tasks    = Keyword.get(opts, :active_tasks, [])
    recent_done     = Keyword.get(opts, :recent_done, [])
    files           = Keyword.get(opts, :files, [])
    user_id         = Keyword.get(opts, :user_id)
    timezone        = Keyword.get(opts, :timezone)
    local_date      = Keyword.get(opts, :local_date)
    anchor_task_num = Keyword.get(opts, :anchor_task_num)
    memo_context    = Keyword.get(opts, :memo_context)
    indexed_context = Keyword.get(opts, :indexed_context)

    system_msg = %{role: "system",
                   content: SystemPrompt.generate_assistant(
                     profile:    profile,
                     timezone:   timezone,
                     local_date: local_date
                   )}

    # Per-user "Conservative token saving": when enabled AND a task is
    # currently the anchor, drop messages tagged with task_num != anchor
    # from the persisted message history. The model still sees the Task
    # List block (next-state knowledge) and can `fetch_task(N)` for the
    # closed-task body on demand. With anchor=nil (free-mode / just
    # post-completion follow-up) the filter is a no-op so the user
    # doesn't lose context for an in-flight follow-up. See architecture
    # spec §Conservative token saving.
    session_data = maybe_filter_other_tasks(session_data, user_id, anchor_task_num)

    # Auto-fetched memo + indexed blocks land in the current user
    # message via `build_current_msg(:assistant)`. Caller (run_assistant)
    # supplies the strings; we just thread them through. Per-turn
    # freshness is automatic — `build_current_msg` rebuilds each
    # turn, so any previous turn's blocks never persist.
    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, [], files, nil, memo_context, indexed_context, :assistant)

    # Re-inject the last N turns' tool_call / tool_result messages right
    # before their matching final-assistant text in history. Lets the
    # model answer immediate follow-ups ("elaborate on section 3")
    # without re-running the tool — the raw tool output is back in
    # context. Older turns' tool messages age out per the N-turn and
    # byte caps enforced by ToolHistory.save_tools_result_of_chain.
    #
    # `session_data["id"]` is REQUIRED — a missing id here silently
    # disables both the tool_history injection AND the Recently-extracted
    # files block below, leaving the model blind to retained tool output.
    # Raise loudly so any future wiring break fails immediately instead of
    # degrading behavior invisibly.
    session_id =
      case session_data["id"] do
        sid when is_binary(sid) and sid != "" ->
          sid
        other ->
          raise ArgumentError,
            "ContextEngine.build_assistant_messages/2: session_data must include a non-empty \"id\" key " <>
              "(got #{inspect(other)}). This id drives ToolHistory.load and the Recently-extracted " <>
              "files block — silently skipping them would disable Phase-3 features. Ensure load_session/2 " <>
              "(or any caller constructing session_data) populates \"id\"."
      end

    tool_history = DmhAi.Agent.ToolHistory.load(session_id)
    history_llm  = DmhAi.Agent.ToolHistory.inject(history_llm, tool_history)

    # Build a runtime directory naming the files whose raw extracted
    # content sits in the retention window — cross-referenced to their
    # originating task_num. Lets the model see at a glance which
    # filenames it can answer from retained `role: "tool"` messages
    # without re-extracting. Empty when no extract_content ran in the
    # last N turns.
    extracted_files_block =
      build_recently_extracted_block(tool_history, active_tasks, recent_done)

    # Assistant-mode only: rewrite `📎 ` lines in the LAST user message to
    # `📎 [newly attached] ` so the model can distinguish attachments the
    # user just re-posted (must be re-extracted) from older ones still
    # living in conversation history (do not re-extract). Purely ephemeral
    # — session.messages stays bare.
    last_msgs = mark_fresh_attachments(last_msgs)

    task_list_block = build_task_list_block(active_tasks, recent_done, base_level: 2)

    # Active-task anchor — a single `## Active task` block naming the
    # `(N)` this chain is for. Runtime decides; model follows. Nil
    # when no anchor can be derived (free mode). See architecture.md
    # §Active-task anchor. Injected between the task list and the
    # last user message so it's the final framing the model reads
    # before the user's latest input.
    anchor_block =
      session_id
      |> DmhAi.Agent.Anchor.resolve(silent_turn_task_id: Keyword.get(opts, :silent_turn_task_id))
      |> render_anchor_block()

    available_services_block = build_available_services_block(user_id)

    # Optional runtime guidance — injected only when the chain-prep's
    # inactive-task classifier returned a positive match. NOT persisted
    # to session.messages; lives only in this LLM call. Prepended to
    # the latest user message's content so the model reads the hint
    # in the same message slot it reads the user's actual text.
    last_msgs = maybe_prepend_runtime_hint(last_msgs, Keyword.get(opts, :runtime_resume_hint))

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++ task_list_block ++ available_services_block ++ extracted_files_block ++ anchor_block ++ last_msgs
  end

  # Prepend a runtime hint string to the content of the most-recent
  # user-role message in `last_msgs`, leaving everything else
  # untouched. Returns the list verbatim when the hint is nil/empty.
  defp maybe_prepend_runtime_hint(last_msgs, nil), do: last_msgs
  defp maybe_prepend_runtime_hint(last_msgs, ""), do: last_msgs

  defp maybe_prepend_runtime_hint(last_msgs, hint) when is_binary(hint) do
    last_user_idx =
      last_msgs
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {m, idx} ->
        if (m[:role] || m["role"]) == "user", do: idx, else: nil
      end)

    case last_user_idx do
      nil ->
        last_msgs

      idx ->
        List.update_at(last_msgs, idx, fn m ->
          old_content = m[:content] || m["content"] || ""
          new_content = hint <> "\n\n" <> old_content
          if Map.has_key?(m, :content), do: %{m | content: new_content}, else: %{m | "content" => new_content}
        end)
    end
  end

  # User-scoped catalog of services the user has authorized at some
  # point. Included so the model knows what `connect_mcp` URLs
  # are already known-good — without this, the model has no view
  # into past authorizations and tends to fall back on `web_search`
  # instead of attaching the right MCP server. Each row carries
  # everything the model needs to make a correct attach call: alias,
  # canonical URL, sample namespaced tool names from the cached
  # catalog, and a literal `connect_mcp(...)` template. Empty
  # list when no services have been authorized.
  defp build_available_services_block(nil), do: []

  defp build_available_services_block(user_id) when is_binary(user_id) do
    oauth_section = format_oauth_section(user_id)
    mcp_section   = format_mcp_section(user_id)

    case Enum.reject([oauth_section, mcp_section], &(&1 == "")) do
      [] ->
        []

      sections ->
        # XML-tag wrapping makes this a structurally-visible block the
        # model can't drift past. The `target=` strings inside are
        # LITERAL — `lookup_creds` does an exact match on `target`,
        # not a fuzzy resolve, so the model must pass exactly what's
        # shown here. Header forbids paraphrase to make that contract
        # unmissable.
        body =
          "<authorized_services>\n\n" <>
            "Use these EXACT strings — copy verbatim, don't paraphrase.\n\n" <>
            Enum.join(sections, "\n\n") <>
            "\n\n</authorized_services>"

        [
          %{role: "user",      content: body},
          %{role: "assistant", content: "Understood — I'll use lookup_creds for OAuth and connect_mcp for MCP services."}
        ]
    end
  end

  defp build_available_services_block(_), do: []

  # OAuth section — one bullet per credential row, showing the literal
  # `target=` string the model must pass to `lookup_creds`. Multi-
  # account rows list every account label so the `account=` arg has a
  # known, copyable shape. Rows with `account=""` render as `default`.
  # Empty string when the user has no oauth2_service credentials so
  # the caller can drop the section entirely.
  defp format_oauth_section(user_id) do
    creds =
      user_id
      |> DmhAi.Auth.Credentials.list()
      |> Enum.filter(&(&1.kind == "oauth2_service"))

    case creds do
      [] ->
        ""

      _ ->
        by_target = Enum.group_by(creds, & &1.target)

        rows =
          by_target
          |> Enum.map(fn {target, accounts} ->
            account_labels =
              accounts
              |> Enum.map(fn a ->
                case a.account do
                  "" -> "default"
                  acc -> acc
                end
              end)
              |> Enum.uniq()
              |> Enum.join(", ")

            "- target=`#{target}`   accounts: #{account_labels}"
          end)
          |> Enum.sort()
          |> Enum.join("\n")

        "**OAuth** — call `lookup_creds(target: \"<target>\")`. " <>
          "Multiple accounts → pass `account: \"<account>\"` to filter to one.\n\n" <>
          rows
    end
  end

  # MCP section — one bullet per attached server with alias + URL.
  # `connect_mcp` takes a URL, not a target, so the URL is what the
  # model copies. `[needs_auth]` surfaces re-auth state so the model
  # can call `connect_mcp` to recover.
  defp format_mcp_section(user_id) do
    services = DmhAi.MCP.Registry.list_authorized(user_id)

    case services do
      [] ->
        ""

      _ ->
        rows =
          services
          |> Enum.map(fn s ->
            tag =
              case s.status do
                "needs_auth" -> " [needs_auth]"
                _            -> ""
              end

            "- slug=`#{s.alias}`#{tag}"
          end)
          |> Enum.sort()
          |> Enum.join("\n")

        "**MCP** — already-authorized servers re-attach to the current " <>
          "task via `connect_mcp(slug: \"<slug>\")` using the slug below " <>
          "(NOT a URL — these services are already authorised, you're " <>
          "binding the existing authorisation to this task):\n\n" <>
          rows
    end
  end

  # Anchor rendering. Produces a user/assistant pair so the
  # OpenAI-sequencing contract (alternating roles at conversation
  # boundaries) stays clean. Empty list when no anchor — the model
  # operates in free mode.
  defp render_anchor_block(nil), do: []
  defp render_anchor_block(%{task_num: n}) when is_integer(n) do
    # Anchor wording is deliberately NON-LEADING toward `fetch_task`.
    # The model's context already carries recent activity for this
    # task (via session.messages + ToolHistory.inject), so fetching
    # is typically redundant. Fetch is framed as a fallback for the
    # specific case where a decision or tool output was compacted
    # away and the model needs to reload it — prevents weaker models
    # from reflexively fetching on every chain.
    body =
      "<active_task>\n\n" <>
        "- Current task: (#{n})\n" <>
        "- Your recent activity on this task (prior tool calls, " <>
        "results, narration) is already present in the conversation " <>
        "above. Answer / act from it directly.\n" <>
        "- Call `fetch_task` for (#{n}) ONLY as a fallback: if you " <>
        "need a specific past decision or tool output that was " <>
        "compacted away (older turns no longer visible in your " <>
        "context).\n" <>
        "- Once the task is done, close it with `complete_task` — " <>
        "passing the task's number and a one-line outcome summary.\n\n" <>
        "</active_task>"

    [
      %{role: "user",      content: body},
      %{role: "assistant", content: "Understood."}
    ]
  end
  defp render_anchor_block(_), do: []

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
    # Inside the XML wrapper, sub-sections start at h3 (the wrapper
    # itself replaces what was an h2 heading). `base_level` was the
    # markdown-only knob from the pre-XML block; we still honour the
    # caller's intent by using `base_level + 1` for sub-section
    # depth (gives `### periodic`, `### one_off`, etc.) and
    # `base_level + 2` for per-task titles. base_level=2 (default)
    # → sub=h3, task=h4, which is the FE-rendered shape today.
    base_level = Keyword.get(opts, :base_level, 2)

    if base_level + 2 > 6 do
      raise ArgumentError,
        "task-list block base_level=#{base_level} would push task-title headings to level #{base_level + 2}, past Markdown h6"
    end

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
      body = "<task_list>\n\n" <> Enum.join(sections, "\n\n") <> "\n\n</task_list>"

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
    # `tasks` is ordered newest-first by `Tasks.recent_done_for_session`
    # (ORDER BY updated_at DESC). Tag the head with `*[most recent]*` so
    # the model has an explicit anchor for pronoun resolution in the
    # NEXT chain ("that server", "the API we just used"). Surface each
    # row's `task_result` underneath the title — that's the one-line
    # outcome the model stored at `complete_task` time, and it's the
    # piece that lets pronouns resolve to concrete referents (server
    # names, IDs, URLs) without re-fetching the task.
    # See architecture.md §Task list block.
    lines =
      tasks
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {t, idx} ->
        tag = if idx == 0, do: "  *[most recent]*", else: ""
        result_line =
          case Map.get(t, :task_result) do
            r when is_binary(r) and r != "" -> "\n  #{r}"
            _ -> ""
          end

        "- #{num_label(t)}#{t.task_title}#{tag}#{result_line}"
      end)
    "#{sub} done\n\n" <> lines
  end

  # Tasks render by their per-session `(N)` label only — `task_id`
  # is BE-internal and never exposed to model or user. Active tasks
  # use a Markdown heading (`#### (N) title`); done tasks use a
  # bullet. The model references tasks exclusively via `task_num: N`
  # in verb tool calls; the resolver at the BE tool boundary maps
  # (session_id, N) → internal task_id.
  defp render_task_block(task, heading) do
    title_line = "#{heading} #{num_label(task)}#{task.task_title}"

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

  # Render the per-session "(N) " prefix; empty string when the row
  # has no task_num (NULL).
  defp num_label(%{task_num: n}) when is_integer(n) and n > 0, do: "(#{n}) "
  defp num_label(_), do: ""

  # Build the "Recently-extracted files" directory block — user/assistant
  # pair, injected between the task-list block and the current user
  # message. Walks tool_history, pulls every `extract_content` tool_call's
  # `path` argument, cross-references it to the originating task_num via
  # task_id (from the same retained turn's task-verb call — pickup_task,
  # complete_task, pause_task, cancel_task, or fetch_task — falling back
  # to any task whose attachments column contains the path). Truthful by
  # construction: only files whose raw content is actually still in the
  # retained window appear. Returns `[]` when nothing is extracted.
  defp build_recently_extracted_block(tool_history, active_tasks, recent_done) do
    entries = collect_extracted_file_entries(tool_history, active_tasks, recent_done)

    case entries do
      [] -> []
      _ ->
        lines =
          Enum.map_join(entries, "\n", fn e ->
            tn = if e.task_num, do: "from task (#{e.task_num})", else: "(task unknown)"
            "- `#{e.path}` — #{tn}"
          end)

        body =
          "<recently_extracted_files>\n\n" <>
            "The raw extracted content of each file below is currently " <>
            "in your context as a `role: \"tool\"` message (retained from " <>
            "recent turns). Answer follow-up questions about these files " <>
            "directly from those tool messages — do NOT call " <>
            "`extract_content` on them again.\n\n" <>
            lines <>
            "\n\n</recently_extracted_files>"

        [
          %{role: "user",      content: body},
          %{role: "assistant", content: "Understood."}
        ]
    end
  end

  defp collect_extracted_file_entries(tool_history, active_tasks, recent_done) do
    all_tasks = (active_tasks || []) ++ (recent_done || [])

    # Map: task_id → task_num (for cross-reference)
    tid_to_num =
      all_tasks
      |> Enum.flat_map(fn t ->
        case {Map.get(t, :task_id), Map.get(t, :task_num)} do
          {tid, tn} when is_binary(tid) and is_integer(tn) -> [{tid, tn}]
          _ -> []
        end
      end)
      |> Map.new()

    # Walk tool_history (each entry = one turn's worth of tool_call/tool_result
    # messages) and collect every extract_content path. Same entry's
    # pickup_task / complete_task / fetch_task call (if any) tells us
    # which task_id owns this extraction.
    tool_history
    |> Enum.flat_map(fn entry -> extract_paths_from_entry(entry, tid_to_num) end)
    |> Enum.uniq_by(& &1.path)
  end

  defp extract_paths_from_entry(entry, tid_to_num) do
    msgs = Map.get(entry, "messages") || Map.get(entry, :messages) || []

    # Find the task_id the model worked against this turn — inferred from
    # any task_id it passed to a task verb (pickup_task / complete_task /
    # pause_task / cancel_task / fetch_task) or created (create_task
    # return, but we don't have that here — fall back to scanning args
    # for a task_id key).
    task_id =
      msgs
      |> Enum.flat_map(fn m -> tool_call_args(m) end)
      |> Enum.find_value(fn args -> args["task_id"] end)

    task_num = task_id && Map.get(tid_to_num, task_id)

    msgs
    |> Enum.flat_map(fn m -> tool_call_args(m) end)
    |> Enum.flat_map(fn args ->
      case {args["path"], tool_call_name(args)} do
        {path, _name} when is_binary(path) and path != "" -> [%{path: path, task_num: task_num}]
        _ -> []
      end
    end)
  end

  # Returns list of argument maps for `extract_content` tool_calls in a
  # single message (assistant with tool_calls). We also include args
  # for any task verb (pickup/complete/pause/cancel/fetch) so we can
  # pick up task_id references.
  @task_verbs_with_task_id ~w(pickup_task complete_task pause_task cancel_task fetch_task)

  defp tool_call_args(msg) do
    calls = msg["tool_calls"] || msg[:tool_calls] || []
    role  = msg["role"] || msg[:role]

    if role == "assistant" and is_list(calls) do
      Enum.flat_map(calls, fn c ->
        fn_map = c["function"] || c[:function] || %{}
        name   = fn_map["name"] || ""
        args   = fn_map["arguments"] || %{}
        args   = if is_binary(args), do: Jason.decode!(args), else: args

        cond do
          name == "extract_content"          -> [Map.put(args, "__tool__", name)]
          name in @task_verbs_with_task_id   -> [Map.put(args, "__tool__", name)]
          true                               -> []
        end
      end)
    else
      []
    end
  end

  defp tool_call_name(args), do: Map.get(args, "__tool__")

  defp attachments_line(task) do
    # Structured attachments column is authoritative. Fall back to a
    # regex parse of task_spec when the column is empty so any row
    # without a populated attachments list still renders its paths.
    paths =
      case Map.get(task, :attachments) do
        list when is_list(list) and list != [] -> list
        _                                       -> extract_attachments(task.task_spec)
      end

    case paths do
      [] -> nil
      _  ->
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
    token_budget = AgentSettings.estimated_context_tokens() * @chars_per_token

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

      # Before running the compactor LLM, snapshot any task-tagged
      # messages in `to_summarize` to `task_chain_archive` grouped by
      # `task_num`. Preserves verbatim per-task history even as the
      # master session summary compresses the range away from the
      # LLM's working context. Untagged messages (pure chat) are
      # represented only by the summary. See architecture.md §Task
      # state continuity across chains.
      archive_to_summarize_per_task(session_id, to_summarize)

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
      case LLM.call(AgentSettings.oracle_model(), compaction_messages, trace: trace) do
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

  # Archive hook — called by `compact!/3` before summarisation.
  # Partitions `to_summarize` by `task_num` tag and persists verbatim
  # snapshots to `task_chain_archive` per task. Untagged messages are
  # dropped here (they'll live on only in the master session summary).
  defp archive_to_summarize_per_task(session_id, to_summarize) do
    to_summarize
    |> Enum.group_by(fn m -> m["task_num"] end)
    |> Enum.each(fn
      {nil, _msgs} -> :ok
      {task_num, msgs} when is_integer(task_num) ->
        case DmhAi.Agent.Tasks.resolve_num(session_id, task_num) do
          {:ok, task_id} ->
            DmhAi.Agent.TaskChainArchive.append_raw(task_id, session_id, msgs)
            Logger.info("[ContextEngine] archived #{length(msgs)} msg(s) for task=(#{task_num}) session=#{session_id}")

          {:error, :not_found} ->
            Logger.warning("[ContextEngine] compaction-time archive: task_num=#{task_num} no longer exists in session=#{session_id}; dropping its messages")
        end

      {_non_int, _msgs} ->
        # Malformed tag (e.g. string). Drop.
        :ok
    end)
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  # Shared message assembly used by both pipelines:
  # summary prefix + history + keyword snippets + current message.
  # `web_context` and `memo_context` are nil for the Assistant path
  # (no inline web search, no auto-retrieve memo).
  @doc """
  Drop persisted messages whose `task_num` tag points at a task other
  than the current anchor. Used by:
    * `build_assistant_messages/2` — chain-start filter when the user
      has `conservativeTokenSaving=true`.
    * `DmhAi.Agent.UserAgent.session_chain_loop` — mid-chain re-filter
      after `maybe_mutate_anchor` flips the anchor to a different
      non-nil task. Same rule, applied as the chain progresses.

  Behaviour:
    * `anchor_task_num == nil` → returns the input list unchanged
      (free-mode / just-completed-follow-up case — no flush).
    * `anchor_task_num == N` → drops messages where `task_num` is set
      AND not equal to `N`. Untagged messages stay (free-mode chats,
      synthetic kickers, in-chain pairs added by `session_chain_loop`).
    * `messages` containing entries without a `task_num` field — those
      are always preserved; this helper never invents tags.

  This helper is the single source of truth for the filter rule;
  callers never re-implement the comparison so a future tag-key change
  only touches one place.
  """
  @spec filter_other_tasks([map()], integer() | nil) :: [map()]
  def filter_other_tasks(messages, nil), do: messages
  def filter_other_tasks(messages, anchor_task_num) when is_integer(anchor_task_num) do
    Enum.reject(messages, fn m ->
      tag = m["task_num"] || m[:task_num]
      is_integer(tag) and tag != anchor_task_num
    end)
  end
  def filter_other_tasks(messages, _), do: messages

  # Conservative-token-saving gate: only filter when the user opted in.
  # Returns `session_data` unchanged when the toggle is off so the
  # default-behaviour path is byte-identical to pre-feature builds.
  defp maybe_filter_other_tasks(session_data, nil, _anchor_task_num), do: session_data
  defp maybe_filter_other_tasks(session_data, user_id, anchor_task_num)
       when is_binary(user_id) do
    if DmhAi.Auth.UserPreferences.conservative_token_saving?(user_id) do
      messages = session_data["messages"] || []
      filtered = filter_other_tasks(messages, anchor_task_num)
      Map.put(session_data, "messages", filtered)
    else
      session_data
    end
  end

  defp build_core(session_data, images, files, web_context, memo_context, indexed_context, pipeline)
       when pipeline in [:confidant, :assistant] do
    # Exclude archived messages (previous periodic-task cycles) — visible in FE
    # but not relevant to the LLM's context.
    # Also exclude `kind: "command"` (user's `/index …` text) and
    # `kind: "command_ack"` (runtime's synthetic ack) — the runtime
    # handled them entirely; they're audit log, not conversation.
    # See specs/commands.md.
    messages =
      (session_data["messages"] || [])
      |> Enum.reject(&(&1["_archived"] == true))
      |> Enum.reject(fn m -> m["kind"] in ["command", "command_ack"] end)
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
          %{role: "user",
            content: "<conversation_summary>\n\n" <>
                       "Summary of our conversation so far:\n\n" <>
                       summary <>
                       "\n\n</conversation_summary>"},
          %{role: "assistant", content: "Understood, I have the full context of our conversation."}
        ]
      else
        []
      end

    # Split recent history so we can inject relevant snippets just before the
    # last (current) user message. Web context and memo context are merged
    # INTO the last user message (replacing it).
    {history, last_msgs} =
      case Enum.split(recent, -1) do
        {h, [last]} -> {h, [build_current_msg(last, images, files, web_context, memo_context, indexed_context, pipeline)]}
        {h, []}     -> {h, []}
      end

    history_llm = Enum.map(history, &to_llm_msg/1)

    {prefix, history_llm, relevant_msgs, last_msgs}
  end

  # Build the last (current) user message — pipeline-specific.
  #
  # Confidant: canonical tagged shape, see arch_wiki/dmh_ai/architecture.md
  # §"Per-turn user-message structure":
  #
  #   <bare content>
  #   [if files] <attachments>… file names …</attachments>
  #   [if memo]  <augmented_facts type="memo">…</augmented_facts>
  #   [if web]   <augmented_facts type="web_search" retrieved="…">…</augmented_facts>
  #   [per file] <augmented_facts type="file" name="…">…content…</augmented_facts>
  #   <runtime_instruction>… focus on ongoing conversation … </runtime_instruction>
  #
  # Assistant: legacy inline shape — bare content + per-file `[File: name]`
  # fenced block. NO `<attachments>` user-message block (the Assistant
  # system prompt uses that XML tag for its OWN teaching section about
  # `📎 <path>` markers — duplicating the tag at message level would
  # collide). NO `<augmented_facts>` (Assistant has no auto-retrieve;
  # facts arrive via tool results). NO `<runtime_instruction>` (Assistant's
  # tool-driven runtime guidance lives entirely in the system prompt;
  # a per-turn injection would compete with task-anchored reasoning).
  #
  # Images are attached multimodally via `Map.put(llm_msg, :images, …)` —
  # they're NOT in the text body. The system prompt carries
  # image_descriptions / video_descriptions separately.
  #
  # Build-time only — never persisted.
  defp build_current_msg(msg, images, files, web_context, memo_context, _indexed_context, :confidant) do
    base = msg["content"] || msg[:content] || ""

    attachments_block =
      case files do
        [] ->
          ""

        _ ->
          names = Enum.map_join(files, "\n", fn f -> "- #{f["name"]}" end)
          "<attachments>\n#{names}\n</attachments>"
      end

    memo_block =
      if is_binary(memo_context) and memo_context != "" do
        ~s|<augmented_facts type="memo">\n| <> memo_context <> "\n</augmented_facts>"
      else
        ""
      end

    web_block =
      if is_binary(web_context) and web_context != "" do
        today = Date.to_string(Date.utc_today())
        ~s|<augmented_facts type="web_search" retrieved="#{today}">\n| <>
          web_context <> "\n</augmented_facts>"
      else
        ""
      end

    file_blocks =
      Enum.map_join(files, "\n\n", fn f ->
        ~s|<augmented_facts type="file" name="#{f["name"]}">\n| <>
          (f["content"] || "") <> "\n</augmented_facts>"
      end)

    content =
      [base, attachments_block, memo_block, web_block, file_blocks, confidant_runtime_instruction()]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    finalize_current_msg(msg, images, content)
  end

  defp build_current_msg(msg, images, files, _web_context, memo_context, indexed_context, :assistant) do
    base = msg["content"] || msg[:content] || ""

    # Order: indexed BEFORE memo BEFORE files. Reflects the
    # precedence rule the system prompt encodes (indexed > memo >
    # web > training) — surfacing the highest-authority block
    # first nudges the model to read it first.
    indexed_block =
      if is_binary(indexed_context) and indexed_context != "" do
        ~s|<augmented_facts type="indexed">\n| <> indexed_context <> "\n</augmented_facts>"
      else
        ""
      end

    memo_block =
      if is_binary(memo_context) and memo_context != "" do
        ~s|<augmented_facts type="memo">\n| <> memo_context <> "\n</augmented_facts>"
      else
        ""
      end

    file_block =
      Enum.map_join(files, "\n\n", fn f ->
        "[File: #{f["name"]}]\n```\n#{f["content"]}\n```"
      end)

    content =
      [indexed_block, memo_block, base, file_block]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    finalize_current_msg(msg, images, content)
  end

  # Common llm_msg packaging — preserve ts (load-bearing for mid-chain
  # splice floor in UserAgent.max_user_ts_in_messages/1; without it, the
  # floor collapses to 0 and splice_mid_chain_user_msgs re-appends the
  # current user message as a duplicate) and attach images multimodally.
  defp finalize_current_msg(msg, images, content) do
    llm_msg = %{role: "user", content: content}

    llm_msg =
      case msg[:ts] || msg["ts"] do
        ts when is_integer(ts) -> Map.put(llm_msg, :ts, ts)
        _                       -> llm_msg
      end

    if images != [], do: Map.put(llm_msg, :images, images), else: llm_msg
  end

  # Per-turn runtime guidance appended to every Confidant user message.
  # Tells the model the message is part of an ongoing conversation (not a
  # fresh stand-alone request), and how to use any <augmented_facts>
  # blocks the runtime supplied above. See arch_wiki/dmh_ai/architecture.md
  # §"Per-turn user-message structure". Assistant pipeline does NOT use
  # this — its tool-driven runtime guidance lives in the system prompt.
  defp confidant_runtime_instruction do
    """
    <runtime_instruction>
    Craft the most accurate, comprehensive answer to the user based on the ongoing conversation. Focus on the topic emerging from the most recent turns of the conversation — when the user's latest message refers implicitly to a subject already raised, it extends the prior topic; bridge them in your answer rather than treating the latest message as a fresh, isolated question. If <augmented_facts> blocks appear above, use their content as reference material to ground specific facts, figures, and names. Even when the augmented_facts cover only one side of the bridged topic, still relate your answer to the broader thread rather than restricting yourself to what the augmented_facts describe.
    </runtime_instruction>\
    """
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

  # Preserves `ts` when present so downstream consumers (ToolHistory.inject)
  # can match assistant messages back to their retained tool_call pairs.
  # LLM APIs ignore unknown fields in messages, so this is harmless on
  # the wire.
  defp to_llm_msg(%{"role" => r, "content" => c} = m),
    do: maybe_ts(%{role: r, content: c}, m)
  defp to_llm_msg(%{role: r, content: c} = m),
    do: maybe_ts(%{role: r, content: c}, m)
  defp to_llm_msg(msg), do: msg

  defp maybe_ts(out, src) do
    case src[:ts] || src["ts"] do
      ts when is_integer(ts) -> Map.put(out, :ts, ts)
      _                       -> out
    end
  end

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
