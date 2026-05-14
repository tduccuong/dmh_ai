# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Mock.VendorMCPServer do
  @moduledoc """
  Generic mock vendor MCP server. Plug-based, parameterised by a
  verb-fixture map at start time. Shared by every connector's
  integration tests AND the corresponding demo runbook — write the
  fixtures once per vendor, exercise them both ways.

  Implements the minimum Streamable HTTP MCP subset that
  `DmhAi.MCP.Client.call_tool/4` walks:

    * `initialize` — returns a server-info block, sets the
      `Mcp-Session-Id` response header (required by spec-compliant
      session-tracking clients).
    * `tools/list` — returns the verb manifest derived from the
      fixture map keys (or from an explicit `:tools` option for
      tests that want to assert tools/list-vs-manifest divergence).
    * `tools/call` — looks up the verb in the fixture map and
      returns its canned response wrapped in MCP's
      `content[]` envelope.

  ## Starting an instance

      DmhAi.Connectors.Mock.VendorMCPServer.start_link(
        instance: "mock_gw",
        port:     8086,
        fixtures: %{
          "gmail.search" => %{"messages" => [%{"id" => "m1", ...}]},
          "gmail.send"   => fn args -> %{"id" => "sent-" <> args["subject"]} end
        }
      )

  Fixture values can be either:

    * a plain map — returned verbatim
    * a 1-arity function — invoked with the verb's `arguments`,
      whatever it returns becomes the response

  ## Safety

  The module refuses to start unless `:enable_vendor_mocks` is set
  to `true` in application env (operators set this via the env var
  `DMH_AI_ENABLE_VENDOR_MOCKS` in `runtime.exs`). Production
  installs default to `false`; tests and stage demos opt in
  explicitly. Without the flag, `start_link/1` returns
  `{:error, :vendor_mocks_disabled}` — a hard fail so the cause
  is unambiguous in logs and CI output.
  """

  require Logger

  @doc """
  Start a mock vendor MCP server on the given port with the given
  fixtures. Returns `{:ok, pid}` (the Bandit supervisor) on success.

  Required options:
    * `:instance` — a unique string id for this server (used to
      key the fixture map in application env so multiple mocks can
      run in parallel without clashing).
    * `:fixtures` — `%{verb_name => response_or_fn}` (see module
      doc for the shape).

  Optional:
    * `:port` — TCP port (default 0 = pick a free one;
      `:ranch.get_port/1` on the returned listener reveals it).
    * `:tools` — explicit `tools/list` response (list of
      `%{"name" => ..., "description" => ..., "inputSchema" => ...}`);
      defaults to a derived list from `:fixtures` keys.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    if Application.get_env(:dmh_ai, :enable_vendor_mocks, false) do
      instance = Keyword.fetch!(opts, :instance)
      fixtures = Keyword.fetch!(opts, :fixtures)
      port     = Keyword.get(opts, :port, 0)
      tools    = Keyword.get(opts, :tools, derive_tools(fixtures))

      mocks = Application.get_env(:dmh_ai, :vendor_mocks, %{})
      Application.put_env(:dmh_ai, :vendor_mocks,
        Map.put(mocks, instance, %{fixtures: fixtures, tools: tools})
      )

      Bandit.start_link(
        plug:   {__MODULE__.Plug, instance: instance},
        scheme: :http,
        ip:     {127, 0, 0, 1},
        port:   port
      )
    else
      {:error, :vendor_mocks_disabled}
    end
  end

  @doc """
  Reads the bound port from a `start_link/1` return value. Useful
  in tests that ask for `port: 0` and need to know which port the
  OS gave back.
  """
  @spec port(pid()) :: pos_integer()
  def port(pid) when is_pid(pid) do
    ThousandIsland.listener_info(pid) |> elem(1) |> elem(1)
  end

  @doc """
  Convenience: pause / replace fixtures on a running instance.
  Tests that walk multi-step flows (`gmail.search` then
  `gmail.send`) can re-arm canned responses between steps.
  """
  @spec set_fixtures(String.t(), map()) :: :ok
  def set_fixtures(instance, fixtures) when is_binary(instance) and is_map(fixtures) do
    mocks = Application.get_env(:dmh_ai, :vendor_mocks, %{})
    current = Map.get(mocks, instance, %{})
    Application.put_env(:dmh_ai, :vendor_mocks,
      Map.put(mocks, instance, Map.put(current, :fixtures, fixtures))
    )
  end

  defp derive_tools(fixtures) do
    fixtures
    |> Map.keys()
    |> Enum.map(fn name ->
      %{
        "name"        => name,
        "description" => "Mock verb #{name}",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    end)
  end

  defmodule Plug do
    @moduledoc false

    use Elixir.Plug.Router

    plug :match
    plug Elixir.Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    def init(opts), do: Keyword.fetch!(opts, :instance)

    def call(conn, instance) do
      conn = Elixir.Plug.Conn.put_private(conn, :vendor_mock_instance, instance)
      super(conn, instance)
    end

    post "/" do
      instance = conn.private[:vendor_mock_instance]
      mock = Map.get(Application.get_env(:dmh_ai, :vendor_mocks, %{}), instance, %{})
      request = conn.body_params

      {response_body, session_id_header} =
        handle_request(request, mock[:fixtures] || %{}, mock[:tools] || [])

      conn
      |> Elixir.Plug.Conn.put_resp_header("mcp-session-id", session_id_header)
      |> Elixir.Plug.Conn.put_resp_content_type("application/json")
      |> Elixir.Plug.Conn.send_resp(200, Jason.encode!(response_body))
    end

    match _ do
      Elixir.Plug.Conn.send_resp(conn, 404, "")
    end

    # ── Method dispatch ─────────────────────────────────────────────

    defp handle_request(%{"method" => "initialize", "id" => id}, _fixtures, _tools) do
      {
        %{
          "jsonrpc" => "2.0",
          "id"      => id,
          "result"  => %{
            "protocolVersion" => "2024-11-05",
            "capabilities"    => %{"tools" => %{}},
            "serverInfo"      => %{"name" => "dmh-ai-mock-vendor", "version" => "0.1.0"}
          }
        },
        "mock-session-" <> Integer.to_string(:erlang.unique_integer([:positive]))
      }
    end

    defp handle_request(%{"method" => "tools/list", "id" => id}, _fixtures, tools) do
      {%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}, "mock-session-static"}
    end

    defp handle_request(
           %{"method" => "tools/call", "id" => id, "params" => %{"name" => verb} = params},
           fixtures,
           _tools
         ) do
      args = Map.get(params, "arguments", %{})

      body =
        case Map.get(fixtures, verb) do
          nil ->
            %{
              "jsonrpc" => "2.0",
              "id"      => id,
              "error"   => %{"code" => -32601, "message" => "Mock has no fixture for verb '#{verb}'"}
            }

          fixture when is_function(fixture, 1) ->
            payload = fixture.(args)
            envelope_ok(id, payload)

          fixture when is_map(fixture) ->
            envelope_ok(id, fixture)
        end

      {body, "mock-session-static"}
    end

    defp handle_request(%{"method" => method, "id" => id}, _fixtures, _tools) do
      {
        %{
          "jsonrpc" => "2.0",
          "id"      => id,
          "error"   => %{"code" => -32601, "message" => "Method not handled by mock: #{method}"}
        },
        "mock-session-static"
      }
    end

    defp handle_request(_, _, _) do
      {%{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32600, "message" => "Invalid request"}}, "mock-session-static"}
    end

    # MCP `tools/call` results are wrapped in a `content[]` envelope
    # per spec — at least one item with `type: "text"`. The Caller's
    # `normalize_mcp_result/1` JSON-decodes that text back into a
    # map, so we encode our fixture map into the text field here.
    defp envelope_ok(id, payload) when is_map(payload) do
      %{
        "jsonrpc" => "2.0",
        "id"      => id,
        "result"  => %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]
        }
      }
    end
  end
end
