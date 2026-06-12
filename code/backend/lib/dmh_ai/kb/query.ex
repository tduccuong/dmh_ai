# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Kb.Query do
  @moduledoc """
  Runtime fan-out over both confidant memory stores. For each user message it
  embeds the query once, queries facts.db and memos.db in parallel, and
  returns the `<user_facts>` / `<user_memos>` blocks (top-k each) to inject
  into the LLM prompt. Not model-invoked — the runtime calls it every turn.
  See arch_wiki/dmh_ai/facts_memos.md.
  """

  alias DmhAi.{Kb, FactsRepo, MemosRepo}
  alias DmhAi.Agent.AgentSettings
  alias DmhAi.Kb.Embedder
  require Logger

  @await_ms 8_000

  @doc "Returns `{facts_block, memos_block}` (each `\"\"` when empty)."
  @spec blocks(String.t(), String.t()) :: {String.t(), String.t()}
  def blocks(user_id, q) do
    q = String.trim(q || "")

    q_vec =
      case q != "" && Embedder.embed(q) do
        {:ok, v} -> v
        _ -> nil
      end

    fk = AgentSettings.user_facts_top_k()
    mk = AgentSettings.user_memos_top_k()

    ft = Task.async(fn -> Kb.query(FactsRepo, "facts", user_id, q, q_vec, fk) end)
    mt = Task.async(fn -> Kb.query(MemosRepo, "memos", user_id, q, q_vec, mk) end)

    facts = ft |> Task.await(@await_ms) |> Enum.map(& &1.text)
    memos = mt |> Task.await(@await_ms) |> Enum.map(& &1.text)

    {format_block("user_facts", facts), format_block("user_memos", memos)}
  rescue
    e ->
      Logger.warning("[Kb.Query] blocks failed: #{Exception.message(e)}")
      {"", ""}
  end

  defp format_block(_tag, []), do: ""

  defp format_block(tag, items) do
    body = Enum.map_join(items, "\n", fn t -> "- " <> t end)
    "<#{tag}>\n#{body}\n</#{tag}>"
  end
end
