# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Commands.WikiAck do
  @moduledoc """
  Helpers for composing `/wiki` runtime acks. Centralises the
  18-word title-truncate so every pipeline (text/file/url/folder)
  produces the same shape.
  """

  @max_title_words 18

  @doc "Final ack after a successful `/wiki` ingest."
  @spec final_ack(String.t() | nil) :: String.t()
  def final_ack(title) do
    "I indexed your input about '#{truncate_title(title)}' in the internal Wiki, ready to use from now."
  end

  @doc "Sync acknowledgement when long-running ingest is starting in the background."
  @spec accepted_ack(String.t() | nil) :: String.t()
  def accepted_ack(title) do
    "Noted, indexing '#{truncate_title(title)}' in the background — I'll confirm when done."
  end

  @doc """
  Slice the title down to `@max_title_words` (18) words. Empty / nil →
  `"(untitled)"`. Plain word split — no char count.
  """
  @spec truncate_title(String.t() | nil) :: String.t()
  def truncate_title(nil), do: "(untitled)"
  def truncate_title(title) when is_binary(title) do
    words = String.split(title, ~r/\s+/, trim: true)

    cond do
      words == []                     -> "(untitled)"
      length(words) <= @max_title_words -> Enum.join(words, " ")
      true                              ->
        words |> Enum.take(@max_title_words) |> Enum.join(" ") |> Kernel.<>("…")
    end
  end
end
