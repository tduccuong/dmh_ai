# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.FetchMemo do
  @moduledoc """
  Look up things the user saved via `/memo`. Strictly user-scoped:
  `user_id` comes from execution context, never from the model. Cross-
  user memo leakage is impossible by construction.

  Dynamically gated — only present in the catalog on turns whose user
  message starts with `/memo`. See specs/commands.md.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder

  @impl true
  def name, do: "fetch_memo"

  @impl true
  def description,
    do: "Look up things you saved about this user via /memo. Personal preferences, account references, project context."

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        required: ["q"],
        properties: %{
          q: %{type: "string", description: "Keywords or natural-language phrase."}
        }
      }
    }
  end

  @impl true
  def execute(%{"q" => q}, ctx) when is_binary(q) and q != "" do
    user_id = ctx[:user_id] || ctx["user_id"]

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "fetch_memo requires authenticated user context"}

      true ->
        with {:ok, vec}  <- Embedder.embed(q),
             {:ok, hits} <- VectorDB.search(:memo, q, vec, AgentSettings.kb_top_n(), {:user, user_id}) do
          {:ok, format(hits)}
        else
          {:error, reason} -> {:error, "fetch_memo failed: #{inspect(reason)}"}
        end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: q"}

  defp format(hits) do
    Enum.map(hits, fn h ->
      %{
        text:   h.chunk_text,
        source: "#{h.source_kind}:#{h.source_ref}",
        score:  Float.round(h.score, 4)
      }
    end)
  end
end
