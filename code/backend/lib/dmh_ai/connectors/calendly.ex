# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Calendly do
  @moduledoc """
  Calendly connector (Universal Region, Case A — DMH-AI hosts the
  MCP server in-process; Calendly has no first-party MCP, so we
  speak to Calendly's REST API v2 via the shared
  `Connectors.MCPServer` + `RestBridge` translator).

  Sixteen functions at the SME-relevant slice of Calendly's API
  (developers.calendly.com) — five available capability groups
  spanning identity, scheduling, organization admin, and webhooks:

    user.me                      [read]   identity of the connected account
    user.busy_times              [read]   user's busy intervals in a window
    event_type.list              [read]   list user's scheduling links
    event_type.get               [read]   read one event type by uuid
    event_type.available_slots   [read]   open booking slots for an event type
    event.list                   [read]   list scheduled meetings (date window)
    event.get                    [read]   read one scheduled event by uuid
    event.invitees               [read]   list invitees on a scheduled event
    invitee.get                  [read]   read one invitee (custom Q answers + tracking)
    organization.members         [read]   list org members (optionally by email)
    webhook.list                 [read]   list webhook subscriptions in scope
    single_use_link.create       [write]  one-time link to send a contact
    event.cancel                 [write]  cancel a scheduled meeting
    event.mark_no_show           [write]  mark an invitee as no-show
    organization.invite          [write]  invite a new member by email
    webhook.create               [write]  subscribe to vendor push events

  ## URI vs UUID in the wire shape

  Calendly's API is URI-centric for QUERY params (e.g.
  `?user=https://api.calendly.com/users/{uuid}`) and UUID-only for
  PATH params (e.g. `GET /scheduled_events/{uuid}`). Arguments
  follow the same duality: `*_uri` args carry the full URL from a
  previous read, `*_uuid` args carry only the trailing identifier.
  When the agent has a URI from `user.me.current_organization` and
  needs a UUID for a path param, it strips the prefix client-side
  and passes the bare UUID; the handler then routes it through
  `safe_path_id/1` before interpolation.

  Five capability groups go live (event_types, events, users,
  organization, webhooks). Six more (workspaces, groups,
  routing_forms, activity_log, shares, data_compliance) are exposed
  in the External Connectors ticker as `:planned` so admins see the
  full Calendly surface and know what's coming.

  ## Vendor quirks (`remap_error/1`)

  Calendly returns RFC-7807-style JSON error envelopes with a
  `title` field. Their 404s on cancelled/deleted events surface
  as `Resource Not Found`; their rate-limit response is a plain
  HTTP 429 with no special body. The HTTP-status → canonical
  mapping is enough — no body sniffing needed for the slice we
  ship.

  ## Scope model

  Calendly's OAuth server returns a granular vendor scope vocabulary
  in the token-response `scope` claim — NOT the literal `"default"`
  keyword that some docs / install URLs use as shorthand. Manifest
  scopes therefore use the canonical vendor names (`users:read`,
  `event_types:read`, `scheduling_links:write`,
  `scheduled_events:read`, `scheduled_events:write`,
  `availability:read`, `organizations:read`, `organizations:write`,
  `webhooks:read`, `webhooks:write`), so the dispatcher's
  scope-subset check sees exactly what the user's
  `user_credentials.payload.scope` contains. Organization +
  webhook endpoints additionally require an org-admin token at
  the vendor level; member tokens get 401 on those endpoints and
  the connector remaps to `:unauthorised`. The OAuth install URL
  scopes (in `oauth_catalog_descriptor/0`) are unchanged — Calendly
  bundles the org + webhook surface under the user-level
  authorization granted at install time.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(token),
    do: DmhAi.OAuth.Identity.OIDC.fetch(token,
          "https://api.calendly.com/users/me", "resource.email")

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.calendly.com/api-docs",                          title: "Calendly API overview"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-event-types",      title: "Calendly - event types"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-scheduled-events", title: "Calendly - scheduled events"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-scheduling-links", title: "Calendly - scheduling links"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-organizations",    title: "Calendly - organizations"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-webhook-subscriptions", title: "Calendly - webhook subscriptions"},
       %{url: "https://developers.calendly.com/api-docs/Z3JvdXA-availability",     title: "Calendly - availability + busy times"}
     ]}
  end

  @impl true
  def mcp_slug, do: "calendly"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl true
  def manifest do
    %Manifest{
      connector: "calendly",
      region:    "universal",
      functions: %{
        # vendor: GET /users/me
        # docs:   https://developers.calendly.com/api-docs/ff48c8ba8d5f1-get-current-user
        "user.me" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{},
          returns: %{user: :map},
          scopes:  ["users:read"]
        },

        # vendor: GET /event_types?user={uri}
        # docs:   https://developers.calendly.com/api-docs/eb45fa1c5e0a3-list-event-types
        "event_type.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "active_only" => %{type: :boolean, required: false},
            "limit"       => %{type: :integer, required: false}
          },
          returns: %{event_types: :list},
          scopes:  ["event_types:read"]
        },

        # vendor: GET /event_type_available_times?event_type={uri}&start_time=...&end_time=...
        # docs:   https://developers.calendly.com/api-docs/35ee3e3d9c0a3-list-event-type-available-times
        "event_type.available_slots" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "event_type_uri" => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "calendly.event_type.list"}},
            "start_time"     => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default}},
            "end_time"       => %{type: :string, required: true,
                                  provenance: %{kind: :literal_default}}
          },
          returns: %{slots: :list},
          scopes:  ["availability:read"]
        },

        # vendor: GET /scheduled_events?user={uri}&min_start_time=...&max_start_time=...
        # docs:   https://developers.calendly.com/api-docs/64fa4d63cb567-list-events
        "event.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "min_start_time" => %{type: :string,  required: false},
            "max_start_time" => %{type: :string,  required: false},
            "status"         => %{type: :string,  required: false},
            "limit"          => %{type: :integer, required: false}
          },
          returns: %{events: :list},
          scopes:  ["scheduled_events:read"]
        },

        # vendor: GET /scheduled_events/{uuid}/invitees
        # docs:   https://developers.calendly.com/api-docs/9ed5e87fae5e0-list-event-invitees
        "event.invitees" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "event_uri" => %{type: :string,  required: true,
                             provenance: %{kind: :lookup,
                                           source: "calendly.event.list"}},
            "limit"     => %{type: :integer, required: false}
          },
          returns: %{invitees: :list},
          scopes:  ["scheduled_events:read"]
        },

        # vendor: POST /scheduling_links
        # docs:   https://developers.calendly.com/api-docs/c1ddc06ce1f1b-create-single-use-scheduling-link
        # Returns a `booking_url` valid for `max_event_count` bookings
        # (default 1). The booking flow happens on Calendly's hosted
        # page; we never see the invitee data until they book.
        "single_use_link.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "event_type_uri"  => %{type: :string,  required: true,
                                   provenance: %{kind: :lookup,
                                                 source: "calendly.event_type.list"}},
            "max_event_count" => %{type: :integer, required: false}
          },
          returns: %{booking_url: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["scheduling_links:write"]
        },

        # vendor: POST /scheduled_events/{uuid}/cancellation
        # docs:   https://developers.calendly.com/api-docs/dc8af6a3742bd-cancel-event
        # The cancellation `reason` is emailed to invitees verbatim
        # by Calendly; keep it user-facing-clean.
        "event.cancel" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "event_uri" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "calendly.event.list"}},
            "reason"    => %{type: :string, required: false}
          },
          returns: %{cancelled: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["scheduled_events:write"]
        },

        # vendor: POST /invitee_no_shows
        # docs:   https://developers.calendly.com/api-docs/04b624270b559-create-invitee-no-show
        "event.mark_no_show" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "invitee_uri" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "calendly.event.invitees"}}
          },
          returns: %{marked: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["scheduled_events:write"]
        },

        # vendor: GET /scheduled_events/{event_uuid}
        # docs:   https://developers.calendly.com/api-docs/c1ec9b8a0ff14-get-event
        # `event_uuid` is the trailing segment of an event URI; the
        # handler whitelists it via `safe_path_id/1` before
        # interpolating into the path.
        "event.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "event_uuid" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "calendly.event.list"}}
          },
          returns: %{event: :map},
          scopes:  ["scheduled_events:read"]
        },

        # vendor: GET /event_types/{event_type_uuid}
        # docs:   https://developers.calendly.com/api-docs/8c2bd02a76247-get-event-type
        "event_type.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "event_type_uuid" => %{type: :string, required: true,
                                   provenance: %{kind: :lookup,
                                                 source: "calendly.event_type.list"}}
          },
          returns: %{event_type: :map},
          scopes:  ["event_types:read"]
        },

        # vendor: GET /scheduled_events/{event_uuid}/invitees/{invitee_uuid}
        # docs:   https://developers.calendly.com/api-docs/580d278d0c873-get-event-invitee
        # Carries custom question/answer payload + UTM/tracking data
        # not present in the bulk `event.invitees` list.
        "invitee.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "event_uuid"   => %{type: :string, required: true,
                                provenance: %{kind: :lookup,
                                              source: "calendly.event.list"}},
            "invitee_uuid" => %{type: :string, required: true,
                                provenance: %{kind: :lookup,
                                              source: "calendly.event.invitees"}}
          },
          returns: %{invitee: :map},
          scopes:  ["scheduled_events:read"]
        },

        # vendor: GET /user_busy_times?user={user_uri}&start_time=...&end_time=...
        # docs:   https://developers.calendly.com/api-docs/6e51c40d28b97-list-user-busy-times
        # `user_uri` is the FULL URI from `user.me.uri`; Req
        # URL-encodes it via the `:params` mechanism.
        "user.busy_times" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "user_uri"   => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "calendly.user.me"}},
            "start_time" => %{type: :string, required: true, format: :datetime,
                              provenance: %{kind: :literal_default}},
            "end_time"   => %{type: :string, required: true, format: :datetime,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{busy_times: :list},
          scopes:  ["availability:read"]
        },

        # vendor: GET /organization_memberships?organization={uri}&email=&count=
        # docs:   https://developers.calendly.com/api-docs/2ec96a4a32d6a-list-organization-memberships
        # `organization_uri` is the FULL URI of the connected user's
        # current organization (`user.me.current_organization`). The
        # optional `email` filter narrows to one member; otherwise the
        # full membership list is returned (capped by `count`).
        "organization.members" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "organization_uri" => %{type: :string,  required: true,
                                    provenance: %{kind: :lookup,
                                                  source: "calendly.user.me"}},
            "email"            => %{type: :string,  required: false, format: :email},
            "count"            => %{type: :integer, required: false}
          },
          returns: %{members: :list},
          scopes:  ["organizations:read"]
        },

        # vendor: POST /organizations/{organization_uuid}/invitations
        # docs:   https://developers.calendly.com/api-docs/1d5f60bda73b5-invite-user-to-organization
        # `organization_uuid` is the trailing segment of
        # `user.me.current_organization` — the agent strips the URI
        # prefix and supplies the bare UUID for the path param.
        "organization.invite" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "organization_uuid" => %{type: :string, required: true,
                                     provenance: %{kind: :lookup,
                                                   source: "calendly.user.me"}},
            "email"             => %{type: :string, required: true, format: :email,
                                     provenance: %{kind: :from_user}}
          },
          returns: %{invitation_uri: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate, :validation],
          scopes:  ["organizations:write"]
        },

        # vendor: POST /webhook_subscriptions
        # docs:   https://developers.calendly.com/api-docs/c1ddc06ce1f1b-create-webhook-subscription
        # `scope` defaults to "organization" (org-wide subscription);
        # `user_uri` is only required when `scope == "user"`. `events`
        # is a list of vendor literals (e.g.
        # ["invitee.created","invitee.canceled"]).
        "webhook.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "url"              => %{type: :string, required: true, format: :url,
                                    provenance: %{kind: :from_user}},
            "events"           => %{type: :list,   required: true,
                                    provenance: %{kind: :literal_default}},
            "organization_uri" => %{type: :string, required: true,
                                    provenance: %{kind: :lookup,
                                                  source: "calendly.user.me"}},
            "user_uri"         => %{type: :string, required: false,
                                    provenance: %{kind: :lookup,
                                                  source: "calendly.user.me"}},
            "scope"            => %{type: :string, required: false,
                                    provenance: %{kind: :literal_default,
                                                  value: "organization"}}
          },
          returns: %{webhook_uri: :string},
          errors:  [:unauthorised, :rate_limited, :duplicate, :validation],
          scopes:  ["webhooks:write"]
        },

        # vendor: GET /webhook_subscriptions?organization={uri}&scope=&count=
        # docs:   https://developers.calendly.com/api-docs/d52ddd8caeb37-list-webhook-subscriptions
        "webhook.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "organization_uri" => %{type: :string,  required: true,
                                    provenance: %{kind: :lookup,
                                                  source: "calendly.user.me"}},
            "scope"            => %{type: :string,  required: false,
                                    provenance: %{kind: :literal_default,
                                                  value: "organization"}},
            "count"            => %{type: :integer, required: false}
          },
          returns: %{webhooks: :list},
          scopes:  ["webhooks:read"]
        }
      }
    }
  end

  @impl true
  # Primitive 0.9 — Calendly creds are single-user OAuth: a user
  # connects their OWN Calendly. There's no API to look up another
  # org member's Calendly identity by email. Workflows that name
  # `@user_N` against Calendly will hit `unmappable_identity` at
  # compile time and the compiler asks the user to either use
  # their own Calendly account or supply a manual override row.
  def identity_lookup, do: nil

  @impl true
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Calendly's OAuth
  endpoints live under `auth.calendly.com`; the API itself answers
  on `api.calendly.com`. The scope list is the union of the
  granular vendor scopes the three live capability groups need —
  what the install URL requests, and what the token response then
  echoes back on `payload.scope` for the dispatcher to compare
  against. Userinfo lives at `/users/me` and returns a `resource`
  envelope with `email` — we extract the email so the user's
  `account` label populates after the OAuth dance.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "calendly",
      display_name:           "Calendly",
      host_match:             "auth.calendly.com",
      authorization_endpoint: "https://auth.calendly.com/oauth/authorize",
      token_endpoint:         "https://auth.calendly.com/oauth/token",
      scopes: [
        "users:read",
        "event_types:read",
        "availability:read",
        "scheduling_links:write",
        "scheduled_events:read",
        "scheduled_events:write"
      ],
      # Identity capture lives in `fetch_userinfo/1` (see top of module).
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
      slug:        "calendly",
      name:        "Calendly",
      description: "Calendly — scheduling links + meeting management.",
      auth_kind:   :oauth,
      categories:  ["scheduling", "productivity"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers in the fixture (German
  fake event-type names + invitee emails) so chain results are
  mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_calendly",
      port_env:     "DMH_AI_CALENDLY_MOCK_PORT",
      default_port: 8090,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Calendly.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Calendly MCP as an in-process REST translator
  on the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/calendly"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Calendly on the
  shared in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Calendly.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Five
  groups go live (event_types, events, users, organization,
  webhooks); six more ship as `:planned` so the ticker reflects
  the full Calendly surface — admin sees what's coming and can
  plan vendor-side scope grants accordingly. The three enforcement
  layers (OAuth scope filter, tool catalog filter, dispatcher
  gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "event_types",
        display_name: "Event types",
        description:  "List a user's event types, read one event type by id, query open booking slots, and create one-time scheduling links to send to contacts.",
        scopes:       ["event_types:read", "availability:read", "scheduling_links:write"],
        functions:    ["event_type.list", "event_type.get", "event_type.available_slots", "single_use_link.create"],
        vendor_prereq: %{
          label:      "Calendly OAuth app — `event_types:read` + `availability:read` + `scheduling_links:write`",
          enable_url: "https://developer.calendly.com/api-docs/eb45fa1c5e0a3-list-event-types"
        }
      },
      %{
        id:           "events",
        display_name: "Events",
        description:  "Read scheduled events, list their invitees, fetch one event or one invitee in detail, cancel events, and record no-shows.",
        scopes:       ["scheduled_events:read", "scheduled_events:write"],
        functions:    ["event.list", "event.get", "event.invitees", "invitee.get", "event.cancel", "event.mark_no_show"],
        vendor_prereq: %{
          label:      "Calendly OAuth app — `scheduled_events:read` + `scheduled_events:write`",
          enable_url: "https://developer.calendly.com/api-docs/64fa4d63cb567-list-events"
        }
      },
      %{
        id:           "users",
        display_name: "Users",
        description:  "Read the connected Calendly account's identity (used to scope per-user queries) and that user's busy intervals in a window.",
        scopes:       ["users:read", "availability:read"],
        functions:    ["user.me", "user.busy_times"],
        vendor_prereq: %{
          label:      "Calendly OAuth app — `users:read` + `availability:read`",
          enable_url: "https://developer.calendly.com/api-docs/ff48c8ba8d5f1-get-current-user"
        }
      },
      %{
        id:           "organization",
        display_name: "Organization",
        description:  "List organization members (optionally filtered by email) and invite new members.",
        scopes:       ["organizations:read", "organizations:write"],
        functions:    ["organization.members", "organization.invite"],
        vendor_prereq: %{
          label:      "Calendly OAuth app — `organizations:read|write` (org-admin token)",
          enable_url: "https://developer.calendly.com/api-docs/2ec96a4a32d6a-list-organization-memberships"
        }
      },
      %{
        id:           "webhooks",
        display_name: "Webhooks",
        description:  "List + create webhook subscriptions at organization or user scope. Vendor pushes are wired in once the agent's webhook ingress lands.",
        scopes:       ["webhooks:read", "webhooks:write"],
        functions:    ["webhook.list", "webhook.create"],
        vendor_prereq: %{
          label:      "Calendly OAuth app — `webhooks:read|write`",
          enable_url: "https://developer.calendly.com/api-docs/c1ddc06ce1f1b-create-webhook-subscription"
        }
      },
      # ── Planned (full vendor surface visible to admins) ──
      %{
        id:           "workspaces",
        display_name: "Workspaces",
        description:  "List workspaces and their members.",
        status:       :planned,
        scopes:       ["organizations:read"],
        functions:    [],
        vendor_prereq: %{label: "Calendly OAuth app — `organizations:read`",
                         enable_url: "https://developer.calendly.com/api-docs/d4f47e0a5b3df-list-workspaces"}
      },
      %{
        id:           "groups",
        display_name: "Groups (Enterprise)",
        description:  "Manage groups and group-level event types. Calendly Enterprise plans only.",
        status:       :planned,
        scopes:       ["groups:read"],
        functions:    [],
        vendor_prereq: %{label: "Calendly Enterprise — `groups:read`",
                         enable_url: "https://developer.calendly.com/api-docs/3c43c5837f2e6-list-groups"}
      },
      %{
        id:           "routing_forms",
        display_name: "Routing forms",
        description:  "Read routing-form definitions and the submissions invitees leave on them.",
        status:       :planned,
        scopes:       ["routing_forms:read"],
        functions:    [],
        vendor_prereq: %{label: "Calendly OAuth app — `routing_forms:read`",
                         enable_url: "https://developer.calendly.com/api-docs/14523c2cc44ce-list-routing-forms"}
      },
      %{
        id:           "activity_log",
        display_name: "Activity log (Enterprise)",
        description:  "Read the organization audit log. Calendly Enterprise plans only.",
        status:       :planned,
        scopes:       ["activity_log:read"],
        functions:    [],
        vendor_prereq: %{label: "Calendly Enterprise — `activity_log:read`",
                         enable_url: "https://developer.calendly.com/api-docs/8e07a4ad62afe-list-activity-log-entries"}
      },
      %{
        id:           "shares",
        display_name: "Shares",
        description:  "Create shareable booking pages for event types (one-to-many, vs single-use which is one-to-one).",
        status:       :planned,
        scopes:       ["shares:write"],
        functions:    [],
        vendor_prereq: %{label: "Calendly OAuth app — `shares:write`",
                         enable_url: "https://developer.calendly.com/api-docs/03cf02bc6f9d4-create-share"}
      },
      %{
        id:           "data_compliance",
        display_name: "Data compliance",
        description:  "GDPR — delete invitee data on request.",
        status:       :planned,
        scopes:       ["data_compliance:write"],
        functions:    [],
        vendor_prereq: %{label: "Calendly OAuth app — `data_compliance:write`",
                         enable_url: "https://developer.calendly.com/api-docs/f1b1b3c1d8b3e-delete-invitee-data"}
      }
    ]
  end
end
