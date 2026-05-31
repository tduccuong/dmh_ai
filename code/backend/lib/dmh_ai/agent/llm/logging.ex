# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.Logging do
  @moduledoc """
  Diagnostic + bookkeeping helpers shared by the call + stream paths
  in `DmhAi.Agent.LLM`. Pure formatters, the optional `LogTrace`
  write-through, the auto-wired `TokenTracker` callback, and the
  random-id mint used for assistant-side tool-call IDs.

    * `log_messages/1` + `content_to_log_string/1` — produce the
      one-line SysLog preview of an outbound message list.
    * `maybe_trace/5` — write a full request/response trace via
      `LogTrace` when the global trace flag is on.
    * `auto_token_tracker/1` — derive a `TokenTracker.add/5`
      callback from the trace meta when the caller didn't pass one.
    * `generate_id/0` — short URL-safe random id for tool-call slots.
  """

  alias DmhAi.Agent.{AgentSettings, LogTrace, TokenTracker}

  def log_messages(messages) do
    non_sys = Enum.reject(messages, fn m -> (m[:role] || m["role"]) == "system" end)
    parts = Enum.map(non_sys, fn m ->
      role    = m[:role]       || m["role"]       || "?"
      content = m[:content]    || m["content"]    || ""
      calls   = m[:tool_calls] || m["tool_calls"] || []
      if is_list(calls) and calls != [] do
        names = Enum.map_join(calls, ",", fn c -> get_in(c, ["function", "name"]) || "?" end)
        "[#{role}→#{names}]"
      else
        snippet =
          content
          |> content_to_log_string()
          |> String.slice(0, 100)
          |> String.replace("\n", "↵")

        "[#{role}]#{snippet}"
      end
    end)
    result = Enum.join(parts, " | ")
    if String.length(result) > 1000, do: String.slice(result, 0, 1000) <> "…", else: result
  end

  # OpenAI vision messages use `content` as a LIST of typed blocks
  # (`%{type: "text", text: "..."}`, `%{type: "image_url", image_url: ...}`),
  # not a plain string. `to_string/1` would crash on that shape.
  # Flatten to a one-line preview: text blocks inline, images as a
  # short `[image]` marker so SysLog stays readable without dumping
  # base64.
  def content_to_log_string(content) when is_binary(content), do: content
  def content_to_log_string(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{type: "text", text: t}        when is_binary(t) -> t
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{type: "image_url"}                              -> "[image]"
      %{"type" => "image_url"}                          -> "[image]"
      other                                             -> inspect(other, limit: 30)
    end)
  end
  def content_to_log_string(other), do: inspect(other, limit: 30)

  def maybe_trace(nil, _model_str, _messages, _tools, _result), do: :ok
  def maybe_trace(meta, model_str, messages, tools, result) do
    if AgentSettings.log_trace() do
      LogTrace.write(meta, model_str, messages, tools, result)
    end
  end

  # Derive a TokenTracker callback from the trace meta when the caller
  # didn't pass an explicit `:on_tokens`. Auto-wire fires only when
  # the trace carries `tier`, `user_id`, and `session_id` (session_id
  # may be `nil` for user-global calls like ProfileExtractor — the
  # tracker writes the sentinel row in that case). Anything else
  # → no callback (the adapter sees a nil and skips the credit).
  def auto_token_tracker(%{tier: tier, user_id: user_id, session_id: session_id})
      when is_atom(tier) and is_binary(user_id) do
    fn rx, tx -> TokenTracker.add(session_id, user_id, tier, rx, tx) end
  end

  def auto_token_tracker(_), do: nil

  def generate_id, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
end
