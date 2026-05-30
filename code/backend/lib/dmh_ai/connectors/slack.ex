# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.Slack do
  @moduledoc """
  Slack connector (Universal Region, Case B — vendor MCP).

  Sixteen functions at the SME-relevant slice of Slack's Web API
  (api.slack.com/methods) — messages, channels, search, users, files,
  pins, reactions:

    message.send        [write]  post a message to a channel / thread
    message.update      [write]  edit an existing message
    message.schedule    [write]  schedule a message for future delivery
    message.delete      [write]  delete a previously posted message
    message.find        [read]   full-text search messages
    channel.find        [read]   list channels (optional name filter)
    channel.history     [read]   read recent messages in a channel
    channel.create      [write]  create a public or private channel
    channel.invite      [write]  invite users to a channel
    channel.archive     [write]  archive a channel
    user.find_by_email  [read]   look a user up by email
    user.list           [read]   list workspace users
    user.set_status     [write]  set the connecting user's status text/emoji
    file.upload         [write]  upload a text file to a channel
    pin.add             [write]  pin a message in a channel
    reaction.add        [write]  add an emoji reaction to a message

  Six capability groups (messaging / channels / search / directory /
  files / pins) so admins can scope per-org — a notify-only org might
  tick messaging, while a support org also enables search + directory.

  ## Fixed host, Bearer auth

  Unlike Shopify / Salesforce, the Slack Web API is a single fixed
  host (`https://slack.com/api`) — there is no per-shop / per-instance
  templating. Every call uses standard `Authorization: Bearer <token>`
  auth, which `RestBridge` injects from `ctx.bearer_token`.

  ## Vendor quirk: HTTP 200 on failure (`remap_error/1`)

  The Slack Web API returns **HTTP 200 even on failure**, with a body
  of the shape `%{"ok" => false, "error" => "<code>"}`. So the success
  path can't key off the HTTP status alone — each function's `response`
  parser inspects the `"ok"` field and returns `{:error, body}` on a
  false result. `remap_error/1` then pattern-matches that body shape
  (in addition to the usual HTTP-status tuples) and maps the vendor
  error code to the canonical class: `already_reacted` / `name_taken`
  → `:duplicate`; auth codes → `:unauthorised`; `*_not_found` /
  `not_in_channel` → `:not_found`; `rate_limited` → `:rate_limited`.
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Tools.Manifest
  alias DmhAi.Tools.Manifest.Function

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(access_token) when is_binary(access_token) do
    # Slack's `auth.test` returns the bot/user id + workspace name but
    # NO email — capturing the connecting user's email needs the OIDC
    # `openid email` scope (a separate Sign in with Slack flow). So we
    # return only the id here. Like every Slack call this answers HTTP
    # 200 with `{"ok": false, ...}` on failure, so the success clause
    # keys off `"ok" => true`.
    url = "https://slack.com/api/auth.test"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: %{"ok" => true, "user_id" => uid}}}
          when is_binary(uid) and uid != "" ->
        {:ok, %{id: uid}}

      {:ok, %{status: 200, body: %{"ok" => false, "error" => code}}} ->
        {:error, {:slack, code}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http, s, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_get(url, access_token) do
    case Application.get_env(:dmh_ai, :__slack_authtest_stub__) do
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
  def mcp_slug, do: "slack"

  @impl DmhAi.Connectors.Discoverable
  def discover_functions, do: DmhAi.Connectors.Seed.read_priv_rows(mcp_slug())

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://api.slack.com/web", title: "Slack Web API overview"},
       %{url: "https://api.slack.com/methods/chat.postMessage", title: "Slack — chat.postMessage"},
       %{url: "https://api.slack.com/methods/conversations.list", title: "Slack — conversations.list"},
       %{url: "https://api.slack.com/methods/search.messages", title: "Slack — search.messages"},
       %{url: "https://api.slack.com/methods/users.lookupByEmail", title: "Slack — users.lookupByEmail"}
     ]}
  end

  # Per-user metadata sweep. Slack has no per-user custom-property
  # schema analogous to HubSpot's `/crm/v3/properties/<object>` — its
  # objects are fixed-shape. So there is nothing to sweep: always
  # return an empty row set (no metadata to cache) — same contract as
  # the other Case-B connectors.
  @impl DmhAi.Connectors.Discoverable
  def discover_metadata(user_id) when is_binary(user_id) do
    {:ok, []}
  end

  # Layer B reader. Slack objects are fixed-shape with no custom
  # property schema to introspect, so there is no metadata cache to
  # consult. Always return `:not_supported`, which the compiler treats
  # as "trust the literal" — same contract as the default.
  @impl true
  def inspect_property(_function_name, _path, _ctx), do: {:error, :not_supported}

  @impl true
  def manifest do
    %Manifest{
      connector: "slack",
      region:    "universal",
      functions: %{
        # vendor: POST /chat.postMessage
        # docs:   https://api.slack.com/methods/chat.postMessage
        "message.send" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel"   => %{type: :string, required: true,
                             provenance: %{kind: :from_user}},
            "text"      => %{type: :string, required: true,
                             provenance: %{kind: :literal_default}},
            "thread_ts" => %{type: :string, required: false}
          },
          returns: %{ts: :string, channel: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["chat:write"]
        },

        # vendor: POST /chat.update
        "message.update" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel" => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "slack.channel.find"}},
            "ts"      => %{type: :string, required: true,
                           provenance: %{kind: :lookup,
                                         source: "slack.message.find"}},
            "text"    => %{type: :string, required: true,
                           provenance: %{kind: :literal_default}}
          },
          returns: %{ts: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["chat:write"]
        },

        # vendor: GET /conversations.list
        "channel.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            # Workflow authors legitimately bake a name filter
            # ("#general") OR bind it to a trigger input
            # (`{{T.query}}`). Either form is fine — the validator
            # accepts both under `:literal_default`.
            "query" => %{type: :string,  required: false,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{channels: :list},
          scopes:  ["channels:read"]
        },

        # vendor: GET /conversations.history
        "channel.history" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "channel" => %{type: :string,  required: true,
                           provenance: %{kind: :lookup,
                                         source: "slack.channel.find"}},
            "limit"   => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["channels:history"]
        },

        # vendor: GET /search.messages
        "message.find" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "query" => %{type: :string,  required: true,
                         provenance: %{kind: :literal_default}},
            "limit" => %{type: :integer, required: false}
          },
          returns: %{messages: :list},
          scopes:  ["search:read"]
        },

        # vendor: GET /users.lookupByEmail
        "user.find_by_email" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "email" => %{type: :string, required: true, format: :email,
                         provenance: %{kind: :from_user}}
          },
          returns: %{user: :map},
          scopes:  ["users:read.email"]
        },

        # vendor: GET /users.list
        "user.list" => %Function{
          permission:    :read,
          callable_from: [:chat, :task],
          args: %{
            "limit" => %{type: :integer, required: false}
          },
          returns: %{users: :list},
          scopes:  ["users:read"]
        },

        # vendor: POST /reactions.add
        "reaction.add" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel"   => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "slack.channel.find"}},
            "timestamp" => %{type: :string, required: true,
                             provenance: %{kind: :lookup,
                                           source: "slack.message.find"}},
            "name"      => %{type: :string, required: true,
                             provenance: %{kind: :from_user}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :duplicate, :rate_limited],
          scopes:  ["reactions:write"]
        },

        # vendor: POST /conversations.create
        # docs:   https://api.slack.com/methods/conversations.create
        "channel.create" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "name"       => %{type: :string,  required: true,
                              provenance: %{kind: :from_user}},
            "is_private" => %{type: :boolean, required: false}
          },
          returns: %{channel_id: :string},
          errors:  [:unauthorised, :duplicate, :rate_limited],
          scopes:  ["channels:manage", "groups:write"]
        },

        # vendor: POST /conversations.invite
        # docs:   https://api.slack.com/methods/conversations.invite
        "channel.invite" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.channel.find"}},
            "user_ids"   => %{type: :list,   required: true,
                              provenance: %{kind: :literal_default}}
          },
          returns: %{channel_id: :string},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["channels:manage", "groups:write"]
        },

        # vendor: POST /conversations.archive
        # docs:   https://api.slack.com/methods/conversations.archive
        "channel.archive" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.channel.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["channels:manage", "groups:write"]
        },

        # vendor: POST /chat.scheduleMessage
        # docs:   https://api.slack.com/methods/chat.scheduleMessage
        "message.schedule" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id"    => %{type: :string,  required: true,
                                 provenance: %{kind: :lookup,
                                               source: "slack.channel.find"}},
            "text"          => %{type: :string,  required: true,
                                 provenance: %{kind: :literal_default}},
            "post_at_epoch" => %{type: :integer, required: true,
                                 provenance: %{kind: :literal_default}}
          },
          returns: %{scheduled_message_id: :string, post_at: :integer},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["chat:write"]
        },

        # vendor: POST /chat.delete
        # docs:   https://api.slack.com/methods/chat.delete
        "message.delete" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.channel.find"}},
            "ts"         => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.message.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :rate_limited],
          scopes:  ["chat:write"]
        },

        # vendor: POST /files.upload (multipart/form-data)
        # docs:   https://api.slack.com/methods/files.upload
        # NOTE — Slack has deprecated `files.upload` in favour of a
        # 2-step `files.getUploadURLExternal` + `files.completeUpload
        # External` flow. The deprecated endpoint is still live at the
        # time of writing; when Slack switches it off the handler must
        # be migrated to the 2-step shape (the typed-args surface stays
        # the same — only the MCPHandler implementation changes).
        "file.upload" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.channel.find"}},
            "filename"   => %{type: :string, required: true,
                              provenance: %{kind: :from_user}},
            "content"    => %{type: :string, required: true,
                              provenance: %{kind: :literal_default}},
            "title"      => %{type: :string, required: false}
          },
          returns: %{file_id: :string},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["files:write"]
        },

        # vendor: POST /pins.add
        # docs:   https://api.slack.com/methods/pins.add
        "pin.add" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "channel_id" => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.channel.find"}},
            "ts"         => %{type: :string, required: true,
                              provenance: %{kind: :lookup,
                                            source: "slack.message.find"}}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :not_found, :duplicate, :rate_limited],
          scopes:  ["pins:write"]
        },

        # vendor: POST /users.profile.set
        # docs:   https://api.slack.com/methods/users.profile.set
        "user.set_status" => %Function{
          permission:      :write,
          callable_from:   [:task],
          idempotency_key: :required,
          args: %{
            "status_text"       => %{type: :string,  required: true,
                                     provenance: %{kind: :from_user}},
            "status_emoji"      => %{type: :string,  required: false},
            "status_expiration" => %{type: :integer, required: false}
          },
          returns: %{ok: :boolean},
          errors:  [:unauthorised, :rate_limited],
          scopes:  ["users.profile:write"]
        }
      }
    }
  end

  @impl true
  # Slack exposes `users.lookupByEmail`, which IS an email-pivot, but
  # the identity-probe contract emits a single vendor id field — wiring
  # `user.find_by_email` (which returns the whole user map) into it is
  # future work. Fix: switch this to:
  #   %{function: "slack.user.find_by_email",
  #     by_arg: :email, emit_field: "id"}
  def identity_lookup, do: nil

  @impl true
  # Slack answers HTTP 200 even on failure, with body
  # `%{"ok" => false, "error" => "<code>"}`. The function `response`
  # parsers surface that body as `{:error, body}`, so the leading
  # clauses here key off the `"ok" => false` shape and map the vendor
  # error code to the canonical class. The HTTP-status tuples below
  # cover transport-level failures (e.g. a 5xx before Slack frames a
  # JSON body).
  def remap_error(%{"ok" => false, "error" => code}) when is_binary(code) do
    cond do
      code in ["already_reacted", "name_taken", "already_pinned"] ->
        :duplicate

      code in ["not_authed", "invalid_auth", "token_revoked", "account_inactive"] ->
        :unauthorised

      code in ["channel_not_found", "user_not_found", "message_not_found", "not_in_channel"] ->
        :not_found

      code in ["rate_limited", "ratelimited"] ->
        :rate_limited

      true ->
        :passthrough
    end
  end

  def remap_error(%{"ok" => false}), do: :passthrough

  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error(_),                do: :passthrough

  # ─── Boot-time seeders + FE/admin descriptors ─────────────────────────

  @doc """
  OAuth catalog descriptor — vendor facts only. Slack OAuth v2 lives
  at `slack.com/oauth/v2/authorize` (consent) +
  `slack.com/api/oauth.v2.access` (exchange). Fixed host, no
  per-instance templating.
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "slack",
      display_name:           "Slack",
      host_match:             "slack.com",
      authorization_endpoint: "https://slack.com/oauth/v2/authorize",
      token_endpoint:         "https://slack.com/api/oauth.v2.access",
      scopes: [
        "chat:write",
        "channels:read",
        "channels:history",
        "channels:manage",
        "groups:write",
        "search:read",
        "users:read",
        "users:read.email",
        "users.profile:write",
        "files:write",
        "pins:write",
        "reactions:write"
      ],
      # Slack's `auth.test` identity probe returns no email without the
      # OIDC `openid email` scope (a separate Sign in with Slack flow),
      # so `fetch_userinfo/1` captures only the user id. There is no
      # generic OIDC userinfo endpoint to point the catalog at.
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
      slug:        "slack",
      name:        "Slack",
      description: "Slack — post/search messages, channels, users, reactions.",
      auth_kind:   :oauth,
      categories:  ["messaging", "collaboration"]
    }
  end

  @doc """
  Mock vendor MCP fixture descriptor. Boots a deterministic mock
  vendor server when `DMH_AI_ENABLE_VENDOR_MOCKS=true`. Demo
  scenarios assert on sentinel identifiers (Slack-style channel /
  message / user IDs) so chain results are mechanically provable.
  """
  def mock_descriptor do
    %{
      instance:     "demo_slack",
      port_env:     "DMH_AI_SLACK_MOCK_PORT",
      default_port: 8092,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.Slack.fixtures()
    }
  end

  @doc """
  Where this connector's MCP server lives in *this* deployment.
  DMH-AI hosts the Slack MCP as an in-process REST translator on the
  shared real-MCP port. FE pre-fills this in the External Connectors
  form.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/slack"
  end

  @doc """
  Handler module that owns the slug → FunctionSpec map consumed by
  `Connectors.MCPServer`. Exporting this callback signals to
  `Bootstrap.start_real_mcp_server/0` to mount Slack on the shared
  in-process MCPServer at the slug path.
  """
  def mcp_handler_module, do: DmhAi.Connectors.Slack.MCPHandler

  @doc """
  Capability groups admin curates via External Connectors. Six
  domain groups go live — messaging / channels / search / directory
  / files / pins — so a notify-only org can expose messaging and
  skip the rest, while a support org also enables search + directory.
  The three enforcement layers (OAuth scope filter, tool catalog
  filter, dispatcher gate) all read from `enabled_capabilities`.
  """
  @spec capabilities() :: [map()]
  def capabilities do
    [
      %{
        id:           "messaging",
        display_name: "Messaging",
        description:  "Post, edit, schedule, delete messages; add emoji reactions.",
        scopes:       ["chat:write", "reactions:write"],
        functions:    [
          "message.send",
          "message.update",
          "message.schedule",
          "message.delete",
          "reaction.add"
        ],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Messaging)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      },
      %{
        id:           "channels",
        display_name: "Channels",
        description:  "List, read, create, invite-to, and archive channels.",
        scopes:       ["channels:read", "channels:history", "channels:manage", "groups:write"],
        functions:    [
          "channel.find",
          "channel.history",
          "channel.create",
          "channel.invite",
          "channel.archive"
        ],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Channels)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      },
      %{
        id:           "search",
        display_name: "Search",
        description:  "Full-text search across messages.",
        scopes:       ["search:read"],
        functions:    ["message.find"],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Search)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      },
      %{
        id:           "directory",
        display_name: "Directory",
        description:  "Look up workspace users by email; list users; set the connecting user's status.",
        scopes:       ["users:read", "users:read.email", "users.profile:write"],
        functions:    ["user.find_by_email", "user.list", "user.set_status"],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Directory)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      },
      %{
        id:           "files",
        display_name: "Files",
        description:  "Upload files to a channel.",
        scopes:       ["files:write"],
        functions:    ["file.upload"],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Files)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      },
      %{
        id:           "pins",
        display_name: "Pins",
        description:  "Pin a message in a channel.",
        scopes:       ["pins:write"],
        functions:    ["pin.add"],
        vendor_prereq: %{
          label:      "Slack app OAuth scopes (Pins)",
          enable_url: "https://api.slack.com/authentication/oauth-v2"
        }
      }
    ]
  end

end
