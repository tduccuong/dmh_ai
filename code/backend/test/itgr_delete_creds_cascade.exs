# Phase C / Chunk 3 — `delete_creds` cascade + revocation (RFC 7009).
#
# Behaviors covered (offline):
#   * Non-`mcp:` targets keep the existing simple delete behavior —
#     no cascade, no revocation, no spurious side effects.
#   * `mcp:<canonical>` targets:
#       - drop the credential row,
#       - deauthorize (drops the authorized_services row + every
#         task_services attachment),
#       - best-effort POST to `revocation_endpoint` if the AS
#         advertises one.
#   * Revocation is best-effort: a 4xx/5xx, network failure, or
#     missing endpoint must NOT block the local cleanup.
#   * api_key_mcp creds skip the revocation step (no token to revoke
#     at an OAuth AS) but still cascade.
#   * Missing credential row + orphan attachments: deauthorize still
#     fires, dropping orphans.

defmodule Itgr.DeleteCredsCascade do
  use ExUnit.Case, async: false

  alias Dmhai.Auth.Credentials
  alias Dmhai.MCP.Registry
  alias Dmhai.Tools.DeleteCreds
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT OR IGNORE INTO users (id, email, role, created_at) VALUES (?,?,?,?)",
      [user_id, "del_#{user_id}@itgr.local", "user", now]
    )
  end

  defp seed_attached(task_id, user_id, alias_) do
    now = System.os_time(:millisecond)

    query!(Repo, """
    INSERT OR REPLACE INTO task_services (task_id, user_id, alias, attached_ts)
    VALUES (?, ?, ?, ?)
    """, [task_id, user_id, alias_, now])
  end

  defp count_attachments(user_id, alias_) do
    %{rows: [[n]]} =
      query!(Repo,
        "SELECT count(*) FROM task_services WHERE user_id=? AND alias=?",
        [user_id, alias_]
      )

    n
  end

  defp save_oauth_mcp_cred(user_id, canonical, alias_, opts \\ []) do
    rev_endpoint = Keyword.get(opts, :revocation_endpoint, nil)

    asm =
      %{"token_endpoint"      => "https://127.0.0.1:1/token",
        "issuer"               => "https://as.example.com"}
      |> maybe_put("revocation_endpoint", rev_endpoint)

    Credentials.save(
      user_id,
      "mcp:" <> canonical,
      "oauth2_mcp",
      %{
        "access_token"       => "AT_" <> uid(),
        "refresh_token"      => "RT_" <> uid(),
        "alias"              => alias_,
        "canonical_resource" => canonical,
        "asm_json"           => Jason.encode!(asm),
        "client_id"          => "client_id_x",
        "client_secret"      => "client_secret_x"
      }
    )
  end

  defp maybe_put(m, _k, nil), do: m
  defp maybe_put(m, k, v),    do: Map.put(m, k, v)

  defp save_api_key_mcp_cred(user_id, canonical, alias_) do
    Credentials.save(
      user_id,
      "mcp:" <> canonical,
      "api_key_mcp",
      %{
        "api_key"            => "key",
        "api_key_header"     => "Authorization",
        "alias"              => alias_,
        "canonical_resource" => canonical
      }
    )
  end

  setup do
    user_id = uid()
    seed_user(user_id)
    {:ok, user_id: user_id}
  end

  # ─── non-MCP targets keep simple behavior ──────────────────────────────

  describe "non-mcp targets" do
    test "ad-hoc credential delete returns the original shape — no cascade fields", %{user_id: user_id} do
      target = "adhoc_pw_" <> uid()
      Credentials.save(user_id, target, "user_pass", %{"username" => "u", "password" => "p"})

      assert {:ok, result} = DeleteCreds.execute(%{"target" => target}, %{user_id: user_id})

      assert result.deleted == true
      assert result.target == target
      refute Map.has_key?(result, :disconnected)
      refute Map.has_key?(result, :revoked)

      assert Credentials.lookup(user_id, target) == nil
    end
  end

  # ─── MCP targets — full cascade ────────────────────────────────────────

  describe "mcp:<canonical> targets" do
    setup ctx do
      alias_     = "svc_" <> uid()
      canonical  = "https://example.com/mcp/" <> alias_
      task_id    = "tk_" <> uid()
      Registry.authorize(ctx.user_id, alias_, canonical, canonical, %{})
      seed_attached(task_id, ctx.user_id, alias_)
      {:ok, alias: alias_, canonical: canonical, task_id: task_id}
    end

    test "drops credential, authorized_services row, and every task attachment", ctx do
      save_oauth_mcp_cred(ctx.user_id, ctx.canonical, ctx.alias)

      assert count_attachments(ctx.user_id, ctx.alias) == 1
      assert Registry.find_authorized(ctx.user_id, ctx.alias) != nil

      target = "mcp:" <> ctx.canonical

      assert {:ok, result} =
               DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      assert result.deleted     == true
      assert result.disconnected == true
      assert result.alias        == ctx.alias

      assert Credentials.lookup(ctx.user_id, target) == nil
      assert Registry.find_authorized(ctx.user_id, ctx.alias) == nil
      assert count_attachments(ctx.user_id, ctx.alias) == 0
    end

    test "AS without revocation_endpoint → revoked=false, reason mentions advertisement", ctx do
      save_oauth_mcp_cred(ctx.user_id, ctx.canonical, ctx.alias)
      target = "mcp:" <> ctx.canonical

      {:ok, result} = DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      assert result.revoked == false
      assert result.revoke_reason =~ "revocation_endpoint"
    end

    test "AS with revocation_endpoint at unrouteable host → best-effort fail, but cleanup completes", ctx do
      save_oauth_mcp_cred(ctx.user_id, ctx.canonical, ctx.alias,
        revocation_endpoint: "https://127.0.0.1:1/revoke")

      target = "mcp:" <> ctx.canonical

      {:ok, result} = DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      # Revocation attempt failed at transport, but local cleanup
      # still happened — that's the contract.
      assert result.revoked == false
      assert result.revoke_reason =~ "transport"

      assert result.disconnected == true
      assert result.deleted      == true
      assert Credentials.lookup(ctx.user_id, target) == nil
      assert Registry.find_authorized(ctx.user_id, ctx.alias) == nil
    end

    test "api_key_mcp credential skips revocation but still cascades", ctx do
      save_api_key_mcp_cred(ctx.user_id, ctx.canonical, ctx.alias)
      target = "mcp:" <> ctx.canonical

      {:ok, result} = DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      assert result.revoked == false
      assert result.revoke_reason =~ "kind=api_key_mcp"
      assert result.disconnected == true
      assert Credentials.lookup(ctx.user_id, target) == nil
      assert Registry.find_authorized(ctx.user_id, ctx.alias) == nil
    end

    test "no credential row but registered + attached → deauthorize still fires", ctx do
      # Don't save a credential — only the registry + attachment exist.
      target = "mcp:" <> ctx.canonical

      assert count_attachments(ctx.user_id, ctx.alias) == 1
      assert Registry.find_authorized(ctx.user_id, ctx.alias) != nil

      {:ok, result} = DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      assert result.deleted == true
      assert result.disconnected == true
      assert result.revoke_reason == "no credential row to revoke"
      assert Registry.find_authorized(ctx.user_id, ctx.alias) == nil
      assert count_attachments(ctx.user_id, ctx.alias) == 0
    end

    test "multiple task attachments all drop", ctx do
      save_oauth_mcp_cred(ctx.user_id, ctx.canonical, ctx.alias)

      seed_attached("tk_other_" <> uid(), ctx.user_id, ctx.alias)
      seed_attached("tk_third_" <> uid(), ctx.user_id, ctx.alias)
      assert count_attachments(ctx.user_id, ctx.alias) == 3

      target = "mcp:" <> ctx.canonical
      {:ok, _} = DeleteCreds.execute(%{"target" => target}, %{user_id: ctx.user_id})

      assert count_attachments(ctx.user_id, ctx.alias) == 0
    end
  end

  # ─── no user_id / bad args ─────────────────────────────────────────────

  describe "input guards" do
    test "missing user_id → {:error, _}" do
      assert {:error, _} =
               DeleteCreds.execute(%{"target" => "mcp:x"}, %{})
    end

    test "missing target → {:error, _}", %{user_id: user_id} do
      assert {:error, _} =
               DeleteCreds.execute(%{}, %{user_id: user_id})
    end

    test "empty target → {:error, _}", %{user_id: user_id} do
      assert {:error, _} =
               DeleteCreds.execute(%{"target" => ""}, %{user_id: user_id})
    end
  end
end
