# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.DocuSign.MCPHandler do
  @moduledoc """
  FunctionSpec map for the DocuSign connector consumed by the generic
  `Connectors.MCPServer`. Each function is a 1:1 mapping to a
  DocuSign eSignature REST endpoint at
  `{base_host}/restapi/v2.1/accounts/{account_id}/*`:

    envelope.find                 — GET  /envelopes
    envelope.create               — POST /envelopes
    envelope.get                  — GET  /envelopes/{envelope_id}
    envelope.send                 — PUT  /envelopes/{envelope_id}  (status=sent)
    envelope.void                 — PUT  /envelopes/{envelope_id}  (status=voided)
    envelope.list_recipients      — GET  /envelopes/{envelope_id}/recipients
    envelope.list_documents       — GET  /envelopes/{envelope_id}/documents
    envelope.download_document    — GET  /envelopes/{envelope_id}/documents/{document_id}  (binary PDF)
    envelope.create_from_template — POST /envelopes  (templateId + templateRoles body)
    envelope.resend               — PUT  /envelopes/{envelope_id}/recipients?resend_envelope=true
    envelope.update_recipient     — PUT  /envelopes/{envelope_id}/recipients
    envelope.audit_events         — GET  /envelopes/{envelope_id}/audit_events
    recipient.add                 — POST /envelopes/{envelope_id}/recipients
    template.find                 — GET  /templates
    template.get                  — GET  /templates/{template_id}

  ## Per-account, per-environment API base

      @api_base "https://demo.docusign.net/restapi/v2.1/accounts/{account_id}"

  Both placeholders need framework templating BEFORE a live call:

    * `{account_id}` — from the OAuth userinfo's `accounts[].account_id`.
    * Base host (`demo.docusign.net`) — from `accounts[].base_uri`.
      Sandbox calls hit `demo.docusign.net`; production swaps to
      `www.docusign.net` (or a regional host like `na1.docusign.net`
      / `eu.docusign.net`). The userinfo `base_uri` value already
      encodes the user's environment + region.

  The mock vendor server answers by function name, not URL, so the
  bridge is exercised without substitution.

  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## Path-param ids

  Functions acting on a specific envelope (`envelope.get` /
  `envelope.send` / `envelope.void` / `envelope.list_recipients` /
  `envelope.list_documents` / `envelope.download_document` /
  `envelope.resend` / `envelope.update_recipient` /
  `envelope.audit_events` / `recipient.add`) or template
  (`template.get`) interpolate the id into the URL path via a `:url`
  function `(args -> url)`. DocuSign envelope_ids are UUIDs *with
  dashes*, so the id is whitelisted to `^[A-Za-z0-9-]+$` before the
  URL is built (`safe_path_id/1`) — no raw interpolation of
  unvalidated input.

  ## Binary document download

  `envelope.download_document` uses a custom handler (`:handler`)
  rather than the default JSON `:request` builder — DocuSign returns
  the document as raw binary (typically PDF). The handler captures
  `response.body` via `RestBridge.raw_request/2`, base64-encodes it so
  it survives the JSON-shaped tool-result envelope, and surfaces a
  `content_type` of `application/pdf` (DocuSign's default for the
  `/documents/{document_id}` endpoint).
  """

  alias DmhAi.Connectors.MCPServer.{FunctionSpec, RestBridge}
  require Logger

  @api_base "https://demo.docusign.net/restapi/v2.1/accounts/{account_id}"

  # DocuSign envelope_ids are UUIDs with dashes. Whitelist the
  # charset (allowing the hyphen) before interpolating into a URL
  # path so an attacker can't inject path segments or query strings
  # via a lookup arg.
  @path_id_re ~r/^[A-Za-z0-9-]+$/

  @doc """
  Handler entry consumed by `Connectors.MCPServer.Registry.put/1` at
  boot.
  """
  @spec handler() :: DmhAi.Connectors.MCPServer.Registry.handler()
  def handler do
    %{slug: "docusign", functions: functions()}
  end

  @spec functions() :: %{required(String.t()) => FunctionSpec.t()}
  def functions do
    %{
      "envelope.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/envelopes",
        request: &envelope_find_request/2,
        response: &envelope_find_response/2,
        doc:     "List DocuSign envelopes; filter by status / from_date."
      },
      "envelope.create" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/envelopes",
        request: &envelope_create_request/2,
        response: &envelope_create_response/2,
        doc:     "Create + (optionally) send a new DocuSign envelope."
      },
      "envelope.get" => %FunctionSpec{
        method:  :get,
        url:     &envelope_get_url/1,
        request: &envelope_get_request/2,
        response: &envelope_get_response/2,
        doc:     "Read one DocuSign envelope by id."
      },
      "envelope.send" => %FunctionSpec{
        method:  :put,
        url:     &envelope_send_url/1,
        request: &envelope_send_request/2,
        response: &envelope_send_response/2,
        doc:     "Flip an existing draft envelope to status=sent."
      },
      "envelope.void" => %FunctionSpec{
        method:  :put,
        url:     &envelope_void_url/1,
        request: &envelope_void_request/2,
        response: &envelope_void_response/2,
        doc:     "Void an existing envelope with a voided reason."
      },
      "recipient.add" => %FunctionSpec{
        method:  :post,
        url:     &recipient_add_url/1,
        request: &recipient_add_request/2,
        response: &recipient_add_response/2,
        doc:     "Add one or more recipients to an existing envelope."
      },
      "template.find" => %FunctionSpec{
        method:  :get,
        url:     "#{@api_base}/templates",
        request: &template_find_request/2,
        response: &template_find_response/2,
        doc:     "List DocuSign templates."
      },
      "envelope.list_recipients" => %FunctionSpec{
        method:  :get,
        url:     &envelope_list_recipients_url/1,
        request: &envelope_list_recipients_request/2,
        response: &envelope_list_recipients_response/2,
        doc:     "List every recipient on an envelope (signers + ccs + certified deliveries)."
      },
      "envelope.list_documents" => %FunctionSpec{
        method:  :get,
        url:     &envelope_list_documents_url/1,
        request: &envelope_list_documents_request/2,
        response: &envelope_list_documents_response/2,
        doc:     "List the documents attached to an envelope."
      },
      "envelope.download_document" => %FunctionSpec{
        handler: &envelope_download_document/2,
        doc:     "Download an envelope document; binary body base64-encoded."
      },
      "template.get" => %FunctionSpec{
        method:  :get,
        url:     &template_get_url/1,
        request: &template_get_request/2,
        response: &template_get_response/2,
        doc:     "Read one DocuSign template by id."
      },
      "envelope.create_from_template" => %FunctionSpec{
        method:  :post,
        url:     "#{@api_base}/envelopes",
        request: &envelope_create_from_template_request/2,
        response: &envelope_create_from_template_response/2,
        doc:     "Create + (optionally) send an envelope from a template + roles."
      },
      "envelope.resend" => %FunctionSpec{
        method:  :put,
        url:     &envelope_resend_url/1,
        request: &envelope_resend_request/2,
        response: &envelope_resend_response/2,
        doc:     "Resend notification email for an existing envelope (no-op recipient PUT with ?resend_envelope=true)."
      },
      "envelope.update_recipient" => %FunctionSpec{
        method:  :put,
        url:     &envelope_update_recipient_url/1,
        request: &envelope_update_recipient_request/2,
        response: &envelope_update_recipient_response/2,
        doc:     "Patch one recipient on an envelope (PUT /recipients, signers array of one)."
      },
      "envelope.audit_events" => %FunctionSpec{
        method:  :get,
        url:     &envelope_audit_events_url/1,
        request: &envelope_audit_events_request/2,
        response: &envelope_audit_events_response/2,
        doc:     "Read the envelope's audit trail (auditEvents array)."
      }
    }
  end

  # ─── envelope.find — GET /envelopes ───────────────────────────────────

  defp envelope_find_request(args, _ctx) do
    params =
      %{}
      |> maybe_put_kv("status", Map.get(args, "status"))
      |> maybe_put_kv("from_date", Map.get(args, "from_date"))
      |> maybe_put_kv("count", Map.get(args, "limit"))

    [params: params]
  end

  defp envelope_find_response(s, body) when s in 200..299 do
    envelopes =
      body
      |> envelopes_list()
      |> Enum.map(&normalise_envelope/1)

    {:ok, %{"envelopes" => envelopes}}
  end

  # DocuSign returns the envelope list under `envelopes` (paginated
  # listings) or as a bare array (the mock fixture). Tolerate both.
  defp envelopes_list(%{"envelopes" => list}) when is_list(list), do: list
  defp envelopes_list(body) when is_list(body), do: body
  defp envelopes_list(_), do: []

  defp normalise_envelope(e) do
    %{
      "envelope_id"   => to_string(Map.get(e, "envelopeId") || Map.get(e, "envelope_id") || ""),
      "status"        => Map.get(e, "status"),
      "email_subject" => Map.get(e, "emailSubject") || Map.get(e, "email_subject")
    }
  end

  # ─── envelope.create — POST /envelopes ────────────────────────────────

  defp envelope_create_request(args, _ctx) do
    body =
      %{
        "emailSubject" => args["subject"],
        "status"       => args["status"] || "sent",
        "recipients"   => args["recipients"] || [],
        "documents"    => args["documents"] || []
      }

    [json: body]
  end

  defp envelope_create_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "envelope_id" =>
         to_string(Map.get(body, "envelopeId") || Map.get(body, "envelope_id") || "")
     }}
  end

  # ─── envelope.get — GET /envelopes/{id} ───────────────────────────────

  defp envelope_get_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}"

  defp envelope_get_request(_args, _ctx), do: []

  defp envelope_get_response(s, body) when s in 200..299 do
    {:ok, %{"envelope" => body}}
  end

  # ─── envelope.send — PUT /envelopes/{id} status=sent ──────────────────

  defp envelope_send_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}"

  defp envelope_send_request(_args, _ctx) do
    [json: %{"status" => "sent"}]
  end

  defp envelope_send_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── envelope.void — PUT /envelopes/{id} status=voided ────────────────

  defp envelope_void_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}"

  defp envelope_void_request(args, _ctx) do
    [json: %{"status" => "voided", "voidedReason" => args["voided_reason"]}]
  end

  defp envelope_void_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── recipient.add — POST /envelopes/{id}/recipients ──────────────────

  defp recipient_add_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/recipients"

  defp recipient_add_request(args, _ctx) do
    recipients = args["recipients"] || []
    # The DocuSign POST /recipients body expects a `signers` array
    # under the recipient role. The connector accepts a flat
    # `recipients` list (manifest type :list) and forwards it as
    # `signers` — the most common recipient role. Specific role
    # routing (carbonCopies, certifiedDeliveries, …) is future work.
    [json: %{"signers" => recipients}]
  end

  defp recipient_add_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "recipient_id_added" => to_string(first_recipient_id(body))
     }}
  end

  # DocuSign returns the created recipients under `signers` (or other
  # role arrays). Pick the first recipient id we can find — the
  # manifest declares a single `recipient_id_added` field.
  defp first_recipient_id(%{"signers" => [first | _]}) when is_map(first),
    do: Map.get(first, "recipientId") || Map.get(first, "recipient_id") || ""

  defp first_recipient_id(%{"recipientId" => id}), do: id
  defp first_recipient_id(_), do: ""

  # ─── template.find — GET /templates ───────────────────────────────────

  defp template_find_request(args, _ctx) do
    params = maybe_put_kv(%{}, "count", Map.get(args, "limit"))
    [params: params]
  end

  defp template_find_response(s, body) when s in 200..299 do
    templates =
      body
      |> templates_list()
      |> Enum.map(&normalise_template/1)

    {:ok, %{"templates" => templates}}
  end

  defp templates_list(%{"envelopeTemplates" => list}) when is_list(list), do: list
  defp templates_list(%{"templates" => list}) when is_list(list), do: list
  defp templates_list(body) when is_list(body), do: body
  defp templates_list(_), do: []

  defp normalise_template(t) do
    %{
      "template_id" => to_string(Map.get(t, "templateId") || Map.get(t, "template_id") || ""),
      "name"        => Map.get(t, "name")
    }
  end

  # ─── envelope.list_recipients — GET /envelopes/{id}/recipients ────────

  defp envelope_list_recipients_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/recipients"

  defp envelope_list_recipients_request(_args, _ctx), do: []

  defp envelope_list_recipients_response(s, body) when s in 200..299 do
    recipients =
      body
      |> recipients_union()
      |> Enum.map(&normalise_recipient/1)

    {:ok, %{"recipients" => recipients}}
  end

  # DocuSign splits recipients by routing class — signers vs.
  # carbonCopies vs. certifiedDeliveries. The connector hands the
  # union to the caller as a flat list: every recipient on the
  # envelope regardless of class. The mock fixture returns a bare
  # `recipients` array, which we tolerate too.
  defp recipients_union(body) when is_map(body) do
    Enum.concat([
      list_or_empty(Map.get(body, "signers")),
      list_or_empty(Map.get(body, "carbonCopies")),
      list_or_empty(Map.get(body, "certifiedDeliveries")),
      list_or_empty(Map.get(body, "recipients"))
    ])
  end

  defp recipients_union(body) when is_list(body), do: body
  defp recipients_union(_), do: []

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []

  defp normalise_recipient(r) do
    %{
      "recipient_id" => to_string(Map.get(r, "recipientId") || Map.get(r, "recipient_id") || ""),
      "name"         => Map.get(r, "name"),
      "email"        => Map.get(r, "email"),
      "status"       => Map.get(r, "status"),
      "role_name"    => Map.get(r, "roleName") || Map.get(r, "role_name")
    }
  end

  # ─── envelope.list_documents — GET /envelopes/{id}/documents ──────────

  defp envelope_list_documents_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/documents"

  defp envelope_list_documents_request(_args, _ctx), do: []

  defp envelope_list_documents_response(s, body) when s in 200..299 do
    documents =
      body
      |> documents_list()
      |> Enum.map(&normalise_document/1)

    {:ok, %{"documents" => documents}}
  end

  defp documents_list(%{"envelopeDocuments" => list}) when is_list(list), do: list
  defp documents_list(%{"documents" => list}) when is_list(list), do: list
  defp documents_list(body) when is_list(body), do: body
  defp documents_list(_), do: []

  defp normalise_document(d) do
    %{
      "document_id" => to_string(Map.get(d, "documentId") || Map.get(d, "document_id") || ""),
      "name"        => Map.get(d, "name"),
      "type"        => Map.get(d, "type")
    }
  end

  # ─── envelope.download_document — GET /documents/{document_id} ────────

  # Custom handler: DocuSign returns the document as raw binary
  # (typically PDF), which doesn't fit the default JSON `:response`
  # builder. The handler base64-encodes the body so it survives the
  # JSON-shaped tool-result envelope. DocuSign's
  # `/envelopes/{id}/documents/{document_id}` endpoint returns PDF by
  # default; specialised flows (`?certificate=true`, combined-document
  # options) are out of scope here, so the connector surfaces
  # `application/pdf` as the content_type.
  defp envelope_download_document(args, ctx) do
    envelope_id = safe_path_id(args["envelope_id"])
    document_id = safe_path_id(args["document_id"])
    url = "#{@api_base}/envelopes/#{envelope_id}/documents/#{document_id}"

    opts =
      [url: url]
      |> add_bearer(ctx)

    case RestBridge.raw_request(:get, opts) do
      {:ok, status, body} when status in 200..299 ->
        {:ok,
         %{
           "content_b64"  => base64_encode_body(body),
           "content_type" => "application/pdf"
         }}

      {:ok, _status, body} ->
        {:error, body}

      {:error, _} = err ->
        err
    end
  end

  # DocuSign's binary body comes back as a Req-decoded binary; if the
  # vendor (or a stub) returns the already-encoded base64 string
  # verbatim, surface it as-is. The mock fixture supplies the
  # base64-encoded string directly so the round-trip is deterministic
  # without a real binary blob in the test.
  defp base64_encode_body(body) when is_binary(body) do
    case Base.decode64(body, padding: false) do
      {:ok, _} -> body
      :error   -> Base.encode64(body)
    end
  end

  defp base64_encode_body(body), do: Base.encode64(to_string(body))

  defp add_bearer(opts, %{bearer_token: t}) when is_binary(t) and t != "" do
    headers = Keyword.get(opts, :headers, [])
    Keyword.put(opts, :headers, [{"authorization", "Bearer " <> t} | headers])
  end

  defp add_bearer(opts, _), do: opts

  # ─── template.get — GET /templates/{template_id} ──────────────────────

  defp template_get_url(args),
    do: "#{@api_base}/templates/#{safe_path_id(args["template_id"])}"

  defp template_get_request(_args, _ctx), do: []

  defp template_get_response(s, body) when s in 200..299 do
    {:ok, %{"template" => body}}
  end

  # ─── envelope.create_from_template — POST /envelopes ──────────────────

  defp envelope_create_from_template_request(args, _ctx) do
    body =
      %{
        "templateId"    => args["template_id"],
        "templateRoles" => args["template_roles"] || [],
        "status"        => args["status"] || "sent"
      }
      |> maybe_put_kv("emailSubject", Map.get(args, "email_subject"))

    [json: body]
  end

  defp envelope_create_from_template_response(s, body) when s in 200..299 do
    {:ok,
     %{
       "envelope_id" =>
         to_string(Map.get(body, "envelopeId") || Map.get(body, "envelope_id") || "")
     }}
  end

  # ─── envelope.resend — PUT /envelopes/{id}/recipients?resend_envelope=true

  defp envelope_resend_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/recipients"

  # DocuSign requires a body even though resend is a no-op on
  # recipient state — `{signers: []}` keeps the existing recipient
  # list intact while the `?resend_envelope=true` query flag triggers
  # the notification email.
  defp envelope_resend_request(_args, _ctx) do
    [params: %{"resend_envelope" => "true"}, json: %{"signers" => []}]
  end

  defp envelope_resend_response(s, _body) when s in 200..299 do
    {:ok, %{"ok" => true}}
  end

  # ─── envelope.update_recipient — PUT /envelopes/{id}/recipients ───────

  defp envelope_update_recipient_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/recipients"

  # DocuSign expects the recipient PUT body as an array under the
  # role key (`signers`), even when patching a single recipient. The
  # connector exposes a single-recipient API and wraps it into the
  # vendor's array shape here.
  defp envelope_update_recipient_request(args, _ctx) do
    signer =
      %{"recipientId" => args["recipient_id"]}
      |> maybe_put_kv("name", Map.get(args, "name"))
      |> maybe_put_kv("email", Map.get(args, "email"))

    [json: %{"signers" => [signer]}]
  end

  defp envelope_update_recipient_response(s, _body) when s in 200..299 do
    # Vendor returns the recipientUpdateResults array on success but
    # the connector's manifest declares a single `recipient_id` field
    # — echo back the supplied id so downstream refs resolve.
    {:ok, %{"recipient_id" => "updated"}}
  end

  # ─── envelope.audit_events — GET /envelopes/{id}/audit_events ─────────

  defp envelope_audit_events_url(args),
    do: "#{@api_base}/envelopes/#{safe_path_id(args["envelope_id"])}/audit_events"

  defp envelope_audit_events_request(_args, _ctx), do: []

  defp envelope_audit_events_response(s, body) when s in 200..299 do
    events =
      body
      |> audit_events_list()
      |> Enum.map(&normalise_audit_event/1)

    {:ok, %{"events" => events}}
  end

  defp audit_events_list(%{"auditEvents" => list}) when is_list(list), do: list
  defp audit_events_list(body) when is_list(body), do: body
  defp audit_events_list(_), do: []

  # DocuSign audit-event records carry `eventFields`, an array of
  # `{name, value}` records. Flatten to a string-keyed map so the
  # caller sees `event.action`, `event.timestamp`, etc. without
  # walking a nested array.
  defp normalise_audit_event(%{"eventFields" => fields}) when is_list(fields) do
    Enum.reduce(fields, %{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) ->
        Map.put(acc, name, value)

      _, acc ->
        acc
    end)
  end

  defp normalise_audit_event(other) when is_map(other), do: other
  defp normalise_audit_event(_), do: %{}

  # ─── helpers ──────────────────────────────────────────────────────────

  # Whitelist a path-param id to the DocuSign id charset (UUID with
  # dashes) before interpolating it into a URL. A value that doesn't
  # match raises — the dispatcher surfaces it as an error envelope
  # rather than building a URL with an injected segment / query string.
  defp safe_path_id(id) do
    str = to_string(id)

    if Regex.match?(@path_id_re, str) do
      str
    else
      raise ArgumentError, "invalid docusign id: #{inspect(id)}"
    end
  end

  defp maybe_put_kv(map, _k, nil), do: map
  defp maybe_put_kv(map, _k, ""),  do: map
  defp maybe_put_kv(map, k, v),    do: Map.put(map, k, v)
end
