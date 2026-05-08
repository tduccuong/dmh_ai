# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.Auth do
  import Plug.Conn
  alias DmhAi.Repo
  alias DmhAi.AuthPlug
  alias DmhAi.MemoCrypto
  alias DmhAi.Agent.UserAgent
  require Logger
  import Ecto.Adapters.SQL, only: [query!: 2, query!: 3]

  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  # GET /auth/me
  def get_me(conn) do
    case AuthPlug.get_auth_user(conn) do
      nil -> json(conn, 401, %{error: "Unauthorized"})
      user -> json(conn, 200, user)
    end
  end

  # GET /users
  def get_users(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      result = query!(Repo, "SELECT id, email, name, role, created_at FROM users WHERE deleted=0 ORDER BY created_at")

      users =
        Enum.map(result.rows, fn [id, email, name, role, created_at] ->
          %{id: id, email: email, name: name, role: role, createdAt: created_at}
        end)

      json(conn, 200, users)
    end
  end

  # GET /user/profile
  def get_user_profile(conn, user) do
    result = query!(Repo, "SELECT profile FROM users WHERE id=?", [user.id])

    profile =
      case result.rows do
        [[p] | _] -> p || ""
        _ -> ""
      end

    json(conn, 200, %{profile: profile})
  end

  # GET /admin/user-profiles
  def get_admin_user_profiles(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      result =
        query!(Repo, "SELECT id, email, name, role, profile FROM users WHERE deleted=0 ORDER BY created_at")

      users =
        Enum.map(result.rows, fn [id, email, name, role, profile] ->
          %{id: id, email: email, name: name, role: role, profile: profile || ""}
        end)

      json(conn, 200, users)
    end
  end

  # GET /users/prefs
  def get_user_prefs(conn, user) do
    key = "prefs_#{user.id}"
    result = query!(Repo, "SELECT value FROM settings WHERE key=?", [key])

    prefs =
      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    json(conn, 200, prefs)
  end

  # GET /user/fact-counts
  def get_user_fact_counts(conn, user) do
    result = query!(Repo, "SELECT topic, count FROM user_fact_counts WHERE user_id=?", [user.id])
    counts = Map.new(result.rows, fn [topic, count] -> {topic, count} end)
    json(conn, 200, counts)
  end

  # POST /auth/login
  def post_login(conn) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    email = (d["email"] || "") |> String.trim() |> String.downcase()
    password = d["password"] || ""

    result =
      query!(Repo, """
      SELECT id, email, name, role, password_hash, password_changed,
             memo_kdf_salt, memo_wrapped_mmk
      FROM users WHERE email=? AND deleted=0
      """, [email])

    case result.rows do
      [[id, db_email, name, role, password_hash, pw_changed, memo_salt, memo_wrapped] | _] ->
        if AuthPlug.verify_password(password, password_hash) do
          token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
          now = :os.system_time(:second)
          query!(Repo, "INSERT INTO auth_tokens (token, user_id, created_at) VALUES (?,?,?)", [token, id, now])

          # One-shot V1 → V2 migration. Only fires for users who still
          # have a legacy password-wrapped MMK (memo_kdf_salt non-NULL,
          # memo_wrapped_mmk leading byte == 0x01). Idempotent: V2-
          # wrapped users skip immediately. See specs/memo_encryption.md
          # § Migration from V1.
          maybe_migrate_v1_to_v2(id, password, memo_salt, memo_wrapped)

          display = name || hd(String.split(db_email, "@"))

          json(conn, 200, %{
            token: token,
            user: %{
              id: id,
              email: db_email,
              name: display,
              role: role,
              passwordChanged: pw_changed == 1 or pw_changed == true
            }
          })
        else
          json(conn, 401, %{error: "Invalid username or password"})
        end

      _ ->
        json(conn, 401, %{error: "Invalid username or password"})
    end
  end

  # V1 → V2 migration. Login is the only place that has the user's
  # password, and the password is needed to unwrap a V1 wrap once.
  # After this point the MMK is wrapped under the deployment master
  # key and no further password unwrap is ever needed.
  #
  # Branches:
  #   * memo_salt nil OR wrap nil → user has no V1 wrap. Nothing to do
  #     (the lazy ensure path handles V2 + first-time on demand).
  #   * wrap leading byte 0x02 → already V2. Idempotent skip.
  #   * wrap leading byte 0x01 → unwrap with password, re-wrap with
  #     master, persist. NULL out memo_kdf_salt to mark migration done.
  #   * unknown leading byte → log warning, leave alone.
  defp maybe_migrate_v1_to_v2(user_id, password, memo_salt, memo_wrapped) do
    cond do
      not (is_binary(memo_salt) and is_binary(memo_wrapped)) ->
        :ok

      MemoCrypto.wrap_version(memo_wrapped) != :v1 ->
        :ok

      true ->
        password_key = MemoCrypto.derive_password_key(password, memo_salt)

        case MemoCrypto.unwrap_mmk(memo_wrapped, password_key) do
          {:ok, mmk} ->
            wrapped_v2 = MemoCrypto.wrap_with_master(mmk, MemoCrypto.MasterKey.get())

            query!(Repo, """
              UPDATE users SET memo_wrapped_mmk = ?, memo_kdf_salt = NULL WHERE id = ?
              """, [wrapped_v2, user_id])

            Logger.info("[MemoCrypto] migrated v1 → v2 wrap for user=#{user_id}")

          {:error, reason} ->
            Logger.warning(
              "[MemoCrypto] v1 unwrap failed for user=#{user_id} reason=#{inspect(reason)} — leaving wrap untouched")
        end
    end
  end

  # POST /auth/logout
  def post_logout(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token = String.trim(token)

        # Logout revokes the auth token but does NOT wipe the in-memory
        # MMK cache. Per specs/memo_encryption.md, memo access must
        # survive logout/login — the encryption key is master-key-
        # wrapped on disk and re-unwraps lazily on the next memo
        # activity (regardless of which session it happens in). The
        # logout act here is purely about token revocation.
        query!(Repo, "DELETE FROM auth_tokens WHERE token=?", [token])

      _ ->
        :ok
    end

    json(conn, 200, %{ok: true})
  end

  # POST /users (admin: create user)
  def post_create_user(conn, user) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")
      email = (d["email"] || "") |> String.trim() |> String.downcase()
      name = d["name"] |> then(fn n -> if n && String.trim(n) != "", do: String.trim(n), else: nil end)
      password = d["password"] || ""
      role = d["role"] || "user"

      if email == "" or password == "" do
        json(conn, 400, %{error: "Email and password are required"})
      else
        existing = query!(Repo, "SELECT id, deleted FROM users WHERE email=?", [email])

        case existing.rows do
          [[existing_id, 1] | _] ->
            # Reactivate soft-deleted user
            query!(Repo, """
            UPDATE users SET name=?, password_hash=?, role=?, deleted=0, password_changed=0
            WHERE id=?
            """, [name, AuthPlug.hash_password(password), role, existing_id])

            json(conn, 200, %{id: existing_id, email: email, name: name, role: role})

          [[_existing_id, _] | _] ->
            json(conn, 409, %{error: "Email already exists"})

          _ ->
            uid = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
            now = :os.system_time(:second)

            query!(Repo, """
            INSERT INTO users (id, email, name, password_hash, role, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [uid, email, name, AuthPlug.hash_password(password), role, now])

            json(conn, 200, %{id: uid, email: email, name: name, role: role})
        end
      end
    end
  end

  # POST /user/track-facts
  # Accepts {candidates: [string]}, runs Jaccard normalization + threshold check,
  # promotes to user profile if threshold reached. Idempotent fire-and-forget endpoint.
  @fact_threshold 3

  def post_track_facts(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    candidates = d["candidates"] || []

    track_facts_for_user(user.id, candidates)
    json(conn, 200, %{ok: true})
  end

  @doc "Called from ProfileExtractor to process candidate topics after each LLM turn."
  def track_facts_for_user(user_id, candidates) do
    if is_list(candidates) and candidates != [] do
      result = query!(Repo, "SELECT topic, count FROM user_fact_counts WHERE user_id=?", [user_id])
      initial_counts = Map.new(result.rows, fn [topic, count] -> {topic, count} end)

      {new_counts, promoted} = process_fact_candidates(candidates, initial_counts)

      # Write deltas to DB
      Enum.each(new_counts, fn {topic, new_val} ->
        old_val = Map.get(initial_counts, topic, 0)
        delta = new_val - old_val
        if delta != 0 do
          query!(Repo, """
          INSERT INTO user_fact_counts (user_id, topic, count) VALUES (?, ?, ?)
          ON CONFLICT(user_id, topic) DO UPDATE SET count = count + excluded.count
          """, [user_id, topic, delta])
        end
      end)

      # Merge promoted topics into user profile
      if promoted != [] do
        pr = query!(Repo, "SELECT profile FROM users WHERE id=?", [user_id])
        profile = case pr.rows do
          [[p] | _] -> p || ""
          _ -> ""
        end
        new_profile = merge_interests(profile, promoted) |> String.slice(0, 4000)
        query!(Repo, "UPDATE users SET profile=? WHERE id=?", [new_profile, user_id])
      end
    end
  end

  defp process_fact_candidates(candidates, initial_counts) do
    Enum.reduce(candidates, {initial_counts, []}, fn raw, {counts, promoted} ->
      t = raw |> to_string() |> String.trim() |> String.downcase()
      if t == "" do
        {counts, promoted}
      else
        t = jaccard_normalize(t, counts)
        current = Map.get(counts, t, 0)
        if current < 0 do
          # Already promoted — skip
          {counts, promoted}
        else
          new_val = current + 1
          if new_val >= @fact_threshold do
            {Map.put(counts, t, -1), [String.trim(raw) | promoted]}
          else
            {Map.put(counts, t, new_val), promoted}
          end
        end
      end
    end)
  end

  # Word-level Jaccard similarity normalization: if a known topic key matches
  # the candidate with score >= 0.4, collapse candidate into that key.
  defp jaccard_normalize(topic, counts) do
    t_words = topic |> String.split() |> Enum.filter(&(String.length(&1) > 3))
    if t_words == [] do
      topic
    else
      best =
        Enum.reduce(counts, {nil, 0.0}, fn {key, _}, {best_key, best_score} ->
          k_words = key |> String.split() |> Enum.filter(&(String.length(&1) > 3))
          intersection = Enum.count(t_words, &(&1 in k_words))
          if intersection == 0 do
            {best_key, best_score}
          else
            union = length(t_words) + length(k_words) - intersection
            score = if union > 0, do: intersection / union, else: 0.0
            if score > best_score, do: {key, score}, else: {best_key, best_score}
          end
        end)

      case best do
        {key, score} when score >= 0.4 and key != nil -> key
        _ -> topic
      end
    end
  end

  # Parse bullet-list profile format and merge new topics under the "Interests" key.
  # Format: "- Key: val1, val2\n- Key2: val3"
  defp merge_interests(profile, topics) do
    lines = profile |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "-"))

    {key_order, key_map} =
      Enum.reduce(lines, {[], %{}}, fn line, {order, map} ->
        rest = line |> String.slice(1, String.length(line)) |> String.trim()
        {k, v_str} =
          case String.split(rest, ":", parts: 2) do
            [k, v] -> {String.trim(k), String.trim(v)}
            [k] -> {String.trim(k), ""}
          end
        kl = String.downcase(k)
        values = v_str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        if Map.has_key?(map, kl) do
          {order, Map.update!(map, kl, fn e -> %{e | values: e.values ++ values} end)}
        else
          {order ++ [kl], Map.put(map, kl, %{orig_key: k, values: values})}
        end
      end)

    {key_order, key_map} =
      if Map.has_key?(key_map, "interests") do
        {key_order, key_map}
      else
        {key_order ++ ["interests"], Map.put(key_map, "interests", %{orig_key: "Interests", values: []})}
      end

    key_map =
      Enum.reduce(topics, key_map, fn topic, m ->
        tl = String.downcase(topic)
        Map.update!(m, "interests", fn e ->
          existing_lower = Enum.map(e.values, &String.downcase/1)
          if tl in existing_lower, do: e, else: %{e | values: e.values ++ [tl]}
        end)
      end)

    key_order
    |> Enum.map(fn kl ->
      e = key_map[kl]
      deduped =
        Enum.reduce(e.values, {[], MapSet.new()}, fn v, {acc, seen} ->
          vl = String.downcase(v)
          if MapSet.member?(seen, vl), do: {acc, seen}, else: {acc ++ [v], MapSet.put(seen, vl)}
        end)
        |> elem(0)
      "- #{e.orig_key}: #{Enum.join(deduped, ", ")}"
    end)
    |> Enum.join("\n")
  end

  # PUT /auth/password
  def put_password(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    current = d["current"] || ""
    new_pw = d["new"] || ""

    if new_pw == "" do
      json(conn, 400, %{error: "New password required"})
    else
      result = query!(Repo, "SELECT password_hash FROM users WHERE id=?", [user.id])

      case result.rows do
        [[password_hash] | _] ->
          if AuthPlug.verify_password(current, password_hash) do
            # No memo-key work needed — under V2 the MMK is wrapped
            # under the deployment master key, not the user's
            # password. Changing the password leaves the wrap (and
            # therefore memo access) untouched.
            query!(Repo, "UPDATE users SET password_hash=?, password_changed=1 WHERE id=?",
              [AuthPlug.hash_password(new_pw), user.id])

            json(conn, 200, %{ok: true})
          else
            json(conn, 401, %{error: "Current password is incorrect"})
          end

        _ ->
          json(conn, 401, %{error: "Current password is incorrect"})
      end
    end
  end

  # PUT /user/profile
  def put_user_profile(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    profile = (d["profile"] || "") |> to_string() |> String.slice(0, 4000)
    query!(Repo, "UPDATE users SET profile=? WHERE id=?", [profile, user.id])
    json(conn, 200, %{ok: true})
  end

  # PUT /users/prefs
  def put_user_prefs(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    key = "prefs_#{user.id}"

    result = query!(Repo, "SELECT value FROM settings WHERE key=?", [key])

    prefs =
      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end

    allowed_keys = ["lang", "notificationPollInterval"]
    updates = Map.take(d, allowed_keys)
    new_prefs = Map.merge(prefs, updates)

    query!(Repo, "INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", [key, Jason.encode!(new_prefs)])

    json(conn, 200, new_prefs)
  end

  # PUT /user/fact-counts
  def put_user_fact_counts(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")

    if not is_map(d) do
      json(conn, 400, %{error: "Expected object"})
    else
      Enum.each(d, fn {topic, delta} ->
        topic = if is_binary(topic), do: String.trim(topic), else: ""

        if topic != "" do
          query!(Repo, """
          INSERT INTO user_fact_counts (user_id, topic, count) VALUES (?, ?, ?)
          ON CONFLICT(user_id, topic) DO UPDATE SET count = count + excluded.count
          """, [user.id, String.downcase(topic), trunc(delta)])
        end
      end)

      result = query!(Repo, "SELECT topic, count FROM user_fact_counts WHERE user_id=?", [user.id])
      counts = Map.new(result.rows, fn [topic, count] -> {topic, count} end)
      json(conn, 200, counts)
    end
  end

  # ── Browser-tools consent ────────────────────────────────────────────────

  # GET /auth/me/browser-consent
  # Always returns 200 with the canonical text + hash + the user's
  # current state. Drives the Settings → Browser tools panel.
  def get_browser_consent(conn, user) do
    state = browser_consent_payload(user.id)
    json(conn, 200, state)
  end

  # POST /auth/me/browser-consent — record acceptance.
  #
  # Body:
  #   `text_hash`  (required): hex sha256 of the text the FE actually
  #     showed the user. Stale-text race protection — a mismatch with
  #     the current canonical hash is rejected with 409 and the FE
  #     re-fetches.
  #   `session_id` (optional): when present AND owned by `user`,
  #     fires `{:auto_resume_assistant, session_id}` to the user's
  #     UserAgent after the watermark write. Same pattern as the
  #     OAuth/MCP callback — the chain that hit `needs_consent`
  #     auto-retries `browser_navigate` instead of leaving the user with
  #     a stale "blocked" message.
  def post_browser_consent(conn, user) do
    {:ok, body, conn} = read_body(conn)
    d = Jason.decode!(body || "{}")
    sent_hash = d["text_hash"]
    session_id = d["session_id"]
    current_hash = DmhAi.Browser.ConsentText.hash()

    cond do
      not is_binary(sent_hash) or sent_hash == "" ->
        json(conn, 400, %{error: "text_hash required"})

      sent_hash != current_hash ->
        json(conn, 409, %{
          error: "stale text_hash — refresh the consent text and retry",
          current_hash: current_hash
        })

      true ->
        now = System.os_time(:millisecond)
        query!(Repo,
          "UPDATE users SET browser_consent_at=?, browser_consent_text_hash=? WHERE id=?",
          [now, current_hash, user.id])

        Logger.info("[BrowserConsent] accepted user=#{user.id} hash=#{current_hash}")

        # Fire auto-resume for the originating session, but ONLY when
        # session_id is owned by this user — never trigger a chain on
        # a session the caller doesn't own.
        if is_binary(session_id) and session_owned_by?(session_id, user.id) do
          case DmhAi.Agent.Supervisor.ensure_started(user.id) do
            {:ok, pid} ->
              send(pid, {:auto_resume_assistant, session_id})
              Logger.info("[BrowserConsent] auto-resume dispatched session=#{session_id}")
            _ ->
              :ok
          end
        end

        json(conn, 200, browser_consent_payload(user.id))
    end
  end

  defp session_owned_by?(session_id, user_id) do
    case query!(Repo, "SELECT 1 FROM sessions WHERE id=? AND user_id=? LIMIT 1",
                [session_id, user_id]) do
      %{rows: [[_]]} -> true
      _ -> false
    end
  end

  # DELETE /auth/me/browser-consent — revoke. Next browser_navigate
  # invocation re-prompts.
  def delete_browser_consent(conn, user) do
    query!(Repo,
      "UPDATE users SET browser_consent_at=NULL, browser_consent_text_hash=NULL WHERE id=?",
      [user.id])

    Logger.info("[BrowserConsent] revoked user=#{user.id}")
    json(conn, 200, browser_consent_payload(user.id))
  end

  defp browser_consent_payload(user_id) do
    {accepted_at, accepted_hash} =
      case query!(Repo,
             "SELECT browser_consent_at, browser_consent_text_hash FROM users WHERE id=?",
             [user_id]) do
        %{rows: [[ts, hash]]} -> {ts, hash}
        _ -> {nil, nil}
      end

    current_hash = DmhAi.Browser.ConsentText.hash()

    %{
      accepted_at:        accepted_at,
      accepted_hash:      accepted_hash,
      current_hash:       current_hash,
      current_text:       DmhAi.Browser.ConsentText.text(),
      hash_matches:       accepted_hash == current_hash,
      consented:          not is_nil(accepted_at) and accepted_hash == current_hash
    }
  end

  # GET /me/preferences — return current per-user preferences blob,
  # FE-serialised with defaults filled in. Visible to every
  # authenticated user.
  def get_my_preferences(conn, user) do
    json(conn, 200, DmhAi.Auth.UserPreferences.serialize(user.id))
  end

  # PUT /me/preferences — replace one or more preference keys. Body
  # shape: `{"conservativeTokenSaving": true|false, ...}`. Unknown
  # keys are rejected with 400; type-mismatches are rejected so the
  # JSON blob stays canonical.
  def put_my_preferences(conn, user) do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body || "{}") do
      {:ok, payload} when is_map(payload) ->
        case validate_and_apply_preferences(user.id, payload) do
          :ok ->
            json(conn, 200, DmhAi.Auth.UserPreferences.serialize(user.id))

          {:error, reason} ->
            json(conn, 400, %{error: reason})
        end

      _ ->
        json(conn, 400, %{error: "Body must be a JSON object"})
    end
  end

  # GET /me/credentials — list-only view of the caller's saved
  # credential rows. Metadata only — never payload — so accidental
  # console / FE leaks can't expose tokens. Surface fields the
  # Connected accounts panel needs to render: id (for the per-row
  # revoke button), target (service identity), account (multi-
  # account label), kind (oauth2_service / api_key_mcp / etc.),
  # expiry status, and timestamps.
  def list_my_credentials(conn, user) do
    rows = DmhAi.Auth.Credentials.list(user.id)
    json(conn, 200, %{credentials: rows})
  end

  # DELETE /me/credentials/:id — revoke ONE row, scoped to the
  # caller's user_id. We resolve `(user_id, id)` to a target+account
  # pair before delegating to `delete/3` so the caller can't trick
  # the row-id into deleting another user's credential by guessing.
  def delete_my_credential(conn, user, id_str) do
    case Integer.parse(id_str || "") do
      {id, ""} ->
        case DmhAi.Auth.Credentials.list(user.id) |> Enum.find(&(&1.id == id)) do
          nil ->
            json(conn, 404, %{error: "credential not found"})

          %{target: target, account: account} ->
            DmhAi.Auth.Credentials.delete(user.id, target, account)
            DmhAi.SysLog.log("[ME:CREDS] revoked user=#{user.id} target=#{target} account=#{inspect(account)}")
            json(conn, 200, %{ok: true})
        end

      _ ->
        json(conn, 400, %{error: "id must be an integer"})
    end
  end

  defp validate_and_apply_preferences(user_id, payload) do
    Enum.reduce_while(payload, :ok, fn
      {"conservativeTokenSaving", v}, :ok when is_boolean(v) ->
        :ok = DmhAi.Auth.UserPreferences.put_conservative_token_saving(user_id, v)
        {:cont, :ok}

      {"conservativeTokenSaving", _}, :ok ->
        {:halt, {:error, "conservativeTokenSaving must be boolean"}}

      {key, _}, :ok ->
        {:halt, {:error, "unknown preference key: #{key}"}}
    end)
  end

  # PUT /users/:id (admin: update user)
  def put_update_user(conn, user, uid) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      {:ok, body, conn} = read_body(conn)
      d = Jason.decode!(body || "{}")

      if Map.has_key?(d, "name") or Map.has_key?(d, "role") do
        name = d["name"] |> then(fn n -> if n && String.trim(n) != "", do: String.trim(n), else: nil end)
        role = d["role"] || "user"
        query!(Repo, "UPDATE users SET name=?, role=? WHERE id=?", [name, role, uid])
      end

      if d["password"] && d["password"] != "" do
        # Admin-reset is destructive to the target user's memos —
        # the admin doesn't know the old password, so the existing
        # wrapped MMK is unrecoverable. Require an explicit confirm
        # flag if the user has saved memos; the FE prompts.
        # See specs/memo_encryption.md § Admin password reset.
        memo_count = count_memo_rows(uid)
        confirmed = d["confirm_memo_wipe"] == true

        cond do
          memo_count > 0 and not confirmed ->
            json(conn, 409, %{
              error: "memo_wipe_required",
              memo_count: memo_count,
              message: "User has #{memo_count} saved memo(s) which cannot be recovered without their old password. Re-submit with confirm_memo_wipe: true to proceed."
            })

          true ->
            wipe_user_memo_state(uid)

            query!(Repo, """
              UPDATE users
              SET password_hash=?, password_changed=1,
                  memo_kdf_salt=NULL, memo_wrapped_mmk=NULL
              WHERE id=?
              """, [AuthPlug.hash_password(d["password"]), uid])

            # Force re-login on every device so a stale token can't
            # keep an in-memory MMK alive past the reset moment.
            query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
            UserAgent.wipe_memo_key(uid)

            json(conn, 200, %{ok: true, memo_rows_deleted: memo_count})
        end
      else
        json(conn, 200, %{ok: true})
      end
    end
  end

  defp count_memo_rows(uid) do
    case query!(Repo,
           "SELECT COUNT(*) FROM kb_chunks_meta WHERE scope='memo' AND user_id=?",
           [uid]) do
      %{rows: [[n] | _]} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp wipe_user_memo_state(uid) do
    # Delete the user's memo metadata rows; the corresponding vector
    # rows in `kb_vec_memo` and `kb_fts` (if any) reference these
    # `id`s — but FTS is skipped for memo scope on write, and the
    # vec table keys by the same rowid as meta. Same row deletion
    # cascades naturally.
    query!(Repo,
      "DELETE FROM kb_vec_memo WHERE rowid IN (SELECT id FROM kb_chunks_meta WHERE scope='memo' AND user_id=?)",
      [uid])
    query!(Repo, "DELETE FROM kb_chunks_meta WHERE scope='memo' AND user_id=?", [uid])
  end

  # DELETE /users/:id (admin: soft-delete user)
  def delete_user(conn, user, uid) do
    if user.role != "admin" do
      json(conn, 403, %{error: "Forbidden"})
    else
      if uid == user.id do
        json(conn, 400, %{error: "Cannot delete your own account"})
      else
        query!(Repo, "UPDATE users SET deleted=1 WHERE id=?", [uid])
        query!(Repo, "DELETE FROM auth_tokens WHERE user_id=?", [uid])
        json(conn, 200, %{ok: true})
      end
    end
  end
end
