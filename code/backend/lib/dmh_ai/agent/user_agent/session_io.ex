# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.SessionIO do
  @moduledoc """
  Session-row DB read/write helpers plus the in-loop message splicing
  and rolling tool-result flush.

  * `load_session/2` — single-row read used by the dispatch task to
    determine `mode` before invoking Confidant vs Assistant.
  * `append_session_message/3` — BE-stamps `ts` and persists.
  * `splice_mid_chain_user_msgs/2` — fold any user msgs that arrived
    while the chain was mid-flight into the next LLM call.
  * `flush_stale_tool_results/2` — rolling replacement of old tool
    bodies with a placeholder, keeping the call/result pairing intact.
  * `compact_if_needed/3` — call into `Agent.Compactor` and merge any
    new context back into the in-memory session map.
  """

  require Logger

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # See architecture.md §Rolling tool-result flush.
  @flushed_tool_result_placeholder "[result removed to save tokens]"

  @doc """
  Append `message` to `sessions.messages`. Stamps `ts` server-side
  (Rule 9 — backend is the sole timestamp authority). Returns
  `{:ok, stamped_ts}` on success.
  """
  def append_session_message(session_id, user_id, message) do
    try do
      result = query!(Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                      [session_id, user_id])

      case result.rows do
        [[msgs_json]] ->
          msgs = Jason.decode!(msgs_json || "[]")
          now  = System.os_time(:millisecond)
          stamped = Map.put(message, :ts, now)
          updated = Jason.encode!(msgs ++ [stamped])
          query!(Repo, "UPDATE sessions SET messages=?, updated_at=? WHERE id=?",
                 [updated, now, session_id])
          {:ok, now}

        _ ->
          {:error, :session_not_found}
      end
    rescue
      e ->
        Logger.error("[UserAgent] append_session_message failed: #{Exception.message(e)}")
        {:error, :exception}
    end
  end

  @doc """
  Load `sessions.{model, messages, context, mode}` for the user.
  Returns `{:ok, model, session_map}` or `{:error, reason}`.
  """
  def load_session(session_id, user_id) do
    try do
      result =
        query!(Repo, "SELECT model, messages, context, mode FROM sessions WHERE id=? AND user_id=?",
               [session_id, user_id])

      case result.rows do
        [[model, msgs_json, ctx_json, mode]] ->
          messages = Jason.decode!(msgs_json || "[]")

          context =
            case Jason.decode(ctx_json || "{}") do
              {:ok, m} when is_map(m) -> m
              _                       -> %{}
            end

          {:ok, model || "",
           %{"id" => session_id,
             "messages" => messages,
             "context" => context,
             "mode" => mode || "confidant"}}

        _ ->
          {:error, "Session not found"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Pull the last 10 user messages (truncated to 300 chars each) out of
  a session map — feeder for the memo-context embed and Confidant
  search-intent prompt.
  """
  def extract_user_messages(session_data) do
    messages = session_data["messages"] || []

    messages
    |> Enum.filter(fn m -> m["role"] == "user" end)
    |> Enum.take(-10)
    |> Enum.map(fn m -> String.slice(m["content"] || "", 0, 300) end)
  end

  @doc """
  When user messages have arrived between the chain's current
  outgoing-message list and now (mid-chain), splice them in so the
  next turn answers them. Floor is the max `ts` already present.
  """
  def splice_mid_chain_user_msgs(messages, %{session_id: session_id}) do
    floor_ts = max_user_ts_in_messages(messages)

    case DmhAi.Agent.UserAgentMessages.user_msgs_since(session_id, floor_ts) do
      [] ->
        messages

      new_msgs ->
        DmhAi.SysLog.log("[ASSISTANT] mid-chain splice: #{length(new_msgs)} new user msg(s) since ts=#{floor_ts}")
        messages ++ new_msgs
    end
  end

  @doc "Highest `ts` of any `role: \"user\"` message in the list (0 if none)."
  def max_user_ts_in_messages(messages) do
    Enum.reduce(messages, 0, fn m, acc ->
      role = m[:role] || m["role"]
      ts   = m[:ts]   || m["ts"]

      if role == "user" and is_integer(ts) and ts > acc, do: ts, else: acc
    end)
  end

  # Rolling tool-result flush. For `role: "tool"` messages whose
  # `emit_turn` is older than `tool_result_retention_turns`, REPLACE
  # the `content` body with `@flushed_tool_result_placeholder`; keep
  # the message itself and its `tool_call_id` so the LLM-API pairing
  # rule (every `tool_call` has a matching `tool_result`) stays
  # intact. The prior assistant text + the original `tool_call` args
  # ride forward verbatim — only the verbose result body is dropped.
  # See architecture.md §Rolling tool-result flush.
  @doc """
  Replace stale `role: \"tool\"` result bodies with a placeholder while
  keeping `tool_call_id` pairing intact. Retention horizon is read from
  `AgentSettings.tool_result_retention_turns/0`.
  """
  def flush_stale_tool_results(messages, current_turn) do
    retention = AgentSettings.tool_result_retention_turns()

    Enum.map(messages, fn m ->
      role = m[:role] || m["role"]
      emit_turn = m[:emit_turn] || m["emit_turn"]

      if role == "tool" and is_integer(emit_turn) and current_turn - emit_turn > retention do
        replace_content(m, @flushed_tool_result_placeholder)
      else
        m
      end
    end)
  end

  @doc "Replace whichever `content` key (`:content` or `\"content\"`) the message uses."
  def replace_content(msg, new_content) do
    cond do
      Map.has_key?(msg, :content)  -> Map.put(msg, :content, new_content)
      Map.has_key?(msg, "content") -> Map.put(msg, "content", new_content)
      true                         -> Map.put(msg, :content, new_content)
    end
  end

  @doc """
  Hand `(session_id, user_id)` to `Agent.Compactor`. On a compaction
  pass, re-read `sessions.context` and merge it into the in-memory
  session map; otherwise return `session_data` unchanged.
  """
  def compact_if_needed(session_id, user_id, session_data) do
    case DmhAi.Agent.Compactor.maybe_compact(session_id, user_id) do
      {:compacted, _kept_chars} ->
        ctx =
          case query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id]) do
            %{rows: [[ctx_json]]} ->
              case Jason.decode(ctx_json || "{}") do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            _ ->
              %{}
          end

        Map.put(session_data, "context", ctx)

      _ ->
        session_data
    end
  end
end
