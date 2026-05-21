# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.VectorDB.SourceScope do
  @moduledoc """
  Semantic classification of a KB source. Stored as JSON in
  `kb_sources.source_scope`:

      {"platform": "<connector-slug or null>",
       "category": "<api-docs | sop | policy | workflow | spec | general>"}

  Used by retrieval-time scope filters so a workflow-compile query
  doesn't latch onto third-party SaaS API docs the org has indexed
  for some other purpose.

  ## How sources get classified

  - **URL ingest**: hostname → platform via `from_url/1`. Unknown
    hosts → `platform: nil`. Category defaults to `"api-docs"` for
    known-platform domains, `"general"` otherwise.
  - **File / folder / text ingest**: defaults to
    `{platform: nil, category: "general"}`. Admin can override at
    upsert time via `attrs[:source_scope]`.
  - **Saved workflow class** (Layer W indexer):
    `{platform: "dmh_ai", category: "workflow"}` — always.
  - **DMH-AI specs / SOPs** (operator hand-indexes): tag explicitly
    via `attrs[:source_scope]` at /index time. v1 has no admin UI
    for this; operators set it via the `Ingest.upsert_kb_source/2`
    attrs map.

  NULL in the DB == untagged == implicitly `{platform: nil,
  category: "general"}`. Pre-existing rows from before this column
  was added pass through every filter (they're treated as
  general-purpose org KB).

  ## How retrieval filters

  See `DmhAi.VectorDB.Backend.filter()` — the new `{:org, org_id,
  scope_predicate}` variant lets the caller restrict by platform /
  category. `scope_predicate` is a map:

      %{
        platforms_in:     [<slug> | nil, ...],   # whitelist (matches given platforms)
        platforms_not_in: [<slug>, ...],         # blacklist (excludes these)
        categories_in:    ["sop", ...],          # whitelist categories
        include_untagged: true | false           # default true — untagged rows always pass
      }

  Empty / missing keys are no-ops; only stated constraints apply.
  """

  # ── Authoritative platform list ──────────────────────────────────────
  # Maps hostname patterns to the connector slug we use everywhere
  # else. Adding a new connector vertical = one new row here. The
  # left side is a String pattern (`String.contains?/2` substring
  # match against `host`); the right is the slug.
  @host_to_platform [
    # Google Workspace
    {"googleapis.com",         "google_workspace"},
    {"google.com",             "google_workspace"},
    {"workspace.google.com",   "google_workspace"},

    # Microsoft 365
    {"microsoft.com",          "m365"},
    {"microsoftonline.com",    "m365"},
    {"graph.microsoft.com",    "m365"},
    {"office.com",             "m365"},
    {"sharepoint.com",         "m365"},

    # HubSpot
    {"hubspot.com",            "hubspot"},
    {"hubapi.com",             "hubspot"},

    # Calendly
    {"calendly.com",           "calendly"},

    # Stripe
    {"stripe.com",             "stripe"},

    # Other prominent SaaS we've seen leak into the KB (Bitrix24
    # was the one that flagged this whole bug class). Adding them
    # here as "known third-party platforms" lets the operator
    # exclude them from compile-mode scope without needing to
    # delete the indexed docs.
    {"bitrix24.com",           "bitrix24"},
    {"bitrix24.de",            "bitrix24"},
    {"salesforce.com",         "salesforce"},
    {"force.com",              "salesforce"},
    {"shopify.com",            "shopify"},
    {"myshopify.com",          "shopify"},
    {"slack.com",              "slack"},
    {"zoom.us",                "zoom"},
    {"docusign.com",           "docusign"},
    {"klaviyo.com",            "klaviyo"},
    {"atlassian.com",          "atlassian"},
    {"atlassian.net",          "atlassian"},
    {"asana.com",              "asana"},
    {"notion.so",              "notion"},
    {"notion.com",             "notion"},
    {"brevo.com",              "brevo"},
    {"sendinblue.com",         "brevo"}
  ]

  # Same shape as `@host_to_platform`, but matched against
  # `github.com`-hosted URLs by their org segment (the first path
  # component after the leading slash). Lets us classify mirror /
  # documentation repos (e.g. `github.com/bitrix24/b24restdocs`) as
  # belonging to the upstream platform even though the host is GitHub.
  @github_org_to_platform [
    {"bitrix24",  "bitrix24"},
    {"hubspot",   "hubspot"},
    {"salesforce", "salesforce"},
    {"shopify",   "shopify"},
    {"slackapi",  "slack"},
    {"zoom",      "zoom"},
    {"docusign",  "docusign"},
    {"klaviyo",   "klaviyo"},
    {"atlassian", "atlassian"},
    {"asana",     "asana"},
    {"makenotion","notion"},
    {"sendinblue","brevo"},
    {"calendly",  "calendly"},
    {"stripe",    "stripe"},
    {"microsoftgraph", "m365"},
    {"microsoft", "m365"},
    {"googleworkspace", "google_workspace"},
    {"googleapis", "google_workspace"}
  ]

  @doc """
  Derive a scope from a URL (or any source-identifying string). Returns
  the JSON-encoded scope ready to store in `kb_sources.source_scope`,
  or `nil` for unknown / non-URL inputs (the caller stores NULL).

      iex> SourceScope.from_url("https://helpdesk.bitrix24.com/.../workflow.html")
      ~s({"platform":"bitrix24","category":"api-docs"})

      iex> SourceScope.from_url("https://acme.com/handbook.pdf")
      nil  # unknown host → leave NULL → counts as untagged/general
  """
  @spec from_url(String.t()) :: String.t() | nil
  def from_url(url) when is_binary(url) do
    parsed = URI.parse(url)

    cond do
      not is_binary(parsed.host) or parsed.host == "" ->
        nil

      true ->
        host = String.downcase(parsed.host)

        case match_platform(host) do
          slug when is_binary(slug) ->
            encode(slug, "api-docs")

          nil ->
            # GitHub-hosted docs repos: classify by org segment.
            case github_org_from_path(host, parsed.path) do
              nil  -> nil
              slug -> encode(slug, "api-docs")
            end
        end
    end
  end

  def from_url(_), do: nil

  # Pull the first path segment of a github.com URL and match it
  # against the github-org-to-platform table.
  defp github_org_from_path("github.com", "/" <> rest) when is_binary(rest) do
    org =
      rest
      |> String.split("/", parts: 2)
      |> List.first()
      |> case do
        s when is_binary(s) -> String.downcase(s)
        _                    -> nil
      end

    if is_binary(org) do
      Enum.find_value(@github_org_to_platform, fn {pattern, slug} ->
        if org == pattern, do: slug, else: nil
      end)
    else
      nil
    end
  end

  defp github_org_from_path(_host, _path), do: nil

  @doc """
  Build an explicit scope JSON string. Used by callers that want to
  tag a non-URL source (file/folder/text) or override the
  URL-derived default.
  """
  @spec encode(String.t() | nil, String.t()) :: String.t()
  def encode(platform, category) when is_binary(category) do
    Jason.encode!(%{
      "platform" => platform,
      "category" => category
    })
  end

  @doc """
  Parse a stored scope blob back to the map. Returns
  `%{"platform" => slug | nil, "category" => category}` on success,
  `nil` on parse failure or `nil` input.
  """
  @spec decode(String.t() | nil) :: map() | nil
  def decode(nil), do: nil
  def decode(""),  do: nil

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = m} -> m
      _ -> nil
    end
  end

  def decode(_), do: nil

  # ── private ──────────────────────────────────────────────────────────

  defp match_platform(host) do
    Enum.find_value(@host_to_platform, fn {pattern, slug} ->
      if String.contains?(host, pattern), do: slug, else: nil
    end)
  end

  @doc """
  Default category by source_kind. Used when no explicit category
  is supplied AND the URL-host derivation didn't fire.
  """
  @spec default_category(String.t()) :: String.t()
  def default_category("url"),    do: "general"
  def default_category("file"),   do: "general"
  def default_category("folder"), do: "general"
  def default_category("text"),   do: "general"
  def default_category(_),        do: "general"

  @doc """
  Every distinct third-party platform slug this module knows about.
  Used by runtime scope-filter helpers (e.g. compile-mode auto-fetch
  excludes all third-party SaaS API docs). The list is derived from
  the `@host_to_platform` table — adding a new SaaS = one new entry
  there propagates here automatically.
  """
  @spec third_party_platforms() :: [String.t()]
  def third_party_platforms do
    @host_to_platform
    |> Enum.map(fn {_host, slug} -> slug end)
    |> Enum.uniq()
  end

  @doc """
  Scope predicate for **compile-mode auto-fetch**: exclude all
  third-party platforms, include untagged + DMH-AI-tagged content.
  Workflow compilation should only reach for the org's own SOPs /
  policies / saved workflows / DMH-AI internal docs — NOT for
  third-party SaaS API documentation that happens to mention the
  word "workflow".
  """
  @spec compile_mode_predicate() :: map()
  def compile_mode_predicate do
    %{platforms_not_in: third_party_platforms(), include_untagged: true}
  end
end
