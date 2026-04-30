# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.MMR do
  use ExUnit.Case, async: true

  alias Dmhai.VectorDB.MMR

  defp hit(text, score), do: %{chunk_text: text, score: score}

  describe "rerank/3" do
    test "returns input unchanged when count <= final_k" do
      hits = [hit("a", 0.9), hit("b", 0.8)]
      assert MMR.rerank(hits, 5, 0.6) == hits
    end

    test "lambda=1.0 collapses to top-k by relevance (no diversification)" do
      hits = [
        hit("alpha", 0.9),
        hit("beta",  0.8),
        hit("gamma", 0.7),
        hit("delta", 0.6)
      ]

      assert MMR.rerank(hits, 2, 1.0) == [hit("alpha", 0.9), hit("beta", 0.8)]
    end

    test "drops near-duplicate boilerplate, promotes the next genuinely-different hit" do
      # The exact failure mode we observed: 3 nearly-identical
      # error-handling chunks crowd out a fourth, distinct chunk
      # that has lower cosine but adds new info. MMR should pick
      # the duplicate ONCE then move to the distinct chunk.
      duplicate_text =
        "Error handling. HTTP status 403 ACCESS_DENIED. Method not found. " <>
        "Invalid token. Please contact support administrator."

      hits = [
        hit(duplicate_text,                                          0.92),
        hit(duplicate_text <> " (different doc, same boilerplate)",  0.91),
        hit(duplicate_text <> " (yet another doc)",                  0.90),
        hit("Workflow template add: REST method bizproc.workflow.template.add — fields TEMPLATE, MODULE_ID, ENTITY, DOCUMENT_TYPE, NAME.", 0.65)
      ]

      result = MMR.rerank(hits, 2, 0.5)
      texts  = Enum.map(result, & &1.chunk_text)

      # First slot: the highest-scoring representative.
      assert hd(texts) == duplicate_text

      # Second slot: NOT another near-duplicate. The "Workflow
      # template add" chunk has lower cosine but should beat the
      # 0.91 / 0.90 redundant clones once λ=0.5 kicks in.
      assert texts |> Enum.at(1) =~ "Workflow template add"
    end

    test "preserves hit map fields untouched (no MMR-internal keys leak out)" do
      hits = [
        %{chunk_text: "alpha tokens here", score: 0.9, source_id: 1, extra: :foo},
        %{chunk_text: "beta different content", score: 0.8, source_id: 2, extra: :bar}
      ]

      [first] = MMR.rerank(hits, 1, 0.6)

      refute Map.has_key?(first, :__mmr_tokens)
      assert first.chunk_text == "alpha tokens here"
      assert first.source_id == 1
      assert first.extra == :foo
    end
  end

  describe "tokens/1 + jaccard/2" do
    test "case-insensitive, punctuation-stripped, drops length-1 noise" do
      tokens = MMR.tokens("Hello, world! a b cat-dog.")
      assert MapSet.member?(tokens, "hello")
      assert MapSet.member?(tokens, "world")
      assert MapSet.member?(tokens, "cat")
      assert MapSet.member?(tokens, "dog")
      refute MapSet.member?(tokens, "a")
      refute MapSet.member?(tokens, "b")
    end

    test "jaccard: identical sets = 1.0, disjoint = 0.0" do
      a = MMR.tokens("the quick brown fox")
      b = MMR.tokens("the quick brown fox")
      assert MMR.jaccard(a, b) == 1.0

      c = MMR.tokens("alpha beta gamma")
      d = MMR.tokens("delta epsilon zeta")
      assert MMR.jaccard(c, d) == 0.0
    end

    test "jaccard on empty inputs is 0.0" do
      assert MMR.jaccard(MapSet.new(), MapSet.new()) == 0.0
      assert MMR.jaccard(MapSet.new(), MMR.tokens("hello world")) == 0.0
    end
  end
end
