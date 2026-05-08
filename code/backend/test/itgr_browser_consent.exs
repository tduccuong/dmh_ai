# Integration tests: browser-tools consent gate (v0 phase 1).
#
# Coverage:
#   - Tools.BrowserNavigate blocks with status="needs_consent" on a fresh
#     user (NULL watermark) and writes a kind="browser_consent_required"
#     session_progress row carrying the canonical consent text.
#   - Status reason text differentiates :never_accepted vs :hash_mismatch.
#   - After POST /auth/me/browser-consent with the correct hash, the
#     gate passes; the tool now returns the Phase-1 placeholder error
#     ("action loop not yet enabled") rather than needs_consent.
#   - DELETE /auth/me/browser-consent revokes; the next invocation
#     re-prompts.
#   - POST with a wrong text_hash is rejected with 409.
#   - GET /auth/me/browser-consent returns the canonical payload.
#   - URL must be https://; missing or non-https `url` is rejected
#     before the consent check.
#
# Run with:   MIX_ENV=test mix test test/itgr_browser_consent.exs

defmodule Itgr.BrowserConsent do
  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Browser.ConsentText, Tools.BrowserNavigate}
  alias DmhAi.Handlers.Auth, as: AuthHandler
  import Ecto.Adapters.SQL, only: [query!: 3]
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  defp uid, do: T.uid()

  defp seed_user(user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at)
      VALUES (?,?,?,?,?)
      """,
      [user_id, "bc_#{user_id}@itgr.local", "", "user", now])
  end

  defp seed_session(session_id, user_id) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, created_at, updated_at) VALUES (?,?,?,?,?)",
      [session_id, user_id, "assistant", now, now])
  end

  defp consent_state(user_id) do
    %{rows: [[ts, hash]]} =
      query!(Repo,
        "SELECT browser_consent_at, browser_consent_text_hash FROM users WHERE id=?",
        [user_id])
    {ts, hash}
  end

  defp progress_rows_of_kind(session_id, kind) do
    %{rows: rows} =
      query!(Repo,
        "SELECT label FROM session_progress WHERE session_id=? AND kind=? ORDER BY id",
        [session_id, kind])

    Enum.map(rows, fn [label] -> label end)
  end

  defp post_consent(user, body) do
    encoded = Jason.encode!(body)

    conn(:post, "/_test", encoded)
    |> put_req_header("content-type", "application/json")
    |> AuthHandler.post_browser_consent(user)
  end

  defp delete_consent(user) do
    conn(:delete, "/_test") |> AuthHandler.delete_browser_consent(user)
  end

  defp get_consent(user) do
    conn(:get, "/_test") |> AuthHandler.get_browser_consent(user)
  end

  defp parse_json(conn), do: Jason.decode!(conn.resp_body)

  defp browser_args do
    %{"url" => "https://example.com", "goal" => "find the latest news"}
  end

  # ─── consent gate: never accepted ──────────────────────────────────────────

  test "fresh user: tool returns needs_consent + writes a browser_consent_required row" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id)

    assert {:ok, %{status: "needs_consent", reason: reason}} =
             BrowserNavigate.execute(browser_args(), %{user_id: user_id, session_id: sid})

    assert reason =~ "must read and accept"

    # Row label is a short marker — the full canonical text comes
    # from GET /auth/me/browser-consent at modal-open time. See the
    # comment on @progress_marker in Tools.BrowserNavigate.
    assert [marker] = progress_rows_of_kind(sid, "browser_consent_required")
    assert marker == BrowserNavigate.progress_marker()
  end

  # ─── consent state lookup ─────────────────────────────────────────────────

  test "consent_state/1: never_accepted → :hash_mismatch → :consented" do
    user_id = uid()
    seed_user(user_id)

    assert :never_accepted = BrowserNavigate.consent_state(user_id)

    # Inject a stale hash (simulates a user who accepted under a
    # previous canonical text).
    query!(Repo,
      "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
      [1, "stalehash", user_id])
    assert :hash_mismatch = BrowserNavigate.consent_state(user_id)

    # Update to the current hash.
    query!(Repo,
      "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
      [System.os_time(:millisecond), ConsentText.hash(), user_id])
    assert :consented = BrowserNavigate.consent_state(user_id)
  end

  # ─── once accepted, gate passes (Phase 1: phase-2-not-enabled error) ──────

  test "after POST /auth/me/browser-consent: gate passes; tool returns Phase-1 placeholder error" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id)

    conn = post_consent(%{id: user_id}, %{text_hash: ConsentText.hash()})
    assert conn.status == 200
    assert %{"consented" => true} = parse_json(conn)

    {ts, hash} = consent_state(user_id)
    assert is_integer(ts)
    assert hash == ConsentText.hash()

    # With consent in place, the tool no longer returns needs_consent —
    # it returns the Phase-1 placeholder shape (`:ok` with a distinct
    # status string) so the model can clearly tell consent passed.
    assert {:ok, %{status: status, reason: reason}} =
             BrowserNavigate.execute(browser_args(), %{user_id: user_id, session_id: sid})

    assert status == "browser_action_loop_pending"
    assert reason =~ "Consent recorded"
    assert reason =~ "enabled"
  end

  # ─── stale hash rejected at POST ──────────────────────────────────────────

  test "POST with stale text_hash: 409 rejected; consent state untouched" do
    user_id = uid()
    seed_user(user_id)

    conn = post_consent(%{id: user_id}, %{text_hash: "deadbeef"})
    assert conn.status == 409
    assert %{"current_hash" => current} = parse_json(conn)
    assert current == ConsentText.hash()

    assert {nil, nil} = consent_state(user_id)
  end

  test "POST with missing text_hash: 400 rejected" do
    user_id = uid()
    seed_user(user_id)

    conn = post_consent(%{id: user_id}, %{})
    assert conn.status == 400
  end

  # ─── revoke ───────────────────────────────────────────────────────────────

  test "DELETE /auth/me/browser-consent: nulls both columns; next call re-prompts" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id)

    # Accept first.
    _ = post_consent(%{id: user_id}, %{text_hash: ConsentText.hash()})

    # Revoke.
    conn = delete_consent(%{id: user_id})
    assert conn.status == 200
    assert %{"consented" => false} = parse_json(conn)
    assert {nil, nil} = consent_state(user_id)

    # Tool re-prompts.
    assert {:ok, %{status: "needs_consent"}} =
             BrowserNavigate.execute(browser_args(), %{user_id: user_id, session_id: sid})
  end

  # ─── GET payload shape ────────────────────────────────────────────────────

  test "GET /auth/me/browser-consent returns canonical payload" do
    user_id = uid()
    seed_user(user_id)

    conn = get_consent(%{id: user_id})
    assert conn.status == 200

    payload = parse_json(conn)
    assert payload["current_hash"] == ConsentText.hash()
    assert payload["current_text"] =~ "DMH-AI Browser Tools"
    assert payload["consented"] == false
    assert payload["accepted_at"] == nil
    assert payload["hash_matches"] == false
  end

  # ─── input validation ─────────────────────────────────────────────────────

  test "non-https URL is rejected before the consent check" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id)

    args = %{"url" => "http://example.com", "goal" => "x"}

    assert {:error, msg} =
             BrowserNavigate.execute(args, %{user_id: user_id, session_id: sid})

    assert msg =~ "https://"
    # No consent prompt fired — the URL check rejected first.
    assert progress_rows_of_kind(sid, "browser_consent_required") == []
  end

  test "missing goal is rejected" do
    user_id = uid()
    seed_user(user_id)

    args = %{"url" => "https://example.com"}
    assert {:error, msg} = BrowserNavigate.execute(args, %{user_id: user_id, session_id: uid()})
    assert msg =~ "goal"
  end

  # ─── consent text changes drift the hash (re-prompt-on-edit invariant) ────

  test "current hash matches the canonical text byte-for-byte" do
    expected = :crypto.hash(:sha256, ConsentText.text()) |> Base.encode16(case: :lower)
    assert ConsentText.hash() == expected
  end

  # ─── auto-resume after accept ─────────────────────────────────────────────

  test "POST with session_id fires {:auto_resume_assistant, session_id} to the user's agent" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id)

    # Stand in for the user's UserAgent: register THIS test process
    # under the user_id key so Supervisor.ensure_started returns
    # self() and the send/2 lands in our mailbox.
    {:ok, _} = Registry.register(DmhAi.Agent.Registry, user_id, nil)

    conn = post_consent(%{id: user_id}, %{text_hash: ConsentText.hash(), session_id: sid})
    assert conn.status == 200

    assert_receive {:auto_resume_assistant, ^sid}, 500
  end

  test "POST without session_id does NOT fire auto_resume" do
    user_id = uid()
    seed_user(user_id)

    {:ok, _} = Registry.register(DmhAi.Agent.Registry, user_id, nil)

    conn = post_consent(%{id: user_id}, %{text_hash: ConsentText.hash()})
    assert conn.status == 200

    refute_receive {:auto_resume_assistant, _}, 200
  end

  test "POST with session_id NOT owned by caller does NOT fire auto_resume" do
    owner = uid(); other = uid(); sid = uid()
    seed_user(owner); seed_user(other)
    seed_session(sid, owner)

    # Register `other` (the caller), but the session belongs to
    # `owner`. The handler must refuse to auto-resume someone else's
    # session even when the session_id is real.
    {:ok, _} = Registry.register(DmhAi.Agent.Registry, other, nil)

    conn = post_consent(%{id: other}, %{text_hash: ConsentText.hash(), session_id: sid})
    assert conn.status == 200

    refute_receive {:auto_resume_assistant, _}, 200
  end
end
