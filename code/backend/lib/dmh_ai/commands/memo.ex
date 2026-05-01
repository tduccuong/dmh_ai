# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Memo do
  @moduledoc """
  `/memo <content>` runtime command — write-only save against the
  user's per-user memo store.

  Querying is conversational, not slash-driven:
    * Assistant calls the `fetch_memo` tool from its catalog when a
      question matches stored memo content.
    * Confidant runs an automatic memo-retrieval pre-step before each
      LLM call (see task #186).

  Save flow:
    1. Persist the user message synchronously with `kind="command"`
       so `user_ts` can return immediately for FE optimistic-render
       dedup. The kind tag also keeps the message out of LLM context
       (it's audit log, not conversation).
    2. Background `Task.Supervisor` child runs `VectorDB.ingest/2` +
       `Oracle.localize/2` for the ack. The ack is appended with
       `kind="command_ack"` once the ingest completes.

  Safety: if the background task crashes mid-ingest, the worst case
  is a stuck `kind="command"` message in scrollback — never an
  unanswered message in the LLM's context.

  See specs/commands.md.
  """

  alias DmhAi.Agent.{Oracle, UserAgentMessages}
  alias DmhAi.Commands
  alias DmhAi.VectorDB
  require Logger

  @save_ack_template "Saved."

  @spec run(String.t(), String.t(), String.t(), String.t()) :: {:handled, non_neg_integer()}
  def run(arg, original_content, session_id, user_id) do
    arg = String.trim(arg)

    if arg == "" do
      # No input → no language signal; English usage hint, sync.
      Commands.append_command_pair(session_id, user_id, original_content,
        "Usage: `/memo <content to save>`")
    else
      # Persist user msg synchronously with kind="command" — this is
      # the safe default (filtered from LLM context) and gives us a
      # `user_ts` to return immediately so the FE can patch its
      # optimistic copy.
      {:ok, user_ts} = UserAgentMessages.append(session_id, user_id, %{
        role: "user",
        content: original_content,
        kind: "command"
      })

      Task.Supervisor.start_child(DmhAi.Agent.TaskSupervisor, fn ->
        run_save(arg, session_id, user_id)
      end)

      {:handled, user_ts}
    end
  end

  # Background worker — runs after the HTTP response has already
  # closed. Result lands in `session.messages` and reaches the FE
  # via `/poll`.
  defp run_save(text, session_id, user_id) do
    attrs = %{
      scope:       :memo,
      user_id:     user_id,
      source_kind: "text",
      source_ref:  sha256(text),
      title:       nil
    }

    ack =
      case VectorDB.ingest(attrs, text) do
        {:ok, _info} ->
          Oracle.localize(@save_ack_template, text)

        {:error, reason} ->
          Oracle.localize("Couldn't save: #{inspect(reason, limit: 80)}", text)
      end

    UserAgentMessages.append(session_id, user_id, %{
      role: "assistant",
      content: ack,
      kind: "command_ack"
    })
  rescue
    e ->
      Logger.error("[Memo] save worker crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
  end

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
end
