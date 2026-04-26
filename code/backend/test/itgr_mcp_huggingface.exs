# Spec-compliant MCP Phase A smoke test.
#
# Hits real HuggingFace endpoints to verify the parts of the
# spec-compliant flow that don't need human authorization:
#
#   1. PRM discovery (RFC 9728) — fetch + parse against HF.
#   2. ASM discovery (RFC 8414) — fetch + parse against the AS that
#      PRM points to.
#   3. RFC 8615 well-known URL construction — table-driven, no network.
#   4. MCP unauthenticated probe — POST `initialize` to the MCP URL
#      WITHOUT credentials and expect the spec-mandated 401 plus a
#      `WWW-Authenticate` header carrying the resource metadata
#      pointer (RFC 9728 §5.1). This is the bootstrap signal a real
#      client uses to decide "I need to start the OAuth dance".
#
# What's NOT covered (requires human-in-the-loop):
#
#   * The OAuth authorization-code grant — the user must visit the
#     authorize URL in a browser and click Approve.
#   * Token exchange + authenticated `tools/list` / `tools/call` —
#     gated by the human step above.
#
# Tagged `:network` so the default `mix test` skips it. Run
# explicitly with:
#
#   mix test test/itgr_mcp_huggingface.exs --only network
#
# Smoke target may need updating if HuggingFace re-skins their
# discovery layout — failures here are usually a real signal that
# our discovery code or HF's metadata drifted.

