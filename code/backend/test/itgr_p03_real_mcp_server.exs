# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03RealMCPServerTest do
  @moduledoc """
  Pins the in-process real MCPServer end-to-end:

    * MCP JSON-RPC envelope handling (initialize / tools/list /
      tools/call) over HTTP.
    * FunctionSpec-driven functions (4 of 6 GW functions).
    * Custom-handler functions (gmail.search fan-out,
      gcal.find_free_slots slot computation, drive.upload
      multipart) — same stub catches all sub-calls because
      `GoogleWorkspace.MCPHandler` routes every HTTP request
      through `RestBridge.simple_get/3` / `simple_post/3` /
      `raw_request/2`.
    * Bearer token forwarding from the MCP request's
      Authorization header to every outbound vendor REST call.
    * Per-function request shape (URL, method, body) matches the
      vendor-grounded comments in
      `Connectors.GoogleWorkspace.MCPHandler`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.GoogleWorkspace.MCPHandler
  alias DmhAi.Connectors.MCPServer
  alias DmhAi.Connectors.MCPServer.Registry, as: MCPRegistry

  setup do
    MCPRegistry.reset()
    MCPRegistry.put(MCPHandler.handler())

    {:ok, sock} = :gen_tcp.listen(0, [:binary])
    {:ok, {_addr, port}} = :inet.sockname(sock)
    :gen_tcp.close(sock)

    {:ok, server_pid} = MCPServer.start_link(port: port)

    parent = self()

    # Stub intercepts every outbound REST call from the handler.
    # The stub runs INSIDE the Plug request process — it sends
    # `{:rest_call, method, opts, stub_pid}` to the test, then
    # blocks waiting for a `:reply` message routed back. The test
    # does `assert_receive` on the rest_call envelope, captures
    # `stub_pid`, and `send(stub_pid, {:reply, …})` to unblock the
    # handler with the synthetic vendor response.
    Application.put_env(:dmh_ai, :__rest_bridge_http_stub__, fn method, opts ->
      send(parent, {:rest_call, method, opts, self()})

      receive do
        {:reply, ^method, response} -> response
      after
        1_000 -> {:error, :stub_timeout}
      end
    end)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__rest_bridge_http_stub__)
      MCPRegistry.reset()
      if Process.alive?(server_pid), do: Process.exit(server_pid, :shutdown)
    end)

    {:ok, %{port: port}}
  end

  defp url(port, slug), do: "http://127.0.0.1:#{port}/#{slug}"

  defp post_jsonrpc(port, body, slug \\ "google_workspace", bearer \\ "test-bearer") do
    Req.post!(
      url:     url(port, slug),
      json:    body,
      headers: [{"authorization", "Bearer #{bearer}"}]
    )
  end

  describe "MCP JSON-RPC envelope" do
    test "initialize returns server info + protocolVersion", %{port: port} do
      resp = post_jsonrpc(port, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

      assert resp.status == 200
      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => result} = resp.body
      assert result["protocolVersion"] == "2024-11-05"
      assert result["serverInfo"]["name"] == "dmh-ai-mcp-google_workspace"
      assert result["serverInfo"]["function_count"] == 6
    end

    test "tools/list returns 6 GW functions by name", %{port: port} do
      resp = post_jsonrpc(port, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
      tools = resp.body["result"]["tools"]
      names = Enum.map(tools, & &1["name"]) |> Enum.sort()

      assert names == [
               "drive.list",
               "drive.upload",
               "gcal.create_event",
               "gcal.find_free_slots",
               "gmail.search",
               "gmail.send"
             ]
    end

    test "unknown slug returns -32601", %{port: port} do
      resp = post_jsonrpc(port, %{"jsonrpc" => "2.0", "id" => 3, "method" => "initialize"},
                          "unknown_connector")
      assert resp.body["error"]["code"] == -32601
    end

    test "unknown function returns -32601", %{port: port} do
      Task.start(fn ->
        post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "nonexistent.function", "arguments" => %{}}
        })
      end)

      # Unknown function is rejected BEFORE any HTTP stub call.
      refute_receive {:rest_call, _, _}, 200
    end
  end

  describe "gmail.search — fan-out (list + per-id metadata gets)" do
    test "list request shape + metadata sub-calls + composed reply", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 10,
          "method" => "tools/call",
          "params" => %{
            "name" => "gmail.search",
            "arguments" => %{"query" => "is:unread", "limit" => 2}
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      # 1. List call — assert URL + query + bearer + reply 2 ids.
      assert_receive {:rest_call, :get, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/gmail/v1/users/me/messages"
      query = Keyword.get(opts, :params) || []
      assert {"q", "is:unread"} in query
      assert {"maxResults", 2} in query
      assert [{"authorization", "Bearer test-bearer"}] = Keyword.get(opts, :headers)
      send(stub_pid, {:reply, :get,
                      {:ok, 200, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]}}})

      # 2. Metadata call for m1.
      assert_receive {:rest_call, :get, opts1, stub_pid1}, 1_000
      assert Keyword.get(opts1, :url) == "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1"
      send(stub_pid1, {:reply, :get,
                       {:ok, 200, %{
                         "id" => "m1",
                         "snippet" => "first message snippet",
                         "payload" => %{"headers" => [
                           %{"name" => "From",    "value" => "alice@example.test"},
                           %{"name" => "Subject", "value" => "Q2 numbers"}
                         ]}
                       }}})

      # 3. Metadata call for m2.
      assert_receive {:rest_call, :get, opts2, stub_pid2}, 1_000
      assert Keyword.get(opts2, :url) == "https://gmail.googleapis.com/gmail/v1/users/me/messages/m2"
      send(stub_pid2, {:reply, :get,
                       {:ok, 200, %{
                         "id" => "m2",
                         "snippet" => "second snippet",
                         "payload" => %{"headers" => [
                           %{"name" => "From",    "value" => "bob@example.test"},
                           %{"name" => "Subject", "value" => "Re: Vertrag"}
                         ]}
                       }}})

      assert_receive {:final_resp, resp}, 2_000
      assert %{"result" => %{"content" => [%{"text" => json}]}} = resp.body
      decoded = Jason.decode!(json)
      assert length(decoded["messages"]) == 2
      assert Enum.map(decoded["messages"], & &1["from"]) ==
               ["alice@example.test", "bob@example.test"]
      assert Enum.map(decoded["messages"], & &1["subject"]) ==
               ["Q2 numbers", "Re: Vertrag"]
      assert decoded["queried"] == "is:unread"
    end
  end

  describe "gmail.send — MIME composition + base64url" do
    test "request body has base64url-encoded RFC-2822 MIME", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 20,
          "method" => "tools/call",
          "params" => %{
            "name" => "gmail.send",
            "arguments" => %{
              "to"      => "alice@example.test",
              "subject" => "Hello",
              "body"    => "Hi Alice"
            }
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :post, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/gmail/v1/users/me/messages/send"
      assert %{"raw" => raw} = Keyword.get(opts, :json)
      mime = Base.url_decode64!(raw, padding: false)
      assert mime =~ "To: alice@example.test"
      assert mime =~ "Subject: Hello"
      assert mime =~ "Hi Alice"

      send(stub_pid, {:reply, :post,
                      {:ok, 200, %{"id" => "sent-msg-1", "threadId" => "t-1"}}})

      assert_receive {:final_resp, _resp}, 1_000
    end
  end

  describe "gcal.find_free_slots — busy → free computation" do
    test "freebusy.query is called, slots computed from busy intervals", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 30,
          "method" => "tools/call",
          "params" => %{
            "name" => "gcal.find_free_slots",
            "arguments" => %{
              "duration_min" => 30,
              "between_from" => "2026-05-21T09:00:00+00:00",
              "between_to"   => "2026-05-21T11:00:00+00:00"
            }
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :post, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/calendar/v3/freeBusy"
      assert %{"timeMin" => "2026-05-21T09:00:00+00:00"} = Keyword.get(opts, :json)

      # One busy block 09:30-10:00 → free slots 09:00-09:30 and 10:00-10:30.
      send(stub_pid, {:reply, :post,
                      {:ok, 200, %{
                        "calendars" => %{
                          "primary" => %{
                            "busy" => [%{
                              "start" => "2026-05-21T09:30:00+00:00",
                              "end"   => "2026-05-21T10:00:00+00:00"
                            }]
                          }
                        }
                      }}})

      assert_receive {:final_resp, resp}, 1_000
      decoded = Jason.decode!(resp.body["result"]["content"] |> hd() |> Map.get("text"))
      slots = decoded["slots"]
      assert is_list(slots) and length(slots) >= 1
      assert hd(slots)["duration_min"] == 30
    end
  end

  describe "gcal.create_event — title→summary translation" do
    test "request body uses `summary` not `title`", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 40,
          "method" => "tools/call",
          "params" => %{
            "name" => "gcal.create_event",
            "arguments" => %{
              "title"     => "Customer review",
              "start"     => "2026-05-21T14:00:00+02:00",
              "end"       => "2026-05-21T15:00:00+02:00",
              "attendees" => ["alice@example.test"]
            }
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :post, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/calendar/v3/calendars/primary/events"

      body = Keyword.get(opts, :json)
      assert body["summary"] == "Customer review"
      refute Map.has_key?(body, "title")
      assert body["start"]["dateTime"] == "2026-05-21T14:00:00+02:00"
      assert body["attendees"] == [%{"email" => "alice@example.test"}]

      send(stub_pid, {:reply, :post, {:ok, 200, %{"id" => "ev-1", "htmlLink" => "https://cal/ev-1"}}})

      assert_receive {:final_resp, resp}, 1_000
      decoded = Jason.decode!(resp.body["result"]["content"] |> hd() |> Map.get("text"))
      assert decoded["event_id"] == "ev-1"
    end
  end

  describe "drive.list — folder_id → `q` clause" do
    test "GET files with q='<id>' in parents", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 50,
          "method" => "tools/call",
          "params" => %{
            "name" => "drive.list",
            "arguments" => %{"folder_id" => "folder-XYZ"}
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :get, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/drive/v3/files"
      query = Keyword.get(opts, :params) || []
      assert {"q", "'folder-XYZ' in parents"} in query

      send(stub_pid, {:reply, :get,
                      {:ok, 200, %{"files" => [%{"id" => "f1", "name" => "a.txt"}]}}})

      assert_receive {:final_resp, resp}, 1_000
      decoded = Jason.decode!(resp.body["result"]["content"] |> hd() |> Map.get("text"))
      assert decoded["items"] == [%{"id" => "f1", "name" => "a.txt"}]
    end
  end

  describe "drive.upload — multipart shape" do
    test "POST to /upload/drive/v3/files?uploadType=multipart with multipart body", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 60,
          "method" => "tools/call",
          "params" => %{
            "name" => "drive.upload",
            "arguments" => %{
              "name"      => "Notes.txt",
              "content"   => "Hello world",
              "mime_type" => "text/plain"
            }
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :post, opts, stub_pid}, 1_000
      assert Keyword.get(opts, :url) =~ "/upload/drive/v3/files?uploadType=multipart"
      headers = Keyword.get(opts, :headers)
      assert Enum.any?(headers, fn {k, v} ->
               k == "content-type" and String.starts_with?(v, "multipart/related")
             end)
      body = Keyword.get(opts, :body)
      assert is_binary(body)
      assert body =~ "Hello world"
      assert body =~ ~s("name":"Notes.txt")

      send(stub_pid, {:reply, :post,
                      {:ok, 200, %{"id" => "fid-1", "name" => "Notes.txt", "mimeType" => "text/plain"}}})

      assert_receive {:final_resp, resp}, 1_000
      decoded = Jason.decode!(resp.body["result"]["content"] |> hd() |> Map.get("text"))
      assert decoded["file_id"] == "fid-1"
    end
  end

  describe "error mapping" do
    test "vendor 401 → MCP JSON-RPC -32000 'Vendor error: unauthorised'", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 70,
          "method" => "tools/call",
          "params" => %{
            "name" => "drive.list",
            "arguments" => %{}
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :get, _opts, stub_pid}, 1_000
      send(stub_pid, {:reply, :get, {:ok, 401, %{"error" => "invalid token"}}})

      assert_receive {:final_resp, resp}, 1_000
      assert resp.body["error"]["code"] == -32000
      assert resp.body["error"]["message"] =~ "unauthorised"
    end

    test "vendor 429 → 'Vendor error: rate_limited'", %{port: port} do
      reply_pid = self()

      Task.start(fn ->
        resp = post_jsonrpc(port, %{
          "jsonrpc" => "2.0",
          "id" => 71,
          "method" => "tools/call",
          "params" => %{
            "name" => "drive.list",
            "arguments" => %{}
          }
        })

        send(reply_pid, {:final_resp, resp})
      end)

      assert_receive {:rest_call, :get, _opts, stub_pid}, 1_000
      send(stub_pid, {:reply, :get, {:ok, 429, %{}}})

      assert_receive {:final_resp, resp}, 1_000
      assert resp.body["error"]["message"] =~ "rate_limited"
    end
  end
end
