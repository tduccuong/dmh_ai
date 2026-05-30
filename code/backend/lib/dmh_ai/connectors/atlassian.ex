# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Atlassian do
  @moduledoc """
  Atlassian connector (Universal Region, Case B — vendor MCP) covering
  Jira + Confluence under a single slug. Trello is deferred.

  Seventeen functions at the SME-relevant slice of Atlassian's Cloud
  REST APIs (developer.atlassian.com) — Jira issues / projects /
  transitions / comments / attachments / agile boards + sprints, a
  Jira user-lookup pivot, and Confluence pages + spaces:

    issue.find            [read]   build a JQL search from structured args
    issue.create          [write]  create a Jira issue
    issue.update          [write]  PUT fields on an existing issue
    issue.transition      [write]  POST a workflow transition on an issue
    issue.comment         [write]  POST a comment on an issue
    issue.delete          [write]  DELETE an issue by key
    issue.add_attachment  [write]  POST a multipart attachment on an issue
    issue.move_to_sprint  [write]  POST issue keys onto a sprint (Agile API)
    sprint.find           [read]   list sprints on a board (Agile API)
    board.find            [read]   list Jira Agile boards (Agile API)
    project.find          [read]   list Jira projects
    user.find_by_email    [read]   search Jira users by email (identity pivot)
    page.find             [read]   find Confluence pages by space + title
    page.create           [write]  create a Confluence page
    page.update           [write]  PUT-replace a Confluence page
    page.delete           [write]  DELETE a Confluence page
    space.find            [read]   list Confluence spaces

  Capability groups (jira_issues / jira_agile / jira_projects / users
  / confluence_pages / confluence_spaces) so admins can scope per-org —
  a dev-tooling org might tick jira_issues + jira_projects + jira_agile
  only, while a docs-heavy org also enables confluence_pages +
  confluence_spaces. A separate `trello` group is listed as
  `status: :planned` so the FE can show it as deferred.

  ## Per-tenant API host (`cloudId`)

  Atlassian Cloud REST is per-tenant: every Jira call lives at
  `https://api.atlassian.com/ex/jira/{cloudid}/rest/api/3/...`, every
  Jira Agile call at
  `https://api.atlassian.com/ex/jira/{cloudid}/rest/agile/1.0/...`
  (boards + sprints live on a SEPARATE Jira `agile/1.0` prefix, not
  the `api/3` prefix), and every Confluence call at
  `https://api.atlassian.com/ex/confluence/{cloudid}/wiki/rest/api/...`,
  where `{cloudid}` is a placeholder, not a real host. After the OAuth
  token exchange the framework calls
  `https://api.atlassian.com/oauth/token/accessible-resources` to
  resolve the tenant's `cloudId`, then templates it into the bases
  before any live call. Those API bases live in the MCP handler.

  Standard `Authorization: Bearer <token>` auth, which `RestBridge`
  injects from `ctx.bearer_token`.

  ## JQL / CQL safety

  Search functions build JQL server-side from structured args
  (`project_key`, `status`, …). Raw JQL strings from the model are
  never accepted — `jql_quote/1` escapes backslash THEN single quote
  (same shape as Salesforce's `soql_quote/1`) before composing the
  query. The Confluence `page.find` filters by structured params using
  Req's `:params` keyword (the encoder URL-escapes them), not URL
  interpolation.

  ## Path-param ids

  Issue keys (`PROJ-123`) and Confluence page ids (numeric strings)
  are whitelisted to `^[A-Za-z0-9_-]+$` (`safe_path_id/1` in the
  handler) before being interpolated into a URL path — no raw
  injection of unvalidated input.

  ## Vendor quirks (`remap_error/1`)

  Jira returns an error body shaped
  `%{"errorMessages" => [...], "errors" => %{}}` with the HTTP status.
  The `errorMessages` array can carry a soft 400 like `"Issue Does
  Not Exist"` that semantically means `:not_found` even though the
  status is 400. Confluence returns
  `%{"statusCode" => <int>, "message" => ...}` and relies on the HTTP
  status. The leading clauses inspect the message array; the
  HTTP-status tuples then cover the standard 4xx classes.

  ## Trello — deferred

  Trello shares the Atlassian account model but lives on a separate
  REST API (`api.trello.com/1`) with its own OAuth 1.0a-derived flow.
  Out of scope for this slice; the capability entry exists so admins
  can see it as a coming-soon item.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  # Atlassian's REST API is per-tenant: every data call lives at
  # `api.atlassian.com/ex/jira/{cloudid}/...` or
  # `api.atlassian.com/ex/confluence/{cloudid}/...`, where `{cloudid}`
  # is a placeholder, not a real host — the OAuth flow resolves the
  # tenant's `cloudId` via `/oauth/token/accessible-resources`, which
  # the framework must template into the bases before any live call.
  # Those bases live in the MCP handler (which owns the data calls);
  # identity capture below uses the fixed `api.atlassian.com/me`
  # endpoint instead, so the per-tenant base is not referenced in this
  # module.

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Atlassian's `/me` endpoint returns the connecting user's email +
    # account id. Standard Bearer auth. Response:
    #   `{"email": ..., "account_id": ..., ...}`.
    url = "https://api.atlassian.com/me"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"email" => email, "account_id" => id}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(id)}}

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
    case Application.get_env(:dmh_ai, :__atlassian_me_stub__) do
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
  def mcp_slug, do: "atlassian"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/", title: "Jira Cloud — REST API v3"},
       %{url: "https://developer.atlassian.com/cloud/jira/platform/jira-expressions/", title: "Jira — JQL reference"},
       %{url: "https://developer.atlassian.com/cloud/confluence/rest/v1/intro/", title: "Confluence Cloud — REST API"},
       %{url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/", title: "Atlassian — OAuth 2.0 (3LO)"},
       %{url: "https://developer.atlassian.com/cloud/jira/platform/scopes-for-oauth-2-3LO-and-forge-apps/", title: "Atlassian — OAuth scopes"}
     ]}
  end

  # Per-user metadata sweep. Atlassian DOES expose a Jira fields
  # endpoint (`/rest/api/3/field`) that returns the project's field
  # schema, but wiring it is future work. Always return an empty row
  # set (no metadata to cache) — same contract as the other Case-B
  # connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. Atlassian's field/property schemas are not yet
  # wired into a metadata cache, so there is nothing to consult.
  # Always return `:not_supported`, which the compiler treats as
  # "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "atlassian",
      region:    "universal",
      functions: %{
        # vendor: GET /rest/api/3/search?jql=<server-built JQL>
        # docs:   https://developer.atlassian.com/cloud/jira/platform/jira-expressions/
        #
        # JQL is built server-side from structured args; the model
        # never supplies a raw JQL string. `jql_quote/1` escapes the
        # project_key + status values before they hit the query.
        "issue.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "project_key" => %{type: :string,  required: true,
                               provenance: %{kind: :lookup,
                                             source: "atlassian.project.find"}},
            "status"      => %{type: :string,  required: false},
            "limit"       => %{type: :integer, required: false}
          },
          returns: %{issues: :list},
          scopes:  ["read:jira-work"]
        },

        # vendor: POST /rest/api/3/issue
        "issue.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "project_key" => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "atlassian.project.find"}},
            "summary"     => %{type: :string, required: true,
                               provenance: %{kind: :from_user}},
            "issue_type"  => %{type: :string, required: true,
                               provenance: %{kind: :literal_default, value: "Task"}},
            "description" => %{type: :string, required: false}
          },
          returns: %{issue_id: :string, key: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: PUT /rest/api/3/issue/{issue_key}
        # `patch` is a free-form map of Jira issue fields → values;
        # the shim does not enumerate or validate field names so any
        # field passes through.
        "issue.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "issue_key" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "atlassian.issue.find"}},
            "patch"     => %{type: :map,    required: true,
                             provenance: %{kind: :literal_default}}
          },
          returns: %{issue_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: POST /rest/api/3/issue/{issue_key}/transitions
        "issue.transition" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "issue_key"     => %{type: :string, required: true,
                                 provenance: %{kind: :lookup,
                                               source: "atlassian.issue.find"}},
            "transition_id" => %{type: :string, required: true,
                                 provenance: %{kind: :from_user}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: POST /rest/api/3/issue/{issue_key}/comment
        "issue.comment" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "issue_key" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "atlassian.issue.find"}},
            "body"      => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}}
          },
          returns: %{comment_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: DELETE /rest/api/3/issue/{issue_key}
        "issue.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "issue_key" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "atlassian.issue.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: POST /rest/api/3/issue/{issue_key}/attachments
        # Multipart upload with the Atlassian-required header
        # `X-Atlassian-Token: no-check`; the connector composes the
        # multipart body via a custom handler since the form-data shape
        # does not fit the default JSON `request` builder.
        "issue.add_attachment" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "issue_key" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "atlassian.issue.find"}},
            "filename"  => %{type: :string, required: true,
                             provenance: %{kind: :from_user}},
            "content"   => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}}
          },
          returns: %{attachment_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: GET /rest/agile/1.0/board/{board_id}/sprint
        # Jira Agile lives on a SEPARATE `agile/1.0` URL prefix, not
        # `api/3`; sprints are owned by a board so the board id is
        # required. `state` defaults to `active` so chats can ask
        # "the current sprint" without naming the state literal.
        "sprint.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "board_id" => %{type: :string,  required: true,
                            provenance: %{kind: :lookup,
                                          source: "atlassian.board.find"}},
            "state"    => %{type: :string,  required: false,
                            provenance: %{kind: :literal_default, value: "active"}},
            "limit"    => %{type: :integer, required: false}
          },
          returns: %{sprints: :list},
          scopes:  ["read:jira-work"]
        },

        # vendor: POST /rest/agile/1.0/sprint/{sprint_id}/issue
        # Body shape `{issues: [issue_keys]}` — the vendor moves the
        # listed issues onto the sprint. Idempotent at the Atlassian
        # side; the connector still requires an idempotency key so
        # retries don't double-fire downstream effects.
        "issue.move_to_sprint" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "sprint_id"  => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "atlassian.sprint.find"}},
            "issue_keys" => %{type: :list,   required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:jira-work"]
        },

        # vendor: GET /rest/agile/1.0/board
        "board.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{boards: :list},
          scopes:  ["read:jira-work"]
        },

        # vendor: GET /rest/api/3/project
        "project.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{projects: :list},
          scopes:  ["read:jira-work"]
        },

        # vendor: GET /rest/api/3/user/search?query={email}
        # Atlassian's user-search endpoint filters by email OR display
        # name via the same `query` param. The connector takes the
        # first match and exposes its `accountId` as the identity
        # pivot — used by the framework's lookup-by-email shortcut so
        # downstream functions referencing `{{owner}}` resolve.
        "user.find_by_email" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["read:jira-user"]
        },

        # vendor: GET /wiki/rest/api/content?spaceKey=…&title=…&type=page
        "page.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "space_key" => %{type: :string,  required: true,
                             provenance: %{kind: :from_user}},
            "title"     => %{type: :string,  required: false},
            "limit"     => %{type: :integer, required: false}
          },
          returns: %{pages: :list},
          scopes:  ["read:confluence-content.summary"]
        },

        # vendor: POST /wiki/rest/api/content
        "page.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "space_key"    => %{type: :string, required: true,
                                provenance: %{kind: :from_user}},
            "title"        => %{type: :string, required: true,
                                provenance: %{kind: :from_user}},
            "body_storage" => %{type: :string, required: true,
                                provenance: %{kind: :literal_default}}
          },
          returns: %{page_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["write:confluence-content"]
        },

        # vendor: PUT /wiki/rest/api/content/{page_id}
        # Confluence requires a monotonically-increasing `version.number`
        # on every page update; the caller supplies the next integer.
        "page.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "page_id"        => %{type: :string,  required: true,
                                  provenance: %{kind: :lookup,
                                                source: "atlassian.page.find"}},
            "title"          => %{type: :string,  required: false},
            "body_storage"   => %{type: :string,  required: false},
            "version_number" => %{type: :integer, required: true,
                                  provenance: %{kind: :literal_default}}
          },
          returns: %{page_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:confluence-content"]
        },

        # vendor: DELETE /wiki/rest/api/content/{page_id}
        "page.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "page_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "atlassian.page.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["write:confluence-content"]
        },

        # vendor: GET /wiki/rest/api/space
        "space.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{spaces: :list},
          scopes:  ["read:confluence-space.summary"]
        }
      }
    }
  end

  @impl true
  # `user.find_by_email` hits Jira's `/user/search?query=<email>` —
  # Atlassian's user-search endpoint matches by email or display name.
  # The connector takes the first match and emits its `accountId`, so
  # downstream functions referencing `{{owner}}` resolve to the
  # account id the Jira REST API expects on assignment fields.
  def identity_lookup,
    do: %{function: "atlassian.user.find_by_email", by_arg: :email, emit_field: "accountId"}

  @impl true
  # Atlassian error bodies vary by product: Jira returns
  # `%{"errorMessages" => [...], "errors" => %{}}` with the HTTP
  # status; Confluence returns
  # `%{"statusCode" => <int>, "message" => ...}` and relies on the
  # HTTP status. The leading clauses look at the message array — a
  # 400 carrying "Issue Does Not Exist" is semantically a not-found,
  # which the dispatcher should surface as `:not_found` rather than
  # `:passthrough`. The HTTP-status tuples below cover the standard
  # 4xx classes.
  def remap_error(%{"errorMessages" => msgs}) when is_list(msgs) do
    if Enum.any?(msgs, &(is_binary(&1) and &1 =~ "Issue Does Not Exist")),
      do: :not_found,
      else: :passthrough
  end

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 409, _}), do: :duplicate
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Atlassian 3LO lives
  at `auth.atlassian.com/authorize` (consent) +
  `auth.atlassian.com/oauth/token` (exchange). The `audience` param
  on the consent URL is REQUIRED by Atlassian — without it the user
  sees a generic "the link is invalid" page.

  IMPORTANT: the auth host is only used for the OAuth handshake. The
  live REST API host is per-tenant — after the token exchange the
  framework calls
  `https://api.atlassian.com/oauth/token/accessible-resources` to
  resolve the tenant's `cloudId`, which it then templates into the
  per-product API bases (`{cloudid}` placeholder) before any data
  call. The mock test does not drive the OAuth flow, so this
  descriptor is correct as a vendor-fact record while the per-tenant
  substitution is wired.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "atlassian",
      display_name:           "Atlassian (Jira + Confluence)",
      host_match:             "atlassian.com",
      authorization_endpoint: "https://auth.atlassian.com/authorize",
      token_endpoint:         "https://auth.atlassian.com/oauth/token",
      scopes: [
        "read:jira-work",
        "write:jira-work",
        "read:jira-user",
        "read:confluence-content.summary",
        "write:confluence-content",
        "read:me",
        "offline_access"
      ],
      userinfo_endpoint:      "https://api.atlassian.com/me",
      userinfo_field_path:    "email",
      # Atlassian 3LO requires `audience=api.atlassian.com` on the
      # consent URL — without it the user sees a generic invalid-link
      # error and the flow never reaches the token exchange.
      extra_auth_params:      %{"audience" => "api.atlassian.com"}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "atlassian",
      name:        "Atlassian (Jira + Confluence)",
      description: "Jira issues, projects, transitions, comments; Confluence pages. Trello deferred.",
      auth_kind:   :oauth,
      categories:  ["project_management", "docs", "collaboration"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (obviously-fake Jira /
  Confluence ids + a fake company / space name) so chain results are
  mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_atlassian",
      port_env:     "DMH_AI_ATLASSIAN_MOCK_PORT",
      default_port: 8096,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Atlassian.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Atlassian MCP as an in-process REST translator on
  the shared real-MCP port. FE pre-fills this in the External
  Connectors form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/atlassian"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Atlassian on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Atlassian.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Six domain
  groups go live — jira_issues / jira_agile / jira_projects / users /
  confluence_pages / confluence_spaces — so a dev-tooling org can
  expose Jira surfaces (issues + projects + agile boards/sprints) and
  skip the docs surface, while a docs-heavy org also enables
  confluence_pages + confluence_spaces. A separate `trello` entry
  exists at `status: :planned` so the FE can render it as a coming-soon
  item; it carries no functions and is filtered out of the dispatcher
  gate. The three enforcement layers (OAuth scope filter, tool catalog
  filter, dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "jira_issues",
        display_name: "Jira — Issues",
        description:  "Search, create, update, transition, comment on, delete, and attach files to Jira issues.",
        scopes:       ["read:jira-work", "write:jira-work"],
        functions:    ["issue.find", "issue.create", "issue.update",
                       "issue.transition", "issue.comment",
                       "issue.delete", "issue.add_attachment"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Jira scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "jira_agile",
        display_name: "Jira — Agile (boards + sprints)",
        description:  "List Jira Agile boards + sprints, and move issues onto a sprint.",
        scopes:       ["read:jira-work", "write:jira-work"],
        functions:    ["sprint.find", "issue.move_to_sprint", "board.find"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Jira scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "jira_projects",
        display_name: "Jira — Projects",
        description:  "List Jira projects.",
        scopes:       ["read:jira-work"],
        functions:    ["project.find"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Jira scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "users",
        display_name: "Jira — Users",
        description:  "Pivot a Jira user by email to their accountId (identity lookup).",
        scopes:       ["read:jira-user"],
        functions:    ["user.find_by_email"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Jira scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "confluence_pages",
        display_name: "Confluence — Pages",
        description:  "Find, create, update, and delete Confluence pages.",
        scopes:       ["read:confluence-content.summary", "write:confluence-content"],
        functions:    ["page.find", "page.create", "page.update", "page.delete"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Confluence scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "confluence_spaces",
        display_name: "Confluence — Spaces",
        description:  "List Confluence spaces.",
        scopes:       ["read:confluence-space.summary"],
        functions:    ["space.find"],
        vendor_prereq: %{
          label:      "Atlassian OAuth 2.0 (3LO) app — Confluence scopes",
          enable_url: "https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/"
        }
      },
      %{
        id:           "trello",
        display_name: "Trello",
        description:  "Trello boards / cards. Coming soon — separate REST API + auth model.",
        status:       :planned,
        scopes:       [],
        functions:    [],
        vendor_prereq: %{
          label:      "Trello — separate REST API + OAuth",
          enable_url: "https://developer.atlassian.com/cloud/trello/rest/"
        }
      }
    ]
  end
end
