# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands do
  @moduledoc """
  Slash-command runtime. Every command is intercepted by the chat
  HTTP entry BEFORE the LLM call runs:

    * `/memo <content>` — save into the user's memo store. Runtime
      vector-ingests the content, persists `kind="command"` /
      `kind="command_ack"` pair (both filtered from LLM context).
      Querying memos is conversational — Confidant runs an automatic
      memo-retrieval pre-step before each turn.

    * `/tts [text]` — render text / OCR'd images / the previous reply as
      a sentence-per-row Read-out-loud panel (`kind="tts"`).

  """

  alias DmhAi.Agent.UserAgentMessages
  alias DmhAi.Commands.{Parser, Memo}
  alias DmhAi.Commands.Pipelines.Tts

  @doc """
  Parse + dispatch. Returns:

    * `{:handled, user_ts}` — runtime took it; caller should NOT
      proceed to the LLM call. `user_ts` is the BE-stamped timestamp
      of the persisted user message (the FE patches its optimistic
      copy via this — without it, poll returns the BE row as a "new"
      message and the chat shows a duplicate).
    * `:not_a_command` — caller continues with the regular flow.
  """
  @spec dispatch(String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()} | :not_a_command
  def dispatch(content, session_id, user_id, lang \\ "en", image_paths \\ []) when is_binary(content) do
    case Parser.parse(content) do
      {:memo, arg}    -> Memo.run(arg, content, session_id, user_id, lang)
      {:tts, arg}     -> Tts.run(content, arg, session_id, user_id, lang, image_paths)
      _               -> :not_a_command
    end
  end

  @doc false
  # Exposed for `DmhAi.Commands.Memo` so the runtime can persist a
  # `kind="command"` / `kind="command_ack"` pair (both filtered from
  # LLM context). Returns `{:handled, user_ts}` per `dispatch/5`'s
  # contract — `user_ts` lets the FE patch its optimistic user-message
  # copy so the polled BE row doesn't render twice.
  def append_command_pair(session_id, user_id, original_content, ack_text) do
    {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
      role: "user",
      content: original_content,
      kind: "command"
    })

    {:ok, _ack_ts} = UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: ack_text,
      kind: "command_ack"
    })

    {:handled, user_ts}
  end
end
