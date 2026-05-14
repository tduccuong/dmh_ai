# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F35 — Cross-org KB isolation e2e (Primitive 0.1 multi-tenant boundary).
#
# Two users in DIFFERENT orgs:
#   * Admin in org "default" indexes inline text containing UNIQUE-MARKER.
#   * Member in org "org_b" queries /kb/query for UNIQUE-MARKER.
#
# The negative half of F34: org-B's user MUST NOT see org-A's KB
# content. If they do, the multi-tenant security boundary is broken
# and every flow above this would have a data-leak.

defmodule DmhAi.Flows.F35CrossOrgIsolation do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F35"

  @embedding_dim 1024
  @marker "UNIQUE-MARKER-F35-#{:erlang.unique_integer([:positive])}"
  @body @marker <> " " <>
        String.duplicate("Org-A only KB content for F35 cross-org isolation test. ", 8)

  @org_a DmhAi.Constants.default_org_id()
  @org_b "f35_other_org"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F35")

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

    # Seed the second org so org_b's user has a valid FK target.
    now_ms = System.os_time(:millisecond)
    query!(Repo,
           "INSERT OR IGNORE INTO organizations (id, name, settings_json, created_at) VALUES (?, ?, NULL, ?)",
           [@org_b, "F35 Other Org", now_ms])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__embedder_stub__)
      Application.delete_env(:dmh_ai, :__tagger_stub__)
      Application.delete_env(:dmh_ai, :__llm_call_stub__)
      query!(Repo, "DELETE FROM organizations WHERE id=?", [@org_b])
      teardown.()
    end)

    :ok
  end

  setup do
    admin_a_id = T.uid()
    member_b_id = T.uid()
    admin_a_email  = "u-#{admin_a_id}@test.local" |> String.downcase()
    member_b_email = "u-#{member_b_id}@test.local" |> String.downcase()
    admin_a_pwd  = "p-#{admin_a_id}"
    member_b_pwd = "p-#{member_b_id}"
    now = System.os_time(:millisecond)

    # User A: admin of org "default". User B: member of org "f35_other_org".
    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_a_id, admin_a_email, "Admin org-A", "user", DmhAi.AuthPlug.hash_password(admin_a_pwd), 1,
       @org_a, "admin", now,
       member_b_id, member_b_email, "Member org-B", "user", DmhAi.AuthPlug.hash_password(member_b_pwd), 1,
       @org_b, "member", now])

    trimmed_body = String.trim(@body)
    source_ref = :crypto.hash(:sha256, trimmed_body) |> Base.encode16(case: :lower)
    source_id  = SourceId.derive("text", source_ref, @org_a)

    on_exit(fn ->
      DmhAi.Ingest.remove_kb_source!(@org_a, source_id)
      for uid <- [admin_a_id, member_b_id] do
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM sessions WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM users WHERE id=?", [uid])
      end
    end)

    %{
      admin_a_email: admin_a_email,   admin_a_pwd: admin_a_pwd,
      member_b_email: member_b_email, member_b_pwd: member_b_pwd,
      source_id: source_id
    }
  end

  test "org-B member cannot see org-A admin's KB content",
       %{admin_a_email: admin_a_email, admin_a_pwd: admin_a_pwd,
         member_b_email: member_b_email, member_b_pwd: member_b_pwd,
         source_id: source_id} do
    # 1. Admin in org-A indexes inline text.
    admin_token = login_for_token(admin_a_email, admin_a_pwd)
    session_id = T.uid()
    assert post_json("/sessions", %{"id" => session_id}, token: admin_token).status == 200

    chat = post_json("/agent/chat",
                     %{"sessionId" => session_id, "content" => "/index " <> @body},
                     token: admin_token)
    assert chat.status == 200

    [[_internal_id]] =
      query!(Repo, "SELECT id FROM kb_sources WHERE org_id=? AND source_id=?",
             [@org_a, source_id]).rows

    # Sanity: admin themselves CAN see their own content (same-org positive control).
    self_query =
      post_json("/kb/query", %{"q" => @marker}, token: admin_token)

    assert self_query.status == 200
    %{"hits" => admin_hits} = Jason.decode!(self_query.resp_body)
    assert Enum.any?(admin_hits, fn h -> h["source_id"] == source_id end),
           "admin (org-A) should see their own content as positive control"

    # 2. Member in org-B queries for the same marker — expect ZERO hits.
    member_token = login_for_token(member_b_email, member_b_pwd)

    member_query =
      post_json("/kb/query", %{"q" => @marker}, token: member_token)

    assert member_query.status == 200,
           "kb/query for org-B member: #{member_query.status} #{member_query.resp_body}"

    %{"hits" => member_hits} = Jason.decode!(member_query.resp_body)

    refute Enum.any?(member_hits, fn h ->
             h["source_id"] == source_id
           end),
           "org-B member must NOT see org-A's source_id; got hits=#{inspect(member_hits)}"
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp random_ip, do: {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}

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
