# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Asana do
  @moduledoc """
  Asana connector (Universal Region, Case B — vendor MCP).

  Eight functions at the SME-relevant slice of Asana's REST API
  (developers.asana.com) — projects, tasks, comments, users:

    project.find    [read]   list projects (optional workspace filter)
    project.create  [write]  create a project in a workspace
    task.find       [read]   list tasks inside a project
    task.create     [write]  create a task (optionally in a project)
    task.update     [write]  patch an existing task
    task.complete   [write]  mark a task complete
    story.create    [write]  add a comment (story) to a task
    user.find       [read]   read a user (defaults to the authed user)

  Four capability groups (projects / tasks / comments / directory)
  so admins can scope per-org — a task-tracking org might tick
  projects + tasks, while a collaboration org also enables comments.

  ## Fixed host, Bearer auth

  The Asana REST API is a single fixed host
  (`https://app.asana.com/api/1.0`) — there is no per-account /
  per-instance templating. Every call uses standard
  `Authorization: Bearer <token>` auth, which `RestBridge` injects
  from `ctx.bearer_token`.

  ## Vendor quirk: the `"data"` envelope

  Every Asana request body and response is wrapped in a top-level
  `"data"` key. POST / PUT send `%{"data" => %{...fields...}}`;
  responses come back as `%{"data" => obj}` (single object) or
  `%{"data" => [obj, ...]}` (collection). So each `request` builder
  wraps its payload under `"data"`, and each `response` parser
  unwraps `body["data"]` before mapping to the declared returns.

  ## Vendor quirk: error body (`remap_error/1`)

  Asana returns normal HTTP status codes with a JSON error body of
  the shape `%{"errors" => [%{"message" => ...}, ...]}`. There is no
  reliable per-message canonical mapping, so the error body itself
  maps to `:passthrough` and the HTTP status drives classification
  (`401` / `403` → `:unauthorised`; `404` → `:not_found`; `429` →
  `:rate_limited`). Asana has no strong duplicate concept, so there
  is no `:duplicate` mapping.

  ## Path-param ids

  Functions acting on a specific object (`task.find` /
  `task.update` / `task.complete` / `story.create`, and `user.find`
  for a non-self user) interpolate the id into the URL path. Asana
  gids are digit strings; the id is whitelisted to `^[A-Za-z0-9_-]+$`
  in the MCP handler before the URL is built — no raw interpolation
  of unvalidated input.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Asana's `/users/me` returns the connecting user's gid + email,
    # both wrapped in the top-level `"data"` envelope. The access
    # token goes in standard Bearer auth. Response:
    #   `{"data": {"gid": ..., "email": ..., ...}}`.
    url = "https://app.asana.com/api/1.0/users/me"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"data" => %{"gid" => id, "email" => email}}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email, id: to_string(id)}}

      {:ok, %{status: 200, body: %{"data" => %{"email" => email}}}}
          when is_binary(email) and email != "" ->
        {:ok, %{email: email}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__asana_userinfo_stub__) do
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
  def mcp_slug, do: "asana"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.asana.com/docs/overview", title: "Asana API overview"},
       %{url: "https://developers.asana.com/reference/tasks", title: "Asana — Tasks API"},
       %{url: "https://developers.asana.com/reference/projects", title: "Asana — Projects API"},
       %{url: "https://developers.asana.com/reference/stories", title: "Asana — Stories API"},
       %{url: "https://developers.asana.com/reference/users", title: "Asana — Users API"}
     ]}
  end

  # Per-user metadata sweep. Asana has no per-user custom-property
  # schema analogous to HubSpot's `/crm/v3/properties/<object>` — its
  # objects are fixed-shape. So there is nothing to sweep: always
  # return an empty row set (no metadata to cache) — same contract as
  # the other Case-B connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. Asana objects are fixed-shape with no custom
  # property schema to introspect, so there is no metadata cache to
  # consult. Always return `:not_supported`, which the compiler treats
  # as "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "asana",
      region:    "universal",
      functions: %{
        # vendor: GET /projects
        # docs:   https://developers.asana.com/reference/projects
        #
        # Asana's scope model is coarse — `default` = full access;
        # granular `<resource>:<action>` scopes are newer and may need
        # updating for live OAuth. So every function declares ["default"].
        "project.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "workspace_id" => %{type: :string,  required: false,
                                provenance: %{kind: :from_user}},
            "limit"        => %{type: :integer, required: false}
          },
          returns: %{projects: :list},
          scopes:  ["default"]
        },

        # vendor: POST /projects
        "project.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"         => %{type: :string, required: true,
                                provenance: %{kind: :from_user}},
            "workspace_id" => %{type: :string, required: true,
                                provenance: %{kind: :from_user}}
          },
          returns: %{project_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: GET /projects/{project_id}/tasks
        "task.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "project_id" => %{type: :string,  required: true,
                              provenance: %{kind: :lookup,
                                            source: "asana.project.find"}},
            "limit"      => %{type: :integer, required: false}
          },
          returns: %{tasks: :list},
          scopes:  ["default"]
        },

        # vendor: POST /tasks
        "task.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"       => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "project_id" => %{type: :string, required: false,
                              provenance: %{kind: :lookup,
                                            source: "asana.project.find"}},
            "notes"      => %{type: :string, required: false},
            "due_on"     => %{type: :string, required: false}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: PUT /tasks/{task_id}
        # `patch` is a free-form map of Asana task fields → values;
        # the shim does not enumerate or validate field names so any
        # field passes through (wrapped under the `"data"` envelope).
        "task.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "task_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "asana.task.find"}},
            "patch"   => %{type: :map,    required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: PUT /tasks/{task_id} (data: %{completed: true})
        "task.complete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "task_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "asana.task.find"}}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: POST /tasks/{task_id}/stories (a comment)
        "story.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "task_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "asana.task.find"}},
            "text"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{story_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: GET /users/{user_id_or_me}
        "user.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "user_id" => %{type: :string, required: false,
                           provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["default"]
        }
      }
    }
  end

  @impl true
  # Asana exposes `/users/{id}` keyed by gid OR email (`workspace`
  # qualified), but a dedicated identity-pivot function is not yet in
  # this manifest. Fix: add `user.find_by_email` and switch this to:
  #   %{function: "asana.user.find_by_email",
  #     by_arg: :email, emit_field: "gid"}
  def identity_lookup, do: nil

  @impl true
  # Asana returns normal HTTP status codes with a JSON error body of
  # the shape `%{"errors" => [%{"message" => ...}, ...]}`. There is no
  # reliable per-message canonical mapping, so the error body maps to
  # `:passthrough` and the HTTP-status tuples below drive the canonical
  # class. Asana has no strong duplicate concept, so there is no
  # `:duplicate` mapping.
  def remap_error(%{"errors" => errors}) when is_list(errors), do: :passthrough

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Asana OAuth lives at
  `app.asana.com/-/oauth_authorize` (consent) +
  `app.asana.com/-/oauth_token` (exchange). Fixed host, no
  per-instance templating.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "asana",
      display_name:           "Asana",
      host_match:             "asana.com",
      authorization_endpoint: "https://app.asana.com/-/oauth_authorize",
      token_endpoint:         "https://app.asana.com/-/oauth_token",
      # Asana's scope model is coarse — `default` = full access;
      # granular `<resource>:<action>` scopes are newer and may need
      # updating for live OAuth.
      scopes:                 ["default"],
      userinfo_endpoint:      "https://app.asana.com/api/1.0/users/me",
      userinfo_field_path:    "data.email",
      extra_auth_params:      %{}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Admin sets `mcp_url`
  via External Connectors (pre-filled to the in-process default).
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "asana",
      name:        "Asana",
      description: "Asana — projects, tasks, comments.",
      auth_kind:   :oauth,
      categories:  ["project_management", "productivity"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (Asana-style project /
  task / user / story gids) so chain results are mechanically
  provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_asana",
      port_env:     "DMH_AI_ASANA_MOCK_PORT",
      default_port: 8094,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Asana.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Asana MCP as an in-process REST translator on the
  shared real-MCP port. FE pre-fills this in the External Connectors
  form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/asana"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Asana on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Asana.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Four
  domain groups go live — projects / tasks / comments / directory
  — so a task-tracking org can expose projects + tasks and skip the
  rest, while a collaboration org also enables comments. The three
  enforcement layers (OAuth scope filter, tool catalog filter,
  dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "projects",
        display_name: "Projects",
        description:  "List and create projects.",
        scopes:       ["default"],
        functions:    ["project.find", "project.create"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "tasks",
        display_name: "Tasks",
        description:  "List, create, update, and complete tasks.",
        scopes:       ["default"],
        functions:    ["task.find", "task.create", "task.update", "task.complete"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "comments",
        display_name: "Comments",
        description:  "Add comments (stories) to tasks.",
        scopes:       ["default"],
        functions:    ["story.create"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "directory",
        display_name: "Directory",
        description:  "Look up Asana users.",
        scopes:       ["default"],
        functions:    ["user.find"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      }
    ]
  end

end
