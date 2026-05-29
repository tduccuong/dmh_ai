# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Salesforce do
  @moduledoc """
  Salesforce connector (Universal Region, Case B — vendor MCP).

  Eleven functions at the SME-relevant slice of Salesforce's REST API
  (developer.salesforce.com/docs/atlas.en-us.api_rest.meta) — leads,
  contacts, accounts, opportunities, cases, tasks:

    lead.find          [read]   SOQL search over Lead
    lead.create        [write]  create a Lead
    contact.find       [read]   SOQL search over Contact
    contact.create     [write]  create a Contact (optionally on an Account)
    account.find       [read]   SOQL search over Account
    account.create     [write]  create an Account
    opportunity.find   [read]   SOQL search over Opportunity
    opportunity.create [write]  open an Opportunity
    opportunity.update [write]  PATCH an existing Opportunity
    case.create        [write]  open a support Case
    task.create        [write]  create a Task activity

  Six capability groups (leads / contacts / accounts / opportunities
  / service / tasks) so admins can scope per-org — a service-desk org
  might tick contacts + service, while a sales org enables leads +
  accounts + opportunities.

  ## Coarse OAuth scopes

  Every function declares `scopes: ["api"]`. Salesforce OAuth scopes
  are coarse: the single `api` scope grants REST CRUD across every
  sObject. Object-level read/write is governed by the connecting
  user's Salesforce profile + permission sets, NOT by an OAuth scope.
  So there is no per-object scope to filter on — the capability groups
  exist for admin curation, not OAuth scope narrowing.

  ## Vendor quirks (`remap_error/1`)

  Salesforce returns its REST error body as a JSON array of
  `{"message", "errorCode"}` objects. The duplicate signal is
  `errorCode` `DUPLICATE_VALUE` / `DUPLICATES_DETECTED`; the
  rate-limit signal is `REQUEST_LIMIT_EXCEEDED`. Map them to the
  canonical `:duplicate` / `:rate_limited` so recipes / tasks branch
  deterministically rather than parsing the upstream string.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  # Salesforce's REST API is versioned + per-instance: every data call
  # lives at `https://{instance}.salesforce.com/services/data/v60.0/
  # ...`, where `{instance}` is a placeholder, not a real host — OAuth
  # returns the org's `instance_url`, which the framework must template
  # into the base before any live call. That API base lives in the MCP
  # handler (which owns the data calls); identity capture below uses
  # the fixed `login.salesforce.com` OIDC host instead, so the
  # per-instance base is not referenced in this module.

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Salesforce ships an OIDC userinfo endpoint at the login host.
    # The access token goes in standard Bearer auth. Response:
    #   `{"email": ..., "user_id": ..., ...}`.
    url = "https://login.salesforce.com/services/oauth2/userinfo"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"email" => email, "user_id" => uid}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(uid)}}

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
    case Application.get_env(:dmh_ai, :__salesforce_userinfo_stub__) do
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
  def mcp_slug, do: "salesforce"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/intro_what_is_rest_api.htm", title: "Salesforce REST API Developer Guide"},
       %{url: "https://developer.salesforce.com/docs/atlas.en-us.soql_sosl.meta/soql_sosl/sforce_api_calls_soql.htm", title: "Salesforce SOQL reference"},
       %{url: "https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_list.htm", title: "Salesforce sObject reference"}
     ]}
  end

  # Per-user metadata sweep. Salesforce DOES expose a describe
  # endpoint (`/sobjects/<type>/describe`) that returns the full
  # field schema, but wiring it is future work. For now: when the
  # user has a credential we return an empty row set (no metadata
  # cached), and when they don't we surface the missing-credential
  # error so the runner's indicator turns red — same contract as the
  # other connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    case DmhAi.Auth.Credentials.lookup_all(user_id, "oauth:salesforce") do
      [%{payload: %{"access_token" => token}} | _] when is_binary(token) ->
        {:ok, []}

      _ ->
        {:error, :no_salesforce_credential}
    end
  end

  # Layer B reader. Salesforce's describe endpoint is not yet wired
  # into a metadata cache, so there is nothing to consult. Always
  # return `:not_supported`, which the compiler treats as "trust the
  # literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "salesforce",
      region:    "universal",
      functions: %{
        # vendor: GET /query?q=<SOQL over Lead>
        # docs:   https://developer.salesforce.com/docs/atlas.en-us.soql_sosl.meta
        "lead.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # Workflow authors legitimately bake search strings
            # ("leads in Berlin") OR bind them to trigger inputs
            # (`{{T.query}}`). Either form is fine — the validator
            # accepts both under `:literal_default`.
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{leads: :list},
          # Coarse OAuth: one `api` scope covers all REST CRUD;
          # object access is the user's SF profile, not a scope.
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Lead
        "lead.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "last_name"  => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "company"    => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "email"      => %{type: :string, required: false, format: :email},
            "first_name" => %{type: :string, required: false}
          },
          returns: %{lead_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: GET /query?q=<SOQL over Contact>
        "contact.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{contacts: :list},
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Contact
        "contact.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "last_name"  => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "email"      => %{type: :string, required: false, format: :email},
            "first_name" => %{type: :string, required: false},
            "account_id" => %{type: :string, required: false,
                              provenance: %{kind: :lookup,
                                            source: "salesforce.account.find"}}
          },
          returns: %{contact_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: GET /query?q=<SOQL over Account>
        "account.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{accounts: :list},
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Account
        "account.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"     => %{type: :string, required: true,
                            provenance: %{kind: :from_user}},
            "website"  => %{type: :string, required: false},
            "industry" => %{type: :string, required: false}
          },
          returns: %{account_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: GET /query?q=<SOQL over Opportunity>
        "opportunity.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "stage" => %{type: :string,  required: false},
            "owner" => %{type: :string,  required: false},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{opportunities: :list},
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Opportunity
        # shim translation: `account_id` → AccountId; `stage` →
        # StageName; `close_date` → CloseDate.
        "opportunity.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"       => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "stage"      => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "close_date" => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "amount"     => %{type: :number, required: false},
            "account_id" => %{type: :string, required: false,
                              provenance: %{kind: :lookup,
                                            source: "salesforce.account.find"}}
          },
          returns: %{opportunity_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: PATCH /sobjects/Opportunity/{id}
        # The agent uses this for post-call "move it to Closed Won" /
        # "set the amount to 50000" follow-ups. `patch` is a free-form
        # map of Salesforce Opportunity fields → values; the shim does
        # not enumerate or validate field names so any field passes
        # through.
        "opportunity.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "opportunity_id" => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "salesforce.opportunity.find"}},
            "patch"          => %{type: :map,    required: true,
                                  provenance: %{kind: :literal_default}}
          },
          returns: %{opportunity_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Case
        "case.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subject"     => %{type: :string, required: true,
                               provenance: %{kind: :from_user}},
            "description" => %{type: :string, required: false},
            "priority"    => %{type: :string, required: false},
            "contact_id"  => %{type: :string, required: false,
                               provenance: %{kind: :lookup,
                                             source: "salesforce.contact.find"}}
          },
          returns: %{case_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["api"]
        },

        # vendor: POST /sobjects/Task
        "task.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "subject"    => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "due_date"   => %{type: :string, required: false},
            "priority"   => %{type: :string, required: false},
            "contact_id" => %{type: :string, required: false}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["api"]
        }
      }
    }
  end

  @impl true
  # Salesforce exposes SOQL over Contact/User keyed by email, but a
  # dedicated identity-pivot function is not yet in this manifest.
  # Fix: add `contact.find_by_email` and switch this to:
  #   %{function: "salesforce.contact.find_by_email",
  #     by_arg: :email, emit_field: "id"}
  def identity_lookup, do: nil

  @impl true
  # Salesforce REST error body is a JSON array of
  # `{"message", "errorCode"}` objects. Decoded, that is a list (or a
  # bare map for some single-error shapes); the leading clause matches
  # either and keys off `errorCode`.
  def remap_error(decoded) when is_list(decoded) or is_map(decoded) do
    codes = error_codes(decoded)

    cond do
      Enum.any?(codes, &(&1 in ["DUPLICATE_VALUE", "DUPLICATES_DETECTED"])) -> :duplicate
      Enum.any?(codes, &(&1 == "REQUEST_LIMIT_EXCEEDED"))                   -> :rate_limited
      true                                                                  -> :passthrough
    end
  end

  def remap_error({:http, 400, body}) when is_binary(body) do
    if body =~ "DUPLICATE_VALUE" or body =~ "DUPLICATES_DETECTED",
      do: :duplicate,
      else: :passthrough
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited

  def remap_error({:http, _, body}) when is_binary(body) do
    if body =~ "REQUEST_LIMIT_EXCEEDED", do: :rate_limited, else: :passthrough
  end

  def remap_error(_), do: :passthrough

  # Pull every `errorCode` out of a decoded Salesforce error body —
  # whether it arrived as the documented array of error objects or as
  # a bare single-error map.
  defp error_codes(decoded) when is_list(decoded) do
    decoded
    |> Enum.flat_map(&error_codes/1)
  end

  defp error_codes(%{"errorCode" => code}) when is_binary(code), do: [code]
  defp error_codes(_), do: []

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Salesforce OAuth
  lives at `login.salesforce.com/services/oauth2/authorize` (consent)
  + `login.salesforce.com/services/oauth2/token` (exchange).

  IMPORTANT: the login host is only used for the OAuth handshake. The
  live REST API host is per-instance — the token exchange returns the
  org's `instance_url`, which the framework must template into the
  API base (`{instance}` placeholder) before any data call. The mock
  test does not drive the OAuth flow, so this descriptor is correct
  as a vendor-fact record while the per-instance substitution is
  wired.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "salesforce",
      display_name:           "Salesforce",
      host_match:             "salesforce.com",
      authorization_endpoint: "https://login.salesforce.com/services/oauth2/authorize",
      token_endpoint:         "https://login.salesforce.com/services/oauth2/token",
      scopes: [
        "api",
        "refresh_token",
        "openid",
        "email"
      ],
      userinfo_endpoint:      "https://login.salesforce.com/services/oauth2/userinfo",
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
      slug:        "salesforce",
      name:        "Salesforce",
      description: "Salesforce CRM — leads, contacts, accounts, opportunities, cases, tasks.",
      auth_kind:   :oauth,
      categories:  ["crm", "sales"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (German fake company +
  Salesforce-style object IDs) so chain results are mechanically
  provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_salesforce",
      port_env:     "DMH_AI_SALESFORCE_MOCK_PORT",
      default_port: 8091,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Salesforce.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Salesforce MCP as an in-process REST translator
  on the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/salesforce"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Salesforce on the
  shared in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Salesforce.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Six
  domain groups go live — leads / contacts / accounts / opportunities
  / service / tasks — so a service-desk org can expose contacts +
  service and skip the sales pipeline, while a sales org enables
  leads + accounts + opportunities. The three enforcement layers
  (OAuth scope filter, tool catalog filter, dispatcher gate) all read
  from `enabled_capabilities`.

  Every group's `scopes` is `["api"]` — Salesforce OAuth has no
  per-object scope; the groups exist for admin curation, not OAuth
  narrowing.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "leads",
        display_name: "Leads",
        description:  "Search and create Leads.",
        scopes:       ["api"],
        functions:    ["lead.find", "lead.create"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      },
      %{
        id:           "contacts",
        display_name: "Contacts",
        description:  "Search and create Contacts.",
        scopes:       ["api"],
        functions:    ["contact.find", "contact.create"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      },
      %{
        id:           "accounts",
        display_name: "Accounts",
        description:  "Search and create Accounts (B2B org records).",
        scopes:       ["api"],
        functions:    ["account.find", "account.create"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      },
      %{
        id:           "opportunities",
        display_name: "Opportunities",
        description:  "Find opportunities and create / update them.",
        scopes:       ["api"],
        functions:    ["opportunity.find", "opportunity.create", "opportunity.update"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      },
      %{
        id:           "service",
        display_name: "Service",
        description:  "Open support Cases.",
        scopes:       ["api"],
        functions:    ["case.create"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      },
      %{
        id:           "tasks",
        display_name: "Tasks",
        description:  "Create Task activities.",
        scopes:       ["api"],
        functions:    ["task.create"],
        vendor_prereq: %{
          label:      "Salesforce Connected App (API access)",
          enable_url: "https://help.salesforce.com/s/articleView?id=sf.connected_app_overview.htm"
        }
      }
    ]
  end

end
