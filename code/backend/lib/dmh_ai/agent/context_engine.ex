# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ContextEngine do
  @moduledoc """
  Server-side context engineering for LLM conversations.

  Two entry points:
    build_confidant_messages/2  — Confidant pipeline (image / video descriptions, web context)
    build_assistant_messages/2  — Assistant pipeline (services blocks, current message)

  Both produce: [system] ++ [compaction prefix] ++ [history] ++ [snippets] ++ [current msg]
  """

  alias DmhAi.Agent.SystemPrompt
  require Logger

  # Keyword retrieval — top-K snippets injected before the current message.
  @top_k 4
  @min_relevance 0.25
  @snippet_preview_chars 500
  @min_keyword_len 3

  # ─── Public API ───────────────────────────────────────────────────────────

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

    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, images, files, web_context, memo_context, nil, :confidant)

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++ last_msgs
  end

  @spec build_assistant_messages(map(), keyword()) :: [map()]
  def build_assistant_messages(session_data, opts \\ []) do
    profile         = Keyword.get(opts, :profile, "")
    files           = Keyword.get(opts, :files, [])
    user_id         = Keyword.get(opts, :user_id)
    timezone        = Keyword.get(opts, :timezone)
    local_date      = Keyword.get(opts, :local_date)
    memo_context    = Keyword.get(opts, :memo_context)
    indexed_context = Keyword.get(opts, :indexed_context)

    system_msg = %{role: "system",
                   content: SystemPrompt.generate_assistant(
                     profile:    profile,
                     timezone:   timezone,
                     local_date: local_date
                   )}

    {prefix, history_llm, relevant_msgs, last_msgs} =
      build_core(session_data, [], files, nil, memo_context, indexed_context, :assistant)

    last_msgs = mark_fresh_attachments(last_msgs)

    available_services_block = build_available_services_block(user_id)
    pending_services_block   = build_pending_services_block(user_id)

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++
      available_services_block ++ pending_services_block ++ last_msgs
  end

  # ─── Authorized + pending services blocks ─────────────────────────────────

  defp build_available_services_block(nil), do: []

  defp build_available_services_block(user_id) when is_binary(user_id) do
    oauth_section = format_oauth_section(user_id)
    mcp_section   = format_mcp_section(user_id)

    # MCP listed FIRST: when a request maps to an MCP slug's scope,
    # typed connector tools are the right path (validated args,
    # consistent errors, no URL/method guesswork). Raw OAuth + curl
    # is the fallback for vendors with no MCP coverage.
    case Enum.reject([mcp_section, oauth_section], &(&1 == "")) do
      [] ->
        []

      sections ->
        body =
          "<authorized_services>\n\n" <>
            "Use these EXACT strings — copy verbatim, don't paraphrase. " <>
            "When the request maps to an MCP slug's scope, prefer connect_mcp — " <>
            "raw OAuth + curl is for vendors no slug covers.\n\n" <>
            Enum.join(sections, "\n\n") <>
            "\n\n</authorized_services>"

        [
          %{role: "user",      content: body},
          %{role: "assistant", content: "Understood — connect_mcp first when a slug covers the request; lookup_creds + curl for vendors no slug covers."}
        ]
    end
  end

  defp build_available_services_block(_), do: []

  defp build_pending_services_block(nil), do: []

  defp build_pending_services_block(user_id) when is_binary(user_id) do
    pending = list_pending_connectors(user_id)

    case pending do
      [] ->
        []

      _ ->
        rows =
          pending
          |> Enum.map(fn c ->
            base = "- slug=`#{c.slug}` — **#{c.name}**"
            case c.description do
              d when is_binary(d) and d != "" -> base <> ": " <> d
              _ -> base
            end
          end)
          |> Enum.sort()
          |> Enum.join("\n")

        body =
          "<pending_services>\n\n" <>
            "The administrator has CONFIGURED these external systems but " <>
            "the current user has NOT yet authorized them. " <>
            "If the user asks anything about a system in this list — its " <>
            "data, identity, contents, status, ANYTHING — do NOT call its " <>
            "functions, do NOT invent an answer, and do NOT pattern-match " <>
            "from unrelated context. The single correct response is to " <>
            "tell the user that the connector is configured but not yet " <>
            "authorized for their account, and direct them to click " <>
            "**My Services → Connect <name>** to authorize.\n\n" <>
            rows <>
            "\n\n</pending_services>"

        [
          %{role: "user",      content: body},
          %{role: "assistant", content: "Understood — for any system in the pending list I'll instruct the user to click My Services → Connect, never invoke or fabricate."}
        ]
    end
  end

  defp build_pending_services_block(_), do: []

  defp list_pending_connectors(user_id) do
    authorized =
      user_id
      |> DmhAi.MCP.Registry.list_authorized()
      |> MapSet.new(& &1.alias)

    DmhAi.MCP.Catalog.list()
    |> Enum.filter(fn c -> c.enabled and is_binary(c.slug) and c.slug != "" end)
    |> Enum.reject(fn c -> MapSet.member?(authorized, c.slug) end)
  end

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

  defp format_mcp_section(user_id) do
    services = DmhAi.MCP.Registry.list_authorized(user_id)

    case services do
      [] ->
        ""

      _ ->
        rows =
          services
          |> Enum.map(fn s -> format_mcp_row(s, user_id) end)
          |> Enum.sort()
          |> Enum.join("\n")

        "**MCP** — these MCP servers are already authorized for this " <>
          "user. Each exposes typed actions on a specific external " <>
          "system. When the request maps to a slug's scope, attach " <>
          "with `connect_mcp(slug: \"<slug>\")` — that's the deployment's " <>
          "source of truth for everything in scope, faster than " <>
          "`web_search`. After attach, the connector's typed functions " <>
          "appear in your tools catalog as `<slug>.<function_name>`.\n\n" <>
          rows
    end
  end

  defp format_mcp_row(%{alias: alias_, status: status}, user_id) do
    tag      = if status == "needs_auth", do: " [needs_auth]", else: ""
    accounts = mcp_accounts_for(alias_, user_id)
    accounts_clause =
      case accounts do
        [] -> ""
        list -> " (accounts: #{Enum.join(list, ", ")})"
      end

    case mcp_description_for(alias_) do
      nil  -> "- slug=`#{alias_}`#{accounts_clause}#{tag}"
      desc -> "- slug=`#{alias_}`#{accounts_clause}#{tag} — #{desc}"
    end
  end

  defp mcp_description_for(slug) when is_binary(slug) do
    case DmhAi.MCP.Catalog.get_by_slug(slug) do
      %{description: d} when is_binary(d) and d != "" -> d
      _ -> nil
    end
  end

  defp mcp_accounts_for(slug, user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "oauth:" <> slug) do
      creds when is_list(creds) ->
        creds
        |> Enum.map(fn c ->
          case Map.get(c, :account, "") do
            "" -> "default"
            acc -> acc
          end
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # ─── attachment markers ────────────────────────────────────────────────

  defp mark_fresh_attachments([]), do: []
  defp mark_fresh_attachments(msgs) do
    last_idx = length(msgs) - 1

    Enum.with_index(msgs)
    |> Enum.map(fn {msg, idx} ->
      if idx == last_idx and ((msg[:role] || msg["role"]) == "user") do
        content = msg[:content] || msg["content"] || ""
        new = String.replace(content, ~r/(^|\n)📎\s+(\S+)/u, "\\1📎 [newly attached] \\2")
        if Map.has_key?(msg, :content) do
          %{msg | content: new}
        else
          %{msg | "content" => new}
        end
      else
        msg
      end
    end)
  end

  @doc """
  Pull file path tokens out of a task spec — kept as a public helper
  because other modules (e.g. `Tools.ExtractContent`'s docs and tests)
  reference the same 📎-line shape.
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

  # ─── Private ──────────────────────────────────────────────────────────────

  defp build_core(session_data, images, files, web_context, memo_context, indexed_context, pipeline)
       when pipeline in [:confidant, :assistant] do
    messages =
      (session_data["messages"] || [])
      |> Enum.reject(&(&1["_archived"] == true))
      |> Enum.reject(fn m -> m["kind"] in ["command", "command_ack"] end)

    ctx      = session_data["context"] || %{}
    summary  = ctx["summary"]
    cutoff   = ctx["summary_up_to_index"] || -1

    recent = Enum.drop(messages, cutoff + 1)
    old    = Enum.take(messages, cutoff + 1)

    current_text  = last_user_content(recent)
    relevant_msgs = retrieve_relevant(old, current_text)

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

    {history, last_msgs} =
      case Enum.split(recent, -1) do
        {h, [last]} -> {h, [build_current_msg(last, images, files, web_context, memo_context, indexed_context, pipeline)]}
        {h, []}     -> {h, []}
      end

    history_llm = Enum.map(history, &to_llm_msg/1)

    {prefix, history_llm, relevant_msgs, last_msgs}
  end

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

  defp finalize_current_msg(msg, images, content) do
    llm_msg = %{role: "user", content: content}

    llm_msg =
      case msg[:ts] || msg["ts"] do
        ts when is_integer(ts) -> Map.put(llm_msg, :ts, ts)
        _                       -> llm_msg
      end

    if images != [], do: Map.put(llm_msg, :images, images), else: llm_msg
  end

  defp confidant_runtime_instruction do
    """
    <runtime_instruction>
    Craft the most accurate, comprehensive answer to the user based on the ongoing conversation. Focus on the topic emerging from the most recent turns of the conversation — when the user's latest message refers implicitly to a subject already raised, it extends the prior topic; bridge them in your answer rather than treating the latest message as a fresh, isolated question. If <augmented_facts> blocks appear above, use their content as reference material to ground specific facts, figures, and names. Even when the augmented_facts cover only one side of the bridged topic, still relate your answer to the broader thread rather than restricting yourself to what the augmented_facts describe.
    </runtime_instruction>\
    """
  end

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
            {pairs ++ [pair], %{user: content, assistant: ""}}

          _ ->
            {pairs, pending}
        end
      end)

    if pending, do: pairs ++ [pending], else: pairs
  end

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

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn msg ->
      role = msg["role"] || msg[:role]
      if role == "user", do: msg["content"] || msg[:content] || "", else: nil
    end)
  end
end
