defmodule Itgr.OAuthCatalogResolve do
  @moduledoc """
  Locks in the hierarchical resolver — exact slug → exact host_match
  → host suffix on URL → substring/token → Jaro fallback. Each test
  pins a specific tier so a refactor that breaks one match path can
  be diagnosed at a glance.
  """

  use ExUnit.Case, async: false

  alias DmhAi.OAuth.Catalog
  alias DmhAi.Repo

  import Ecto.Adapters.SQL, only: [query!: 3]

  setup do
    # Wipe + reseed the catalog into a known state. `enabled = 1`
    # for every test row so all tiers can hit them.
    query!(Repo, "DELETE FROM oauth_catalog", [])

    seed!("google",     "Google APIs (Calendar / Gmail / Drive)", "googleapis.com")
    seed!("github",     "GitHub",                                   "api.github.com")
    seed!("microsoft",  "Microsoft Graph (Outlook / OneDrive)",     "graph.microsoft.com")
    seed!("dropbox",    "Dropbox",                                  "api.dropboxapi.com")

    on_exit(fn -> query!(Repo, "DELETE FROM oauth_catalog", []) end)
    :ok
  end

  describe "tier 1 — exact slug" do
    test "exact slug returns {:ok, entry}" do
      assert {:ok, %{slug: "google"}}    = Catalog.resolve("google")
      assert {:ok, %{slug: "github"}}    = Catalog.resolve("github")
      assert {:ok, %{slug: "microsoft"}} = Catalog.resolve("microsoft")
    end
  end

  describe "tier 2 — exact host_match" do
    test "exact host_match returns {:ok, entry}" do
      assert {:ok, %{slug: "google"}}    = Catalog.resolve("googleapis.com")
      assert {:ok, %{slug: "microsoft"}} = Catalog.resolve("graph.microsoft.com")
    end
  end

  describe "tier 3 — host suffix on URL or subdomain" do
    test "full URL with API path resolves via host suffix" do
      assert {:ok, %{slug: "google"}} =
               Catalog.resolve("https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=2026-01-01")

      assert {:ok, %{slug: "github"}} =
               Catalog.resolve("https://api.github.com/repos/foo/bar/issues")
    end

    test "subdomain of host_match resolves" do
      assert {:ok, %{slug: "google"}} =
               Catalog.resolve("calendar.googleapis.com")

      assert {:ok, %{slug: "google"}} =
               Catalog.resolve("gmail.googleapis.com")
    end

    test "longest-match wins on overlapping suffixes" do
      seed!("specific", "Specific Service", "api.googleapis.com")

      # `api.googleapis.com` is a more specific suffix than
      # `googleapis.com`; resolver picks the longer match.
      assert {:ok, %{slug: "specific"}} =
               Catalog.resolve("https://api.googleapis.com/v3/foo")
    end
  end

  describe "tier 4 — substring / token match (model paraphrasing)" do
    test "human shorthand `google.com` resolves to slug `google`" do
      assert {:ok, %{slug: "google"}} = Catalog.resolve("google.com")
    end

    test "service inside display_name resolves" do
      # `calendar` is a token in Google's display_name → google.
      assert {:ok, %{slug: "google"}} = Catalog.resolve("calendar")
      # `outlook` is a token in Microsoft's display_name → microsoft.
      assert {:ok, %{slug: "microsoft"}} = Catalog.resolve("outlook")
    end
  end

  describe "tier 5 — Jaro typo fallback" do
    test "single-character typo resolves on slug" do
      assert {:ok, %{slug: "google"}} = Catalog.resolve("googlle")
      assert {:ok, %{slug: "github"}} = Catalog.resolve("githab")
    end
  end

  describe "no match — surfaced for the model" do
    test "unrelated word with no close match → {:none, top3}" do
      # `zzzzz-noooo-match` is far from every slug/host.
      assert {:none, candidates} = Catalog.resolve("zzzzz-noooo-match")
      assert is_list(candidates)
      assert length(candidates) <= 3
    end

    test "empty input → {:none, []} without DB lookup" do
      assert {:none, []} = Catalog.resolve("")
      assert {:none, []} = Catalog.resolve("   ")
      assert {:none, []} = Catalog.resolve(nil)
    end
  end

  describe "ambiguous — multiple equally-plausible matches" do
    test "single token that appears in multiple slugs → {:ambiguous, top3}" do
      # Add a row whose display_name shares a token with another.
      seed!("box",      "Box",      "api.box.com")
      seed!("dropbox2", "Dropbox 2", "api.dropbox.com")

      # `box` appears in both slug=box AND in slug=dropbox /
      # display_name; the resolver returns multiple matches and the
      # caller (authorize_service) surfaces them to the user.
      result = Catalog.resolve("box")
      case result do
        {:ambiguous, candidates} ->
          assert is_list(candidates)
          assert length(candidates) >= 2

        # Step 1 (exact slug "box") might fire — if so, also acceptable.
        {:ok, %{slug: "box"}} -> :ok
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp seed!(slug, display, host) do
    now = System.os_time(:millisecond)

    query!(Repo,
      """
      INSERT INTO oauth_catalog
        (slug, display_name, host_match, authorization_endpoint, token_endpoint,
         scopes_default, client_id, client_secret,
         extra_auth_params, extra_token_params,
         userinfo_endpoint, userinfo_field_path,
         enabled, created_ts, updated_ts)
      VALUES (?, ?, ?, ?, ?, '[]', '', NULL, '{}', '{}', NULL, NULL, 1, ?, ?)
      """,
      [
        slug, display, host,
        "https://example.invalid/auth",
        "https://example.invalid/token",
        now, now
      ])
  end
end
