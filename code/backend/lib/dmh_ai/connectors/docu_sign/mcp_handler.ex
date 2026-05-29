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

    envelope.find    — GET  /envelopes
    envelope.create  — POST /envelopes
    envelope.get     — GET  /envelopes/{envelope_id}
    envelope.send    — PUT  /envelopes/{envelope_id}  (status=sent)
    envelope.void    — PUT  /envelopes/{envelope_id}  (status=voided)
    recipient.add    — POST /envelopes/{envelope_id}/recipients
    template.find    — GET  /templates

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
  `envelope.send` / `envelope.void` / `recipient.add`) interpolate
  the id into the URL path via a `:url` function `(args -> url)`.
  DocuSign envelope_ids are UUIDs *with dashes*, so the id is
  whitelisted to `^[A-Za-z0-9-]+$` before the URL is built
  (`safe_path_id/1`) — no raw interpolation of unvalidated input.
  """

  alias DmhAi.Connectors.MCPServer.FunctionSpec
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
