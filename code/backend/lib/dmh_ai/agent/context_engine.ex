# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.ContextEngine do
  @moduledoc """
  Server-side context engineering for the Confidant pipeline.

  `build_confidant_messages/2` produces:
  [system] ++ [summary prefix] ++ [history] ++ [relevant snippets] ++ [current msg]
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
      build_core(session_data, images, files, web_context, memo_context)

    [system_msg] ++ prefix ++ history_llm ++ relevant_msgs ++ last_msgs
  end

  # ─── Private ──────────────────────────────────────────────────────────────

  defp build_core(session_data, images, files, web_context, memo_context) do
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
        {h, [last]} -> {h, [build_current_msg(last, images, files, web_context, memo_context)]}
        {h, []}     -> {h, []}
      end

    history_llm = Enum.map(history, &to_llm_msg/1)

    {prefix, history_llm, relevant_msgs, last_msgs}
  end

  defp build_current_msg(msg, images, files, web_context, memo_context) do
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
