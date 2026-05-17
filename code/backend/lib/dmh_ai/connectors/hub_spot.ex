# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.HubSpot do
  @moduledoc """
  HubSpot connector (Universal Region, Case B — vendor MCP).

  Eleven functions at the SME-relevant slice of HubSpot's CRM API
  (developers.hubspot.com/docs/api/crm/*) — contacts, deals,
  companies, tasks, activities:

    contact.find    [read]   search by query string
    contact.create  [write]  upsert a contact
    contact.update  [write]  PATCH an existing contact's properties
    company.find    [read]   search companies (B2B org records)
    company.create  [write]  create a company
    company.update  [write]  PATCH a company's properties
    deal.find       [read]   list deals (filter by stage / owner)
    deal.create     [write]  open a deal tied to a contact
    deal.update     [write]  patch a deal (stage transition, amount …)
    activity.log    [write]  log a Note engagement on a deal
    task.create     [write]  create a Task engagement (actionable, not a note)

  Five capability groups (contacts / deals / companies / tasks /
  activities) so admins can scope per-org — a CSM-only org might
  tick contacts + activities + companies + tasks; a sales-team
  org enables all five.

  ## Vendor quirks (`remap_error/1`)

  HubSpot returns a JSON error body with `category` on conflicts;
  `OBJECT_ALREADY_EXISTS` is the duplicate signal across both the
  CRM v3 API and the hosted MCP. Map it to canonical `:duplicate`
  so recipes / tasks branch deterministically rather than parsing
  the upstream string.
  """

  use DmhAi.Connectors.MCPAdapter
  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl true
  def mcp_slug, do: "hubspot"

  @impl true
  def manifest do
    %Manifest{
      connector: "hubspot",
      region:    "universal",
      functions: %{
        # vendor: POST /crm/v3/objects/contacts/search
        # docs:   https://developers.hubspot.com/docs/api/crm/contacts
        "contact.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{contacts: :list},
          scopes:  ["crm.objects.contacts.read"]
        },

        # vendor: POST /crm/v3/objects/contacts
        "contact.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "email"      => %{type: :string, required: true, format: :email},
            "first_name" => %{type: :string, required: false},
            "last_name"  => %{type: :string, required: false},
            "company"    => %{type: :string, required: false}
          },
          returns: %{contact_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["crm.objects.contacts.write"]
        },

        # vendor: PATCH /crm/v3/objects/contacts/{id}
        # The agent uses this for post-call "update Brian's title to
        # VP Engineering" / "set company to Acme" / "fix the email"
        # follow-ups. `patch` is a free-form map of HubSpot property
        # names → values; the shim does not enumerate or validate
        # property names so custom properties pass through.
        "contact.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "contact_id" => %{type: :string, required: true},
            "patch"      => %{type: :map,    required: true}
          },
          returns: %{contact_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["crm.objects.contacts.write"]
        },

        # vendor: POST /crm/v3/objects/companies/search
        "company.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{companies: :list},
          scopes:  ["crm.objects.companies.read"]
        },

        # vendor: POST /crm/v3/objects/companies
        "company.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"    => %{type: :string, required: true},
            "domain"  => %{type: :string, required: false},
            "city"    => %{type: :string, required: false},
            "country" => %{type: :string, required: false}
          },
          returns: %{company_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["crm.objects.companies.write"]
        },

        # vendor: PATCH /crm/v3/objects/companies/{id}
        "company.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "company_id" => %{type: :string, required: true},
            "patch"      => %{type: :map,    required: true}
          },
          returns: %{company_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["crm.objects.companies.write"]
        },

        # vendor: POST /crm/v3/objects/deals/search
        # docs:   https://developers.hubspot.com/docs/api/crm/deals
        "deal.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "stage" => %{type: :string,  required: false},
            "owner" => %{type: :string,  required: false},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{deals: :list},
          scopes:  ["crm.objects.deals.read"]
        },

        # vendor: POST /crm/v3/objects/deals
        # shim translation: `contact_id` → association on creation;
        # `amount`, `stage`, `name` → properties payload.
        "deal.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "contact_id" => %{type: :string, required: true},
            "amount"     => %{type: :number, required: true},
            "stage"      => %{type: :string, required: false},
            "name"       => %{type: :string, required: false}
          },
          returns: %{deal_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        },

        # vendor: PATCH /crm/v3/objects/deals/{id}
        "deal.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "deal_id" => %{type: :string, required: true},
            "patch"   => %{type: :map,    required: true}
          },
          returns: %{deal_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        },

        # vendor: POST /crm/v3/objects/notes  (engagement of type Note)
        # docs:   https://developers.hubspot.com/docs/api/crm/notes
        # shim translation: `body` → Notes' `hs_note_body`;
        # `deal_id` → associations[].toObjectId.
        "activity.log" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "deal_id" => %{type: :string, required: true},
            "kind"    => %{type: :string, required: true},
            "body"    => %{type: :string, required: true}
          },
          returns: %{activity_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        },

        # vendor: POST /crm/v3/objects/tasks
        # Tasks are distinct from Notes — they have a status (NOT_STARTED
        # / IN_PROGRESS / COMPLETED), a priority, a due date, and a type
        # (CALL / EMAIL / TODO). The agent uses tasks for "remind the rep
        # to follow up on Thursday" style assignments, vs notes which
        # are informational.
        "task.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subject"    => %{type: :string, required: true},
            "body"       => %{type: :string, required: false},
            "due_date"   => %{type: :string, required: false},
            "priority"   => %{type: :string, required: false},
            "task_type"  => %{type: :string, required: false},
            "deal_id"    => %{type: :string, required: false},
            "contact_id" => %{type: :string, required: false}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["crm.objects.deals.write"]
        }
      }
    }
  end

  @impl true
  def remap_error(%{"category" => "OBJECT_ALREADY_EXISTS"}), do: :duplicate

  def remap_error({:http, 409, body}) when is_binary(body) do
    if body =~ "OBJECT_ALREADY_EXISTS", do: :duplicate, else: :passthrough
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. HubSpot OAuth lives
  at `app.hubspot.com/oauth/authorize` (consent) +
  `api.hubapi.com/oauth/v1/token` (exchange). Per HubSpot docs the
  authorization grant returns refresh_token by default — no extra
  param needed.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "hubspot",
      display_name:           "HubSpot",
      host_match:             "app.hubspot.com",
      authorization_endpoint: "https://app.hubspot.com/oauth/authorize",
      token_endpoint:         "https://api.hubapi.com/oauth/v1/token",
      scopes: [
        "crm.objects.contacts.read",
        "crm.objects.contacts.write",
        "crm.objects.companies.read",
        "crm.objects.companies.write",
        "crm.objects.deals.read",
        "crm.objects.deals.write"
      ],
      # HubSpot doesn't ship an OIDC userinfo endpoint; the
      # `/oauth/v1/access-tokens/{token}` introspection returns
      # `user` + `hub_id`. We don't fetch it at finalize time —
      # the user's `account` label stays blank and the model
      # treats the connection as default-account. Multi-portal
      # support can fan out later.
      userinfo_endpoint:      nil,
      userinfo_field_path:    nil,
      extra_auth_params:      %{}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "hubspot",
      name:        "HubSpot",
      description: "HubSpot CRM — contacts, deals, and activity logging.",
      auth_kind:   :oauth,
      categories:  ["crm", "sales"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (German fake company
  names + deal IDs) so chain results are mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_hubspot",
      port_env:     "DMH_AI_HUBSPOT_MOCK_PORT",
      default_port: 8089,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.HubSpot.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the HubSpot MCP as an in-process REST translator
  on the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/hubspot"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount HubSpot on the
  shared in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.HubSpot.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Five
  domain groups go live — contacts / companies / deals / tasks /
  activities — so a CSM-only org can expose contacts + activities
  + companies + tasks and skip deals, while a sales-team org
  enables all five. The three enforcement layers (OAuth scope
  filter, tool catalog filter, dispatcher gate) all read from
  `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "contacts",
        display_name: "Contacts",
        description:  "Search, create, and update CRM contacts.",
        scopes:       ["crm.objects.contacts.read", "crm.objects.contacts.write"],
        functions:    ["contact.find", "contact.create", "contact.update"],
        vendor_prereq: %{
          label:      "HubSpot Public App scopes (Contacts)",
          enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"
        }
      },
      %{
        id:           "companies",
        display_name: "Companies",
        description:  "Search, create, and update Companies (B2B org records).",
        scopes:       ["crm.objects.companies.read", "crm.objects.companies.write"],
        functions:    ["company.find", "company.create", "company.update"],
        vendor_prereq: %{
          label:      "HubSpot Public App scopes (Companies)",
          enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"
        }
      },
      %{
        id:           "deals",
        display_name: "Deals",
        description:  "Find existing deals and create / update them.",
        scopes:       ["crm.objects.deals.read", "crm.objects.deals.write"],
        functions:    ["deal.find", "deal.create", "deal.update"],
        vendor_prereq: %{
          label:      "HubSpot Public App scopes (Deals)",
          enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"
        }
      },
      %{
        id:           "tasks",
        display_name: "Tasks",
        description:  "Create Task engagements — actionable follow-ups with status, due date, and priority (distinct from informational notes).",
        scopes:       ["crm.objects.deals.write"],
        functions:    ["task.create"],
        vendor_prereq: %{
          label:      "HubSpot Public App scopes (Engagements)",
          enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"
        }
      },
      %{
        id:           "activities",
        display_name: "Activities",
        description:  "Log notes / activities against deals.",
        scopes:       ["crm.objects.deals.write"],
        functions:    ["activity.log"],
        vendor_prereq: %{
          label:      "HubSpot Public App scopes (Engagements)",
          enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"
        }
      },
      # ── Planned (CRM surface visible to admins, not yet built) ──
      %{
        id:           "tickets",
        display_name: "Tickets",
        description:  "Read + manage Service Hub support tickets.",
        status:       :planned,
        scopes:       ["tickets"],
        functions:    [],
        vendor_prereq: %{label: "HubSpot Public App scopes (Tickets)",
                         enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"}
      },
      %{
        id:           "meetings",
        display_name: "Meetings",
        description:  "Read meeting engagements and link them to deals.",
        status:       :planned,
        scopes:       ["crm.objects.deals.read", "crm.objects.deals.write"],
        functions:    [],
        vendor_prereq: %{label: "HubSpot Public App scopes (Meetings)",
                         enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"}
      },
      %{
        id:           "quotes",
        display_name: "Quotes",
        description:  "Create + send Sales Hub quotes from deals.",
        status:       :planned,
        scopes:       ["crm.objects.quotes.read", "crm.objects.quotes.write"],
        functions:    [],
        vendor_prereq: %{label: "HubSpot Public App scopes (Quotes)",
                         enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"}
      },
      %{
        id:           "marketing_email",
        display_name: "Marketing Email",
        description:  "Send campaign / transactional emails via Marketing Hub.",
        status:       :planned,
        scopes:       ["content"],
        functions:    [],
        vendor_prereq: %{label: "HubSpot Public App scopes (Content / Marketing Email)",
                         enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"}
      },
      %{
        id:           "forms",
        display_name: "Forms",
        description:  "Read HubSpot form submissions.",
        status:       :planned,
        scopes:       ["forms"],
        functions:    [],
        vendor_prereq: %{label: "HubSpot Public App scopes (Forms)",
                         enable_url: "https://developers.hubspot.com/docs/api/working-with-oauth"}
      }
    ]
  end

end
