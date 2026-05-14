# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F34 — Same-org KB sharing e2e (Primitive 0.1 org boundary).
#
# Two users in the SAME org:
#   * Admin indexes inline text via `/index <text>` on the chat surface.
#   * Member queries the KB via `POST /kb/query` and gets the same
#     content back.
#
# This is the positive half of the multi-tenant invariant: KB is
# org-shared; every user in the org reads the same corpus.

defmodule DmhAi.Flows.F34OrgKbSharing do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F34"

  @embedding_dim 1024
  @marker "UNIQUE-MARKER-F34-#{:erlang.unique_integer([:positive])}"
  @body @marker <> " " <>
        String.duplicate("Shared org-wide knowledge body for F34 test. ", 8)

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F34")

    Application.put_env(:dmh_ai, :__embedder_stub__, fn texts ->
      vecs =
        Enum.map(texts, fn text ->
          # Deterministic embedding biased by whether the text contains
          # @marker — so a query containing @marker will rank ingested
          # marker-bearing chunks highest under cosine similarity.
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
    member_id = T.uid()
    admin_email  = "u-#{admin_id}@test.local" |> String.downcase()
    member_email = "u-#{member_id}@test.local" |> String.downcase()
    admin_pwd  = "p-#{admin_id}"
    member_pwd = "p-#{member_id}"
    now = System.os_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, admin_email, "Admin", "user", DmhAi.AuthPlug.hash_password(admin_pwd), 1,
       DmhAi.Constants.default_org_id(), "admin", now,
       member_id, member_email, "Member", "user", DmhAi.AuthPlug.hash_password(member_pwd), 1,
       DmhAi.Constants.default_org_id(), "member", now])

    # Pipelines.Text.run trims its body before hashing — match here.
    trimmed_body = String.trim(@body)
    source_ref = :crypto.hash(:sha256, trimmed_body) |> Base.encode16(case: :lower)
    source_id  = SourceId.derive("text", source_ref, DmhAi.Constants.default_org_id())

    on_exit(fn ->
      DmhAi.Ingest.remove_kb_source!(DmhAi.Constants.default_org_id(), source_id)
      for uid <- [admin_id, member_id] do
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM sessions WHERE user_id=?", [uid])
        query!(Repo, "DELETE FROM users WHERE id=?", [uid])
      end
    end)

    %{
      admin_email: admin_email, admin_pwd: admin_pwd,
      member_email: member_email, member_pwd: member_pwd,
      source_id: source_id
    }
  end

  test "member sees admin-indexed content via /kb/query",
       %{admin_email: admin_email, admin_pwd: admin_pwd,
         member_email: member_email, member_pwd: member_pwd,
         source_id: source_id} do
    # 1. Admin indexes inline text.
    admin_token = login_for_token(admin_email, admin_pwd)
    session_id  = T.uid()
    assert post_json("/sessions", %{"id" => session_id}, token: admin_token).status == 200

    chat = post_json("/agent/chat",
                     %{"sessionId" => session_id, "content" => "/index " <> @body},
                     token: admin_token)
    assert chat.status == 200

    # Confirm the row landed.
    [[_internal_id]] =
      query!(Repo, "SELECT id FROM kb_sources WHERE source_id=?", [source_id]).rows

    # 2. Member (different user, same org) queries /kb/query for the marker.
    member_token = login_for_token(member_email, member_pwd)

    query_resp = post_json("/kb/query", %{"q" => @marker}, token: member_token)
    assert query_resp.status == 200, "kb/query: #{query_resp.status} #{query_resp.resp_body}"

    %{"hits" => hits} = Jason.decode!(query_resp.resp_body)
    assert is_list(hits) and hits != [],
           "member must see admin's KB content; got empty hits"

    assert Enum.any?(hits, fn h ->
             h["source_id"] == source_id and String.contains?(h["text"] || "", @marker)
           end),
           "member must see the admin's marker chunk; got #{inspect(hits)}"
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