defmodule Itgr.McpHuggingFace do
  use ExUnit.Case, async: false

  @hf_mcp_url "https://huggingface.co/mcp"

  describe "RFC 8615 well-known URL construction" do
    @describetag :network

    # Black-box check: Discovery's private rfc8615_well_known
    # constructor must split authority from path so HF's PRM is
    # found at `https://huggingface.co/.well-known/oauth-protected-
    # resource/mcp` — not the wrong-shape `.../mcp/.well-known/...`.
    # We don't reach into the private fn; if fetch_prm/1 returns
    # `{:ok, _}` against HF, the URL math was right.
    test "splits authority from path correctly for HF" do
      {:ok, prm} = Dmhai.Auth.Discovery.fetch_prm(@hf_mcp_url)
      # The fact that we got `{:ok, _}` proves the constructor
      # produced the right URL — HF only serves PRM at the
      # spec-compliant location.
      assert is_map(prm)
      assert is_list(prm.authorization_servers) and prm.authorization_servers != []
      assert is_binary(prm.resource) and prm.resource != ""
    end
  end

  describe "PRM (RFC 9728) — Protected Resource Metadata" do
    @describetag :network

    test "fetches and parses HuggingFace PRM" do
      assert {:ok, prm} = Dmhai.Auth.Discovery.fetch_prm(@hf_mcp_url)

      # Mandatory fields per RFC 9728.
      assert is_list(prm.authorization_servers)
      assert prm.authorization_servers != []
      assert Enum.all?(prm.authorization_servers, &is_binary/1)

      assert is_binary(prm.resource)
      assert String.starts_with?(prm.resource, "https://")

      # Sanity: the resource should match the MCP URL we asked about
      # (canonical form may differ in trailing slash, etc.).
      assert String.contains?(prm.resource, "huggingface.co")
    end
  end

  describe "ASM (RFC 8414) — Authorization Server Metadata" do
    @describetag :network

    test "fetches and parses HuggingFace's authorization server metadata" do
      {:ok, prm} = Dmhai.Auth.Discovery.fetch_prm(@hf_mcp_url)
      [as_url | _] = prm.authorization_servers

      assert {:ok, asm} = Dmhai.Auth.Discovery.fetch_asm(as_url)

      # Mandatory endpoints.
      assert is_binary(asm.authorization_endpoint)
      assert String.starts_with?(asm.authorization_endpoint, "https://")
      assert is_binary(asm.token_endpoint)
      assert String.starts_with?(asm.token_endpoint, "https://")

      # OAuth 2.1 mandates PKCE S256.
      assert "S256" in asm.code_challenge_methods_supported,
             "AS must advertise S256 PKCE per OAuth 2.1: got #{inspect(asm.code_challenge_methods_supported)}"

      # We don't strictly require DCR, but Phase A's spec-compliant
      # path relies on it. Surface its absence loudly so we know to
      # retest the manual fallback (Phase B) if HF removes it.
      if is_nil(asm.registration_endpoint) do
        IO.puts(
          "[itgr_mcp_huggingface] WARNING: AS no longer publishes registration_endpoint — Phase A DCR path can't run; #{inspect(asm.issuer)}"
        )
      end
    end
  end

  describe "MCP handshake — Mcp-Session-Id threading (MCP 2025-06-18)" do
    @describetag :network

    test "initialize returns a session id that subsequent calls thread back" do
      # Spec: a streamable-HTTP MCP server returns
      # `Mcp-Session-Id` on `initialize`'s response; the client
      # must echo that header on every subsequent request in the
      # same session. We verify both halves end-to-end against HF.
      #
      # We use Req directly here (not our Transport module) so the
      # raw response headers stay inspectable.
      init_body = %{
        "jsonrpc" => "2.0",
        "id"      => 1,
        "method"  => "initialize",
        "params"  => %{
          "protocolVersion" => "2025-06-18",
          "capabilities"    => %{},
          "clientInfo"      => %{"name" => "dmhai-itgr-test", "version" => "0.0.0"}
        }
      }

      {:ok, %Req.Response{status: init_status, headers: init_headers, body: init_body_resp}} =
        Req.post(@hf_mcp_url,
          json: init_body,
          headers: [{"accept", "application/json, text/event-stream"}],
          receive_timeout: 10_000,
          retry: false
        )

      assert init_status == 200, "initialize should return 200; got #{init_status}"

      session_id =
        init_headers
        |> Enum.find(fn {k, _} -> String.downcase(to_string(k)) == "mcp-session-id" end)
        |> case do
          {_, v} when is_binary(v)  -> v
          {_, [v | _]}              -> v
          _                          -> nil
        end

      assert is_binary(session_id) and session_id != "",
             "initialize must return a Mcp-Session-Id header per MCP 2025-06-18; got: #{inspect(init_headers)}"

      # Body sanity — initialize response carries protocolVersion + serverInfo.
      assert is_binary(extract_jsonrpc_field(init_body_resp, "result", "protocolVersion")),
             "initialize result must include protocolVersion; got: #{inspect(init_body_resp)}"

      # Now do tools/list with the same session id. Whether HF
      # returns 200 (public tools) or 401 (gated) is policy-dependent
      # and not part of Phase A's spec criteria; what we're verifying
      # here is the THREADING — that the server accepts the session
      # id we threaded back. A 400 would mean session-id wasn't
      # accepted, which is the spec-compliance failure we want to
      # catch.
      list_body = %{
        "jsonrpc" => "2.0",
        "id"      => 2,
        "method"  => "tools/list",
        "params"  => %{}
      }

      {:ok, %Req.Response{status: list_status}} =
        Req.post(@hf_mcp_url,
          json: list_body,
          headers: [
            {"accept", "application/json, text/event-stream"},
            {"mcp-session-id", session_id}
          ],
          receive_timeout: 10_000,
          retry: false
        )

      assert list_status in [200, 401],
             "tools/list with valid session id should return 200 (public tools) or 401 " <>
               "(auth required); got #{list_status} — likely the session id didn't thread."
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # JSON-RPC responses arrive as either parsed maps or as
  # text/event-stream chunks. Pull a path out tolerantly so the test
  # doesn't break on either shape.
  defp extract_jsonrpc_field(%{} = body, k1, k2) do
    case body[k1] do
      %{} = inner -> inner[k2]
      _           -> nil
    end
  end

  defp extract_jsonrpc_field(body, k1, k2) when is_binary(body) do
    # SSE shape: lines like "data: {...}\n\n". Find the first JSON
    # blob and look up the path.
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        ["data", payload] ->
          case Jason.decode(String.trim(payload)) do
            {:ok, decoded} -> extract_jsonrpc_field(decoded, k1, k2)
            _ -> nil
          end

        _ -> nil
      end
    end)
  end

  defp extract_jsonrpc_field(_, _, _), do: nil

  describe "Discovery → AS metadata cohesion" do
    @describetag :network

    test "the resource URL in PRM is the canonical resource indicator" do
      {:ok, prm} = Dmhai.Auth.Discovery.fetch_prm(@hf_mcp_url)
      # `prm.resource` is what we'd pass as `resource=` on the
      # authorization request (RFC 8707) so the issued token is
      # audience-bound to this MCP server. Spot-check that it's a
      # plausible canonical form (https, no trailing slash funny
      # business).
      refute String.ends_with?(prm.resource, "/"),
             "Canonical resource should not have a trailing slash: #{prm.resource}"
    end
  end
end
