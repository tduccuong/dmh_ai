ExUnit.start(timeout: 60_000)

# Skip `@tag :network` tests by default — they make real HTTP calls
# (LLM round-trips, MCP discovery, web fetches against live sites)
# and depend on credentials / external uptime / API-key budget. Run
# them explicitly with:
#   mix test --only network
# or per-file:
#   mix test test/itgr_mcp_huggingface.exs --only network
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
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_call(fun) when is_function(fun, 3) do
    Application.put_env(:dmhai, :__llm_call_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmhai, :__llm_call_stub__) end)
  end

  # Install a streaming LLM stub for the duration of a test.
  # `fun` receives (model_str, messages, reply_pid, opts) and returns
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_stream(fun) when is_function(fun, 4) do
    Application.put_env(:dmhai, :__llm_stream_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmhai, :__llm_stream_stub__) end)
  end

  # Install a stub for `Dmhai.MCP.Transport.request/3`. `fun` receives
  # (server_url, %{method, body, headers, auth, session_id}) and must
  # return one of:
  #   {:ok, body :: map(), %{session_id: String.t() | nil}}
  #   {:error, {:status, integer(), term()}}
  #   {:error, {:network, term()}}
  # Used by tests that drive the discovery cascade or per-tool calls
  # without spinning up a real MCP server.
  def stub_mcp_transport(fun) when is_function(fun, 2) do
    Application.put_env(:dmhai, :__mcp_transport_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmhai, :__mcp_transport_stub__) end)
  end

  # Build a normalised tool-call list (as returned by LLM.normalize_tool_calls).
  def tool_call(name, args \\ %{}, id \\ nil) do
    %{"id" => id || uid(), "function" => %{"name" => name, "arguments" => args}}
  end

  def tool_call_with_sig(name, args \\ %{}) do
    %{"id" => uid(),
      "function" => %{"name" => name, "arguments" => args, "thought_signature" => "sig_#{uid()}"}}
  end
end
