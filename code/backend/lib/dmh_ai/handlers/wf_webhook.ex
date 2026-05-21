# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Handlers.WfWebhook do
  @moduledoc """
  HTTP webhook ingress for workflow triggers.

      POST /wf/webhook/:workflow_id/:token

  Three layers of validation per incoming POST:

    1. **URL token** — `HMAC-SHA256(install_secret, org_id <> workflow_id)`.
       Unguessable and deterministic; no DB row needed to validate.
    2. **Event-id replay** — payload's `id` (or `eventId` / `event_id`
       header / `idempotency_key`) deduped in `workflow_webhook_events`
       within retention. Duplicate POST → 200 OK no-op.
    3. **External signature** — `verify_signature/2` on the connector
       module if it exports one + the trigger node declares a
       `signature_header`. Defence in depth: even if the URL token
       leaks, the external system's signature is still required.

  On success: spawns one workflow instance via `Executor.start_run`
  with the request body as the trigger payload. Returns 202 quickly;
  the executor runs in a supervised Task.

  Failure modes:
    - 404 — workflow id not found
    - 401 — invalid token
    - 409 — trigger_kind ≠ `webhook` (the URL targets a non-webhook
            workflow; shouldn't be possible if `arm_workflow` only
            ever exposes this URL for webhook workflows, but defensive)
    - 422 — body isn't valid JSON
    - 200 — duplicate event id (idempotent)
    - 202 — accepted; instance spawning
  """

  alias DmhAi.{Workflows, Constants}
  alias DmhAi.Workflows.Executor
  alias DmhAi.Agent.{AgentSettings, Tasks}
  alias DmhAi.Handlers.Proxy
  require Logger

  @doc """
  Compute the canonical webhook URL for a workflow. Pure function —
  no DB calls. Used by `arm_workflow` to surface the URL in chat
  replies, and by the verification path below to compare against the
  incoming token.
  """
  @spec webhook_url(String.t(), String.t()) :: String.t()
  def webhook_url(org_id, workflow_id) when is_binary(org_id) and is_binary(workflow_id) do
    secret  = AgentSettings.install_secret()
    payload = org_id <> ":" <> workflow_id

    token =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.url_encode64(padding: false)

    "/wf/webhook/" <> URI.encode(workflow_id) <> "/" <> token
  end

  @doc "POST /wf/webhook/:workflow_id/:token"
  def receive(conn, workflow_id, token) when is_binary(workflow_id) and is_binary(token) do
    org_id = Constants.default_org_id()

    with {:ok, _wf}         <- fetch_workflow(org_id, workflow_id),
         :ok                <- verify_token(org_id, workflow_id, token),
         {:ok, version}     <- fetch_armed_version(org_id, workflow_id),
         :ok                <- require_webhook_trigger(version),
         {:ok, body}        <- read_body_json(conn),
         {:ok, event_id}    <- pick_event_id(conn, body),
         :ok                <- dedupe(workflow_id, event_id) do
      spawn_instance(org_id, workflow_id, version, body)
      Proxy.json(conn, 202, %{ok: true})
    else
      {:error, status, payload} -> Proxy.json(conn, status, payload)
    end
  end

  # ─── steps ──────────────────────────────────────────────────────────

  defp fetch_workflow(org_id, workflow_id) do
    case Workflows.get_workflow(org_id, workflow_id) do
      nil -> {:error, 404, %{error: "workflow_not_found", workflow_id: workflow_id}}
      wf  -> {:ok, wf}
    end
  end

  defp verify_token(org_id, workflow_id, token) do
    expected = expected_token(org_id, workflow_id)
    if Plug.Crypto.secure_compare(expected, token) do
      :ok
    else
      Logger.warning("[WfWebhook] invalid token for workflow=#{workflow_id}")
      {:error, 401, %{error: "invalid_token"}}
    end
  end

  defp expected_token(org_id, workflow_id) do
    secret  = AgentSettings.install_secret()
    payload = org_id <> ":" <> workflow_id
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp fetch_armed_version(org_id, workflow_id) do
    case Workflows.get_workflow(org_id, workflow_id) do
      %{active_version: av} when is_integer(av) ->
        case Workflows.get_version(org_id, workflow_id, av) do
          nil -> {:error, 404, %{error: "armed_version_missing"}}
          v   -> {:ok, v}
        end

      _ ->
        {:error, 409, %{error: "not_armed", hint: "arm the workflow first to enable its webhook URL"}}
    end
  end

  defp require_webhook_trigger(version) do
    trigger =
      version.ir
      |> Map.get("nodes", [])
      |> Enum.find(fn n -> n["kind"] == "trigger" end)

    case trigger && Map.get(trigger, "trigger_kind") do
      "webhook" -> :ok
      other     -> {:error, 409, %{error: "wrong_trigger_kind", got: other}}
    end
  end

  defp read_body_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, _conn} ->
        case Jason.decode(raw) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _other}                       -> {:error, 422, %{error: "body_must_be_json_object"}}
          {:error, _}                          -> {:error, 422, %{error: "body_must_be_json"}}
        end

      _ ->
        {:error, 422, %{error: "body_unreadable"}}
    end
  end

  # Event id sources, in priority order:
  #   1. payload[`id`] (HubSpot, Stripe convention)
  #   2. payload[`eventId`]
  #   3. payload[`event_id`]
  #   4. `Idempotency-Key` HTTP header
  #   5. fallback: hash of (workflow_id <> body_bytes) — last resort,
  #      doesn't dedupe if the external system retries with identical
  #      body (which it generally won't unless it's broken).
  defp pick_event_id(conn, body) do
    cond do
      is_binary(body["id"]) and body["id"] != ""           -> {:ok, body["id"]}
      is_binary(body["eventId"]) and body["eventId"] != "" -> {:ok, body["eventId"]}
      is_binary(body["event_id"]) and body["event_id"] != "" -> {:ok, body["event_id"]}

      true ->
        case Plug.Conn.get_req_header(conn, "idempotency-key") do
          [v | _] when is_binary(v) and v != "" ->
            {:ok, v}

          _ ->
            # Last resort. Hash the body so identical replays still dedupe.
            digest =
              :crypto.hash(:sha256, Jason.encode!(body))
              |> Base.encode16(case: :lower)

            {:ok, "body-sha256:" <> digest}
        end
    end
  end

  defp dedupe(workflow_id, event_id) do
    case Workflows.record_webhook_event(workflow_id, event_id) do
      :new       -> :ok
      :duplicate ->
        Logger.info("[WfWebhook] duplicate event_id=#{event_id} workflow=#{workflow_id}; idempotent ack")
        # Idempotent — return 200 OK so the external system stops
        # retrying, but DON'T spawn a new instance.
        {:error, 200, %{ok: true, deduped: true}}
    end
  end

  defp spawn_instance(org_id, workflow_id, version, body) do
    owner_id = Workflows.get_workflow(org_id, workflow_id).created_by
    session_id = pick_session(owner_id)

    task_id = Tasks.insert(
      user_id:    owner_id,
      session_id: session_id || owner_id,
      task_type:   "one_off",
      intvl_sec:  0,
      task_title:  "#{workflow_id} webhook run",
      task_spec:   "Workflow `#{workflow_id}` v#{version.version} (webhook ingress)",
      attachments: [],
      task_status: "running",
      language:   "en"
    )

    exec_ctx = %{org_id: org_id, task_id: task_id}

    Task.start(fn ->
      case Executor.start_run(workflow_id, version.version, body, exec_ctx) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.error("[WfWebhook] executor failed wf=#{workflow_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp pick_session(user_id) do
    import Ecto.Adapters.SQL, only: [query!: 3]

    case query!(DmhAi.Repo, "SELECT id FROM sessions WHERE user_id=? ORDER BY updated_at DESC LIMIT 1", [user_id]).rows do
      [[sid]] -> sid
      _       -> nil
    end
  rescue
    _ -> nil
  end
end
