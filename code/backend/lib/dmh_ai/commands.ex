# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands do
  @moduledoc """
  Slash-command runtime. See specs/commands.md.

  Two commands, both intercepted by the chat HTTP entry BEFORE the
  agent loop runs:

    * `/wiki <text|url|file|folder>` — save into the global wiki.
      Runtime runs the ingest pipeline; ack as `kind="command_ack"`.
      No LLM round-trip on the assistant model.

    * `/memo <content>` — save into the user's memo store. Runtime
      vector-ingests the content, persists `kind="command"` /
      `kind="command_ack"` pair (both filtered from LLM context).
      Querying memos is conversational — the assistant uses
      `fetch_memo` from its tool catalog; Confidant runs an
      automatic retrieval pre-step (task #186).
  """

  alias DmhAi.Agent.{Oracle, UserAgentMessages}
  alias DmhAi.Commands.{Parser, Memo, Pipelines}

  @doc """
  Parse + dispatch. Returns:

    * `{:handled, user_ts}` — runtime took it; caller should NOT proceed
      to the LLM loop. `user_ts` is the BE-stamped timestamp of the
      persisted user message (the FE patches its optimistic copy via
      this — without it, poll returns the BE row as a "new" message
      and the chat shows a duplicate).
    * `:not_a_command` — caller continues with the regular flow.
  """
  @spec dispatch(String.t(), String.t(), String.t()) ::
          {:handled, non_neg_integer()} | :not_a_command
  def dispatch(content, session_id, user_id) when is_binary(content) do
    case Parser.parse(content) do
      {:wiki, arg} -> run_wiki(arg, content, session_id, user_id) |> finalize_command(session_id, user_id, content)
      {:memo, arg} -> Memo.run(arg, content, session_id, user_id)
      _            -> :not_a_command
    end
  end

  # ─── /wiki ────────────────────────────────────────────────────────────────

  defp run_wiki(arg, _original, session_id, user_id) do
    arg = String.trim(arg)

    cond do
      arg == "" ->
        {:ok, "Usage: `/wiki <text | url | absolute file path | absolute folder path>`"}

      Pipelines.URL.url?(arg) ->
        Pipelines.URL.run_async(arg, session_id, user_id)

      Pipelines.Folder.folder?(arg) ->
        Pipelines.Folder.run_async(arg, session_id, user_id)

      Pipelines.File.file?(arg) ->
        Pipelines.File.run(arg, session_id, user_id)

      true ->
        Pipelines.Text.run(arg, session_id, user_id)
    end
  end

  # `/wiki` and `/memo` (save path) ack persistence — both messages
  # tagged `kind` so ContextEngine excludes them from LLM context
  # (audit log, not conversation). Returns `user_ts` so the chat
  # entry can patch the FE's optimistic user-message ts; without
  # that, the FE can't reconcile its optimistic copy with the polled
  # BE row and the message renders twice.
  defp finalize_command({:ok, ack_text}, session_id, user_id, original_content) do
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

  defp finalize_command({:error, reason}, session_id, user_id, original_content) do
    {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
      role: "user",
      content: original_content,
      kind: "command"
    })

    err_msg = Oracle.localize("Couldn't process: " <> to_string(reason), original_content)

    {:ok, _ack_ts} = UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: err_msg,
      kind: "command_ack"
    })

    {:handled, user_ts}
  end

  @doc false
  # Exposed for `DmhAi.Commands.Memo` so the runtime can persist a
  # `kind="command"` / `kind="command_ack"` pair with the same
  # semantics. Returns `{:handled, user_ts}` per `dispatch/3`'s
  # contract.
  def append_command_pair(session_id, user_id, original_content, ack_text) do
    finalize_command({:ok, ack_text}, session_id, user_id, original_content)
  end
end
