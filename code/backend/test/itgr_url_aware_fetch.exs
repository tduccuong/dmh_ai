# Tests for WebSearch.detect_category prompt rules.

defmodule Itgr.WebSearchDetect do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.WebSearch

  describe "detect_category" do
    test "expensive rule present in prompt" do
      test_pid = self()

      T.stub_llm_call(fn _model, [%{content: prompt}], _opts ->
        send(test_pid, {:saw, prompt})
        {:ok, "NO"}
      end)

      WebSearch.detect_category("translate 'hello' to Spanish", "", self())
      assert_receive {:saw, prompt}
      assert prompt =~ "Web search is EXPENSIVE"
    end

    test "returns :no_search on NO response" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "NO: translation task"} end)
      assert :no_search = WebSearch.detect_category("translate 'hello'", "", self())
    end

    test "returns {:search, category} on WEB response" do
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "WEB: needs live data"} end)
      assert {:search, "news,general"} = WebSearch.detect_category("latest AI news", "", self())
    end
  end
end
