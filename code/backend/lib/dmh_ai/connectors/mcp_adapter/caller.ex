# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.MCPAdapter.Caller do
  @moduledoc """
  Bridges the adapter layer to the underlying MCP transport. Handles:

    * `lookup_credentials/3` — fetches the calling user's
      `user_credentials` row for the connector's slug. Returns
      `{:ok, creds_map}` or `{:error, :missing_credentials}`.
    * `invoke/5` — issues the actual MCP `tools/call` against the
      registered server via `DmhAi.MCP.Client.call_tool/4`.

  Kept as a separate module so per-connector files stay focused on
  manifest + error remap; nothing here is connector-specific.

  ## Test hook

  Tests stub at this layer to assert the adapter's call contract
  without standing up a real MCP server:

      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn slug, function_name, args, creds ->
        {:ok, %{"echo" => args}}
      end)

  The stub is invoked as `/4` or `/5` — `/4` for the historical
  contract (slug, function_name, args, creds); `/5` adds the caller_ctx
  for tests that need the user_id.
  """

  alias DmhAi.MCP.Client
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @spec lookup_credentials(String.t(), map(), :oauth2 | :api_key) ::
          {:ok, map()} | {:error, :missing_credentials}
  def lookup_credentials(slug, caller_ctx, kind \\ :oauth2)

  def lookup_credentials(slug, %{user_id: user_id}, :oauth2)
      when is_binary(slug) and is_binary(user_id) do
    fetch_payload(user_id, "oauth:" <> slug, "oauth2")
  end

  def lookup_credentials(slug, %{user_id: user_id}, :api_key)
      when is_binary(slug) and is_binary(user_id) do
    fetch_payload(user_id, "api_key:" <> slug, "api_key")
  end

  def lookup_credentials(_, _, _), do: {:error, :missing_credentials}

  defp fetch_payload(user_id, target, kind) do
    case query!(Repo, """
    SELECT payload FROM user_credentials
    WHERE user_id=? AND target=? AND kind=?
    ORDER BY updated_at DESC LIMIT 1
    """, [user_id, target, kind]).rows do
      [[payload]] when is_binary(payload) ->
        case Jason.decode(payload) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :missing_credentials}
        end

      _ ->
        {:error, :missing_credentials}
    end
  end

  @doc """
  Invoke an MCP tool. `slug` is the connector's `mcp_catalog.slug`
  AND — by convention — the user's `authorized_services.alias`;
  `function_name` is the function name (e.g. `"contact.find"`); `args` is
  the function's arg map (already validated by Dispatcher and carrying
  the injected `__idempotency_key` on writes). `caller_ctx` carries
  at minimum `%{user_id: <id>}` and threads to `MCP.Client.call_tool/4`
  for the per-user MCP connection lookup.

  Stub-friendly: if `:__mcp_caller_stub__` is set, that function is
  invoked instead of the real transport. Stubs may be arity 4
  (slug, function_name, args, creds) for the historical contract or
  arity 5 (… , caller_ctx) for tests that need the user identity.
  """
  @spec invoke(String.t(), String.t(), map(), map(), map()) ::
          {:ok, term()} | {:error, term()}
  def invoke(slug, function_name, args, creds, caller_ctx \\ %{}) do
    case Application.get_env(:dmh_ai, :__mcp_caller_stub__) do
      stub when is_function(stub, 5) ->
        stub.(slug, function_name, args, creds, caller_ctx)

      stub when is_function(stub, 4) ->
        stub.(slug, function_name, args, creds)

      _ ->
        do_real_invoke(slug, function_name, args, creds, caller_ctx)
    end
  end

  # Real-transport path. Bridges into the existing
  # `DmhAi.MCP.Client.call_tool/4` plumbing (initialize → tools/call,
  # OAuth refresh on 401, error normalisation). By convention the
  # user's `authorized_services.alias` equals the connector's slug
  # — `Tools.ConnectMcp` defaults the alias to slug at authorisation
  # time, so a user who walks through `connect_mcp(slug: "google_workspace")`
  # ends up with an alias `"google_workspace"` pointing at the catalog
  # row's `mcp_url`.
  defp do_real_invoke(slug, function_name, args, _creds, %{user_id: user_id})
       when is_binary(user_id) do
    case Client.call_tool(user_id, slug, function_name, args) do
      {:ok, result}   -> {:ok, normalize_mcp_result(result)}
      {:error, _} = e -> e
    end
  end

  defp do_real_invoke(slug, function_name, _args, _creds, _ctx) do
    Logger.warning(
      "[Caller] no user_id in caller_ctx (slug=#{slug}, function=#{function_name}); refusing real invoke"
    )
    {:error, :missing_user_id}
  end

  # MCP `tools/call` returns the server's `result` shape, which is
  # typically `%{"content" => [%{"type" => "text", "text" => "..."}]}`
  # per the Model Context Protocol spec. Connectors handed an args
  # map by the model expect to be handed a result map back — they
  # don't want to know about MCP's wrapping. Extract the JSON-decoded
  # text payload when present; pass through otherwise.
  defp normalize_mcp_result(%{"content" => [%{"type" => "text", "text" => text} | _]})
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      _              -> %{"text" => text}
    end
  end

  defp normalize_mcp_result(other), do: other
end
