# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03RestBridgeHttpTest do
  @moduledoc """
  Pins the seam between `RestBridge` and the real `Req` HTTP
  client. Every other P0.3 test stubs `__rest_bridge_http_stub__`
  and short-circuits before `Req.request/1` ever runs, so Req's
  own option-name validation is never exercised — that's how the
  `:query`-vs-`:params` typo lived in production silently while
  every test was green.

  This file is the lone counterweight: it runs `RestBridge` AGAINST
  Req AGAINST a localhost Plug stub. If any `RestBridge` callsite
  passes an option name Req doesn't recognise, this test fails
  immediately.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Connectors.MCPServer.RestBridge

  defmodule EchoPlug do
    @moduledoc false
    use Elixir.Plug.Router

    plug :match
    plug Elixir.Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    # Echoes the request shape so the test can assert on path,
    # method, query, headers, JSON body — without us needing a
    # separate side-channel.
    match _ do
      auth =
        Elixir.Plug.Conn.get_req_header(conn, "authorization")
        |> List.first()
        |> case do
          nil -> ""
          h   -> h
        end

      body = %{
        "method"        => conn.method |> String.downcase(),
        "path"          => conn.request_path,
        "query_string"  => conn.query_string,
        "authorization" => auth,
        "json_body"     => conn.body_params
      }

      conn
      |> Elixir.Plug.Conn.put_resp_content_type("application/json")
      |> Elixir.Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    # Clear the stub so Req actually runs. Other test files set it;
    # we must reset to its absent state.
    Application.delete_env(:dmh_ai, :__rest_bridge_http_stub__)

    {:ok, sock} = :gen_tcp.listen(0, [:binary])
    {:ok, {_addr, port}} = :inet.sockname(sock)
    :gen_tcp.close(sock)

    {:ok, _pid} = Bandit.start_link(plug: EchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: port)

    {:ok, %{base: "http://127.0.0.1:#{port}"}}
  end

  describe "RestBridge.simple_get/3" do
    test "real Req call — bearer forwarded, query params serialise into URL", %{base: base} do
      ctx = %{bearer_token: "test-bearer-123"}

      {:ok, body} =
        RestBridge.simple_get(
          base <> "/some/path",
          [{"q", "from:vendor"}, {"maxResults", 25}],
          ctx
        )

      assert body["method"]        == "get"
      assert body["path"]          == "/some/path"
      assert body["authorization"] == "Bearer test-bearer-123"
      assert body["query_string"]  =~ "q=from%3Avendor"
      assert body["query_string"]  =~ "maxResults=25"
    end
  end

  describe "RestBridge.simple_post/3" do
    test "real Req call — JSON body round-trips, bearer forwarded", %{base: base} do
      ctx = %{bearer_token: "test-bearer-456"}

      {:ok, body} =
        RestBridge.simple_post(
          base <> "/upload",
          %{"name" => "doc.txt", "size" => 1024},
          ctx
        )

      assert body["method"]        == "post"
      assert body["path"]          == "/upload"
      assert body["authorization"] == "Bearer test-bearer-456"
      assert body["json_body"]["name"] == "doc.txt"
      assert body["json_body"]["size"] == 1024
    end
  end

  describe "RestBridge.raw_request/2" do
    test "real Req call — caller controls full option set", %{base: base} do
      opts = [
        url:     base <> "/raw",
        params:  [{"a", "1"}],
        headers: [{"x-custom", "value"}]
      ]

      assert {:ok, 200, body} = RestBridge.raw_request(:get, opts)
      assert body["method"]       == "get"
      assert body["path"]         == "/raw"
      assert body["query_string"] == "a=1"
    end
  end
end
