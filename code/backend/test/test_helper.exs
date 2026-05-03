ExUnit.start(timeout: 60_000)

# Seed the memo master key once for the whole suite. Tests don't go
# through the on-disk file path, so this avoids touching /data/secrets/
# (which may not be writable as the test user) and gives every test a
# stable, in-memory master key. See specs/memo_encryption.md.
DmhAi.MemoCrypto.MasterKey.put(:crypto.strong_rand_bytes(32))

# Skip `@tag :network` tests by default — they make real HTTP calls
# (LLM round-trips, MCP discovery, web fetches against live sites)
# and depend on credentials / external uptime / API-key budget. Run
# them explicitly with:
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
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_call(fun) when is_function(fun, 3) do
    Application.put_env(:dmh_ai, :__llm_call_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_call_stub__) end)
  end

  # Install a streaming LLM stub for the duration of a test.
  # `fun` receives (model_str, messages, reply_pid, opts) and returns
  # {:ok, text} | {:ok, {:tool_calls, calls}} | {:error, reason}.
  def stub_llm_stream(fun) when is_function(fun, 4) do
    Application.put_env(:dmh_ai, :__llm_stream_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__llm_stream_stub__) end)
  end

  # Install a stub for `DmhAi.MCP.Transport.request/3`. `fun` receives
  # (server_url, %{method, body, headers, auth, session_id}) and must
  # return one of:
  #   {:ok, body :: map(), %{session_id: String.t() | nil}}
  #   {:error, {:status, integer(), term()}}
  #   {:error, {:network, term()}}
  # Used by tests that drive the discovery cascade or per-tool calls
  # without spinning up a real MCP server.
  def stub_mcp_transport(fun) when is_function(fun, 2) do
    Application.put_env(:dmh_ai, :__mcp_transport_stub__, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:dmh_ai, :__mcp_transport_stub__) end)
  end

  # Build a normalised tool-call list (as returned by LLM.normalize_tool_calls).
  def tool_call(name, args \\ %{}, id \\ nil) do
    %{"id" => id || uid(), "function" => %{"name" => name, "arguments" => args}}
  end

  def tool_call_with_sig(name, args \\ %{}) do
    %{"id" => uid(),
      "function" => %{"name" => name, "arguments" => args, "thought_signature" => "sig_#{uid()}"}}
  end

  # ─── Memo encryption helpers ──────────────────────────────────────────────
  #
  # Memo writes/reads use a master-key-wrapped MMK persisted in
  # `users.memo_wrapped_mmk` (see specs/memo_encryption.md). Tests
  # that exercise memo paths should call `install_memo_key/1` to
  # seed both the user row and the wrap. The master key itself is
  # pre-seeded once per suite in test_helper.exs.

  @doc "Generate a fresh 32-byte MMK suitable for direct ingest tests."
  def memo_test_key, do: :crypto.strong_rand_bytes(32)

  @doc """
  Make `user_id` ready for memo ops:
    * upsert a placeholder `users` row if absent (so `ensure_memo_key`
      has a row to UPDATE),
    * call `UserAgent.ensure_memo_key/1` which generates a fresh MMK
      and persists a V2 master-key-wrapped row,
    * register cleanup to wipe the cache + DB row on test exit.

  Returns the resulting 32-byte MMK so tests that bypass the tools
  layer can encrypt directly via `MemoCrypto.encrypt_chunk/4`.
  """
  def install_memo_key(user_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    %{rows: existing} =
      query!(DmhAi.Repo, "SELECT id FROM users WHERE id=?", [user_id])

    inserted_here? =
      case existing do
        [_ | _] ->
          false

        _ ->
          # Use a unique fake email to avoid the UNIQUE(email) collision.
          email = "test-#{user_id}@test.invalid"
          query!(DmhAi.Repo, """
          INSERT INTO users (id, email, name, password_hash, role, created_at)
          VALUES (?,?,?,?,?,?)
          """, [user_id, email, "test", "x:y", "user", :os.system_time(:second)])
          true
      end

    {:ok, mmk} = DmhAi.Agent.UserAgent.ensure_memo_key(user_id)

    ExUnit.Callbacks.on_exit(fn ->
      DmhAi.Agent.UserAgent.wipe_memo_key(user_id)

      if inserted_here? do
        query!(DmhAi.Repo, "DELETE FROM users WHERE id=?", [user_id])
      end
    end)

    mmk
  end
end
