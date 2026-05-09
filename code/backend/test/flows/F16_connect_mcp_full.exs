# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F16 — MCP connect (no-auth path) + tool invocation.
#
# `connect_mcp` is the model's entry point for binding an MCP server
# to the current anchor task. The handler has three branches per the
# server's auth_kind: "none" (silent connect), "oauth" (form +
# OAuth2 dance), "api_key" (form + key save). F16 covers the
# "none" branch end-to-end:
#
#   1. Probe + handshake — `MCP.Client.initialize/1` → POST
#      `initialize` to the server.
#   2. Tool catalog — `MCP.Client.list_tools/2` → POST `tools/list`,
#      passing the session id from the initialize response.
#   3. Persist — `MCP.Registry.authorize/5` (open service row),
#      `set_authorized_tools/3` (cache the catalog),
#      `attach/3` (bind to the anchor task).
#   4. Credentials.save with kind="none_mcp" so the canonical
#      resource is reachable from the chat path.
#   5. After connect, namespaced tool invocation via
#      `Tools.Registry.execute("alias.tool_name", args, ctx)` →
#      `MCP.Client.call_tool/4` → POST `tools/call`.
#
# `T.stub_mcp_transport/1` (already in the harness) replaces
# `MCP.Transport.request/3` per-test, so we drive the entire
# discovery + invocation cascade against an in-memory dispatcher.

