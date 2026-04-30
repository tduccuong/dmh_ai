# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.

defmodule Itgr.Chunker do
  use ExUnit.Case, async: true

  alias Dmhai.VectorDB.Chunker

  describe "split/2" do
    test "blank input returns empty list" do
      assert Chunker.split("") == []
      assert Chunker.split("   \n\n  ") == []
    end

    test "small text fits in one chunk" do
      text = "hello world"
      assert [^text] = Chunker.split(text, max_tokens: 100, overlap_tokens: 10)
    end

    test "splits on paragraphs first when present" do
      text = String.duplicate("a", 600) <> "\n\n" <> String.duplicate("b", 600)
      chunks = Chunker.split(text, max_tokens: 200, overlap_tokens: 20)
      assert length(chunks) >= 2
      assert Enum.all?(chunks, &is_binary/1)
    end

    test "overlap preserves trailing parts of previous chunk" do
      parts = for i <- 1..30, do: "sentence-#{i}"
      text = Enum.join(parts, " ")

      [first, second | _] = Chunker.split(text, max_tokens: 8, overlap_tokens: 4)
      assert is_binary(first) and is_binary(second)
      # Some piece from the tail of `first` should appear in `second`.
      tail_word = first |> String.split() |> List.last()
      assert tail_word != ""
      assert String.contains?(second, tail_word)
    end

    test "hard splits whitespace-free oversized strings" do
      text = String.duplicate("x", 4_000)
      chunks = Chunker.split(text, max_tokens: 100, overlap_tokens: 10)
      assert length(chunks) >= 2
      # Each chunk's byte size respects roughly 4 * max_tokens.
      Enum.each(chunks, fn c -> assert byte_size(c) <= 100 * 4 end)
    end

    test "concatenated chunks cover the original input (sans overlap dedup)" do
      text = """
      Chapter one. The first paragraph has several sentences. We need them.

      Chapter two. Another body of text follows here. With more lines.
      """ |> String.duplicate(5)

      chunks = Chunker.split(text, max_tokens: 60, overlap_tokens: 8)
      joined = Enum.join(chunks, " ")

      # Allow for repeated overlap content; we just want every key
      # phrase present somewhere in the chunked output.
      assert String.contains?(joined, "Chapter one")
      assert String.contains?(joined, "Chapter two")
      assert String.contains?(joined, "We need them")
    end
  end

  describe "token_count/1" do
    test "byte-pair approximation: 4 chars ≈ 1 token" do
      assert Chunker.token_count("") == 0
      assert Chunker.token_count("abcd") == 1
      assert Chunker.token_count(String.duplicate("x", 400)) == 100
    end
  end
end
