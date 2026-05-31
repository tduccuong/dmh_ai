# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.UpsertWorkflow.Normalise do
  @moduledoc """
  Input normalisation for `upsert_workflow`. Coerces the raw tool
  args (`display_name`, `name`, `description`, `ir`, `change_note`,
  plus runtime-supplied `ctx.user_id` / `ctx.session_id`) into the
  shapes the rest of the pipeline expects, returning teaching errors
  when something is missing or malformed.
  """

  alias DmhAi.Workflows

  @description_min 10
  @description_max 280

  @doc """
  Guard a binary context field. `:ok` when the value is a non-empty
  string, otherwise an error citing the label so the runtime can
  point at which context field was missing.
  """
  @spec require_string(any(), String.t()) :: :ok | {:error, String.t()}
  def require_string(v, _label) when is_binary(v) and v != "", do: :ok
  def require_string(_, label), do: {:error, "upsert_workflow: missing #{label}"}

  @doc """
  Trim + length-check the operator-facing display name. Must be at
  least 3 chars so the picker has something meaningful to render.
  """
  @spec normalise_display_name(any()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_display_name(v) when is_binary(v) do
    trimmed = String.trim(v)
    if String.length(trimmed) >= 3 do
      {:ok, trimmed}
    else
      {:error, "upsert_workflow: display_name too short (need ≥ 3 chars)"}
    end
  end
  def normalise_display_name(_),
    do: {:error, "upsert_workflow: display_name required (string)"}

  @doc """
  Resolve the URL-safe slug. Missing / empty → derive from the
  display_name. Provided string → re-slugify (defensive). Anything
  else → error.
  """
  @spec normalise_slug(any(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_slug(nil, display_name), do: {:ok, Workflows.slugify(display_name)}
  def normalise_slug("",  display_name), do: {:ok, Workflows.slugify(display_name)}
  def normalise_slug(v,   _) when is_binary(v) do
    s = Workflows.slugify(v)
    if s == "" do
      {:error, "upsert_workflow: name produced empty slug after normalisation"}
    else
      {:ok, s}
    end
  end
  def normalise_slug(_, _),
    do: {:error, "upsert_workflow: name must be a string when supplied"}

  @doc """
  `ir` must be a JSON object (decoded to a map). Anything else
  fails fast — every downstream pass assumes a map.
  """
  @spec normalise_ir(any()) :: {:ok, map()} | {:error, String.t()}
  def normalise_ir(v) when is_map(v), do: {:ok, v}
  def normalise_ir(_),
    do: {:error, "upsert_workflow: ir must be a JSON object (map)"}

  @doc """
  Trim + length-bound the operator-facing description. The picker
  shows this exact text, so reject too-short ("not enough to
  recognise") and too-long ("hides intent") prose.
  """
  @spec normalise_description(any()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_description(v) when is_binary(v) do
    trimmed = String.trim(v)
    len = String.length(trimmed)

    cond do
      len < @description_min ->
        {:error,
         "upsert_workflow: description too short " <>
           "(got #{len} chars, need ≥ #{@description_min}). " <>
           "Write one or two operator-readable sentences describing WHAT the workflow does."}

      len > @description_max ->
        {:error,
         "upsert_workflow: description too long " <>
           "(got #{len} chars, max #{@description_max}). " <>
           "Keep it to one or two short sentences."}

      true ->
        {:ok, trimmed}
    end
  end

  def normalise_description(_),
    do: {:error,
         "upsert_workflow: description required (string, " <>
           "#{@description_min}-#{@description_max} chars). " <>
           "Write one or two operator-readable sentences describing WHAT the workflow does."}

  @doc """
  Change note is optional — default to `"initial draft"` so the
  version history row always carries readable copy. Truncate at 280
  chars to keep the breadcrumb single-line.
  """
  @spec normalise_change_note(any()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_change_note(v) when is_binary(v) and v != "" do
    {:ok, String.slice(String.trim(v), 0, 280)}
  end
  def normalise_change_note(nil), do: {:ok, "initial draft"}
  def normalise_change_note(""),  do: {:ok, "initial draft"}
  def normalise_change_note(_),
    do: {:error, "upsert_workflow: change_note must be a string"}
end
