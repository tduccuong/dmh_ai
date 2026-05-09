# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F19 — `browser_navigate` consent gate.
#
# `Tools.BrowserNavigate.execute/2` requires the user to have
# accepted the canonical consent text BEFORE the (privacy-touching)
# Playwright session opens. The gate is a single per-user row check
# against `users.browser_consent_at` + `browser_consent_text_hash`,
# resolved by `consent_state/1`. Four states:
#
#   * `:consented`       — accepted, hash matches.
#   * `:never_accepted`  — `consent_at` is NULL.
#   * `:hash_mismatch`   — accepted earlier, but `ConsentText.hash/0`
#                          has rotated (text changed) since.
#   * `:user_not_found`  — defensive; treated as never-accepted.
#
# On any non-`:consented` state, `execute/2` returns
# `{:ok, %{status: "needs_consent", reason: ...}}` WITHOUT spawning
# the browser action loop. The model presents the consent text to
# the user; user POSTs `/auth/me/browser-consent` with the canonical
# `text_hash`; gate flips and a fresh `browser_navigate` proceeds.
#
# The full action-loop (Playwright daemon round-trips through
# `Browser.Loop.run/4`) is a separate flow once the daemon stub
# layer lands. F19 is purely the gate: invoke the tool with each of
# the gate's input states + drive the consent endpoints over HTTP.

