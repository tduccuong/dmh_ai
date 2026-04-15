defmodule Dmhai.Handlers.Auth do
  import Plug.Conn
  alias Dmhai.Repo
  alias Dmhai.AuthPlug
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
      SELECT id, email, name, role, password_hash, password_changed
      FROM users WHERE email=? AND deleted=0
      """, [email])

    case result.rows do
      [[id, db_email, name, role, password_hash, pw_changed] | _] ->
        if AuthPlug.verify_password(password, password_hash) do
          token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
          now = :os.system_time(:second)
          query!(Repo, "INSERT INTO auth_tokens (token, user_id, created_at) VALUES (?,?,?)", [token, id, now])

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

  # POST /auth/logout
  def post_logout(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        token = String.trim(token)
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
        query!(Repo, "UPDATE users SET password_hash=?, password_changed=1 WHERE id=?",
          [AuthPlug.hash_password(d["password"]), uid])
      end

      json(conn, 200, %{ok: true})
    end
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
