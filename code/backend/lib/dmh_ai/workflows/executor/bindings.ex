# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Workflows.Executor.Bindings do
  @moduledoc """
  Ref resolution + emits bookkeeping for the executor.

  All ref discovery + parsing goes through `Workflows.Refs`
  (over args) → `Workflows.Mustache` (over strings) →
  `Workflows.Path` (over each ref body). Single-pass state
  machines, no regex. The walker handles the typed accessors
  against runtime data.

  Two surfaces:

    * `resolve_args/2` — substitutes refs across an arbitrary
      args value (map / list / string / scalar). Used to prepare
      the args BEFORE the tool call.

    * `resolve_ref_body/2` — strict body-only resolver used by
      `Workflows.Expression` to evaluate branch predicates.

  Also owns `extract_emits/2` + `put_emits/3` (the IR's emit
  declaration → runtime bindings flow) and the owner / org
  lookup queries (`{{owner.*}}` / `{{org.*}}` resolution).
  """

  alias DmhAi.Repo
  alias DmhAi.Workflows.{Path, Refs}
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Seconds per day — converts a `{{today±N…}}` offset (carried in
  # seconds by `Workflows.Path`) back to whole days for `Date.add/2`.
  @seconds_per_day 86_400

  # ── arg resolution ──────────────────────────────────────────────────

  @doc """
  Substitute every `{{…}}` ref in `args` against the run state.
  Non-map inputs (literal scalars) pass through untouched.
  """
  def resolve_args(args, state) when is_map(args) do
    Refs.substitute(args, fn body -> resolve_ref_body(body, state) end)
  end

  def resolve_args(other, _), do: other

  @doc """
  A single ref body resolver. Receives the trimmed inner content
  of a `{{…}}`; returns the resolved value, or `:passthrough` if
  the runtime can't resolve it (the template stays untouched so
  downstream synthetic primitives can resolve it themselves).
  """
  def resolve_ref_body(body, state) do
    case Path.parse(body) do
      {:error, _reason} ->
        :passthrough

      {:ok, %{root: :now,   path: []}} ->
        DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, %{root: :today, path: []}} ->
        Date.utc_today() |> Date.to_iso8601()

      {:ok, %{root: {:now, secs}, path: []}} ->
        DateTime.utc_now() |> DateTime.add(secs, :second) |> DateTime.to_iso8601()

      {:ok, %{root: {:today, secs}, path: []}} ->
        Date.utc_today() |> Date.add(div(secs, @seconds_per_day)) |> Date.to_iso8601()

      {:ok, %{root: :trigger, path: path}} ->
        data = state.bindings["trigger"] || state.bindings[:trigger] || %{}
        Path.walk(data, path) |> walked_or_empty()

      {:ok, %{root: :owner, path: path}} ->
        owner_record(state.owner_user_id)
        |> Path.walk(path)
        |> walked_or_empty()

      {:ok, %{root: :org, path: path}} ->
        org_record(state.org_id)
        |> Path.walk(path)
        |> walked_or_empty()

      {:ok, %{root: {:node, id}, path: path}} ->
        emits = state.bindings["emits"] || state.bindings[:emits] || %{}
        node_emit = Map.get(emits, to_string(id)) || Map.get(emits, id, %{})
        Path.walk(node_emit, path) |> walked_or_empty()

      {:ok, _other} ->
        :passthrough
    end
  end

  @doc """
  Normalise the result of `Path.walk/2` so unresolved paths render
  as an empty string (the same shape downstream tools expect for a
  missing key) rather than `nil` / `:not_found`.
  """
  def walked_or_empty(:not_found), do: ""
  def walked_or_empty(nil),         do: ""
  def walked_or_empty(v),           do: v

  # ── emits ───────────────────────────────────────────────────────────

  @doc """
  Project a node's raw `result` through its `emits` declaration.
  Two forms are supported:

    * shorthand list `["field_a", "field_b"]` → pluck top-level keys
      from the result and expose them.
    * map `%{out_name: "$.json.path"}` → JSONPath lookup.

  Falls back to the raw result map when no declaration is present.
  """
  def extract_emits(node, result) when is_map(result) do
    case Map.get(node, "emits") do
      m when is_map(m) ->
        Enum.into(m, %{}, fn {k, _path} ->
          {k, Map.get(result, k) || Map.get(result, to_string(k))}
        end)

      l when is_list(l) ->
        Enum.into(l, %{}, fn k -> {k, Map.get(result, k) || Map.get(result, to_string(k))} end)

      _ ->
        result
    end
  end

  def extract_emits(_node, result), do: %{"value" => result}

  @doc """
  Merge a node's projected emit into the `emits` sub-map of the run
  state's bindings. The key is the stringified node id so that
  `{{<id>.<field>}}` refs from downstream nodes resolve via
  `Path.walk/2`.
  """
  def put_emits(bindings, node_id, emit) when is_map(bindings) do
    cur = Map.get(bindings, "emits") || Map.get(bindings, :emits) || %{}
    new_emits = Map.put(cur, to_string(node_id), emit)
    Map.put(bindings, "emits", new_emits)
  end

  # ── owner / org lookups ─────────────────────────────────────────────

  defp owner_record(user_id) do
    base =
      case query!(Repo, """
      SELECT id, email, name, org_id, org_role
        FROM users WHERE id=?
      """, [user_id]).rows do
        [[id, email, name, org, role]] ->
          %{"user_id" => id, "id" => id,
            "email" => email, "name" => name || "",
            "display_name" => name || email,
            "org_id" => org, "org_role" => role}

        _ ->
          %{}
      end

    # Embed per-connector identity sub-maps so `{{owner.<slug>.email}}`
    # resolves to the email the user OAuth'd with AT THAT VENDOR. This
    # is distinct from `{{owner.email}}` (the DMH-AI app email): a user
    # may sign into DMH-AI as `admin@acme.com` but connect HubSpot as
    # `sales-ops@acme.com`. Most workflows that look up the user's own
    # vendor record (CRM contact, calendar, mailbox) want the VENDOR
    # email, not the app email.
    Map.merge(base, connector_identities(user_id))
  rescue
    _ -> %{}
  end

  # One DB hit per resolution; cheap because there are at most a
  # handful of `oauth:<slug>` rows per user. Returns a map keyed by
  # slug → `%{"email" => <vendor email>}` for every connector the
  # user has authorised AND whose OAuth callback successfully
  # captured the userinfo email into the credential row's `account`
  # column. Slugs without an `account` value (the userinfo call
  # failed, the vendor exposes no email, the OAuth flow predates
  # this wiring) are absent — accessing them resolves to "" via
  # `walked_or_empty/1`, which makes the missing-data signal
  # recoverable through `on_failure: lookup_miss` the same way an
  # empty `<vendor>.find` list does.
  defp connector_identities(user_id) do
    %{rows: rows} =
      query!(Repo, """
      SELECT target, account
        FROM user_credentials
       WHERE user_id = ?
         AND target LIKE 'oauth:%'
         AND account IS NOT NULL
         AND account <> ''
      """, [user_id])

    Enum.into(rows, %{}, fn [target, account] ->
      slug = String.replace_prefix(target, "oauth:", "")
      {slug, %{"email" => account, "account" => account}}
    end)
  end

  defp org_record(org_id) do
    case query!(Repo, "SELECT id, name FROM organizations WHERE id=?", [org_id]).rows do
      [[id, name]] -> %{"id" => id, "name" => name || ""}
      _ -> %{"id" => org_id}
    end
  rescue
    _ -> %{"id" => org_id}
  end
end
