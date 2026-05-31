# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Agent.UserAgent.Memo do
  @moduledoc """
  Master-Memo-Key (MMK) lifecycle + per-turn memo retrieval.

  * `lazy_load_memo_key/1` — read & unwrap `users.memo_wrapped_mmk`.
  * `generate_and_persist_mmk/1` — mint a fresh MMK and persist its
    wrapped form. Returns `{:ok, mmk}` / `{:error, reason}` — purely
    persistence; the shell wires the resulting `{:reply, …}` tuple.
  * `wipe_user_memo_state/1` — drop the user's memo VectorDB rows
    (rotation path when the master-key check fails).
  * `build_memo_context/3` — embed the recent user-turn window, ANN
    against the memo collection, decrypt hits with the live MMK, and
    return a formatted context block + the raw hit list for the
    web-search prompt.
  """

  require Logger

  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Repo
  alias DmhAi.VectorDB
  alias DmhAi.VectorDB.Embedder
  import Ecto.Adapters.SQL, only: [query!: 3]

  @doc """
  Load and unwrap the user's MMK from the DB.
  Returns `{:ok, mmk}` or `{:error, :no_wrap | :legacy_v1 |
  :unknown_format | :bad_master_key | reason}`.
  """
  def lazy_load_memo_key(user_id) do
    case query!(Repo, "SELECT memo_wrapped_mmk FROM users WHERE id=?", [user_id]) do
      %{rows: [[nil]]} ->
        {:error, :no_wrap}

      %{rows: [[wrapped]]} when is_binary(wrapped) ->
        case DmhAi.MemoCrypto.wrap_version(wrapped) do
          :v2 ->
            case DmhAi.MemoCrypto.unwrap_with_master(wrapped, DmhAi.MemoCrypto.MasterKey.get()) do
              {:ok, mmk} -> {:ok, mmk}
              {:error, reason} ->
                Logger.warning("[UserAgent] master-key unwrap failed user=#{user_id} reason=#{inspect(reason)}")
                {:error, reason}
            end

          :v1 ->
            {:error, :legacy_v1}

          :unknown ->
            {:error, :unknown_format}
        end

      _ ->
        {:error, :no_wrap}
    end
  end

  @doc """
  Mint a fresh MMK, wrap it with the master key, persist the wrapped
  form on `users`. Returns `{:ok, mmk}` on success or
  `{:error, message}` on a DB exception.
  """
  def generate_and_persist_mmk(user_id) do
    mmk = DmhAi.MemoCrypto.generate_mmk()
    wrapped = DmhAi.MemoCrypto.wrap_with_master(mmk, DmhAi.MemoCrypto.MasterKey.get())

    try do
      query!(Repo,
        "UPDATE users SET memo_wrapped_mmk = ?, memo_kdf_salt = NULL WHERE id = ?",
        [wrapped, user_id])
      {:ok, mmk}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  @doc "Drop the user's memo rows (rotation when master-key check fails)."
  def wipe_user_memo_state(user_id) do
    DmhAi.VectorDB.Sources.wipe_user_memos(user_id)
  rescue
    e -> Logger.error("[UserAgent] wipe_user_memo_state failed for user=#{user_id}: #{Exception.message(e)}")
  end

  @doc """
  Embed the recent user-turn window + current content, ANN against
  the memo collection, decrypt with the live MMK, return
  `{formatted_block_or_nil, raw_hits}`. Returns `{nil, []}` when no
  MMK is available.
  """
  def build_memo_context(current_content, recent_user_msgs, user_id) do
    case DmhAi.Agent.UserAgent.get_memo_key(user_id) do
      nil ->
        {nil, []}

      mmk ->
        do_build_memo_context(current_content, recent_user_msgs, user_id, mmk)
    end
  end

  defp do_build_memo_context(current_content, recent_user_msgs, user_id, mmk) do
    prior =
      recent_user_msgs
      |> Enum.drop(-1)
      |> Enum.take(-2)

    embed_text = (prior ++ [current_content]) |> Enum.join("\n") |> String.trim()

    case Embedder.embed(embed_text) do
      {:ok, vec} ->
        top_k = AgentSettings.memo_context_top_k()

        case VectorDB.search(:memo, embed_text, vec, top_k, {:user, user_id}) do
          {:ok, raw_hits} ->
            hits = Enum.map(raw_hits, &decrypt_memo_hit(&1, mmk)) |> Enum.reject(&is_nil/1)
            log_memo_retrieval(embed_text, raw_hits, hits)
            {format_memo_context_block(hits), hits}

          {:error, reason} ->
            Logger.warning("[Memo auto] search failed: #{inspect(reason, limit: 80)}")
            {nil, []}
        end

      {:error, reason} ->
        Logger.warning("[Memo auto] embed failed: #{inspect(reason, limit: 80)}")
        {nil, []}
    end
  end

  defp log_memo_retrieval(embed_text, raw_hits, hits) do
    score_summary =
      hits
      |> Enum.map(fn h ->
        s = if is_number(h.score), do: Float.round(h.score, 3), else: h.score
        "#{s}|#{String.slice(h.chunk_text || "", 0, 40) |> String.replace("\n", " ")}"
      end)
      |> Enum.join("; ")

    line =
      "[Memo auto] embed=#{inspect(String.slice(embed_text, 0, 80))} " <>
        "raw=#{length(raw_hits)} decrypted=#{length(hits)} hits=[#{score_summary}]"

    Logger.info(line)
    DmhAi.SysLog.log(line)
  end

  defp decrypt_memo_hit(hit, mmk) do
    src_id = Map.get(hit, :source_id) || ""
    idx    = Map.get(hit, :chunk_idx) || 0
    case DmhAi.MemoCrypto.decrypt_chunk(hit.chunk_text, mmk, src_id, idx) do
      {:ok, plain}                  -> %{hit | chunk_text: plain}
      {:error, :legacy_plaintext}   -> hit
      {:error, :bad_key}            ->
        Logger.warning("[Memo auto] decrypt failed for source_id=#{inspect(src_id)} idx=#{inspect(idx)} — row dropped")
        nil
    end
  end

  defp format_memo_context_block([]) do
    "We checked the user's saved memos for this question. Nothing relevant found.\n\n" <>
      "How to use this signal:\n" <>
      "- IF the user's message references the memo store: tell the user honestly that no saved memo matches their question.\n" <>
      "- OTHERWISE: ignore this block entirely and answer per usual."
  end

  defp format_memo_context_block(hits) do
    bullets =
      hits
      |> Enum.map_join("\n", fn h ->
        "- " <> String.replace(h.chunk_text || "", "\n", " ")
      end)

    "The user previously saved these personal notes. Use any that are relevant; ignore the rest.\n\n" <>
      bullets
  end
end
