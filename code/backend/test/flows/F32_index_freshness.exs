# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F32 — `/index <url>` freshness e2e (Primitive 0.2).
#
# Drives the URL pipeline twice with the Fetcher stubbed to return
# DIFFERENT bodies on each call. Same URL ⇒ same source_id ⇒ second
# ingest hits the REPLACE branch in `DmhAi.Ingest.upsert_kb_source`.
#
# Asserts:
#   * After step 1: chunk text contains v1 marker.
#   * After step 2 (atomic replace): chunks for the source NO LONGER
#     contain v1 marker; ALL chunks contain v2 marker.
#   * `kb_sources.last_indexed_at` strictly greater after replace.
#   * Internal_id changes (delete + insert), per the documented
#     replace semantics.
#
# This exercises the FULL data path on the URL kind:
#   Router → AgentChat → Commands.dispatch → run_index (admin?)
#   → Pipelines.URL.run_async → Task → Fetcher.fetch (stub)
#   → VectorDB.ingest → DmhAi.Ingest.upsert_kb_source (replace branch
#     atomically deletes old chunks/vectors/FTS and inserts fresh).

defmodule DmhAi.Flows.F32IndexFreshness do
  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Ingest.SourceId
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F32"

  @embedding_dim 1024
  @url "https://example.test/freshness-page"

  # Two distinct bodies, each long enough to clear the URL pipeline's
  # `min_chars_for_useful_page` (500-char) gate.
  @body_v1 String.duplicate("ALPHA-MARKER-V1 page content with significant length to clear gates. ", 12)
  @body_v2 String.duplicate("BETA-MARKER-V2 entirely different wording in version two. ", 14)

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F32")

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
      Application.delete_env(:dmh_ai, :__fetcher_stub__)
      teardown.()
    end)

    :ok
  end

  setup do
    user_id  = T.uid()
    email    = "u-#{user_id}@test.local" |> String.downcase()
    password = "p-#{user_id}"
    password_hash = DmhAi.AuthPlug.hash_password(password)

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "Admin", "user", password_hash, 1,
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    source_id = SourceId.derive("url", @url, DmhAi.Constants.default_org_id())

    on_exit(fn ->
      DmhAi.Ingest.remove_kb_source!(DmhAi.Constants.default_org_id(), source_id)
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM session_progress WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM sessions WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, email: email, password: password, source_id: source_id}
  end

  test "re-index of changed URL body atomically replaces chunks (only v2 wording survives)",
       %{email: email, password: password, source_id: source_id} do
    token = login_for_token(email, password)
    session_id = T.uid()
    assert post_json("/sessions", %{"id" => session_id}, token: token).status == 200

    # ── Step 1: stub Fetcher to return v1 body, /index the URL. ──────────
    set_fetcher(@body_v1)

    chat1 =
      post_json("/agent/chat",
                %{"sessionId" => session_id, "content" => "/index " <> @url},
                token: token)

    assert chat1.status == 200

    # URL pipeline is async — poll until kb_sources row appears.
    assert wait_for_kb_row(source_id, 8_000), "v1 /index never persisted kb_sources"

    [[internal_id_v1, last_indexed_v1]] =
      query!(Repo,
             "SELECT id, last_indexed_at FROM kb_sources WHERE source_id=?",
             [source_id]).rows

    chunks_v1 = chunk_texts(internal_id_v1)
    assert chunks_v1 != []
    assert Enum.any?(chunks_v1, &String.contains?(&1, "ALPHA-MARKER-V1")),
           "v1 chunks must contain ALPHA-MARKER-V1; got #{inspect(chunks_v1)}"

    # Tick the clock so a replace produces a strictly-greater last_indexed_at.
    Process.sleep(20)

    # ── Step 2: re-stub Fetcher to return v2, re-/index. ─────────────────
    set_fetcher(@body_v2)

    chat2 =
      post_json("/agent/chat",
                %{"sessionId" => session_id, "content" => "/index " <> @url},
                token: token)

    assert chat2.status == 200

    # Poll for the replace to land: internal_id changes once the
    # atomic delete+insert transaction commits.
    assert wait_for_internal_id_change(source_id, internal_id_v1, 8_000),
           "replace branch never produced a new internal_id"

    [[internal_id_v2, last_indexed_v2]] =
      query!(Repo,
             "SELECT id, last_indexed_at FROM kb_sources WHERE source_id=?",
             [source_id]).rows

    refute internal_id_v2 == internal_id_v1, "replace must produce a fresh internal_id"
    assert last_indexed_v2 > last_indexed_v1,
           "last_indexed_at must bump on replace (was #{last_indexed_v1}, now #{last_indexed_v2})"

    # Critically: no v1 chunks remain.
    assert chunk_count(internal_id_v1) == 0,
           "old internal_id must have zero chunks after replace"

    chunks_v2 = chunk_texts(internal_id_v2)
    assert chunks_v2 != [], "v2 chunks must exist"
    refute Enum.any?(chunks_v2, &String.contains?(&1, "ALPHA-MARKER-V1")),
           "v2 chunks must NOT contain v1 marker (stale fragment leak)"
    assert Enum.all?(chunks_v2, &String.contains?(&1, "BETA-MARKER-V2")),
           "all v2 chunks must contain BETA-MARKER-V2"
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  # Fetcher stub returning a fixed body. The stub closes over `body`
  # captured at install time, so changing the stub flips the payload.
  defp set_fetcher(body) do
    Application.put_env(:dmh_ai, :__fetcher_stub__, fn _url ->
      {:ok,
       %{
         title:        "F32 Test Page",
         content:      body,
         html:         "<html><body>" <> body <> "</body></html>",
         final_url:    @url,
         status:       200,
         content_type: "text/html"
       }}
    end)
  end

  defp wait_for_kb_row(source_id, timeout_ms) do
    poll(fn ->
      case query!(Repo, "SELECT 1 FROM kb_sources WHERE source_id=? LIMIT 1", [source_id]).rows do
        [[1]] -> true
        _     -> false
      end
    end, timeout_ms)
  end

  defp wait_for_internal_id_change(source_id, old_id, timeout_ms) do
    poll(fn ->
      case query!(Repo, "SELECT id FROM kb_sources WHERE source_id=?", [source_id]).rows do
        [[new_id]] when new_id != old_id -> true
        _ -> false
      end
    end, timeout_ms)
  end

  defp poll(check_fn, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_loop(check_fn, deadline)
  end

  defp poll_loop(check_fn, deadline) do
    cond do
      check_fn.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(50); poll_loop(check_fn, deadline)
    end
  end

  defp chunk_texts(internal_id) do
    query!(Repo,
           "SELECT chunk_text FROM kb_chunks_meta WHERE source_id=? ORDER BY chunk_idx",
           [internal_id]).rows
    |> Enum.map(fn [t] -> t end)
  end

  defp chunk_count(internal_id) do
    [[n]] = query!(Repo,
                   "SELECT COUNT(*) FROM kb_chunks_meta WHERE source_id=?",
                   [internal_id]).rows
    n
  end

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
