# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Permissions do
  @moduledoc """
  Central per-org permission predicate. Single API:

      Permissions.can?(user_id, action, target) :: boolean

  Used everywhere — HTTP handlers, tool dispatcher, workflow compiler,
  workflow executor — so the codebase has exactly ONE permission rule.
  No `if user.role == "admin"` elsewhere.

  ## Action enum (closed)

      :read_kb           — query the org's KB
      :write_kb          — ingest into the org's KB
      :read_profile      — read another org member's profile
      :assign_task       — make another org member an assignee
      :request_approval  — request an approval decision from another user
      :act_as_creds      — use a stored connector credential
      :invoke_template   — invoke a curated task template
      :write_settings    — change org-level configuration
      :administer        — install-level super-user bypass

  Unknown action atoms raise `ArgumentError`.

  ## Target shape

  Tagged binary strings, parsed by `parse_target/1`:

      "user:<user_id>"               — an org member's identity
      "creds:<slug>:<user_id>"       — a stored connector credential
      "kb:<source_id>" | "kb:*"      — a KB source or the whole corpus
      "template:<id>"                — a task template
      "function:<slug>.<function>"   — a tool-catalogue entry
      "approval:<id>"                — an open approval record
      "org_settings"                 — org configuration

  ## Denial envelope

  On `false`, the dispatcher / compiler / HTTP layer can call
  `denial/3` to get a `%Permissions.Denial{}` struct describing
  the failure plus a remediation list. One shape, three renderers.

  ## v1 rule table

      Action               │ Allow when
      ─────────────────────┼─────────────────────────────────────────
      :read_kb             │ always (any org member; orgs are isolated)
      :write_kb            │ org_role ∈ {manager, admin}
      :read_profile        │ target user same org as caller
      :assign_task         │ target user same org
      :request_approval    │ target user same org
      :act_as_creds        │ target user_id == caller_user_id, OR
                          │ caller org_role == admin
      :invoke_template     │ template's declared roles include caller's
                          │ org_role  (look-up done at the manifest layer)
      :write_settings      │ org_role == admin
      :administer          │ install-level users.role == admin

  Install-level `users.role == "admin"` bypasses ALL checks (every
  bypass writes `bypass=true` to audit_log).

  Self-allow + same-org are the two simplifying invariants.

  ## Audit

  Every `false` writes one `audit_log` row (`outcome='denied'`).
  Allows are audited only when the action is in the sensitive set
  (`:act_as_creds`, `:write_kb`, `:write_settings`, `:administer`).
  """

  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  # ── Action enum (closed) ────────────────────────────────────────────────

  @actions [
    :read_kb,
    :write_kb,
    :read_profile,
    :assign_task,
    :request_approval,
    :act_as_creds,
    :invoke_template,
    :write_settings,
    :administer
  ]

  @sensitive_allow_audit MapSet.new([
    :act_as_creds,
    :write_kb,
    :write_settings,
    :administer
  ])

  @type action :: unquote(Enum.reduce(@actions, &{:|, [], [&1, &2]}))
  @type target :: String.t()

  # ── Denial envelope ─────────────────────────────────────────────────────

  defmodule Denial do
    @moduledoc """
    Structured failure of `Permissions.can?/3`. Carries enough
    information for any renderer (chat `request_input`, dispatcher
    error envelope, HTTP 403 body) to produce a useful message
    plus remediation options.
    """

    @type t :: %__MODULE__{
            caller_user_id: String.t() | nil,
            action:         atom(),
            target:         String.t(),
            reason:         atom(),
            remediation:    [{atom(), String.t()}]
          }

    defstruct caller_user_id: nil,
              action:         nil,
              target:         "",
              reason:         :denied,
              remediation:    []
  end

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns `true` if the caller is allowed; `false` otherwise.

  - `user_id` — caller's `users.id` (binary).
  - `action`  — must be one of `@actions`; unknown atoms raise.
  - `target`  — tagged string; see `parse_target/1`.

  On `false`, writes a denial row to `audit_log`. On `true` for an
  action in the sensitive set, writes an allow row.
  """
  @spec can?(String.t() | nil, action(), target()) :: boolean()
  def can?(user_id, action, target)
      when (is_binary(user_id) or is_nil(user_id)) and is_atom(action) and is_binary(target) do
    unless action in @actions do
      raise ArgumentError, "unknown action: #{inspect(action)} (allowed: #{inspect(@actions)})"
    end

    caller = resolve_caller(user_id)
    parsed = parse_target(target)

    decision = decide(caller, action, parsed)

    case decision do
      {:allow, :bypass_install_admin} ->
        if audit_install_bypass?(action, parsed, caller) do
          write_audit(caller, action, target, :allowed, "bypass_install_admin", true)
        end
        true

      {:allow, :self} ->
        # Self-call (caller acting on their own resource) is the
        # dominant case for :act_as_creds. Audit volume would explode
        # if every connector function call wrote a row. Stay silent.
        true

      {:allow, reason} ->
        if action in @sensitive_allow_audit do
          write_audit(caller, action, target, :allowed, to_string(reason), false)
        end
        true

      {:deny, reason} ->
        write_audit(caller, action, target, :denied, to_string(reason), false)
        false
    end
  end

  # Install-admin bypass is audited ONLY when it represents a real
  # privilege escalation — i.e. the action would have been denied for
  # a same-org admin too. A connector function call against the
  # caller's own creds is a no-op privilege-wise; auditing it floods
  # the trail. Cross-user / cross-org / settings actions are
  # genuine escalations worth recording.
  defp audit_install_bypass?(:act_as_creds, %{tag: :creds, user_id: target_id}, caller) do
    caller.user_id != target_id
  end

  defp audit_install_bypass?(:read_kb,  _target, _caller), do: false
  defp audit_install_bypass?(:read_profile, %{user_id: target_id}, caller)
       when is_binary(target_id),
       do: caller.user_id != target_id

  defp audit_install_bypass?(_action, _target, _caller), do: true

  @doc """
  Build a `%Denial{}` envelope for the same `(user_id, action, target)`
  triple. Callers use this to render a structured failure
  (chat `request_input`, dispatcher error envelope, HTTP 403).
  """
  @spec denial(String.t() | nil, action(), target()) :: Denial.t()
  def denial(user_id, action, target) when is_atom(action) and is_binary(target) do
    caller = resolve_caller(user_id)
    parsed = parse_target(target)

    {:deny, reason} =
      case decide(caller, action, parsed) do
        {:deny, _} = d -> d
        # If the action is actually allowed, the caller shouldn't be
        # asking for a denial envelope — fabricate one with reason
        # :not_denied so the bug surfaces immediately.
        {:allow, _} -> {:deny, :not_denied}
      end

    %Denial{
      caller_user_id: caller.user_id,
      action:         action,
      target:         target,
      reason:         reason,
      remediation:    remediation_for(reason, caller, action, parsed)
    }
  end

  @doc """
  Parse a target string into its tag and parts. Used by callers that
  need to derive new targets (e.g. compiler probe injection) or by
  the rule engine.

      iex> Permissions.parse_target("creds:google_workspace:u_abc")
      %{tag: :creds, slug: "google_workspace", user_id: "u_abc"}

      iex> Permissions.parse_target("user:u_abc")
      %{tag: :user, user_id: "u_abc"}

      iex> Permissions.parse_target("org_settings")
      %{tag: :org_settings}
  """
  @spec parse_target(String.t()) :: map()
  def parse_target("org_settings"), do: %{tag: :org_settings}

  def parse_target("user:" <> id) when byte_size(id) > 0,
    do: %{tag: :user, user_id: id}

  def parse_target("kb:" <> rest), do: %{tag: :kb, source_id: rest}

  def parse_target("creds:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [slug, user_id] when byte_size(slug) > 0 and byte_size(user_id) > 0 ->
        %{tag: :creds, slug: slug, user_id: user_id}

      _ ->
        %{tag: :unknown, raw: "creds:" <> rest}
    end
  end

  def parse_target("template:" <> id) when byte_size(id) > 0,
    do: %{tag: :template, template_id: id}

  def parse_target("function:" <> rest) when byte_size(rest) > 0,
    do: %{tag: :function, function: rest}

  def parse_target("approval:" <> id) when byte_size(id) > 0,
    do: %{tag: :approval, approval_id: id}

  def parse_target(other), do: %{tag: :unknown, raw: other}

  @doc """
  Explicitly audit an outcome. Use from callsites where the
  permission check happened upstream but the audit row should
  carry the call's full context (e.g. cross-user KB access).
  """
  @spec audit(String.t() | nil, action(), target(), :allowed | :denied, String.t() | nil) :: :ok
  def audit(user_id, action, target, outcome, reason \\ nil) do
    caller = resolve_caller(user_id)
    write_audit(caller, action, target, outcome, reason, false)
  end

  # ── Rule engine ─────────────────────────────────────────────────────────

  defp decide(caller, _action, _target) when caller.install_role == "admin",
    do: {:allow, :bypass_install_admin}

  defp decide(%{org_role: nil}, _action, _target),
    do: {:deny, :no_org_role}

  # :administer — install-level only; already gated above.
  defp decide(_caller, :administer, _target), do: {:deny, :not_install_admin}

  # :read_kb — always allowed for any same-org member. Orgs are
  # isolated at the data layer; the predicate trivially passes.
  defp decide(_caller, :read_kb, _target), do: {:allow, :any_member}

  defp decide(caller, :write_kb, _target) do
    if caller.org_role in ["manager", "admin"],
      do:  {:allow, :role_match},
      else: {:deny, :role_too_low}
  end

  defp decide(caller, action, %{tag: :user, user_id: target_id})
       when action in [:read_profile, :assign_task, :request_approval] do
    if same_org?(caller, target_id),
      do:  {:allow, :same_org},
      else: {:deny, :wrong_org}
  end

  defp decide(_caller, action, _target)
       when action in [:read_profile, :assign_task, :request_approval],
       do: {:deny, :bad_target_shape}

  defp decide(caller, :act_as_creds, %{tag: :creds, user_id: target_id}) do
    cond do
      caller.user_id == target_id ->
        {:allow, :self}

      caller.org_role == "admin" and same_org?(caller, target_id) ->
        {:allow, :admin_in_org}

      true ->
        {:deny, :not_admin}
    end
  end

  defp decide(_caller, :act_as_creds, _target), do: {:deny, :bad_target_shape}

  defp decide(_caller, :invoke_template, _target) do
    # The template's own `roles: [...]` declaration is enforced at the
    # template manifest layer (Primitive 0.3 / templates). At the
    # permission gate, any same-org member may attempt invocation; the
    # template's own gate refuses if the role list doesn't match.
    {:allow, :template_gate_downstream}
  end

  defp decide(caller, :write_settings, _target) do
    if caller.org_role == "admin",
      do:  {:allow, :org_admin},
      else: {:deny, :role_too_low}
  end

  defp decide(_caller, action, _target),
    do: {:deny, {:no_rule_for_action, action}}

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp resolve_caller(nil),
    do: %{user_id: nil, org_id: DmhAi.Constants.default_org_id(), org_role: nil, install_role: nil}

  defp resolve_caller(user_id) when is_binary(user_id) do
    case query!(Repo, "SELECT id, org_id, org_role, role FROM users WHERE id=?", [user_id]).rows do
      [[id, org_id, org_role, role]] ->
        %{user_id: id, org_id: org_id, org_role: org_role, install_role: role}

      _ ->
        %{user_id: user_id, org_id: DmhAi.Constants.default_org_id(), org_role: nil, install_role: nil}
    end
  rescue
    _ ->
      %{user_id: user_id, org_id: DmhAi.Constants.default_org_id(), org_role: nil, install_role: nil}
  end

  defp same_org?(_caller, nil), do: false
  defp same_org?(caller, target_user_id) when is_binary(target_user_id) do
    case query!(Repo, "SELECT org_id FROM users WHERE id=?", [target_user_id]).rows do
      [[org]] -> org == caller.org_id
      _       -> false
    end
  rescue
    _ -> false
  end

  defp write_audit(caller, action, target, outcome, reason, bypass?) do
    payload = %{
      kind:     "permission",
      target:   target,
      bypass:   bypass?
    }

    query!(Repo, """
    INSERT INTO audit_log (org_id, user_id, action, resource, outcome, reason, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """, [
      caller.org_id,
      caller.user_id,
      to_string(action),
      Jason.encode!(payload),
      to_string(outcome),
      reason,
      System.os_time(:millisecond)
    ])

    :ok
  rescue
    e ->
      Logger.warning("[Permissions] audit insert failed: #{Exception.message(e)}")
      :ok
  end

  defp remediation_for(:not_admin, _caller, :act_as_creds, %{slug: slug, user_id: target_id}) do
    [
      {:try, "use your own #{slug} credentials instead"},
      {:ask, "an admin to author or run this workflow"},
      {:ask, "user #{target_id} to grant you access (v2 feature)"}
    ]
  end

  defp remediation_for(:role_too_low, _caller, :write_kb, _target) do
    [
      {:ask, "a manager or admin to perform this action"}
    ]
  end

  defp remediation_for(:role_too_low, _caller, :write_settings, _target) do
    [
      {:ask, "an admin to change this setting"}
    ]
  end

  defp remediation_for(:wrong_org, _caller, _action, _target) do
    [
      {:try, "pick a target in the same organisation"}
    ]
  end

  defp remediation_for(:no_org_role, _caller, _action, _target) do
    [
      {:ask, "an admin to assign you a role in this organisation"}
    ]
  end

  defp remediation_for(_reason, _caller, _action, _target), do: []
end
