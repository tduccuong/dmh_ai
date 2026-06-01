# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands do
  @moduledoc """
  Slash-command runtime. Two commands, both intercepted by the chat
  HTTP entry BEFORE the agent loop runs:

    * `/index <text|url|file|folder>` — save into the global index.
      Runtime runs the ingest pipeline; ack as `kind="command_ack"`.
      No LLM round-trip on the assistant model.

    * `/memo <content>` — save into the user's memo store. Runtime
      vector-ingests the content, persists `kind="command"` /
      `kind="command_ack"` pair (both filtered from LLM context).
      Querying memos is conversational — the assistant uses
      `fetch_memo` from its tool catalog.

  Workflow intent is NOT a slash command. The user speaks naturally
  ("run &<slug>", "edit &<slug> at node 3", "build a workflow that …")
  and the assistant's `<workflow_authoring>` system-prompt section
  interprets intent. The `&<slug>` token in chat is the inline
  reference; FE's WorkflowPicker resolves it to a sidecar entry the
  BE pastes into the LLM-bound content as a `<workflow_references>`
  block.
  """

  alias DmhAi.Agent.{Swift, UserAgentMessages}
  alias DmhAi.Commands.{Parser, Memo, Pipelines}
  alias DmhAi.Commands.Pipelines.Gettext

  @doc """
  Parse + dispatch. Returns:

    * `{:handled, user_ts}` — runtime took it; caller should NOT
      proceed to the LLM loop. `user_ts` is the BE-stamped timestamp
      of the persisted user message (the FE patches its optimistic
      copy via this — without it, poll returns the BE row as a "new"
      message and the chat shows a duplicate).
    * `:not_a_command` — caller continues with the regular flow.
  """
  @spec dispatch(String.t(), String.t(), String.t(), String.t(), [String.t()]) ::
          {:handled, non_neg_integer()} | :not_a_command
  def dispatch(content, session_id, user_id, lang \\ "en", image_paths \\ []) when is_binary(content) do
    case Parser.parse(content) do
      {:index, arg}   -> run_index(arg, content, session_id, user_id) |> finalize_command(session_id, user_id, content)
      {:memo, arg}    -> Memo.run(arg, content, session_id, user_id, lang)
      {:gettext, _}   -> Gettext.run(content, session_id, user_id, lang, image_paths)
      _               -> :not_a_command
    end
  end

  # ─── /index ────────────────────────────────────────────────────────────────

  defp run_index(arg, _original, session_id, user_id) do
    arg = String.trim(arg)

    cond do
      not admin?(user_id) ->
        DmhAi.Permissions.audit(user_id, :write_settings, "org_settings", :denied, "index_admin_only")
        {:ok, "`/index` is restricted to org admins. Ask an admin to ingest this source."}

      arg == "" ->
        {:ok, "Usage: `/index <text | url | absolute file path | absolute folder path>`"}

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

  defp admin?(user_id) when is_binary(user_id) do
    DmhAi.Permissions.can?(user_id, :write_settings, "org_settings")
  end

  defp admin?(_), do: false

  # `/index` and `/memo` (save path) ack persistence — both messages
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

    err_msg = Swift.localize("Couldn't process: " <> to_string(reason), original_content,
                             %{session_id: session_id, user_id: user_id})

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
