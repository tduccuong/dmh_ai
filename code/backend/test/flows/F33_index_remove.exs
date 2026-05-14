# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F33 — Admin /admin/kb-sources/remove e2e (Primitive 0.2 §removability).
#
# Two HTTP roundtrips:
#   1. POST /agent/chat with "/index <text>" as admin → kb_sources row created.
#   2. POST /admin/kb-sources/remove with body {"source_id": "..."} → row gone.
#
# Asserts:
#   * Step 1: kb_sources row + chunks exist.
#   * Step 2: row is gone, chunks are gone (cascade), kb_source_history row
#     records the removal with the admin's user_id + reason.
#   * Re-running the original /index after remove creates a FRESH internal id
#     (no soft-delete zombies).
#
# Non-admin /admin/kb-sources/remove call → 403.

defmodule DmhAi.Flows.F33IndexRemove do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F33"

  @embedding_dim 1024
  @body "F33 removable-test body content. " <>
        "Padded to ensure chunker emits at least one chunk under the default " <>
        "min-chunk-tokens threshold so the embed/insert path runs to completion."

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F33")

    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs =
        Enum.map(texts, fn text ->
          seed = :crypto.hash(:sha256, text)
          bytes = :binary.copy(seed, div(@embedding_dim, byte_size(seed)) + 1)
          for(<<b <- bytes>>, do: b / 255.0) |> Enum.take(@embedding_dim)
        end)
      {:ok, vecs}
    end)

    Application.put_env(:dmh_ai, :__tagger_stub__, fn _body -> [] end)
    Application.put_env(:dmh_ai, :__llm_call_stub__, fn _model, _msgs, _opts ->
      {:ok, %{message: %{"role" => "assistant", "content" => "ok"}, finish_reason: "stop"}}
    end)

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
      Application.delete_env(:dmh_ai, :__llm_call_stub__)
      teardown.()
    end)

    :ok
  end

  setup do
    admin_id = T.uid()
    admin_email = "u-#{admin_id}@test.local" |> String.downcase()
    admin_password = "p-#{admin_id}"

    member_id = T.uid()
    member_email = "u-#{member_id}@test.local" |> String.downcase()
    member_password = "p-#{member_id}"

    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, admin_email, "Admin", "user", DmhAi.AuthPlug.hash_password(admin_password), 1,
       DmhAi.Constants.default_org_id(), "admin", now,
       member_id, member_email, "Member", "user", DmhAi.AuthPlug.hash_password(member_password), 1,
       DmhAi.Constants.default_org_id(), "member", now])

    source_ref = :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower)
    source_id  = SourceId.derive("text", source_ref, DmhAi.Constants.default_org_id())

    on_exit(fn ->
      DmhAi.Ingest.remove_kb_source!(DmhAi.Constants.default_org_id(), source_id)
      for uid <- [admin_id, member_id] do
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM sessions WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM kb_source_history WHERE removed_by_user_id=?", [uid])
        query!(Repo, "DELETE FROM users WHERE id=?", [uid])
      end
    end)

    %{
      admin_email: admin_email,    admin_password: admin_password,    admin_id: admin_id,
      member_email: member_email,  member_password: member_password,  member_id: member_id,
      source_id: source_id
    }
  end

  test "admin remove drops kb_sources + chunks; history row written",
       %{admin_email: admin_email, admin_password: admin_password, admin_id: admin_id,
         source_id: source_id} do
    token = login_for_token(admin_email, admin_password)
    session_id = T.uid()
    assert post_json("/sessions", %{"id" => session_id}, token: token).status == 200

    # 1. Admin indexes inline text.
    chat = post_json("/agent/chat",
                     %{"sessionId" => session_id, "content" => "/index " <> @body},
                     token: token)
    assert chat.status == 200

    [[internal_id_before]] =
      query!(Repo, "SELECT id FROM kb_sources WHERE source_id=?", [source_id]).rows

    assert chunk_count(internal_id_before) > 0

    # 2. Admin removes the source via the new HTTP endpoint.
    remove = post_json("/admin/kb-sources/remove",
                       %{"source_id" => source_id, "reason" => "F33 test cleanup"},
                       token: token)
    assert remove.status == 200, "remove POST: #{remove.status} #{remove.resp_body}"
    decoded = Jason.decode!(remove.resp_body)
    assert decoded["ok"] == true
    assert decoded["source_id"] == source_id

    # kb_sources row is gone.
    [[remaining]] =
      query!(Repo, "SELECT COUNT(*) FROM kb_sources WHERE source_id=?", [source_id]).rows
    assert remaining == 0

    # Cascading chunks are gone.
    assert chunk_count(internal_id_before) == 0

    # History row records the removal.
    [[history_n, removed_by, reason]] =
      query!(Repo, """
      SELECT COUNT(*),
             COALESCE(MAX(removed_by_user_id), ''),
             COALESCE(MAX(reason), '')
      FROM kb_source_history WHERE source_id=?
      """, [source_id]).rows

    assert history_n == 1
    assert removed_by == admin_id
    assert reason == "F33 test cleanup"

    # 3. Re-indexing the same body after remove creates a FRESH internal id.
    chat2 = post_json("/agent/chat",
                      %{"sessionId" => session_id, "content" => "/index " <> @body},
                      token: token)
    assert chat2.status == 200

    [[internal_id_after]] =
      query!(Repo, "SELECT id FROM kb_sources WHERE source_id=?", [source_id]).rows

    refute internal_id_after == internal_id_before,
           "re-index after remove must create a fresh internal id (was #{internal_id_before}, got #{internal_id_after})"
  end

  test "non-admin /admin/kb-sources/remove → 403",
       %{member_email: member_email, member_password: member_password, source_id: source_id} do
    token = login_for_token(member_email, member_password)

    conn = post_json("/admin/kb-sources/remove",
                     %{"source_id" => source_id},
                     token: token)

    assert conn.status == 403, "non-admin should get 403; got #{conn.status} #{conn.resp_body}"
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp chunk_count(internal_id) do
    [[n]] = query!(Repo,
                   "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=?",
                   [internal_id]).rows
    n
  end

  defp random_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}
  end

  defp post_json(path, body, opts \\ []) do
    json_body = Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, path, json_body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, random_ip())

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        tok -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tok)
      end

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end

  defp login_for_token(email, password) do
    conn = post_json("/auth/login", %{"email" => email, "password" => password})
    assert conn.status == 200, "login failed: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["token"]
  end
end
