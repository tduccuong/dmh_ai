# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Brevo do
  @moduledoc """
  Brevo connector (Universal Region — formerly Sendinblue; contacts /
  lists / transactional email / templates / campaigns / deliverability
  events). Case-B vendor-hosted MCP: Brevo runs the MCP server itself,
  so there is no in-process REST translator and no `MCPHandler` subdir
  here. The dispatcher delegates to the vendor's MCP; the per-connector
  module owns slug + manifest + error remap + discovery seeds.

  Auth is **API key**, not OAuth — the third Case-B connector after
  Stripe and Klaviyo to use this credential kind. The per-user
  credential row is `target='api_key:brevo'`, `kind='api_key'` with
  payload `{"api_key": "xkeysib-..."}`.

  ## Vendor auth quirks (concerns of the vendor MCP server, not this module)

    * `api-key: <key>` — Brevo uses a custom request header literally
      named `api-key` rather than the standard `Authorization: Bearer`
      scheme. The vendor's MCP server reads our `api_key` payload and
      inserts the header on each upstream REST call.
    * Contacts are identified by **email in the URL path** (e.g.
      `PUT /v3/contacts/{email}`, `DELETE /v3/contacts/{email}`) —
      there is no integer / opaque contact-id pivot. The vendor MCP
      URL-encodes the email when composing the path.

  REST base for the docs: `https://api.brevo.com/v3`.

  Fourteen functions at the SME-relevant slice:

    contact.find              [read]   look up contacts by email
    contact.create            [write]  create a new contact
    contact.update            [write]  update an existing contact (path-pivot by email)
    contact.delete            [write]  delete a contact (path-pivot by email)
    contact.add_to_list       [write]  bulk-add emails to a list
    contact.remove_from_list  [write]  bulk-remove emails from a list
    email.send                [write]  send a one-off transactional email
    email.send_template       [write]  send a transactional email rendered from a template
    list.find                 [read]   list contact lists
    list.create               [write]  create a contact list
    template.find             [read]   list transactional email templates
    campaign.find             [read]   list email campaigns (optionally filtered by status)
    campaign.create           [write]  create an email campaign (draft)
    transactional.event.find  [read]   browse delivery events (delivered/opened/bounced/...)

  ## Layer B — per-user vendor metadata

  `discover_metadata/1` sweeps two Brevo endpoints with the user's
  `api_key:brevo` credential and caches the result in
  `connector_vendor_metadata` so `inspect_function_property` can answer
  contact-attribute + list-id questions without a live probe at compile
  time. Two cache rows go in per user:

    * `contacts.attributes` — schema for every contact attribute
      (FIRSTNAME, SMS, PREF, …) including the `enumeration` options
      on category-typed attributes.
    * `contacts.lists` — synthesised as a single `list_id` property
      whose `options` enumerate the user's lists so name-match in
      `inspect_property/3` finds them on the same code path as
      attribute lookups.

  ## Templates vs transactional vs campaigns

  Brevo's email surface has three distinct shapes that are easy to confuse:

    * **Transactional one-off** (`email.send`) — caller supplies raw
      `subject` + `html_content`/`text_content`. Endpoint
      `POST /v3/smtp/email`. Use for per-event mail (order confirmation,
      password reset).
    * **Transactional from template** (`email.send_template`) — caller
      references a saved transactional template by `template_id` and
      supplies variable substitutions via `params`. Same endpoint
      `POST /v3/smtp/email`, body uses `templateId` instead of inline
      content. Templates are managed in the Brevo UI; this connector
      only sends from + lists them, doesn't create them.
    * **Campaign** (`campaign.find` / `campaign.create`) — a bulk
      marketing send targeting a contact list. Endpoint
      `/v3/emailCampaigns`. Status values are `draft`, `sent`,
      `scheduled`. Created campaigns land as drafts; sending happens
      via the Brevo UI or a separate trigger step not in this slice.

  ## Deliverability events

  `transactional.event.find` hits `/v3/smtp/statistics/events` — the
  per-message delivery log used to answer "did this email arrive?".
  Filter `event` values are vendor literals: `delivered`, `opened`,
  `clicked`, `bounced`, `hardBounces`, `spam`. Filter by `email` to
  scope to a single recipient.

  Brevo error contract (`/v3/...` REST):
    * 429              -> `:rate_limited`.
    * 404              -> `:not_found`.
    * 401 / 403        -> `:unauthorised`.
    * 400 / 409 whose body contains "duplicate" -> `:duplicate`.
    * JSON body shape `%{"code" => code, "message" => msg}` drives
      canonical mapping when present (per-code mapping below).
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "brevo"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.brevo.com/reference/getting-started-1",   title: "Brevo API reference"},
       %{url: "https://developers.brevo.com/reference/getcontacts",         title: "Brevo - Contacts"},
       %{url: "https://developers.brevo.com/reference/sendtransacemail",    title: "Brevo - Transactional email"},
       %{url: "https://developers.brevo.com/reference/getlists-1",          title: "Brevo - Lists"},
       %{url: "https://developers.brevo.com/reference/gettemplates",        title: "Brevo - Transactional templates"},
       %{url: "https://developers.brevo.com/reference/getemailcampaigns",   title: "Brevo - Email campaigns"},
       %{url: "https://developers.brevo.com/reference/getemaileventreport", title: "Brevo - Transactional email events"}
     ]}
  end

  # Per-user metadata sweep. Hits Brevo's `/v3/contacts/attributes` and
  # `/v3/contacts/lists` endpoints and stores one
  # `connector_vendor_metadata` row per object so the model can later
  # read attribute shapes (incl. `enumeration` options on category
  # attributes) and list ids without a live probe at compile time.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "api_key:brevo") do
      [%{payload: %{"api_key" => key}} | _] when is_binary(key) ->
        sweep_layer_b(key)

      _ ->
        {:error, :no_brevo_credential}
    end
  end

  # Map a function bare-name to the Brevo cache row whose schema is the
  # source of truth for that function's args. The `inspect_property/3`
  # callback uses this to route a property lookup at the cached metadata
  # row produced by `discover_metadata/1`. Contact CRUD functions read
  # the attribute schema; list-membership functions read the synthesised
  # `list_id` enum.
  @function_to_cache %{
    "contact.find"             => "contacts.attributes",
    "contact.create"           => "contacts.attributes",
    "contact.update"           => "contacts.attributes",
    "contact.add_to_list"      => "contacts.lists",
    "contact.remove_from_list" => "contacts.lists"
  }

  # Layer B reader. Same shape as HubSpot's: consult the metadata cache
  # populated by `discover_metadata/1`, locate the matching property by
  # name and return its type, label, and (when set) the vendor's option
  # list.
  #
  # Path-stripping quirk: Brevo's contact-create / contact-update args
  # carry attributes nested under an `attributes` map, so the model
  # frequently passes the dotted form (`"attributes.FIRSTNAME"`) when
  # introspecting one. Strip a leading `attributes.` prefix before the
  # name match so both `"FIRSTNAME"` and `"attributes.FIRSTNAME"` resolve.
  #
  # Returns `:not_supported` when:
  #   * the function name doesn't map to a known cache row
  #   * the user hasn't run Discover Metadata yet (cache empty)
  #   * the requested property isn't in the cached schema
  @impl true
  def inspect_property(function_name, path, ctx) do
    bare_path = strip_attributes_prefix(path)

    with cache_path when is_binary(cache_path) <- Map.get(@function_to_cache, function_name),
         %{schema: %{"properties" => props}} when is_list(props) <-
           Enum.find(ctx[:vendor_metadata] || [], fn r -> r.path == cache_path end),
         %{} = prop <- Enum.find(props, fn p -> p["name"] == bare_path end) do
      {:ok,
       %{
         type:        prop["type"],
         enum:        extract_enum(prop),
         description: prop["label"],
         source:      :vendor_metadata
       }}
    else
      _ -> {:error, :not_supported}
    end
  end

  defp strip_attributes_prefix("attributes." <> rest), do: rest
  defp strip_attributes_prefix(other),                  do: other

  defp extract_enum(%{"options" => options}) when is_list(options) and options != [] do
    options
    |> Enum.map(fn o -> o["value"] end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_enum(_), do: nil

  defp sweep_layer_b(key) do
    headers = [{"api-key", key}, {"accept", "application/json"}]

    steps = [
      {"contacts.attributes",
       "https://api.brevo.com/v3/contacts/attributes",
       &build_attributes_row/1},
      # One-shot pagination is intentional: Brevo defaults to 50 rows
      # which covers SME accounts. If a deployment ever needs more,
      # walk `offset` via the `count` field on the response.
      {"contacts.lists",
       "https://api.brevo.com/v3/contacts/lists?limit=50&offset=0",
       &build_lists_row/1}
    ]

    Enum.reduce_while(steps, {:ok, []}, fn {cache_path, url, builder}, {:ok, acc} ->
      case Req.get(url, headers: headers, finch: DmhAi.Finch, receive_timeout: 8_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          schema = builder.(body)
          {:cont, {:ok, acc ++ [%{path: cache_path, schema: schema, expires_at: nil}]}}

        {:ok, %{status: s, body: body}} ->
          {:halt, {:error, {:http, s, body}}}

        {:error, reason} ->
          {:halt, {:error, {:transport, reason}}}
      end
    end)
  end

  # Brevo's contact-attribute response shape:
  #   {"attributes": [%{"name", "category", "type", "enumeration", ...}, ...]}
  # Keep the useful fields verbatim and rename `enumeration` → `options`
  # so the shared `extract_enum/1` (same shape as HubSpot's) works
  # without a Brevo-specific helper. Non-category attributes don't
  # carry `enumeration`; drop the key in that case.
  defp build_attributes_row(%{"attributes" => attrs}) when is_list(attrs) do
    properties =
      Enum.map(attrs, fn attr ->
        attr
        |> Map.take(~w(name type category enumeration calculatedValue))
        |> rename_enumeration_to_options()
      end)

    %{"object_type" => "contacts.attributes", "properties" => properties}
  end

  defp build_attributes_row(_), do: %{"object_type" => "contacts.attributes", "properties" => []}

  defp rename_enumeration_to_options(%{"enumeration" => enum} = m) when is_list(enum) do
    m
    |> Map.delete("enumeration")
    |> Map.put("options", enum)
  end

  defp rename_enumeration_to_options(m), do: Map.delete(m, "enumeration")

  # Brevo's contact-list response shape:
  #   {"lists": [%{"id", "name", "folderId", ...}, ...], "count": n}
  # Encode as a single synthetic `list_id` property whose `options` are
  # the list ids. That way `inspect_property("contact.add_to_list",
  # "list_id", ctx)` resolves via the same name-match path attribute
  # lookups take — no special-casing in the reader.
  defp build_lists_row(%{"lists" => lists}) when is_list(lists) do
    options =
      Enum.map(lists, fn l -> %{"value" => l["id"], "label" => l["name"]} end)

    %{
      "object_type" => "contacts.lists",
      "properties"  => [
        %{"name" => "list_id", "type" => "integer", "options" => options}
      ]
    }
  end

  defp build_lists_row(_) do
    %{
      "object_type" => "contacts.lists",
      "properties"  => [%{"name" => "list_id", "type" => "integer", "options" => []}]
    }
  end

  @impl true
  def credential_kind, do: :api_key

  @impl true
  def manifest do
    %Manifest{
      connector: "brevo",
      region:    "universal",
      functions: %{
        # vendor: GET /v3/contacts
        "contact.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string,  required: false, format: :email},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{contacts: :list}
        },

        # vendor: POST /v3/contacts
        "contact.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email"      => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :from_user}},
            "attributes" => %{type: :map,    required: false},
            "list_ids"   => %{type: :list,   required: false}
          },
          returns: %{contact_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited]
        },

        # vendor: PUT /v3/contacts/{email}
        # Brevo identifies contacts by email in the path — there is no
        # opaque id pivot. The vendor MCP URL-encodes the email when
        # composing the request URL.
        "contact.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email"      => %{type: :string, required: true, format: :email,
                              provenance: %{kind: :lookup,
                                            source: "brevo.contact.find"}},
            "attributes" => %{type: :map,    required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: DELETE /v3/contacts/{email}
        # Same email-as-path-id quirk as `contact.update`; vendor MCP
        # URL-encodes the email.
        "contact.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :lookup,
                                       source: "brevo.contact.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: POST /v3/contacts/lists/{list_id}/contacts/add
        # Bulk membership add by email list. Returns the count of
        # contacts actually added (existing members are skipped).
        "contact.add_to_list" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "list_id" => %{type: :integer, required: true,
                           provenance: %{kind: :lookup,
                                         source: "brevo.list.find"}},
            "emails"  => %{type: :list,    required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{contacts_added: :integer},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: POST /v3/contacts/lists/{list_id}/contacts/remove
        # Bulk membership remove by email list.
        "contact.remove_from_list" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "list_id" => %{type: :integer, required: true,
                           provenance: %{kind: :lookup,
                                         source: "brevo.list.find"}},
            "emails"  => %{type: :list,    required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{contacts_removed: :integer},
          errors:  [:unauthorised, :not_found, :rate_limited]
        },

        # vendor: POST /v3/smtp/email (transactional email — inline content)
        "email.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "to"           => %{type: :list,   required: true,
                                provenance: %{kind: :from_user}},
            "subject"      => %{type: :string, required: true,
                                provenance: %{kind: :literal_default}},
            "html_content" => %{type: :string, required: false},
            "text_content" => %{type: :string, required: false},
            "sender"       => %{type: :map,    required: false}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :rate_limited]
        },

        # vendor: POST /v3/smtp/email (same endpoint as `email.send`,
        # but the request body carries `templateId` + `params` instead
        # of inline content; vendor renders the saved template with
        # the supplied variable substitutions).
        "email.send_template" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "template_id" => %{type: :integer, required: true,
                               provenance: %{kind: :lookup,
                                             source: "brevo.template.find"}},
            "to"          => %{type: :list,    required: true,
                               provenance: %{kind: :from_user}},
            "params"      => %{type: :map,     required: false,
                               provenance: %{kind: :literal_default}}
          },
          returns: %{message_id: :string},
          errors:  [:unauthorised, :rate_limited]
        },

        # vendor: GET /v3/contacts/lists
        "list.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{lists: :list}
        },

        # vendor: POST /v3/contacts/lists
        "list.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"      => %{type: :string,  required: true,
                             provenance: %{kind: :from_user}},
            "folder_id" => %{type: :integer, required: false}
          },
          returns: %{list_id: :integer},
          errors:  [:unauthorised, :duplicate, :rate_limited]
        },

        # vendor: GET /v3/smtp/templates
        # Lists transactional templates (UI-managed). The id feeds
        # `email.send_template`.
        "template.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{templates: :list}
        },

        # vendor: GET /v3/emailCampaigns
        # `status` values are vendor literals: draft / sent / scheduled.
        "campaign.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "status" => %{type: :string,  required: false},
            "limit"  => %{type: :integer, required: false}
          },
          returns: %{campaigns: :list}
        },

        # vendor: POST /v3/emailCampaigns
        # Vendor MCP wraps `sender_email` / `recipients_list_ids` into
        # the request body shape:
        #   {name, subject, sender: {email: sender_email},
        #    htmlContent: html_content,
        #    recipients: {listIds: recipients_list_ids}}
        # Created campaign lands as a draft; sending is a separate
        # trigger step not in this slice.
        "campaign.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"                 => %{type: :string, required: true,
                                        provenance: %{kind: :from_user}},
            "subject"              => %{type: :string, required: true,
                                        provenance: %{kind: :literal_default}},
            "sender_email"         => %{type: :string, required: true, format: :email,
                                        provenance: %{kind: :from_user}},
            "html_content"         => %{type: :string, required: true,
                                        provenance: %{kind: :literal_default}},
            "recipients_list_ids"  => %{type: :list,   required: true,
                                        provenance: %{kind: :literal_default}}
          },
          returns: %{campaign_id: :integer},
          errors:  [:unauthorised, :duplicate, :rate_limited]
        },

        # vendor: GET /v3/smtp/statistics/events
        # Deliverability log for transactional sends — answers "did
        # the email arrive?". `event` filter values are vendor literals:
        # delivered / opened / clicked / bounced / hardBounces / spam.
        "transactional.event.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string,  required: false, format: :email},
            "event" => %{type: :string,  required: false},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{events: :list}
        }
      }
    }
  end

  @impl true
  # Brevo REST errors arrive shaped as a flat envelope:
  #   %{"code" => "<machine_code>", "message" => "<human text>"}
  # alongside a non-2xx HTTP status. Map the `code` to the canonical
  # vocabulary; when no code is present (or it's not one we recognise)
  # fall through to the HTTP-status clauses below.
  def remap_error(%{"code" => code}) when is_binary(code) do
    cond do
      code in ["duplicate_parameter", "duplicate_request"]    -> :duplicate
      code in ["unauthorized", "invalid_parameter"]            -> :unauthorised
      code in ["document_not_found", "contact_not_found"]      -> :not_found
      code in ["too_many_requests"]                            -> :rate_limited
      true                                                     -> :passthrough
    end
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, status, body}) when status in [400, 409],
    do: if(body_indicates_duplicate?(body), do: :duplicate, else: :passthrough)
  def remap_error(_), do: :passthrough

  # Body inspection used only inside the 400 / 409 clauses. Brevo returns
  # the duplicate signal in human-readable prose in the body — no
  # interpolation of user-supplied content into a regex or shell; plain
  # substring match on the literal vendor word.
  defp body_indicates_duplicate?(body) when is_binary(body),
    do: body =~ "duplicate"

  defp body_indicates_duplicate?(_), do: false
end
