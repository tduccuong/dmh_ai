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

  alias DmhAi.Agent.{AgentSettings, UserAgent}
  alias DmhAi.MemoCrypto
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder
  require Logger

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
        # Memo chunks are AES-GCM ciphertext at rest. We need the
        # user's MMK to decrypt before handing plaintext to the model.
        # Absent key → fail soft with empty results (the model will
        # answer "I don't have that on file" rather than error).
        case UserAgent.get_memo_key(user_id) do
          nil ->
            Logger.info("[FetchMemo] no MMK in state for user=#{user_id} — returning empty result")
            {:ok, []}

          mmk ->
            with {:ok, vec}  <- Embedder.embed(q),
                 {:ok, hits} <- VectorDB.search(:memo, q, vec, AgentSettings.kb_top_n(), {:user, user_id}) do
              {:ok, format(hits, mmk)}
            else
              {:error, reason} -> {:error, "fetch_memo failed: #{inspect(reason)}"}
            end
        end
    end
  end

  def execute(_, _), do: {:error, "Missing required argument: q"}

  defp format(hits, mmk) do
    hits
    |> Enum.map(&decrypt_hit(&1, mmk))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn h ->
      %{
        text:   h.chunk_text,
        source: "#{h.source_kind}:#{h.source_ref}",
        score:  Float.round(h.score, 4)
      }
    end)
  end

  # Try to decrypt the row. Three outcomes:
  #   {:ok, plaintext}      → swap chunk_text and keep the hit.
  #   {:error, :legacy_plaintext} → row predates encryption (lazy-migration
  #                          window). Trust the plaintext and keep the hit.
  #   {:error, :bad_key}    → tag mismatch — corrupted row OR cross-user
  #                          leakage attempted. Drop the hit.
  defp decrypt_hit(hit, mmk) do
    # Map.get/3 (NOT dot-access) — BM25-leg hits historically didn't
    # carry chunk_idx; missing-key raises BadKeyError on dot syntax.
    src_id = Map.get(hit, :source_id) || ""
    idx    = Map.get(hit, :chunk_idx) || 0
    case MemoCrypto.decrypt_chunk(hit.chunk_text, mmk, src_id, idx) do
      {:ok, plain} ->
        %{hit | chunk_text: plain}

      {:error, :legacy_plaintext} ->
        hit

      {:error, :bad_key} ->
        Logger.warning("[FetchMemo] decrypt failed for source_id=#{inspect(src_id)} idx=#{inspect(idx)} — row dropped")
        nil
    end
  end
end
