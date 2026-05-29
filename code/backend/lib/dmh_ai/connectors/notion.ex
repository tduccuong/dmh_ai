# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Notion do
  @moduledoc """
  Notion connector (Universal Region, Case B — vendor MCP).

  Eight functions at the SME-relevant slice of Notion's REST API
  (developers.notion.com) — pages, databases, blocks, comments:

    page.find       [read]   search for pages
    page.get        [read]   read one page by id
    page.create     [write]  create a page under a parent
    page.update     [write]  patch a page's properties
    block.append    [write]  append child blocks to a block/page
    database.find   [read]   search for databases
    database.query  [read]   query rows of a database
    comment.create  [write]  add a comment to a page

  Four capability groups (pages / blocks / databases / comments)
  so admins can scope per-org — a docs-reading org might tick
  pages + databases, while a collaboration org also enables comments.

  ## Fixed host, Bearer auth

  The Notion REST API is a single fixed host
  (`https://api.notion.com/v1`) — there is no per-account /
  per-instance templating. Every call uses standard
  `Authorization: Bearer <token>` auth, which `RestBridge` injects
  from `ctx.bearer_token`.

  ## Vendor quirk: the `Notion-Version` header

  Every Notion request MUST carry the header
  `{"Notion-Version", "2022-06-28"}`. A request without it is
  rejected with a 400. So each `request` builder in the MCP handler
  emits that header alongside its `:json` / `:params` options, and
  `fetch_userinfo/1` sends it too.

  ## Vendor quirk: no OAuth scopes

  Notion OAuth has no granular scope strings. An integration's
  capabilities (read / insert / update content, comment, …) are
  configured when the integration is created in the Notion admin UI,
  not requested via OAuth scope. So every function declares the
  single placeholder scope `["default"]` and the OAuth descriptor
  asks for `["default"]`.

  ## Vendor quirk: error body (`remap_error/1`)

  Notion returns normal HTTP status codes with a JSON error body of
  the shape `%{"object" => "error", "status" => <int>, "code" =>
  <code>, "message" => ...}`. The leading clauses key off the string
  `code` (`conflict_error` → `:duplicate`; `unauthorized` /
  `restricted_resource` → `:unauthorised`; `object_not_found` →
  `:not_found`; `rate_limited` → `:rate_limited`); other codes map to
  `:passthrough` and the HTTP-status tuples drive the canonical class.

  ## Path-param ids

  Functions acting on a specific object (`page.get` / `page.update` /
  `block.append` / `database.query`) interpolate the id into the URL
  path. Notion ids are UUIDs *with dashes*, so the id is whitelisted
  to `^[A-Za-z0-9-]+$` in the MCP handler before the URL is built
  (`safe_path_id/1`) — no raw interpolation of unvalidated input.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  # Every Notion request carries this header or it 400s. Kept in sync
  # with the same constant in `Notion.MCPHandler`.
  @notion_version "2022-06-28"

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Notion's `/users/me` returns the bot's id and, for a bot tied to
    # a workspace member, the person's email — deeply nested under
    # `bot.owner.user.person.email`. Bot integration tokens often have
    # no person email at all, so the email is best-effort: return it
    # when present, otherwise just the id. The access token goes in
    # standard Bearer auth + the mandatory `Notion-Version` header.
    url = "https://api.notion.com/v1/users/me"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"id" => id} = body}} ->
        case extract_person_email(body) do
          email when is_binary(email) and email != "" ->
            {:ok, %{email: email, id: to_string(id)}}

          _ ->
            {:ok, %{id: to_string(id)}}
        end

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # Best-effort nested extraction of the connecting person's email from
  # a `/users/me` bot body (`bot.owner.user.person.email`). Returns nil
  # for a bot token with no associated person.
  defp extract_person_email(%{"bot" => %{"owner" => %{"user" => %{"person" => %{"email" => email}}}}}),
    do: email

  defp extract_person_email(_), do: nil

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__notion_userinfo_stub__) do
      nil ->
        Req.get(url,
          headers: [
            {"authorization", "Bearer " <> access_token},
            {"Notion-Version", @notion_version}
          ],
          finch: DmhAi.Finch,
          receive_timeout: 5_000,
          retry: false
        )

      stub ->
        stub.(url, access_token)
    end
  end

  @impl true
  def mcp_slug, do: "notion"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.notion.com/reference/intro", title: "Notion API reference"},
       %{url: "https://developers.notion.com/reference/post-search", title: "Notion — Search"},
       %{url: "https://developers.notion.com/reference/page", title: "Notion — Pages"},
       %{url: "https://developers.notion.com/reference/database", title: "Notion — Databases"},
       %{url: "https://developers.notion.com/reference/block", title: "Notion — Blocks"}
     ]}
  end

  # Per-user metadata sweep. Notion has no per-user custom-property
  # schema analogous to HubSpot's `/crm/v3/properties/<object>` — its
  # objects are fixed-shape. So there is nothing to sweep: always
  # return an empty row set (no metadata to cache) — same contract as
  # the other Case-B connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. Notion objects are fixed-shape with no custom
  # property schema to introspect, so there is no metadata cache to
  # consult. Always return `:not_supported`, which the compiler treats
  # as "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "notion",
      region:    "universal",
      functions: %{
        # vendor: POST /search (filter object=page)
        # docs:   https://developers.notion.com/reference/post-search
        #
        # Notion has no OAuth scopes — an integration's capabilities are
        # set when it's created, not requested per scope. So every
        # function declares the placeholder ["default"].
        "page.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{pages: :list},
          scopes:  ["default"]
        },

        # vendor: GET /pages/{page_id}
        "page.get" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "page_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "notion.page.find"}}
          },
          returns: %{page: :map},
          scopes:  ["default"]
        },

        # vendor: POST /pages
        "page.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "parent_id"   => %{type: :string, required: true,
                               provenance: %{kind: :from_user}},
            "title"       => %{type: :string, required: true,
                               provenance: %{kind: :from_user}},
            "parent_type" => %{type: :string, required: false}
          },
          returns: %{page_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: PATCH /pages/{page_id}
        # `patch` is a free-form map of Notion page properties → values;
        # the shim does not enumerate or validate property names so any
        # property passes through (sent as the `properties` map).
        "page.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "page_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "notion.page.find"}},
            "patch"   => %{type: :map,    required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{page_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: PATCH /blocks/{block_id}/children
        "block.append" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "block_id" => %{type: :string, required: true,
                            provenance: %{kind: :lookup,
                                          source: "notion.page.find"}},
            "children" => %{type: :list,   required: true,
                            provenance: %{kind: :literal_default}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: POST /search (filter object=database)
        "database.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{databases: :list},
          scopes:  ["default"]
        },

        # vendor: POST /databases/{database_id}/query
        "database.query" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "database_id" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "notion.database.find"}},
            "limit"       => %{type: :integer, required: false}
          },
          returns: %{results: :list},
          scopes:  ["default"]
        },

        # vendor: POST /comments
        "comment.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "page_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "notion.page.find"}},
            "text"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{comment_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        }
      }
    }
  end

  @impl true
  # Notion exposes `/users` keyed by id, but it has no email-pivot
  # endpoint (a bot may not even know a member's email), so a dedicated
  # identity-pivot function is not in this manifest.
  def identity_lookup, do: nil

  @impl true
  # Notion returns normal HTTP status codes with a JSON error body of
  # the shape `%{"object" => "error", "status" => <int>, "code" =>
  # <code>, "message" => ...}`. The leading clauses key off the string
  # `code`; other codes map to `:passthrough` and the HTTP-status
  # tuples below drive the canonical class.
  def remap_error(%{"code" => "conflict_error"}),      do: :duplicate
  def remap_error(%{"code" => "unauthorized"}),        do: :unauthorised
  def remap_error(%{"code" => "restricted_resource"}), do: :unauthorised
  def remap_error(%{"code" => "object_not_found"}),    do: :not_found
  def remap_error(%{"code" => "rate_limited"}),        do: :rate_limited
  def remap_error(%{"code" => _}),                     do: :passthrough

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 409, _}), do: :duplicate
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Notion OAuth lives at
  `api.notion.com/v1/oauth/authorize` (consent) +
  `api.notion.com/v1/oauth/token` (exchange). Notion's token exchange
  uses HTTP Basic auth (client_id:secret in the Authorization header) —
  the generic OAuth path must support Basic for live OAuth. Notion has
  no granular scopes, so this requests the placeholder `["default"]`;
  `extra_auth_params` pins `owner=user` so the consent grants a
  user-owned token (not an internal-integration token).
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "notion",
      display_name:           "Notion",
      host_match:             "notion.so",
      authorization_endpoint: "https://api.notion.com/v1/oauth/authorize",
      token_endpoint:         "https://api.notion.com/v1/oauth/token",
      # Notion has no OAuth scopes — capabilities are set on the
      # integration, not requested per scope. Placeholder only.
      scopes:                 ["default"],
      userinfo_endpoint:      "https://api.notion.com/v1/users/me",
      userinfo_field_path:    "bot.owner.user.person.email",
      extra_auth_params:      %{"owner" => "user"}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "notion",
      name:        "Notion",
      description: "Notion — pages, databases, blocks, comments.",
      auth_kind:   :oauth,
      categories:  ["docs", "knowledge"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (Notion-style page /
  database / comment ids) so chain results are mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_notion",
      port_env:     "DMH_AI_NOTION_MOCK_PORT",
      default_port: 8095,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Notion.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Notion MCP as an in-process REST translator on the
  shared real-MCP port. FE pre-fills this in the External Connectors
  form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/notion"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Notion on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Notion.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Four
  domain groups go live — pages / blocks / databases / comments —
  so a docs-reading org can expose pages + databases and skip the
  rest, while a collaboration org also enables comments. The three
  enforcement layers (OAuth scope filter, tool catalog filter,
  dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "pages",
        display_name: "Pages",
        description:  "Search, read, create, and update pages.",
        scopes:       ["default"],
        functions:    ["page.find", "page.get", "page.create", "page.update"],
        vendor_prereq: %{
          label:      "Notion integration capabilities",
          enable_url: "https://developers.notion.com/docs/authorization"
        }
      },
      %{
        id:           "blocks",
        display_name: "Blocks",
        description:  "Append child blocks to a page or block.",
        scopes:       ["default"],
        functions:    ["block.append"],
        vendor_prereq: %{
          label:      "Notion integration capabilities",
          enable_url: "https://developers.notion.com/docs/authorization"
        }
      },
      %{
        id:           "databases",
        display_name: "Databases",
        description:  "Search and query databases.",
        scopes:       ["default"],
        functions:    ["database.find", "database.query"],
        vendor_prereq: %{
          label:      "Notion integration capabilities",
          enable_url: "https://developers.notion.com/docs/authorization"
        }
      },
      %{
        id:           "comments",
        display_name: "Comments",
        description:  "Add comments to pages.",
        scopes:       ["default"],
        functions:    ["comment.create"],
        vendor_prereq: %{
          label:      "Notion integration capabilities",
          enable_url: "https://developers.notion.com/docs/authorization"
        }
      }
    ]
  end

end
