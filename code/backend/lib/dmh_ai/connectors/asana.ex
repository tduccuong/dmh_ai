# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Asana do
  @moduledoc """
  Asana connector (Universal Region, Case B — vendor MCP).

  Sixteen functions at the SME-relevant slice of Asana's REST API
  (developers.asana.com) — workspaces, teams, projects, sections,
  tasks, subtasks, comments, users:

    workspace.find  [read]   list workspaces the authed user belongs to
    team.find       [read]   list teams in an organisation workspace
    project.find    [read]   list projects (optional workspace filter)
    project.create  [write]  create a project in a workspace
    section.find    [read]   list sections inside a project
    section.create  [write]  create a section in a project
    task.find       [read]   list tasks inside a project
    task.create     [write]  create a task (optionally in a project)
    task.update     [write]  patch an existing task
    task.assign     [write]  assign an existing task to a user
    task.complete   [write]  mark a task complete
    task.delete     [write]  delete a task
    subtask.find    [read]   list subtasks under a parent task
    subtask.create  [write]  create a subtask under a parent task
    story.create    [write]  add a comment (story) to a task
    user.find       [read]   read a user (defaults to the authed user)

  Eight capability groups (workspaces / teams / projects / sections
  / tasks / subtasks / comments / directory) so admins can scope
  per-org — a task-tracking org might tick projects + tasks + sections,
  while a collaboration org also enables comments and subtasks.

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
       %{url: "https://developers.asana.com/reference/users", title: "Asana — Users API"},
       %{url: "https://developers.asana.com/reference/workspaces", title: "Asana — Workspaces API"},
       %{url: "https://developers.asana.com/reference/sections", title: "Asana — Sections API"},
       %{url: "https://developers.asana.com/reference/teams", title: "Asana — Teams API"}
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
        },

        # vendor: GET /users/{email}
        # Identity pivot — Asana's `/users/{user_gid}` endpoint accepts
        # an email as the path id, the API resolves it to a user gid
        # server-side and returns the same Asana user resource. A
        # separate verb (rather than overloading `user.find`) because
        # `safe_path_id/1`'s whitelist rejects `@` + `.`; this verb
        # routes the email through `URI.encode_www_form/1` instead.
        "user.find_by_email" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["default"]
        },

        # vendor: GET /workspaces
        # Workspaces are the top-level container in Asana — every other
        # object lives under one. A read here is the natural seed for
        # any lookup chain that needs a workspace id.
        "workspace.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{workspaces: :list},
          scopes:  ["default"]
        },

        # vendor: GET /projects/{project_id}/sections
        "section.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "project_id" => %{type: :string,  required: true,
                              provenance: %{kind: :lookup,
                                            source: "asana.project.find"}},
            "limit"      => %{type: :integer, required: false}
          },
          returns: %{sections: :list},
          scopes:  ["default"]
        },

        # vendor: POST /projects/{project_id}/sections
        "section.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "project_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "asana.project.find"}},
            "name"       => %{type: :string, required: true,
                              provenance: %{kind: :from_user}}
          },
          returns: %{section_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: PUT /tasks/{task_id} (data: %{assignee: assignee_id})
        # Sub-op of `task.update` but exposed as an explicit verb —
        # useful when a lookup chain wants to pivot from a user_id
        # straight to "give that user this task" without composing a
        # free-form patch.
        "task.assign" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "task_id"     => %{type: :string, required: true,
                               provenance: %{kind: :lookup,
                                             source: "asana.task.find"}},
            "assignee_id" => %{type: :string, required: true,
                               provenance: %{kind: :from_user}}
          },
          returns: %{task_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: DELETE /tasks/{task_id}
        # Asana's DELETE returns the deleted task object inside the
        # `"data"` envelope; the response parser ignores the payload
        # and returns `%{ok: true}` regardless.
        "task.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "task_id" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "asana.task.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: POST /tasks/{parent_task_id}/subtasks
        "subtask.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "parent_task_id" => %{type: :string, required: true,
                                  provenance: %{kind: :lookup,
                                                source: "asana.task.find"}},
            "name"           => %{type: :string, required: true,
                                  provenance: %{kind: :from_user}},
            "notes"          => %{type: :string, required: false},
            "assignee_id"    => %{type: :string, required: false}
          },
          returns: %{subtask_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["default"]
        },

        # vendor: GET /tasks/{parent_task_id}/subtasks
        "subtask.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "parent_task_id" => %{type: :string,  required: true,
                                  provenance: %{kind: :lookup,
                                                source: "asana.task.find"}},
            "limit"          => %{type: :integer, required: false}
          },
          returns: %{subtasks: :list},
          scopes:  ["default"]
        },

        # vendor: GET /organizations/{workspace_id}/teams
        # Teams only exist in organisation workspaces (not personal
        # workspaces); the endpoint surfaces a 4xx for a non-org
        # workspace_id, which the dispatcher classifies via
        # `remap_error/1`.
        "team.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "workspace_id" => %{type: :string,  required: true,
                                provenance: %{kind: :lookup,
                                              source: "asana.workspace.find"}},
            "limit"        => %{type: :integer, required: false}
          },
          returns: %{teams: :list},
          scopes:  ["default"]
        }
      }
    }
  end

  @impl true
  # `user.find_by_email` hits Asana's `/users/{email}` lookup — Asana's
  # `/users/{user_gid}` endpoint accepts an email as the path id, the
  # API resolves it to a user gid server-side. Emits the user object's
  # `gid` (Asana's id field is `"gid"`, not `"id"`).
  def identity_lookup,
    do: %{function: "asana.user.find_by_email", by_arg: :email, emit_field: "gid"}

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
  Capability groups admin curates via External Connectors. Eight
  domain groups go live — workspaces / teams / projects / sections /
  tasks / subtasks / comments / directory — so a task-tracking org
  can expose projects + tasks + sections and skip the rest, while a
  collaboration org also enables comments and subtasks. The three
  enforcement layers (OAuth scope filter, tool catalog filter,
  dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "workspaces",
        display_name: "Workspaces",
        description:  "List workspaces the connected user belongs to.",
        scopes:       ["default"],
        functions:    ["workspace.find"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "teams",
        display_name: "Teams",
        description:  "List teams in an organisation workspace.",
        scopes:       ["default"],
        functions:    ["team.find"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
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
        id:           "sections",
        display_name: "Sections",
        description:  "List and create sections inside a project.",
        scopes:       ["default"],
        functions:    ["section.find", "section.create"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "tasks",
        display_name: "Tasks",
        description:  "List, create, update, assign, complete, and delete tasks.",
        scopes:       ["default"],
        functions:    [
          "task.find",
          "task.create",
          "task.update",
          "task.assign",
          "task.complete",
          "task.delete"
        ],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      },
      %{
        id:           "subtasks",
        display_name: "Subtasks",
        description:  "List and create subtasks under a parent task.",
        scopes:       ["default"],
        functions:    ["subtask.find", "subtask.create"],
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
        description:  "Look up Asana users (by gid or email — identity lookup).",
        scopes:       ["default"],
        functions:    ["user.find", "user.find_by_email"],
        vendor_prereq: %{
          label:      "Asana OAuth app access",
          enable_url: "https://developers.asana.com/docs/oauth"
        }
      }
    ]
  end

end
