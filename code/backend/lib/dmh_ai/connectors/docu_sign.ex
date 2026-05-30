# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.DocuSign do
  @moduledoc """
  DocuSign connector (Universal Region, Case B — vendor MCP / REST
  bridge) covering envelopes, recipients, and templates on the
  DocuSign eSignature REST API (developers.docusign.com).

  Fifteen functions at the SME-relevant slice:

    envelope.find                 [read]   list envelopes matching status / from_date
    envelope.create               [write]  create + send a new envelope (default sent)
    envelope.get                  [read]   read one envelope by id
    envelope.send                 [write]  PUT status=sent on an existing draft
    envelope.void                 [write]  PUT status=voided with a voided reason
    envelope.list_recipients      [read]   union of signers + ccs + certified deliveries
    envelope.list_documents       [read]   list the envelope's documents
    envelope.download_document    [read]   fetch a document as base64 (binary PDF)
    envelope.create_from_template [write]  POST /envelopes from a template + roles
    envelope.resend               [write]  re-send envelope notifications (PUT recipients?resend_envelope=true)
    envelope.update_recipient     [write]  PUT /recipients to patch one recipient
    envelope.audit_events         [read]   read the envelope's audit trail
    recipient.add                 [write]  POST recipients to an existing envelope
    template.find                 [read]   list templates
    template.get                  [read]   read one template by id

  Three capability groups (envelopes / recipients / templates) so
  admins can scope per-org. A fourth `case_e_fallback` entry sits at
  `status: :planned` — the Case-E HTTP-adapter fallback (a feature-
  flagged Elixir-side REST adapter when DocuSign's vendor MCP is
  unavailable) is on the roadmap but not yet built.

  ## Per-account, per-environment API host

  The DocuSign eSignature REST API is per-account-and-environment:
  every data call lives at
  `https://{base_host}/restapi/v2.1/accounts/{account_id}/...`, where:

    * `{base_host}` is the user's environment — `demo.docusign.net`
      (sandbox) or `www.docusign.net` / a regional production host
      (`na1.docusign.net`, `eu.docusign.net`, …) for prod.
    * `{account_id}` is the user's DocuSign account_id.

  Both come from the OAuth userinfo response: `accounts[].base_uri`
  (which already encodes the environment + region) + `accounts[]
  .account_id`. The framework must template BOTH the host AND the
  account_id into the API base BEFORE any live call. The mock vendor
  server answers by function name, not URL, so it is exercised
  without substitution; this `@api_base` is therefore a vendor-facts
  placeholder until the per-account templating is wired.

  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## Coarse OAuth scopes

  DocuSign OAuth's scope model is coarse — the single `signature`
  scope grants envelope / recipient / template operations across the
  account. (The OIDC pair `openid email` is requested too for the
  userinfo round-trip, but functional access is `signature` alone.)
  So every function declares `scopes: ["signature"]`; the capability
  groups exist for admin curation, not OAuth scope narrowing.

  ## Path-param ids

  Functions acting on a specific envelope (`envelope.get` /
  `envelope.send` / `envelope.void` / `recipient.add`) interpolate
  the id into the URL path via a `:url` function `(args -> url)`.
  DocuSign envelope_ids are UUIDs *with dashes*, so the id is
  whitelisted to `^[A-Za-z0-9-]+$` before the URL is built
  (`safe_path_id/1` in the handler) — no raw interpolation of
  unvalidated input.

  ## Vendor quirks (`remap_error/1`)

  DocuSign returns an error body shaped
  `%{"errorCode" => <code>, "message" => ...}` with the HTTP status.
  The leading clauses key off `errorCode` (`USER_AUTHENTICATION_FAILED`
  / `INVALID_TOKEN_FORMAT` / `INVALID_CLIENT_ID` → `:unauthorised`;
  `ENVELOPE_DOES_NOT_EXIST` / `INVALID_ENVELOPE_ID` /
  `TEMPLATE_NOT_FOUND` → `:not_found`; `RATE_LIMIT_EXCEEDED` →
  `:rate_limited`). Other codes pass through, and HTTP-status tuples
  cover the standard 4xx classes.

  ## Demo vs prod OAuth host

  The catalog descriptor uses `account-d.docusign.com` (the sandbox
  / developer host). Production swaps to `account.docusign.com`. The
  framework selects the host based on the operator's environment
  setting; this descriptor records the demo URLs only.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  # DocuSign's REST API is per-account AND per-environment: every
  # data call lives at
  # `{base_host}/restapi/v2.1/accounts/{account_id}/...`, where BOTH
  # `{base_host}` (demo vs prod / region) and `{account_id}` come from
  # the OAuth userinfo `accounts[]` list (`base_uri` + `account_id`).
  # The framework must template BOTH placeholders before any live
  # call. The base host below is the demo sandbox; production reads
  # the user's `accounts[].base_uri` (typically `www.docusign.net`
  # or a regional host) and substitutes. The mock vendor server
  # answers by function name, not URL, so it is exercised without
  # substitution; the per-account base lives in the MCP handler.

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # DocuSign's OIDC userinfo endpoint returns `{ "sub", "email",
    # "accounts" => [%{"account_id", "base_uri", "is_default", ...}, ...] }`.
    # Demo lives at `account-d.docusign.com`; production at
    # `account.docusign.com`. The framework picks the host per its
    # environment setting — this connector module records the demo URL.
    # Standard Bearer auth.
    url = "https://account-d.docusign.com/oauth/userinfo"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"email" => email, "sub" => sub}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(sub)}}

      {:ok, %{status: 200, body: %{"email" => email}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__docusign_userinfo_stub__) do
      nil ->
        Req.get(url,
          headers: [{"authorization", "Bearer " <> access_token}],
          finch: DmhAi.Finch,
          receive_timeout: 5_000,
          retry: false
        )

      stub ->
        stub.(url, access_token)
    end
  end

  @impl true
  def mcp_slug, do: "docusign"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.docusign.com/docs/esign-rest-api/", title: "DocuSign eSignature REST API"},
       %{url: "https://developers.docusign.com/docs/esign-rest-api/reference/envelopes/", title: "DocuSign — Envelopes reference"},
       %{url: "https://developers.docusign.com/docs/esign-rest-api/reference/envelopes/enveloperecipients/", title: "DocuSign — Envelope recipients"},
       %{url: "https://developers.docusign.com/docs/esign-rest-api/reference/templates/", title: "DocuSign — Templates reference"},
       %{url: "https://developers.docusign.com/platform/auth/", title: "DocuSign — OAuth 2.0 reference"}
     ]}
  end

  # Per-user metadata sweep. DocuSign exposes account-level custom
  # fields, recipient roles, and template metadata, but wiring them
  # is future work. Always return an empty row set (no metadata to
  # cache) — same contract as the other Case-B connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. DocuSign field / property schemas are not yet
  # wired into a metadata cache, so there is nothing to consult.
  # Always return `:not_supported`, which the compiler treats as
  # "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "docusign",
      region:    "universal",
      functions: %{
        # vendor: GET /envelopes
        # docs:   https://developers.docusign.com/docs/esign-rest-api/reference/envelopes/envelopes/listStatusChanges/
        #
        # DocuSign OAuth scopes are coarse: the single `signature`
        # scope covers all envelope / recipient / template ops.
        "envelope.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "status"    => %{type: :string,  required: false},
            "from_date" => %{type: :string,  required: false},
            "limit"     => %{type: :integer, required: false}
          },
          returns: %{envelopes: :list},
          scopes:  ["signature"]
        },

        # vendor: POST /envelopes
        "envelope.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subject"    => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "recipients" => %{type: :list,   required: true,
                              provenance: %{kind: :literal_default}},
            "documents"  => %{type: :list,   required: true,
                              provenance: %{kind: :literal_default}},
            "status"     => %{type: :string, required: true,
                              provenance: %{kind: :literal_default, value: "sent"}}
          },
          returns: %{envelope_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["signature"]
        },

        # vendor: GET /envelopes/{envelope_id}
        "envelope.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{envelope: :map},
          scopes:  ["signature"]
        },

        # vendor: PUT /envelopes/{envelope_id} with body
        # `{"status": "sent"}` — flips a draft to sent.
        "envelope.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["signature"]
        },

        # vendor: PUT /envelopes/{envelope_id} with body
        # `{"status": "voided", "voidedReason": <reason>}`.
        "envelope.void" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "envelope_id"   => %{type: :string, required: true,
                                 provenance: %{kind: :lookup,
                                               source: "docusign.envelope.find"}},
            "voided_reason" => %{type: :string, required: true,
                                 provenance: %{kind: :from_user}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["signature"]
        },

        # vendor: POST /envelopes/{envelope_id}/recipients
        "recipient.add" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}},
            "recipients"  => %{type: :list,   required: true,
                               provenance: %{kind: :literal_default}}
          },
          returns: %{recipient_id_added: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["signature"]
        },

        # vendor: GET /templates
        "template.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{templates: :list},
          scopes:  ["signature"]
        },

        # vendor: GET /envelopes/{envelope_id}/recipients
        # Returns the union of `signers` + `carbonCopies` +
        # `certifiedDeliveries` arrays as a flat list — every recipient
        # role on the envelope, regardless of routing class.
        "envelope.list_recipients" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{recipients: :list},
          scopes:  ["signature"]
        },

        # vendor: GET /envelopes/{envelope_id}/documents
        # Response: `envelopeDocuments` array — id + name + type per
        # document attached to the envelope.
        "envelope.list_documents" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{documents: :list},
          scopes:  ["signature"]
        },

        # vendor: GET /envelopes/{envelope_id}/documents/{document_id}
        # Returns the document as binary content (typically PDF). The
        # connector base64-encodes the body so it survives the
        # JSON-shaped tool-result envelope, and surfaces a content_type
        # alongside (defaults to application/pdf — DocuSign returns
        # PDFs unless `?certificate=true` or a combined-document option
        # was supplied).
        "envelope.download_document" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}},
            "document_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.list_documents"}}
          },
          returns: %{content_b64: :string, content_type: :string},
          scopes:  ["signature"]
        },

        # vendor: GET /templates/{template_id}
        "template.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "template_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.template.find"}}
          },
          returns: %{template: :map},
          scopes:  ["signature"]
        },

        # vendor: POST /envelopes (with templateId + templateRoles)
        # Reuses the same `/envelopes` create endpoint as
        # `envelope.create`; the templateId + templateRoles body flips
        # the vendor's branch to materialise the envelope from the
        # template's documents + tab layout.
        "envelope.create_from_template" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "template_id"    => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "docusign.template.find"}},
            "template_roles" => %{type: :list,   required: true,
                                  provenance: %{kind: :literal_default}},
            "email_subject"  => %{type: :string, required: false,
                                  provenance: %{kind: :from_user}},
            "status"         => %{type: :string, required: false,
                                  provenance: %{kind: :literal_default, value: "sent"}}
          },
          returns: %{envelope_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited, :validation],
          scopes:  ["signature"]
        },

        # vendor: PUT /envelopes/{envelope_id}/recipients?resend_envelope=true
        # DocuSign requires a body even though the resend is a no-op on
        # recipient state — the handler sends `{signers: []}` to keep
        # the existing recipient list intact while triggering a new
        # notification email.
        "envelope.resend" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["signature"]
        },

        # vendor: PUT /envelopes/{envelope_id}/recipients
        # Patches one signer in-place. DocuSign expects the body shape
        # `{signers: [%{recipientId, name?, email?}]}` — the array
        # wrapper is required even for a single-recipient update.
        "envelope.update_recipient" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "envelope_id"  => %{type: :string, required: true,
                                provenance: %{kind: :lookup,
                                              source: "docusign.envelope.find"}},
            "recipient_id" => %{type: :string, required: true,
                                provenance: %{kind: :lookup,
                                              source: "docusign.envelope.list_recipients"}},
            "name"         => %{type: :string, required: false,
                                provenance: %{kind: :from_user}},
            "email"        => %{type: :string, required: false, format: :email,
                                provenance: %{kind: :from_user}}
          },
          returns: %{recipient_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited, :validation],
          scopes:  ["signature"]
        },

        # vendor: GET /envelopes/{envelope_id}/audit_events
        # Response: `auditEvents` array of `eventFields` records — flat
        # timestamped log of every state change on the envelope.
        "envelope.audit_events" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "envelope_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "docusign.envelope.find"}}
          },
          returns: %{events: :list},
          scopes:  ["signature"]
        }
      }
    }
  end

  @impl true
  # DocuSign exposes `/users?email_substring=<email>` on the account,
  # but a dedicated identity-pivot function is not yet in this
  # manifest. Fix later: add `user.find_by_email` and switch this to:
  #   %{function: "docusign.user.find_by_email",
  #     by_arg: :email, emit_field: "user_id"}
  def identity_lookup, do: nil

  @impl true
  # DocuSign error bodies look like
  # `%{"errorCode" => <code>, "message" => ...}` with the HTTP status.
  # The leading clauses key off `errorCode` and only the auth-flavored
  # codes map to `:unauthorised`; other codes pass through. The
  # HTTP-status tuples below cover the standard 4xx classes.
  def remap_error(%{"errorCode" => code})
      when code in ["INVALID_TOKEN_FORMAT", "USER_AUTHENTICATION_FAILED", "INVALID_CLIENT_ID"],
      do: :unauthorised

  def remap_error(%{"errorCode" => code})
      when code in ["ENVELOPE_DOES_NOT_EXIST", "INVALID_ENVELOPE_ID", "TEMPLATE_NOT_FOUND"],
      do: :not_found

  def remap_error(%{"errorCode" => "RATE_LIMIT_EXCEEDED"}), do: :rate_limited
  def remap_error(%{"errorCode" => _}),                     do: :passthrough

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. DocuSign OAuth (the
  Authorization Code Grant) lives at `account-d.docusign.com/oauth/auth`
  (consent) + `account-d.docusign.com/oauth/token` (exchange) in the
  developer sandbox. Production swaps `account-d` → `account` (i.e.
  `account.docusign.com/oauth/auth`); the framework picks the host
  per its environment setting.

  Scopes: `signature` is the single broad scope that grants envelope
  / recipient / template operations; `openid` + `email` are added so
  the `/oauth/userinfo` round-trip can return the connecting user's
  email + the `accounts[]` list (which carries `account_id` +
  `base_uri` — both REQUIRED for templating the live REST API base).

  IMPORTANT: the live REST API host is per-account AND per-environment
  — `accounts[].base_uri` from userinfo encodes both, and the
  framework must template BOTH `{base_host}` AND `{account_id}` into
  the per-product API base (`@api_base` placeholder in the MCP
  handler) before any data call. The mock test does not drive the
  OAuth flow, so this descriptor is correct as a vendor-fact record
  while the per-account substitution is wired.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "docusign",
      display_name:           "DocuSign",
      host_match:             "docusign.com",
      authorization_endpoint: "https://account-d.docusign.com/oauth/auth",
      token_endpoint:         "https://account-d.docusign.com/oauth/token",
      scopes:                 ["signature", "openid", "email"],
      userinfo_endpoint:      "https://account-d.docusign.com/oauth/userinfo",
      userinfo_field_path:    "email",
      extra_auth_params:      %{}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "docusign",
      name:        "DocuSign",
      description: "DocuSign eSignature — envelopes, recipients, templates.",
      auth_kind:   :oauth,
      categories:  ["esignature", "documents"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (obviously-fake DocuSign
  UUID-shaped ids + a fake envelope subject) so chain results are
  mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_docusign",
      port_env:     "DMH_AI_DOCUSIGN_MOCK_PORT",
      default_port: 8097,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.DocuSign.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the DocuSign MCP as an in-process REST translator on
  the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/docusign"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount DocuSign on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.DocuSign.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Three
  domain groups go live — envelopes / recipients / templates — so
  an esignature-only org can expose envelopes + recipients and skip
  templates, while a templated-workflow org enables all three. A
  fourth `case_e_fallback` entry sits at `status: :planned` so the FE
  can render it as a coming-soon item; it carries no functions and is
  filtered out of the dispatcher gate. The Case-E HTTP-adapter
  fallback (a feature-flagged Elixir-side REST adapter when DocuSign's
  vendor MCP is unavailable) is on the roadmap but not yet built.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "envelopes",
        display_name: "Envelopes",
        description:  "Find, create, read, send, void, resend, list recipients / documents, download a document, create from a template, update a recipient, and read the audit trail of DocuSign envelopes.",
        scopes:       ["signature"],
        functions:    ["envelope.find", "envelope.create", "envelope.get",
                       "envelope.send", "envelope.void",
                       "envelope.list_recipients", "envelope.list_documents",
                       "envelope.download_document",
                       "envelope.create_from_template",
                       "envelope.resend", "envelope.update_recipient",
                       "envelope.audit_events"],
        vendor_prereq: %{
          label:      "DocuSign developer account + OAuth 2.0 app",
          enable_url: "https://developers.docusign.com/platform/auth/"
        }
      },
      %{
        id:           "recipients",
        display_name: "Recipients",
        description:  "Add recipients to an existing envelope.",
        scopes:       ["signature"],
        functions:    ["recipient.add"],
        vendor_prereq: %{
          label:      "DocuSign developer account + OAuth 2.0 app",
          enable_url: "https://developers.docusign.com/platform/auth/"
        }
      },
      %{
        id:           "templates",
        display_name: "Templates",
        description:  "List DocuSign templates and read one by id.",
        scopes:       ["signature"],
        functions:    ["template.find", "template.get"],
        vendor_prereq: %{
          label:      "DocuSign developer account + OAuth 2.0 app",
          enable_url: "https://developers.docusign.com/platform/auth/"
        }
      },
      %{
        id:           "case_e_fallback",
        display_name: "Case-E HTTP adapter (fallback)",
        description:  "Feature-flagged Elixir REST adapter when DocuSign's vendor MCP is unavailable. Coming soon.",
        status:       :planned,
        scopes:       [],
        functions:    [],
        vendor_prereq: %{
          label:      "DocuSign eSignature REST API",
          enable_url: "https://developers.docusign.com/docs/esign-rest-api/"
        }
      }
    ]
  end
end
