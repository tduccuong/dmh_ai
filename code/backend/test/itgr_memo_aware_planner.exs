# Integration tests: memo-aware web-search planner.
#
# Per specs/commands.md § Memo-aware web planner:
#
#   The Confidant pre-step runs memo retrieval first, then passes
#   matched memo snippets into the web-search planner prompt. The
#   planner sees a `[saved memos]` block and Rule 0 instructs it to
#   return `SEARCH: NO` when a saved memo already answers — no
#   web search, no SearXNG, no homophone-confusion misfires.
#
# These tests pin the contract on the prompt shape and the
# memo_hits → planner relay. They use the LLM stub to capture the
# prompt verbatim.

defmodule Itgr.MemoAwarePlanner do
  use ExUnit.Case, async: false

  alias DmhAi.Web.Search, as: WebSearch

  setup do
    test_pid = self()

    T.stub_llm_call(fn _model, msgs, _opts ->
      user_prompt =
        case Enum.find(msgs, fn m -> Map.get(m, :role) == "user" end) do
          %{content: c} -> c
          _             -> ""
        end

      send(test_pid, {:planner_prompt, user_prompt})

      # Default: SEARCH: NO. Individual tests override this.
      {:ok, "SEARCH: NO"}
    end)

    :ok
  end

  test "planner prompt includes [saved memos] block when hits passed" do
    hits = [
      %{chunk_text: "con chó nhà hàng xóm màu tím và nặng 35kg"},
      %{chunk_text: "my favourite colour is teal"}
    ]

    WebSearch.generate_search_queries("con cho hang xom the nao?", [], :confidant, hits)

    assert_receive {:planner_prompt, prompt}, 1_000

    assert prompt =~ "[saved memos]"
    assert prompt =~ "These facts the user has already saved"
    assert prompt =~ "con chó nhà hàng xóm màu tím và nặng 35kg"
    assert prompt =~ "my favourite colour is teal"
    assert prompt =~ "[/saved memos]"
    # Rule 0 must be present so the planner respects the memo block.
    assert prompt =~ "RULE 0"
    assert prompt =~ "SAVED MEMO COVERAGE"
  end

  # Refute on the rendered-block opener, not the bare token —
  # `[saved memos]` also appears verbatim inside Rule 0 of the
  # template, so a literal-string refute is too coarse.
  @block_open "[saved memos]\nThese facts the user has already saved"

  test "planner prompt has no rendered [saved memos] block when memo_hits empty" do
    WebSearch.generate_search_queries("what is today's weather?", [], :confidant, [])

    assert_receive {:planner_prompt, prompt}, 1_000

    refute prompt =~ @block_open
  end

  test "planner prompt has no rendered [saved memos] block when arg omitted (default)" do
    WebSearch.generate_search_queries("anything", [], :confidant)

    assert_receive {:planner_prompt, prompt}, 1_000

    refute prompt =~ @block_open
  end

  test "Assistant pipeline never gets a [saved memos] block, even with hits" do
    # Belt-and-suspenders: the Assistant pipeline doesn't have memo
    # auto-retrieve at all; if a caller mistakenly passes hits, the
    # Assistant prompt template doesn't render them.
    hits = [%{chunk_text: "should not appear"}]
    WebSearch.generate_search_queries("Latest TSMC earnings", [], :assistant, hits)

    assert_receive {:planner_prompt, prompt}, 1_000

    refute prompt =~ "should not appear"
  end

  test "planner returns :no_search when LLM responds SEARCH: NO" do
    hits = [%{chunk_text: "con chó nhà hàng xóm màu tím và nặng 35kg"}]

    # Stub already returns SEARCH: NO via setup.
    assert {:no_search} =
             WebSearch.generate_search_queries("what colour is the dog?", [], :confidant, hits)
  end

  test "planner returns :search when LLM responds SEARCH: YES (memo doesn't cover)" do
    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "SEARCH: YES\nCATEGORY: NEWS\nLANG:en TSMC earnings May 2026"}
    end)

    hits = [%{chunk_text: "my favourite colour is teal"}]

    assert {:search, _category, queries} =
             WebSearch.generate_search_queries("Latest TSMC earnings?", [], :confidant, hits)

    assert is_list(queries)
    assert length(queries) >= 1
  end

  test "string keys in memo hits also work (Map.get fallback)" do
    # `decrypt_memo_hit` returns atom-keyed maps in production, but
    # any string-keyed payload from a different code path should
    # also render correctly.
    hits = [%{"chunk_text" => "string-keyed memo content"}]

    WebSearch.generate_search_queries("anything", [], :confidant, hits)

    assert_receive {:planner_prompt, prompt}, 1_000

    assert prompt =~ "string-keyed memo content"
  end
end
