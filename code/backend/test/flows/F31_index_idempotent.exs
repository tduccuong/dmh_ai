# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F31 — `/index <text>` idempotent e2e (Primitive 0.2).
#
# Admin POSTs `/index <body>` twice with identical inline text.
# Asserts the FULL data path collapses to the skip branch on the
# second call:
#
#   POST /agent/chat
#     → Router → AgentChat
#     → Commands.dispatch → run_index (admin? ok)
#     → Pipelines.Text.run
#     → VectorDB.ingest (scope=:knowledge)
#     → DmhAi.Ingest.upsert_kb_source (sha256 gate → :skipped)
#
# We use the text pipeline (synchronous) rather than the URL crawler
# pipeline because the URL path is async + has BFS gates that aren't
# the focus of this test. The Ingest pipeline branching (skip vs
# replace) is identical for both source kinds — text gets us there
# in one HTTP roundtrip.

defmodule DmhAi.Flows.F31IndexIdempotent do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F31"

  @embedding_dim 1024
  # Inline text body; sha256(body) becomes the natural source_ref.
  @body "Stable body content used to exercise the idempotent skip path. " <>
        "Padded to ensure the chunker emits at least one chunk under the " <>
        "default min-chunk-tokens threshold so the embed/insert path runs."

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F31")

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

    # Swift.localize → LLM.call passthrough. Some chain steps call
    # this even on the synchronous text path; stub to a deterministic
    # echo of the message so the test never depends on a real model.
    Application.put_env(:dmh_ai, :__llm_call_stub__, fn _model, messages, _opts ->
      msgs = Enum.map(messages, fn m -> Map.new(m, fn {k, v} -> {to_string(k), v} end) end)
      last_user = Enum.reverse(msgs) |> Enum.find(&(&1["role"] == "user"))
      passthrough = (last_user && last_user["content"]) || "ok"
      {:ok, %{message: %{"role" => "assistant", "content" => passthrough}, finish_reason: "stop"}}
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
    user_id  = T.uid()
    email    = "u-#{user_id}@test.local" |> String.downcase()
    password = "p-#{user_id}"
    password_hash = DmhAi.AuthPlug.hash_password(password)

    # Admin in the default org.
    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "Admin User", "user", password_hash, 1,
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    source_ref = :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower)
    source_id  = SourceId.derive("text", source_ref, DmhAi.Constants.default_org_id())

    on_exit(fn ->
      DmhAi.Ingest.remove_kb_source!(DmhAi.Constants.default_org_id(), source_id)
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM session_progress WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, email: email, password: password, source_id: source_id}
  end

  test "second /index of unchanged content is a skip (no row churn, last_seen_at bumps)",
       %{email: email, password: password, source_id: source_id} do
    token = login_for_token(email, password)
    session_id = T.uid()
    assert post_json("/sessions", %{"id" => session_id}, token: token).status == 200

    # First /index — text path is synchronous; row is present by the time the response returns.
    chat1 =
      post_json("/agent/chat",
                %{"sessionId" => session_id, "content" => "/index " <> @body},
                token: token)

    assert chat1.status == 200, "first /index POST: #{chat1.status} #{chat1.resp_body}"

    [[first_id, first_indexed_at, first_seen_at]] =
      query!(Repo,
             "SELECT id, last_indexed_at, last_seen_at FROM kb_sources WHERE source_id=?",
             [source_id]).rows

    chunks_before = chunk_count(first_id)
    assert chunks_before > 0, "first /index should have inserted chunks"

    # Tick the clock so a bump on last_seen_at is observable.
    Process.sleep(20)

    # Second /index — identical body → identical source_id → SKIP path.
    chat2 =
      post_json("/agent/chat",
                %{"sessionId" => session_id, "content" => "/index " <> @body},
                token: token)

    assert chat2.status == 200, "second /index POST: #{chat2.status} #{chat2.resp_body}"

    [[second_id, second_indexed_at, second_seen_at]] =
      query!(Repo,
             "SELECT id, last_indexed_at, last_seen_at FROM kb_sources WHERE source_id=?",
             [source_id]).rows

    assert second_id == first_id,
           "skip path must NOT create a new kb_sources row"
    assert second_indexed_at == first_indexed_at,
           "last_indexed_at must NOT change on skip"
    assert second_seen_at > first_seen_at,
           "last_seen_at must bump on skip (was #{first_seen_at}, now #{second_seen_at})"

    chunks_after = chunk_count(first_id)
    assert chunks_after == chunks_before,
           "skip path must NOT touch chunks (was #{chunks_before}, now #{chunks_after})"
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