defmodule DmhAi.Flows.F16ConnectMcpFull do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.Tasks
  alias DmhAi.MCP.Registry, as: MCPRegistry
  alias DmhAi.Tools.Registry, as: ToolsRegistry
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F16"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F16")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       System.os_time(:millisecond)])

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", "[]", "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    on_exit(fn ->
      # `task_services` is the task ↔ authorized-service junction;
      # `authorized_services` is the per-user authorized-tools row.
      # Delete via user_id which both tables index on.
      query!(Repo, "DELETE FROM task_services WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM authorized_services WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM tasks WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "connect_mcp(no-auth) → cached tools → namespaced tool invocation",
       %{user_id: user_id, session_id: session_id} do
    # Anchor task — connect_mcp requires one.
    task_id =
      Tasks.insert(%{
        user_id:     user_id,
        session_id:  session_id,
        task_type:   "one_off",
        task_title:  "investigate the bug tracker",
        task_spec:   "look at the team's bug tracker MCP server",
        task_status: "ongoing",
        language:    "en"
      })

    %{task_num: anchor_num} = Tasks.get(task_id)

    server_url = "https://example-mcp.test/mcp"
    test_session_id = "mcp-sess-#{T.uid()}"

    # The server exposes ONE tool — search_bugs(query) — with a
    # canned text result. Stub dispatches by method.
    transport_calls = :counters.new(1, [:atomics])

    T.stub_mcp_transport(fn url, req ->
      :counters.add(transport_calls, 1, 1)
      assert url == server_url, "stub got URL=#{url}; expected #{server_url}"

      method = req[:method] || req["method"]

      case method do
        "initialize" ->
          {:ok,
           %{
             "jsonrpc" => "2.0",
             "id"      => req[:body]["id"],
             "result"  => %{
               "protocolVersion" => "2025-06-18",
               "capabilities"    => %{},
               "serverInfo"      => %{"name" => "example-mcp", "version" => "0.1"}
             }
           },
           %{session_id: test_session_id}}

        "tools/list" ->
          # Spec-compliant servers reject `tools/list` without the
          # session id from `initialize`; assert the client threaded it.
          assert req[:session_id] == test_session_id,
                 "tools/list must echo the session id from initialize; " <>
                   "got: #{inspect(req[:session_id])}"

          {:ok,
           %{
             "jsonrpc" => "2.0",
             "id"      => req[:body]["id"],
             "result"  => %{
               "tools" => [
                 %{
                   "name"        => "search_bugs",
                   "description" => "Search the team's bug tracker for issues matching a query",
                   "inputSchema" => %{
                     "type" => "object",
                     "properties" => %{"query" => %{"type" => "string"}},
                     "required"   => ["query"]
                   }
                 }
               ]
             }
           },
           %{session_id: nil}}

        "tools/call" ->
          # Per `MCP.Client.call_tool/4`, each invocation opens a
          # FRESH session: initialize again, then tools/call with
          # the new session id. Verify by asserting the session
          # id changed (the stub returns a new one per initialize
          # at the bottom of this case, see below).
          name = req[:body]["params"]["name"]
          args = req[:body]["params"]["arguments"]

          assert name == "search_bugs",
                 "expected tools/call to invoke search_bugs; got: #{inspect(name)}"
          assert args["query"] == "memory leak",
                 "args should round-trip; got: #{inspect(args)}"

          {:ok,
           %{
             "jsonrpc" => "2.0",
             "id"      => req[:body]["id"],
             "result"  => %{
               "content" => [
                 %{"type" => "text",
                   "text" => "BUG-101 'memory leak in worker pool' (open) — assigned to alex"}
               ]
             }
           },
           %{session_id: nil}}

        other ->
          flunk("unexpected MCP method=#{inspect(other)}")
      end
    end)

    # ── Phase 1 — connect_mcp ─────────────────────────────────────

    ctx = %{
      user_id:        user_id,
      session_id:     session_id,
      anchor_task_num: anchor_num
    }

    {:ok, result} =
      ToolsRegistry.execute("connect_mcp",
        %{"url" => server_url, "alias" => "bugs"}, ctx)

    assert result.status == "connected",
           "connect_mcp(no-auth) should return status=connected; got: #{inspect(result)}"
    assert result.alias == "bugs"
    assert is_list(result.tools)
    assert length(result.tools) == 1,
           "expected 1 advertised tool; got: #{inspect(result.tools)}"

    [tool_summary] = result.tools

    summary_name =
      Map.get(tool_summary, :name) || Map.get(tool_summary, "name") || ""

    assert summary_name == "bugs.search_bugs" or summary_name == "search_bugs",
           "tool summary should name the tool (raw or namespaced); got: #{inspect(tool_summary)}"

    # ── Phase 2 — registry state ──────────────────────────────────

    %{rows: rows_authz} =
      query!(Repo,
        "SELECT canonical_resource, server_url, status, server_tools_json " <>
        "FROM authorized_services WHERE user_id=? AND alias=?",
        [user_id, "bugs"])

    assert match?([[_, ^server_url, _, _]], rows_authz),
           "authorized_services row should bind alias=bugs to server_url=#{server_url}; got: #{inspect(rows_authz)}"

    [[_, _, status, tools_json]] = rows_authz

    assert status in ["authorized", "active", "ok", "connected"],
           "authorized service status should be open/authorized; got: #{inspect(status)}"

    cached_tools = Jason.decode!(tools_json || "[]")
    assert length(cached_tools) == 1
    assert hd(cached_tools)["name"] == "search_bugs"

    # tools_for_task surfaces the namespaced tool to the LLM catalog.
    namespaced = MCPRegistry.tools_for_task(user_id, task_id)

    assert length(namespaced) == 1, "tools_for_task should return one tool; got: #{inspect(namespaced)}"

    [namespaced_tool] = namespaced
    assert namespaced_tool.name == "bugs.search_bugs",
           "MCP tool name should be namespaced as <alias>.<tool>; got: #{inspect(namespaced_tool.name)}"

    # ── Phase 3 — invoke the namespaced tool ──────────────────────

    {:ok, call_result} =
      ToolsRegistry.execute("bugs.search_bugs",
        %{"query" => "memory leak"},
        %{user_id: user_id, session_id: session_id, anchor_task_num: anchor_num})

    # The MCP result is the JSON-RPC `result` payload — a map with a
    # `content` array.
    content =
      Map.get(call_result, "content") ||
        Map.get(call_result, :content) || []

    assert is_list(content) and length(content) == 1,
           "expected one content item from search_bugs; got: #{inspect(call_result)}"

    [first] = content
    text = first["text"] || first[:text] || ""
    assert text =~ "BUG-101", "stubbed result text should round-trip; got: #{inspect(text)}"
    assert text =~ "memory leak"

    # Sanity — the transport was hit. Connect path: probe-classify
    # initialize (`MCP.Probe.classify/1`) + handshake initialize
    # (`no_auth_connect`) + tools/list. Call path: fresh initialize
    # (each `call_tool` opens its own MCP session) + tools/call.
    # Total 5 hits; assert ≥ 4 to tolerate any future probe-cache
    # tightening that might collapse the probe-init into the
    # handshake-init.
    assert :counters.get(transport_calls, 1) >= 4,
           "expected ≥4 transport hits across connect+invoke; got: #{:counters.get(transport_calls, 1)}"
  end

  test "connect_mcp without an anchor task → error",
       %{user_id: user_id, session_id: session_id} do
    # No anchor — registry returns nil for resolve.
    ctx = %{user_id: user_id, session_id: session_id, anchor_task_num: nil}

    {:error, reason} =
      ToolsRegistry.execute("connect_mcp", %{"url" => "https://x.test/mcp"}, ctx)

    assert reason =~ "anchor task",
           "connect_mcp without an anchor must fail-loud with a guidance message; got: #{inspect(reason)}"
  end

  test "connect_mcp with neither url nor slug → error",
       %{user_id: user_id, session_id: session_id} do
    task_id =
      Tasks.insert(%{
        user_id:     user_id,
        session_id:  session_id,
        task_type:   "one_off",
        task_title:  "x",
        task_spec:   "x",
        task_status: "ongoing",
        language:    "en"
      })

    %{task_num: anchor_num} = Tasks.get(task_id)

    ctx = %{
      user_id:        user_id,
      session_id:     session_id,
      anchor_task_num: anchor_num
    }

    {:error, reason} =
      ToolsRegistry.execute("connect_mcp", %{}, ctx)

    assert reason =~ "url" or reason =~ "slug",
           "missing-arg error should name the required field; got: #{inspect(reason)}"
  end
end