defmodule DmhAi.Flows.F19BrowserNavigateConsent do
  use ExUnit.Case, async: false

  alias DmhAi.Browser.ConsentText
  alias DmhAi.Tools.BrowserNavigate
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F19"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F19")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id = T.uid()
    email   = "u-#{user_id}@test.local" |> String.downcase()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, password_changed, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "Test User", "user",
       DmhAi.AuthPlug.hash_password("pw-#{user_id}"), 1,
       System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [user_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, email: email, password: "pw-#{user_id}"}
  end

  describe "consent_state/1" do
    test "fresh user → :never_accepted", %{user_id: user_id} do
      assert BrowserNavigate.consent_state(user_id) == :never_accepted
    end

    test "consent_at + matching hash → :consented", %{user_id: user_id} do
      query!(Repo,
        "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
        [System.os_time(:millisecond), ConsentText.hash(), user_id])

      assert BrowserNavigate.consent_state(user_id) == :consented
    end

    test "consent_at set but stale hash → :hash_mismatch", %{user_id: user_id} do
      query!(Repo,
        "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
        [System.os_time(:millisecond), "stale-hash-from-old-text", user_id])

      assert BrowserNavigate.consent_state(user_id) == :hash_mismatch
    end

    test "unknown user_id → :user_not_found" do
      assert BrowserNavigate.consent_state("ghost-uid-#{T.uid()}") == :user_not_found
    end
  end

  describe "BrowserNavigate.execute/2 gate" do
    test "never_accepted → needs_consent (Browser.Loop NOT invoked)",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, session_id: T.uid()}
      args = %{
        "url"  => "https://example.test/page",
        "goal" => "summarise the page"
      }

      # If the gate falls through to Browser.Loop, the test host would
      # need a running Playwright daemon — it doesn't. So a leak past
      # the gate would fail loudly here. Asserting on the response
      # shape is enough.
      assert {:ok, %{status: "needs_consent", reason: reason}} =
               BrowserNavigate.execute(args, ctx)

      assert is_binary(reason) and reason != "",
             "needs_consent response should carry a human reason; got: #{inspect(reason)}"
    end

    test "consented → falls past the gate (we observe the gate-pass shape, not Loop output)",
         %{user_id: user_id} do
      query!(Repo,
        "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
        [System.os_time(:millisecond), ConsentText.hash(), user_id])

      # Once consented, the tool calls Browser.Loop.run/4 which
      # talks to the Playwright daemon. We don't have one in tests
      # — so the call surfaces as `{:error, ...}` (transport
      # failure) or whatever the loop returns when it can't reach
      # the daemon. The load-bearing assertion is that the gate
      # is no longer the rejecter: result is NOT `needs_consent`.
      ctx = %{user_id: user_id, session_id: T.uid()}
      args = %{"url" => "https://example.test/page", "goal" => "x"}

      result = BrowserNavigate.execute(args, ctx)

      refute match?({:ok, %{status: "needs_consent"}}, result),
             "consented user must pass the gate; got needs_consent: #{inspect(result)}"
    end

    test "missing url → validation error before consent check",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, session_id: T.uid()}

      assert {:error, msg} =
               BrowserNavigate.execute(%{"goal" => "x"}, ctx)
      assert msg =~ "url"
    end

    test "non-https url → validation error",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, session_id: T.uid()}

      assert {:error, msg} =
               BrowserNavigate.execute(
                 %{"url" => "http://example.test", "goal" => "x"}, ctx)
      assert msg =~ "https"
    end

    test "missing goal → validation error",
         %{user_id: user_id} do
      ctx = %{user_id: user_id, session_id: T.uid()}

      assert {:error, msg} =
               BrowserNavigate.execute(
                 %{"url" => "https://example.test"}, ctx)
      assert msg =~ "goal"
    end
  end

  describe "POST /auth/me/browser-consent" do
    test "missing text_hash → 400",
         %{email: email, password: password, user_id: _} do
      token = login_for_token(email, password)

      conn = post_json("/auth/me/browser-consent", %{}, token: token)

      assert conn.status == 400
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] =~ "text_hash"
    end

    test "stale text_hash → 409 with the current hash echoed back",
         %{email: email, password: password, user_id: user_id} do
      token = login_for_token(email, password)

      conn =
        post_json("/auth/me/browser-consent",
          %{"text_hash" => "stale-hash-doesnt-match"}, token: token)

      assert conn.status == 409
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["error"] =~ "stale"
      assert decoded["current_hash"] == ConsentText.hash(),
             "409 response should carry the current canonical hash; got: #{inspect(decoded)}"

      # Stale hash must not flip the user's state.
      assert BrowserNavigate.consent_state(user_id) == :never_accepted
    end

    test "matching hash → 200, consent_state flips to :consented",
         %{email: email, password: password, user_id: user_id} do
      token = login_for_token(email, password)

      assert BrowserNavigate.consent_state(user_id) == :never_accepted

      conn =
        post_json("/auth/me/browser-consent",
          %{"text_hash" => ConsentText.hash()}, token: token)

      assert conn.status == 200,
             "expected 200 on matching hash; got #{conn.status} body=#{conn.resp_body}"

      assert BrowserNavigate.consent_state(user_id) == :consented,
             "after a successful consent POST, consent_state/1 should report :consented"
    end

    test "unauthenticated → 401",
         %{} do
      conn = post_json("/auth/me/browser-consent",
                        %{"text_hash" => ConsentText.hash()})

      assert conn.status == 401
    end
  end

  describe "DELETE /auth/me/browser-consent" do
    test "consented user → revokes, consent_state flips to :never_accepted",
         %{email: email, password: password, user_id: user_id} do
      token = login_for_token(email, password)

      # First accept.
      conn =
        post_json("/auth/me/browser-consent",
          %{"text_hash" => ConsentText.hash()}, token: token)
      assert conn.status == 200
      assert BrowserNavigate.consent_state(user_id) == :consented

      # Then revoke.
      conn =
        delete_request("/auth/me/browser-consent", token: token)

      assert conn.status == 200
      assert BrowserNavigate.consent_state(user_id) == :never_accepted,
             "DELETE must NULL out consent_at AND text_hash so the next " <>
               "browser_navigate re-prompts"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  # `RateLimit` plug keys `/auth/*` requests on remote_ip (login is by
  # definition anonymous, no user_id yet). Hammer's bucket is in-memory
  # and persists across tests — so a few failed test runs in quick
  # succession on the same host fill the 8/min bucket and the next
  # test gets 429. Spread login traffic across IP buckets by giving
  # each test-helper request a unique remote_ip in the 10.x range
  # (private + clearly-not-loopback).
  defp random_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(254)}
  end

  defp post_json(path, body, opts \\ []) do
    conn =
      Plug.Test.conn(:post, path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, random_ip())

    conn =
      case Keyword.get(opts, :token) do
        nil -> conn
        tok -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> tok)
      end

    DmhAi.Router.call(conn, DmhAi.Router.init([]))
  end

  defp delete_request(path, opts) do
    conn =
      :delete
      |> Plug.Test.conn(path)
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
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["token"]
  end
end
