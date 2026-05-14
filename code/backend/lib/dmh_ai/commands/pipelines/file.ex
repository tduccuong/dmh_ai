# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.File do
  @moduledoc """
  File `/index` pipeline — extract via the existing `extract_content`
  tool, then index. Synchronous for files under `learn_sync_max_file_bytes`
  (default 5 MB); larger files route to the async path (handled by the
  caller — `DmhAi.Commands` checks file size + dispatches accordingly).

  See specs/commands.md.
  """

  alias DmhAi.VectorDB
  alias DmhAi.Agent.Swift
  alias DmhAi.Tools.ExtractContent
  alias DmhAi.Commands.IndexAck

  @doc "Heuristic — does the arg look like a file path that exists?"
  @spec file?(String.t()) :: boolean()
  def file?(path) when is_binary(path) do
    String.starts_with?(path, "/") and File.regular?(path)
  end

  def file?(_), do: false

  @spec run(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(path, session_id, user_id) when is_binary(path) do
    ctx = %{user_id: user_id, session_id: session_id}

    case ExtractContent.execute(%{"path" => path}, ctx) do
      {:ok, body} when is_binary(body) and body != "" ->
        attrs = %{
          scope:       :knowledge,
          org_id:      DmhAi.Orgs.for_user(user_id),
          source_kind: "file",
          source_ref:  path,
          title:       Path.basename(path)
        }

        case VectorDB.ingest(attrs, body) do
          {:ok, _info} ->
            # Localize using the file body as the language signal —
            # it's the strongest signal we have (the path is usually
            # English-ish regardless of the user).
            {:ok, Swift.localize(IndexAck.final_ack(Path.basename(path)), body)}

          {:error, reason} ->
            {:error, "ingest failed: #{inspect(reason, limit: 80)}"}
        end

      {:ok, _other} ->
        {:error, "extract_content returned non-text result for `#{path}` — only text-extractable files can be /index'd"}

      {:error, reason} ->
        {:error, "couldn't extract `#{Path.basename(path)}`: #{reason}"}
    end
  end
end
