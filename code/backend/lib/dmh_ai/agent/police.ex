# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.Police do
  @moduledoc """
  Tool-call gate. The model has broad tool freedom, so Police only
  intervenes where the runtime MUST enforce an invariant (sandbox
  escape, malformed call, duplicate calls within one chain, repeated
  errors, etc.).

  Every check returns `:ok` to let the tool call proceed, or
  `{:rejected, reason}` (the runtime turns this into a tool-result the
  model can correct on its next turn). The implementations live in
  sub-modules under `__MODULE__.{Schema, PathSafety, ToolName,
  AssistantText, ChainState.Phantom, ChainState.Repetition}` grouped
  by what the check inspects:

    * `Schema` — argument shape against the tool's declared schema.
    * `PathSafety` — sandbox-escape guard for file / shell tools.
    * `ToolName` — `function.name` must be a registered tool.
    * `AssistantText` — final-text turn shape (empty / pseudo-call /
      bookkeeping annotation).
    * `ChainState.Phantom` — write-class semantics: phantom outcome,
      write-failure budget, workflow-build continuity, fresh
      attachment reads.
    * `ChainState.Repetition` — repetition / overuse: duplicate tool
      calls, repeated tool errors, consecutive `web_search`,
      `run_script` probe budget + advisory.

  Callers continue to resolve every function on `DmhAi.Agent.Police`;
  this shell only re-exports them via `defdelegate`.
  """

  alias __MODULE__.{AssistantText, PathSafety, Schema, ToolName}
  alias __MODULE__.ChainState.{Phantom, Repetition}

  # Schema
  defdelegate check_tool_call_schema(name, args), to: Schema

  # PathSafety
  defdelegate check_path_safety(calls, messages, ctx \\ %{}), to: PathSafety
  defdelegate rejection_msg(reason), to: PathSafety

  # ToolName
  defdelegate check_tool_name_validity(name), to: ToolName
  defdelegate check_tool_name_validity(name, user_id), to: ToolName

  # AssistantText
  defdelegate check_assistant_text(text), to: AssistantText

  # ChainState.Phantom — write-class semantics
  defdelegate check_no_phantom_outcome(outcome_attempts, outcome_failures), to: Phantom
  defdelegate write_class?(tool_name), to: Phantom
  defdelegate outcome_write?(tool_name), to: Phantom
  defdelegate check_write_failure_budget(tool_name, failures_so_far, budget), to: Phantom
  defdelegate check_workflow_build_continuity(name, prior_messages), to: Phantom
  defdelegate check_fresh_attachments_read(fresh_paths, messages), to: Phantom
  defdelegate extract_fresh_attachment_paths(messages), to: Phantom

  # ChainState.Repetition — repetition / overuse
  defdelegate check_no_duplicate_tool_call(name, args, prior_messages), to: Repetition
  defdelegate check_repeated_tool_error(tool_name, error_text, prior_messages), to: Repetition
  defdelegate check_no_consecutive_web_search(name, args, prior_messages), to: Repetition
  defdelegate check_run_script_probe_budget(name, args, prior_messages), to: Repetition
  defdelegate consecutive_run_script_advisory(name, prior_messages), to: Repetition
end
