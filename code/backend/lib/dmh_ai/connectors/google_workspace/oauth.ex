# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Connectors.GoogleWorkspace.OAuth do
  @moduledoc """
  Vendor-fact descriptors consumed by the OAuth + MCP catalog seeders
  at boot, plus the deployment-specific default MCP URL used to
  pre-fill the External Connectors admin form. Pulled out of the
  parent `GoogleWorkspace` connector because the parent is at the
  file-size ceiling and re-exports these via `defdelegate`.
  """

  @doc """
  OAuth catalog descriptor — vendor facts only. Consumed by
  `Connectors.OAuthCatalogSeed.upsert!/1` at boot to populate the
  oauth_catalog row's vendor-metadata columns (endpoints, scopes,
  host_match, etc.). Credentials (`client_id`, `client_secret`)
  are operator-set via the External Connectors admin page; the
  seeder never reads or writes them.

  The scope set here mirrors what the per-function manifest
  declares; expanding the manifest with a new scope-using
  function means adding the scope here too.

  `access_type=offline` + `prompt=consent` ensure a refresh token
  is returned on every grant (Google omits it on subsequent
  grants by default).
  """
  def oauth_catalog_descriptor do
    %{
      slug:                   "google_workspace",
      display_name:           "Google Workspace",
      host_match:             "accounts.google.com",
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint:         "https://oauth2.googleapis.com/token",
      scopes: [
        # OIDC identity scopes — required for `fetch_userinfo/1` to
        # hit `/v1/userinfo` and capture the connecting account's
        # email into `user_credentials.account`. Without them the
        # `{{owner.google_workspace.email}}` binding can't resolve.
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/spreadsheets",
        "https://www.googleapis.com/auth/documents.readonly",
        "https://www.googleapis.com/auth/admin.directory.user.readonly"
      ],
      # Identity capture lives in `fetch_userinfo/1` on the parent module.
      userinfo_endpoint:      nil,
      userinfo_field_path:    nil,
      extra_auth_params:      %{"access_type" => "offline", "prompt" => "consent"}
    }
  end

  @doc """
  MCP catalog descriptor — vendor facts only. Consumed by
  `Connectors.MCPCatalogSeed.upsert!/1` at boot to populate the
  mcp_catalog row's vendor-metadata columns. The `mcp_url`
  (where the vendor's MCP server lives) is operator-set via the
  External Connectors admin page — in production it points at
  Google's official Workspace MCP endpoint; in stage / demo
  the admin pastes the local `Connectors.Mock.VendorMCPServer`
  URL. The seeder never writes mcp_url.
  """
  def mcp_catalog_descriptor do
    %{
      slug:        "google_workspace",
      name:        "Google Workspace",
      description: "Gmail, Calendar, and Drive via the Google MCP server",
      auth_kind:   :oauth,
      categories:  ["productivity", "email", "calendar", "storage"]
    }
  end

  @doc """
  Where the GW MCP server is reachable in *this* deployment.
  DMH-AI hosts the Google Workspace MCP as an in-process REST
  translator (`DmhAi.Connectors.MCPServer`), so we know the URL
  without the admin having to look it up. The FE pre-fills the
  External Connectors form's MCP URL field with this value when
  the row is empty.

  Admin can override the pre-fill (e.g. point at the mock
  `127.0.0.1:8086` during a demo, or Google's official Cloud
  MCP URL when it goes GA); the DB row wins after the first
  Save.
  """
  @spec default_mcp_url() :: String.t()
  def default_mcp_url do
    port = System.get_env("DMH_AI_REAL_MCP_PORT") || "8087"
    "http://127.0.0.1:#{port}/google_workspace"
  end
end
