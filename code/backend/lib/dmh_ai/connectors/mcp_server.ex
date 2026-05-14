# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer do
  @moduledoc """
  Generic, connector-agnostic MCP JSON-RPC server. Hosts every
  Universal Region connector that registers a verb-spec handler
  via `MCPServer.Registry`. The Plug:

    * Responds to `initialize` with the protocol version +
      server capabilities.
    * Responds to `tools/list` with the union of all registered
      verbs across all handlers (slug-prefixed).
    * Routes `tools/call` to the handler that owns the verb's
      slug-prefix and executes via `RestBridge.invoke/3`.

  ## URL convention

  Per-connector URL paths: `/<slug>` (e.g. `/google_workspace`).
  Each connector's `mcp_catalog.mcp_url` row points at
  `http://127.0.0.1:<port>/<slug>`. The Plug reads the slug from
  the path, looks up the handler in the Registry, and routes
  accordingly.

  Operators wanting a different routing (one server per slug, or
  one slug per port) can wrap this Plug — it doesn't assume a
  specific deployment shape.

  ## Bearer token extraction

  The MCP client (Caller / MCP.Client) sends the user's OAuth
  token in the `Authorization: Bearer …` header. The Plug
  extracts it and threads into `RestBridge` so the bridge can
  forward it to the vendor's REST API.
  """

  require Logger

  @doc """
  Start the MCPServer on the given port. Returns
  `{:ok, pid}` (the Bandit supervisor) on success.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    port = Keyword.get(opts, :port, 8087)
    ip   = Keyword.get(opts, :ip,   {127, 0, 0, 1})

    Bandit.start_link(
      plug:   __MODULE__.Plug,
      scheme: :http,
      ip:     ip,
      port:   port
    )
  end

  defmodule Plug do
    @moduledoc false

    use Elixir.Plug.Router
    alias DmhAi.Connectors.MCPServer.{Registry, RestBridge, VerbSpec}

    plug :match
    plug Elixir.Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    # POST /<slug>      JSON-RPC entry per connector
    post "/:slug" do
      slug = conn.path_params["slug"]
      handler = Registry.get(slug)
      bearer  = extract_bearer(conn)
      ctx     = %{bearer_token: bearer, slug: slug}

      {body, session_id} = handle_request(handler, conn.body_params, ctx, slug)

      conn
      |> Elixir.Plug.Conn.put_resp_header("mcp-session-id", session_id)
      |> Elixir.Plug.Conn.put_resp_content_type("application/json")
      |> Elixir.Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    match _ do
      Elixir.Plug.Conn.send_resp(conn, 404, "")
    end

    # ─── Handler dispatch ───────────────────────────────────────────

    defp handle_request(nil, %{"id" => id}, _ctx, slug) do
      {jsonrpc_error(id, -32601, "Unknown connector slug: #{slug}"), session_id()}
    end

    defp handle_request(%{verbs: verbs}, %{"method" => "initialize", "id" => id}, _ctx, slug) do
      {
        %{
          "jsonrpc" => "2.0",
          "id"      => id,
          "result"  => %{
            "protocolVersion" => "2024-11-05",
            "capabilities"    => %{"tools" => %{}},
            "serverInfo"      => %{
              "name"    => "dmh-ai-mcp-#{slug}",
              "version" => "0.1.0",
              "verb_count" => map_size(verbs)
            }
          }
        },
        session_id()
      }
    end

    defp handle_request(%{verbs: verbs}, %{"method" => "tools/list", "id" => id}, _ctx, _slug) do
      tools =
        verbs
        |> Enum.map(fn {name, spec} ->
          %{
            "name"        => name,
            "description" => spec.doc || "MCP verb #{name}",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        end)

      {%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}, session_id()}
    end

    defp handle_request(
           %{verbs: verbs},
           %{"method" => "tools/call", "id" => id, "params" => %{"name" => verb} = params},
           ctx,
           slug
         ) do
      args = Map.get(params, "arguments", %{})

      case Map.get(verbs, verb) do
        nil ->
          {jsonrpc_error(id, -32601, "Unknown verb #{slug}.#{verb}"), session_id()}

        %VerbSpec{} = spec ->
          case RestBridge.invoke(spec, args, ctx) do
            {:ok, payload} ->
              {ok_envelope(id, payload), session_id()}

            {:error, atom} ->
              {jsonrpc_error(id, -32000, "Vendor error: #{atom}"), session_id()}
          end
      end
    end

    defp handle_request(_handler, %{"method" => m, "id" => id}, _ctx, _slug) do
      {jsonrpc_error(id, -32601, "Method not handled: #{m}"), session_id()}
    end

    defp handle_request(_handler, _, _, _) do
      {jsonrpc_error(nil, -32600, "Invalid request"), session_id()}
    end

    # MCP `tools/call` results wrap the payload in a `content[]`
    # envelope with one text item per spec. We encode our verb's
    # return map as JSON inside the text field — the Caller's
    # `normalize_mcp_result/1` JSON-decodes it back into a map on
    # the client side.
    defp ok_envelope(id, payload) do
      %{
        "jsonrpc" => "2.0",
        "id"      => id,
        "result"  => %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]
        }
      }
    end

    defp jsonrpc_error(id, code, message) do
      %{
        "jsonrpc" => "2.0",
        "id"      => id,
        "error"   => %{"code" => code, "message" => message}
      }
    end

    # Streamable HTTP MCP servers allocate a session id on
    # `initialize`. Returning a fixed string is fine — clients
    # echo it on subsequent calls; we don't track per-session
    # state.
    defp session_id, do: "dmh-mcp-session"

    defp extract_bearer(conn) do
      case Elixir.Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _                         -> nil
      end
    end
  end
end
