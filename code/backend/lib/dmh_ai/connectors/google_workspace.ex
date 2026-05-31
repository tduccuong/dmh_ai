# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace do
  @moduledoc """
  Google Workspace connector (Universal Region, Case B — Gmail /
  Calendar / Drive via the official Google APIs).

  ## Vendor source-of-truth

  Each function is grounded in a documented Google REST API endpoint;
  the MCP server (Google's official Cloud MCP catalog, or our own
  thin wrapper) is a JSON-RPC translation layer over those
  endpoints. Function names in this manifest follow SME-ergonomic
  shapes — the wrapper translates each manifest arg to the
  endpoint's actual parameter name. The `# vendor: <endpoint>`
  comment on every function (see `__MODULE__.Manifest`) is the
  auditable link back to the docs.

  Function-to-endpoint mapping (also documented in
  `arch_wiki/dmh_ai/sme/layer-0.md` §0.3.2):

    | Function                  | Endpoint                                          |
    |-----------------------|---------------------------------------------------|
    | gmail.search          | users.messages.list (Gmail API v1)                |
    | gmail.send            | users.messages.send (Gmail API v1)                |
    | gcal.find_free_slots  | freebusy.query + shim slot-computation (Cal v3)   |
    | gcal.create_event     | events.insert (Calendar API v3)                   |
    | drive.list            | files.list (Drive API v3)                         |
    | drive.upload          | files.create multipart (Drive API v3)             |

  ## Vendor quirks (`remap_error/1`)

    * 429 / `RESOURCE_EXHAUSTED` / `rateLimitExceeded` → `:rate_limited`
    * 404 / `NOT_FOUND` / `notFound` → `:not_found`
    * 401 / `UNAUTHENTICATED` / `invalidCredentials` → `:unauthorised`
    * 403 / `PERMISSION_DENIED` (insufficient OAuth scope) → `:unauthorised`
    * `ALREADY_EXISTS` → `:duplicate`

  ## Module layout

  This module is a thin façade. The heavy bags live in siblings under
  `DmhAi.Connectors.GoogleWorkspace.*`:

    * `Manifest`     — per-function manifest (`manifest/0`).
    * `Capabilities` — admin-curated capability groups (`capabilities/0`).
    * `OAuth`        — OAuth + MCP catalog descriptors and
                       deployment-default MCP URL.
    * `LayerB`       — vendor-metadata sweep + cached-property reader
                       (`discover_metadata/1`, `inspect_property/3`).
    * `LiveProbe`    — Google Discovery-Document probe used by
                       `discover_functions/0` to verify scope drift.
    * `MCPHandler`   — in-process REST translation layer
                       (`mcp_handler_module/0`).
  """

  use DmhAi.Connectors.MCPAdapter
  @behaviour DmhAi.Connectors.Discoverable
  @behaviour DmhAi.Connectors.OAuthIdentity

  alias DmhAi.Connectors.GoogleWorkspace.LiveProbe

  require Logger

  @impl DmhAi.Connectors.OAuthIdentity
  def fetch_userinfo(token),
    do: DmhAi.OAuth.Identity.OIDC.fetch(token,
          "https://openidconnect.googleapis.com/v1/userinfo", "email")

  # Always-on identity scopes. Capabilities the admin curates supply
  # API-access scopes (Gmail, Calendar, Drive, …); these two are
  # what the OIDC userinfo endpoint requires to return the connecting
  # account's email, regardless of which capabilities are enabled.
  #
  # Google accepts both `"email"` and the full URI form in the OAuth
  # request, but the TOKEN response normalises to the URI form
  # (`https://www.googleapis.com/auth/userinfo.email`). The runtime's
  # scope-cover check is a literal string subset, so this list must
  # use the form Google actually returns in the grant — otherwise the
  # short `"email"` is never matched against the granted URI string
  # and `connect_mcp` stays stuck on `needs_reauth` even after a
  # fresh consent.
  def base_scopes, do: ["openid", "https://www.googleapis.com/auth/userinfo.email"]

  @impl DmhAi.Connectors.Discoverable
  def discover_docs do
    {:ok,
     [
       %{url: "https://developers.google.com/gmail/api/guides",            title: "Gmail API"},
       %{url: "https://developers.google.com/calendar/api/guides/overview", title: "Google Calendar API"},
       %{url: "https://developers.google.com/drive/api/guides/about-sdk",   title: "Google Drive API"},
       %{url: "https://developers.google.com/docs/api/concepts/document",   title: "Google Docs API"},
       %{url: "https://developers.google.com/sheets/api/guides/concepts",   title: "Google Sheets API"},
       %{url: "https://developers.google.com/tasks",                        title: "Google Tasks API"},
       %{url: "https://developers.google.com/people/api/rest",              title: "Google People API"}
     ]}
  end

  @impl DmhAi.Connectors.Discoverable
  defdelegate discover_metadata(user_id), to: __MODULE__.LayerB

  @impl true
  defdelegate inspect_property(function_name, path, ctx), to: __MODULE__.LayerB

  @impl true
  def mcp_slug, do: "google_workspace"

  # Mapping from our connector function name to the Google API method
  # that backs it. The `discover_functions/0` callback probes each
  # entry's live Discovery Document and overlays the live `scopes`
  # field onto the matching priv-seed row. Functions absent from this
  # map (synthetic recipes, multi-call composites) pass through from
  # the priv baseline unchanged — they have no 1:1 Google method.
  @google_method_map %{
    "gmail.search"       => {"gmail",    "v1", "gmail.users.messages.list"},
    "gmail.send"         => {"gmail",    "v1", "gmail.users.messages.send"},
    "gmail.reply"        => {"gmail",    "v1", "gmail.users.messages.send"},
    "gcal.list_events"   => {"calendar", "v3", "calendar.events.list"},
    "calendar.list"      => {"calendar", "v3", "calendar.events.list"},
    "calendar.create"    => {"calendar", "v3", "calendar.events.insert"},
    "drive.upload"       => {"drive",    "v3", "drive.files.create"},
    "drive.list"         => {"drive",    "v3", "drive.files.list"},
    "drive.read"         => {"drive",    "v3", "drive.files.get"},
    "docs.create"        => {"docs",     "v1", "docs.documents.create"},
    "sheets.read"        => {"sheets",   "v4", "sheets.spreadsheets.values.get"},
    "tasks.list"         => {"tasks",    "v1", "tasks.tasks.list"},
    "tasks.create"       => {"tasks",    "v1", "tasks.tasks.insert"}
  }

  @impl DmhAi.Connectors.Discoverable
  def discover_functions do
    case DmhAi.Connectors.Seed.read_priv_rows(mcp_slug()) do
      {:ok, baseline} ->
        {:ok, overlay_live_scopes(baseline)}

      {:error, _} = err ->
        err
    end
  end

  # For each baseline row whose function_name has a Google Discovery
  # mapping, probe the live Discovery Document and verify the row's
  # `scopes_required` is still in Google's accepted list. Rows are
  # returned UNCHANGED — the probe's job here is verification, not
  # silent rewriting. A drift (declared scope absent from the live
  # list) emits a warning so the operator can investigate; an
  # auto-substitute would be guessing at Google's permission semantics
  # and could be wrong.
  defp overlay_live_scopes(rows) do
    Enum.map(rows, fn row ->
      case Map.get(@google_method_map, row.function_name) do
        nil ->
          row

        {api, version, method_id} ->
          case LiveProbe.probe_method(api, version, method_id) do
            {:ok, %{scopes: live_scopes}} when is_list(live_scopes) ->
              verify_scopes(row, live_scopes, method_id)
              row

            {:ok, _} ->
              row

            {:error, reason} ->
              Logger.warning(
                "[GoogleWorkspace.discover_functions] fn=#{row.function_name} probe " <>
                  "method=#{method_id} failed=#{inspect(reason)}; using priv baseline"
              )
              row
          end
      end
    end)
  end

  defp verify_scopes(row, live_scopes, method_id) do
    declared = Map.get(row, :scopes_required, [])
    drift    = declared -- live_scopes

    if drift != [] do
      Logger.warning(
        "[GoogleWorkspace.discover_functions] fn=#{row.function_name} method=#{method_id} " <>
          "declared scopes #{inspect(drift)} NOT in Google's accepted list " <>
          "#{inspect(live_scopes)} — bundled defaults may be out of date"
      )
    end

    :ok
  end

  @impl true
  defdelegate manifest(), to: __MODULE__.Manifest

  @impl true
  # `directory.users.find_by_email` hits the Directory API's
  # `/users/{userKey}` lookup — Google accepts the primary email as
  # `userKey` and returns the full Directory user resource. Emits the
  # user object's `id` (the Directory numeric user id) for downstream
  # assignment bindings.
  def identity_lookup,
    do: %{function: "google_workspace.directory.users.find_by_email",
          by_arg: :email, emit_field: "id"}

  @impl true
  # Google APIs return errors as
  #   {"error": {"code": <int>, "status": "<UPPER_SNAKE>", "message":…}}
  # or with `errors: [{"reason": "<lowerCamelCase>"}]` on the v1 surfaces.
  def remap_error(%{"error" => %{"status" => status}}) do
    case status do
      "RESOURCE_EXHAUSTED"  -> :rate_limited
      "NOT_FOUND"           -> :not_found
      "UNAUTHENTICATED"     -> :unauthorised
      "PERMISSION_DENIED"   -> :unauthorised
      "ALREADY_EXISTS"      -> :duplicate
      _                     -> :passthrough
    end
  end

  def remap_error(%{"error" => %{"errors" => [%{"reason" => reason} | _]}}) do
    case reason do
      "rateLimitExceeded"     -> :rate_limited
      "userRateLimitExceeded" -> :rate_limited
      "notFound"              -> :not_found
      "invalidCredentials"    -> :unauthorised
      "authError"             -> :unauthorised
      _                       -> :passthrough
    end
  end

  def remap_error({:http, 429, _}), do: :rate_limited
  def remap_error({:http, 404, _}), do: :not_found
  def remap_error({:http, 401, _}), do: :unauthorised
  def remap_error({:http, 403, _}), do: :unauthorised
  def remap_error(_), do: :passthrough

  defdelegate oauth_catalog_descriptor(), to: __MODULE__.OAuth
  defdelegate mcp_catalog_descriptor(),   to: __MODULE__.OAuth
  defdelegate default_mcp_url(),          to: __MODULE__.OAuth

  defdelegate capabilities(), to: __MODULE__.Capabilities

  @doc """
  Mock vendor MCP fixture descriptor, consumed by
  `Connectors.Bootstrap.start_vendor_mocks_if_enabled/0` when the
  operator sets `DMH_AI_ENABLE_VENDOR_MOCKS=true`. The mock binds
  to 127.0.0.1 on the port named by `DMH_AI_GW_MOCK_PORT`
  (default 8086) and serves the canned fixtures from
  `Connectors.Mock.Fixtures.GoogleWorkspace`. Production installs
  leave the flag off; the descriptor is inert without it.
  """
  def mock_descriptor do
    %{
      instance:     "demo_gw",
      port_env:     "DMH_AI_GW_MOCK_PORT",
      default_port: 8086,
      fixtures:     DmhAi.Connectors.Mock.Fixtures.GoogleWorkspace.fixtures()
    }
  end

  @doc """
  Points the in-process `Connectors.MCPServer` at the connector's
  REST function handler. Returns the module that exposes
  `handler/0` (the `slug` + `functions` map the server registers). The
  `MCPServer` boot path enumerates every connector exposing this
  callback; no central list to update when a connector is added.
  """
  def mcp_handler_module, do: DmhAi.Connectors.GoogleWorkspace.MCPHandler
end
