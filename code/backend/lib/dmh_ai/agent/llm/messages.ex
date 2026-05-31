# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.LLM.Messages do
  @moduledoc """
  Protocol-aware message-history sanitisation.

  Gemini thinking-mode responses attach an internal `thought_signature`
  to each function call.  Ollama's /api/chat format does not expose
  this field, so the client can never echo it back.  When the history
  contains tool-call messages from a previous thinking-mode turn,
  Gemini rejects the next request with HTTP 400
  "Function call is missing a thought_signature in functionCall parts."

  Fix: before sending to any Ollama endpoint hosting a Gemini model,
  convert:

      assistant{tool_calls:[…]} → assistant{content:"[used: name(args)]"}
      tool{content:…, tool_call_id:…} → user{content:"[result:name] …"}

  The model continues to understand the conversation from the text
  descriptions. Verified by isolated HTTP replay test: stripping
  tool-call format from history resolves the 400 while preserving
  model reasoning quality.

  Only Gemini models (hosted via Ollama) have the thought_signature
  limitation. Other models (Mistral, LLaMA, etc.) handle tool_call
  history natively — leave them unchanged.
  """

  alias DmhAi.Agent.LLM.ResponseParsing

  def sanitize_messages("ollama", messages, model_name) do
    if String.contains?(String.downcase(model_name), "gemini") do
      do_sanitize_gemini_messages(messages)
    else
      messages
    end
  end

  def sanitize_messages(_protocol, messages, _model_name), do: messages

  defp do_sanitize_gemini_messages(messages) do
    # Build a map from tool_call_id → full call, so the tool result message
    # can include both the name and the arguments for context.
    call_id_to_call =
      Enum.flat_map(messages, fn msg ->
        if (msg[:role] || msg["role"]) == "assistant" do
          (msg[:tool_calls] || msg["tool_calls"] || [])
          |> Enum.map(fn call -> {call["id"] || "", call} end)
        else
          []
        end
      end)
      |> Map.new()

    Enum.map(messages, fn msg ->
      role  = msg[:role]  || msg["role"]
      calls = msg[:tool_calls] || msg["tool_calls"] || []

      cond do
        role == "assistant" and is_list(calls) and calls != [] ->
          existing_content = msg[:content] || msg["content"] || ""
          parts = Enum.map(calls, fn c ->
            name = get_in(c, ["function", "name"]) || "?"
            args = ResponseParsing.decode_args(get_in(c, ["function", "arguments"]) || %{})
            args_str = Jason.encode!(args)
            "[used: #{name}(#{args_str})]"
          end)
          suffix = Enum.join(parts, " ")
          combined = if existing_content != "", do: "#{existing_content}\n#{suffix}", else: suffix
          %{role: "assistant", content: combined}

        role == "tool" ->
          content      = msg[:content] || msg["content"] || ""
          tool_call_id = msg[:tool_call_id] || msg["tool_call_id"] || ""
          call         = Map.get(call_id_to_call, tool_call_id, %{})
          name         = get_in(call, ["function", "name"]) || "tool"
          %{role: "user", content: "[result:#{name}] #{content}"}

        true ->
          msg
      end
    end)
  end
end
