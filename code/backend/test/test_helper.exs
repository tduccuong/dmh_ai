ExUnit.start(timeout: 60_000)

# Skip `@tag :network` tests by default — they make real HTTP calls
# (LLM round-trips, web fetches against live sites) and depend on
# credentials / external uptime / API-key budget. Run them explicitly:
#   mix test --only network
ExUnit.configure(exclude: [:network, :known_design_bug])

defmodule T do
  @moduledoc "Shared test helpers."

  def uid, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  # A session_data map matching the shape returned by DB queries.
  def session_data(opts \\ []) do
    %{
      "id"       => Keyword.get(opts, :id, uid()),
      "user_id"  => Keyword.get(opts, :user_id, uid()),
      "mode"     => Keyword.get(opts, :mode, "confidant"),
      "messages" => Keyword.get(opts, :messages, []),
      "context"  => Keyword.get(opts, :context, nil)
    }
  end

  def user_msg(content),      do: %{"role" => "user",      "content" => content}
  def assistant_msg(content), do: %{"role" => "assistant", "content" => content}

  def conversation(n) do
    Enum.flat_map(1..n, fn i ->
      [user_msg("question #{i}"), assistant_msg("answer #{i}")]
    end)
  end

  # Install a synchronous LLM.call stub for the duration of a test.
  # `fun` receives (model_str, messages, opts) and returns
  # {:ok, text} | {:error, reason}.
  def stub_llm_call(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__llm_call_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_call_stub__) end)
  end

  # Install a streaming LLM stub for the duration of a test.
  # `fun` receives (model_str, messages, reply_pid, opts).
  def stub_llm_stream(fun) when is_function(fun, 4) do
    Application.put_env(:dmh_ai, :__llm_stream_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_stream_stub__) end)
  end

  # Install a deeper transport stub at `LLM.do_stream_request/7` /
  # `do_call_request/6` — exercises the pool rotation/retry logic against
  # deterministic per-account transport outcomes. `fun` receives
  # `(url, headers, body, %{kind: :stream | :call, model, …})`.
  def stub_llm_request(fun) when is_function(fun, 4) do
    Application.put_env(:dmh_ai, :__llm_request_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_request_stub__) end)
  end

  # Install a stub for `DmhAi.Web.Search.call_search_engine/3` — bypasses
  # SearXNG + page-fetcher in confidant's web pre-step. `fun` receives
  # `(queries, category, opts)` and returns `%{snippets: [], pages: []}`.
  def stub_web_search(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__web_search_engine_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__web_search_engine_stub__) end)
  end
end
