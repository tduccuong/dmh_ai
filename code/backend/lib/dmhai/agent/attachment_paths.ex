# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.AttachmentPaths do
  @moduledoc """
  Validation + canonicalisation for the `attachments` argument on
  `create_task` / `update_task` and equivalent operations.

  Contract
  --------
  The assistant passes attachments as a list of strings. Each must start
  with `workspace/` or `data/` (so we only expose paths inside the
  session's sandbox). Anything else is rejected at the tool boundary —
  prevents path smuggling before values reach DB / filesystem layers.

  The validated list is then merged into the task's stored `task_spec`
  as `📎 <path>` lines appended at the end, separated from the
  description by a blank line. This keeps a single source of truth
  (task_spec) while giving `ContextEngine.build_task_list_block/3` a
  stable marker to parse on render.
  """

  @allowed_prefixes ~w(workspace/ data/)

  @doc """
  Validate an `attachments` argument. Accepts:
    - `nil` / missing → `{:ok, []}` (no attachments)
    - `[]` → `{:ok, []}`
    - list of strings → `{:ok, [path1, path2, ...]}` after validation
    - anything else → `{:error, reason}`

  Validation per-path:
    - Must be a binary.
    - Must start with one of `workspace/` or `data/`.
    - Must not contain `..` segments (defence against traversal; the
      resolver already handles this, but early rejection is clearer).
  """
  @spec validate(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate(nil), do: {:ok, []}
  def validate([]),  do: {:ok, []}
  def validate(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn p, {:ok, acc} ->
      case validate_one(p) do
        {:ok, clean}    -> {:cont, {:ok, [clean | acc]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other       -> other
    end
  end
  def validate(other), do: {:error, "attachments must be a list of strings, got: #{inspect(other)}"}

  defp validate_one(p) when is_binary(p) do
    stripped = String.trim(p)
    cond do
      stripped == "" ->
        {:error, "attachment path is empty"}

      String.contains?(stripped, "..") ->
        {:error, "attachment path '#{stripped}' must not contain '..' segments"}

      not Enum.any?(@allowed_prefixes, &String.starts_with?(stripped, &1)) ->
        {:error,
         "attachment path '#{stripped}' must start with one of " <>
           inspect(@allowed_prefixes)}

      true ->
        {:ok, stripped}
    end
  end
  defp validate_one(other),
    do: {:error, "attachment path must be a string, got: #{inspect(other)}"}

  @doc """
  Normalise a `task_spec` by:
    1. Stripping any existing `📎`-prefixed lines (the assistant may
       have hand-embedded them — we ignore those; the `attachments`
       argument is authoritative).
    2. Appending `📎 <path>` lines from the validated list, separated
       from the description by a blank line.

  Called by `create_task` and `update_task` when they accept an
  `attachments` argument.
  """
  @spec normalise_spec(String.t(), [String.t()]) :: String.t()
  def normalise_spec(spec, attachments) when is_binary(spec) and is_list(attachments) do
    base =
      spec
      |> strip_transient_markers()
      |> String.split("\n")
      |> Enum.reject(fn line -> Regex.match?(~r/^\s*📎\s+/u, line) end)
      |> Enum.join("\n")
      |> String.trim_trailing()

    case attachments do
      [] ->
        base

      paths ->
        attachment_block = Enum.map_join(paths, "\n", fn p -> "📎 " <> p end)
        base <> "\n\n" <> attachment_block
    end
  end

  @doc """
  Strip any `[newly attached] ` context-build-time marker from a string.
  The marker is only valid in the ephemeral LLM input array; if it
  reaches any persisted field (task_spec / task_title / task_result)
  it's a leak from the model copying the marker verbatim from its
  input into a tool_call argument. Strip at every persistence boundary
  so the DB never stores it.
  """
  @spec strip_transient_markers(String.t() | nil) :: String.t()
  def strip_transient_markers(nil), do: ""
  def strip_transient_markers(text) when is_binary(text) do
    text
    |> String.replace("📎 [newly attached] ", "📎 ")
    |> String.replace("[newly attached] ", "")
    |> String.replace("[newly attached]", "")
  end
end
