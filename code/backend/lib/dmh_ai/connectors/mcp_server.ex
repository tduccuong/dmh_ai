# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPServer do
  @moduledoc """
  Generic, connector-agnostic MCP JSON-RPC server. Hosts every
  Universal Region connector that registers a function-spec handler
  via `MCPServer.Registry`. The Plug:

    * Responds to `initialize` with the protocol version +
      server capabilities.
    * Responds to `tools/list` with the union of all registered
      functions across all handlers (slug-prefixed).
    * Routes `tools/call` to the handler that owns the function's
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

  @doc """
  Render the MCP `tools/list` entries for a handler record. Single
  source of truth used by both the JSON-RPC `tools/list` response
  served over the wire AND by `ConnectMcp.InProcess.attach/3` which
  short-circuits the network roundtrip and caches the same shape
  directly into `authorized_services.server_tools_json`. Two paths,
  identical rendering — the model can't tell which path produced
  the catalog.

  Optional `enabled_functions` is a `MapSet` of function names the
  admin's capability curation has enabled (Layer 2 of the 3-layer
  policy enforcement). When supplied, functions outside the set
  are filtered out. `:all` (or omitted) means no filter — every
  function in the handler is rendered. Connectors that haven't
  migrated to the capability model end up here.

  Returns a list of `%{"name", "description", "inputSchema"}` maps
  shaped per the Model Context Protocol spec.
  """
  @spec tools_list_for(map(), MapSet.t(String.t()) | :all) :: [map()]
  def tools_list_for(handler, enabled_functions \\ :all)

  def tools_list_for(%{slug: slug, functions: functions}, enabled_functions)
      when is_binary(slug) and is_map(functions) do
    # Pull the connector's manifest so every function's
    # `inputSchema` reflects the real argument names + types the
    # dispatcher will accept. Without this the schema came out
    # `{"properties": {}}` for every function — the model would
    # see a tool name + description but had to guess argument
    # names from prompt context, often wrong, and the vendor
    # response was just `invalid_request` with no recovery hint.
    manifest_args =
      case DmhAi.Connectors.Registry.module_for_slug(slug) do
        nil -> %{}
        mod ->
          try do
            mod.manifest().functions
            |> Enum.into(%{}, fn {fn_name, f} -> {fn_name, f.args || %{}} end)
          rescue
            _ -> %{}
          end
      end

    functions
    |> Enum.filter(fn {name, _} -> function_visible?(name, enabled_functions) end)
    |> Enum.map(fn {name, spec} ->
      args = Map.get(manifest_args, name, %{})

      %{
        "name"        => name,
        "description" => spec.doc || "MCP function #{name}",
        "inputSchema" => json_schema_for(args)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  # Fallback: handlers without a slug (free-form / test fixtures)
  # don't have a manifest to consult, so keep the historical
  # empty-`properties` shape rather than crash.
  def tools_list_for(%{functions: functions}, enabled_functions) when is_map(functions) do
    functions
    |> Enum.filter(fn {name, _} -> function_visible?(name, enabled_functions) end)
    |> Enum.map(fn {name, spec} ->
      %{
        "name"        => name,
        "description" => spec.doc || "MCP function #{name}",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  def tools_list_for(_, _), do: []

  # Manifest arg map → JSON Schema. Each arg's `:type` atom maps
  # to its JSON-Schema string; `required: true` flags fold into
  # the top-level `required` array. `:format` (e.g. `:email`) is
  # passed through verbatim so vendors / models that recognise
  # the JSON-Schema `format` keyword get the extra hint.
  defp json_schema_for(args) when is_map(args) and map_size(args) == 0 do
    %{"type" => "object", "properties" => %{}}
  end

  defp json_schema_for(args) when is_map(args) do
    {props, required} =
      Enum.reduce(args, {%{}, []}, fn {name, spec}, {props, req} ->
        prop = json_schema_prop(spec)
        new_req = if Map.get(spec, :required) == true, do: [name | req], else: req
        {Map.put(props, name, prop), new_req}
      end)

    base = %{"type" => "object", "properties" => props}

    case Enum.sort(required) do
      []   -> base
      list -> Map.put(base, "required", list)
    end
  end

  defp json_schema_prop(spec) when is_map(spec) do
    base = %{"type" => json_schema_type(Map.get(spec, :type))}

    case Map.get(spec, :format) do
      f when is_atom(f) and not is_nil(f) -> Map.put(base, "format", Atom.to_string(f))
      f when is_binary(f) and f != ""     -> Map.put(base, "format", f)
      _                                    -> base
    end
  end

  defp json_schema_type(:string),  do: "string"
  defp json_schema_type(:integer), do: "integer"
  defp json_schema_type(:number),  do: "number"
  defp json_schema_type(:boolean), do: "boolean"
  defp json_schema_type(:map),     do: "object"
  defp json_schema_type(:list),    do: "array"
  defp json_schema_type(_),        do: "string"

  defp function_visible?(_name, :all), do: true
  defp function_visible?(name, %MapSet{} = set), do: MapSet.member?(set, name)

  defmodule Plug do
    @moduledoc false

    use Elixir.Plug.Router
    alias DmhAi.Connectors.MCPServer.{Registry, RestBridge, FunctionSpec}

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

    defp handle_request(%{functions: functions}, %{"method" => "initialize", "id" => id}, _ctx, slug) do
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
              "function_count" => map_size(functions)
            }
          }
        },
        session_id()
      }
    end

    defp handle_request(%{functions: _} = handler, %{"method" => "tools/list", "id" => id}, _ctx, _slug) do
      tools = DmhAi.Connectors.MCPServer.tools_list_for(handler)
      {%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}, session_id()}
    end

    defp handle_request(
           %{functions: functions},
           %{"method" => "tools/call", "id" => id, "params" => %{"name" => function} = params},
           ctx,
           slug
         ) do
      args = Map.get(params, "arguments", %{})

      case Map.get(functions, function) do
        nil ->
          {jsonrpc_error(id, -32601, "Unknown function #{slug}.#{function}"), session_id()}

        %FunctionSpec{} = spec ->
          case RestBridge.invoke(spec, args, ctx) do
            {:ok, payload} ->
              {ok_envelope(id, payload), session_id()}

            {:error, %DmhAi.Connectors.MCPServer.ErrorMap{} = e} ->
              {error_envelope_from_map(id, e), session_id()}

            {:error, atom} when is_atom(atom) ->
              # Custom-handler responses that haven't migrated to the
              # ErrorMap struct yet — surface honestly with whatever
              # the handler returned.
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
    # envelope with one text item per spec. We encode our function's
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

    # Vendor error from RestBridge → JSON-RPC error envelope.
    # JSON-RPC 2.0 allows an optional `data` field; we put the
    # ErrorMap's structured detail there so the Caller can pass
    # vendor_message + vendor_hint_url through to the model.
    defp error_envelope_from_map(id, %DmhAi.Connectors.MCPServer.ErrorMap{} = e) do
      data =
        %{"class" => Atom.to_string(e.class)}
        |> maybe_put("vendor_message",  e.vendor_message)
        |> maybe_put("vendor_hint_url", e.vendor_hint_url)

      %{
        "jsonrpc" => "2.0",
        "id"      => id,
        "error"   => %{
          "code"    => -32000,
          "message" => "Vendor error: #{e.class}",
          "data"    => data
        }
      }
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, _key, ""),  do: map
    defp maybe_put(map, key, val),  do: Map.put(map, key, val)

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
