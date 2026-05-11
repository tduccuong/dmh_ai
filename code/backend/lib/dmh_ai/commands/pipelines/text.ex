# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Commands.Pipelines.Text do
  @moduledoc """
  Inline-text `/index` pipeline. Synchronous — runs in the chat HTTP
  request and returns an ack string. The vector_db pipeline applies
  the centroid-merge logic so similar bodies fold into one source
  rather than fragmenting.

  See specs/vector_kb.md §"Pipeline (chunk → embed → tag → merge-or-insert)".
  """

  alias DmhAi.VectorDB
  alias DmhAi.Agent.Swift
  alias DmhAi.Commands.IndexAck

  @spec run(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(body, _session_id, _user_id) when is_binary(body) do
    body = String.trim(body)

    if body == "" do
      {:error, "empty input"}
    else
      title = title_from_body(body)

      attrs = %{
        scope:       :knowledge,
        user_id:     nil,
        source_kind: "text",
        source_ref:  sha256(body),
        title:       title
      }

      case VectorDB.ingest(attrs, body) do
        {:ok, _info}     -> {:ok, Swift.localize(IndexAck.final_ack(title), body)}
        {:error, reason} -> {:error, "ingest failed: #{inspect(reason, limit: 80)}"}
      end
    end
  end

  defp sha256(s), do: :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)

  # First non-empty line — used for kb_sources.title and ack truncation.
  # No char cap here; IndexAck does the 18-word truncate on display.
  defp title_from_body(body) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "" -> nil
      line -> line
    end
  end
end
