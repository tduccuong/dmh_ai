# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03CalendlyTest do
  @moduledoc """
  Integration tests for the Calendly connector (Universal Region,
  Case A — DMH-AI hosts the MCP server in-process). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific HTTP status remap (401 / 403 / 404 / 429 / pass).
    * OAuth catalog descriptor exports the expected vendor endpoints.
    * The connector resolves via dispatcher namespace `calendly.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Calendly
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Calendly)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "cal-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    on_exit(fn ->
      Application.delete_env(:dmh_ai, :__mcp_caller_stub__)
      query!(Repo, "DELETE FROM user_credentials WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "manifest" do
    test "validates clean" do
      assert :ok = Manifest.validate(Calendly.manifest())
    end

    test "declares 8 functions at the Primitive 0.3 surface" do
      functions = Calendly.manifest().functions

      assert Map.has_key?(functions, "user.me")
      assert Map.has_key?(functions, "event_type.list")
      assert Map.has_key?(functions, "event_type.available_slots")
      assert Map.has_key?(functions, "event.list")
      assert Map.has_key?(functions, "event.invitees")
      assert Map.has_key?(functions, "single_use_link.create")
      assert Map.has_key?(functions, "event.cancel")
      assert Map.has_key?(functions, "event.mark_no_show")
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Calendly.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "region tag is `universal`" do
      assert Calendly.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "calendly" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Calendly" do
      assert Calendly in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "capabilities" do
    test "three groups go live (available), eight visible as planned" do
      caps = Calendly.capabilities()

      live = Enum.filter(caps, fn c -> Map.get(c, :status, :available) == :available end)
      planned = Enum.filter(caps, fn c -> Map.get(c, :status) == :planned end)

      assert length(live) == 3
      assert length(planned) == 8

      live_ids = Enum.map(live, & &1.id) |> Enum.sort()
      assert live_ids == ["meetings", "scheduling_links", "user"]
    end

    test "every available capability lists at least one function" do
      Calendly.capabilities()
      |> Enum.filter(fn c -> Map.get(c, :status, :available) == :available end)
      |> Enum.each(fn c ->
        assert is_list(c.functions) and c.functions != [],
               "capability #{c.id} is :available but has no functions"
      end)
    end

    test "every planned capability has functions: [] (placeholder shape)" do
      Calendly.capabilities()
      |> Enum.filter(fn c -> Map.get(c, :status) == :planned end)
      |> Enum.each(fn c ->
        assert c.functions == [],
               "planned capability #{c.id} unexpectedly carries functions: #{inspect(c.functions)}"
      end)
    end
  end

  describe "error remap" do
    test "HTTP 401/403 maps to :unauthorised" do
      assert :unauthorised = Calendly.remap_error({:http, 401, ""})
      assert :unauthorised = Calendly.remap_error({:http, 403, ""})
    end

    test "HTTP 404 maps to :not_found" do
      assert :not_found = Calendly.remap_error({:http, 404, ""})
    end

    test "HTTP 429 maps to :rate_limited" do
      assert :rate_limited = Calendly.remap_error({:http, 429, ""})
    end

    test "unrelated errors fall through to :passthrough" do
      assert :passthrough = Calendly.remap_error({:http, 500, "boom"})
      assert :passthrough = Calendly.remap_error({:other, :weird})
    end
  end

  describe "oauth catalog descriptor" do
    test "exports Calendly OAuth endpoints + the granular v2 scopes the live capabilities need" do
      d = Calendly.oauth_catalog_descriptor()

      assert d.slug == "calendly"
      assert d.authorization_endpoint == "https://auth.calendly.com/oauth/authorize"
      assert d.token_endpoint == "https://auth.calendly.com/oauth/token"
      assert "users:read"             in d.scopes
      assert "event_types:read"       in d.scopes
      assert "availability:read"      in d.scopes
      assert "scheduling_links:write" in d.scopes
      assert "scheduled_events:read"  in d.scopes
      assert "scheduled_events:write" in d.scopes
      refute "default" in d.scopes,
             "the literal `default` scope is a docs shorthand, not what Calendly's token response returns"
      assert d.userinfo_endpoint == "https://api.calendly.com/users/me"
      assert d.userinfo_field_path == "resource.email"
    end
  end

  describe "dispatcher → Calendly end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:calendly", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-calendly-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (event.list) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "calendly", "event.list", _args, _creds ->
        {:ok, %{"events" => [%{"uri" => "https://api.calendly.com/scheduled_events/e-1"}]}}
      end)

      assert {:ok, %{"events" => [%{"uri" => uri}]}} =
               Dispatcher.call("calendly.event.list",
                               %{"min_start_time" => "2026-05-20T00:00:00Z"},
                               %{user_id: admin_id})

      assert uri =~ "scheduled_events"
    end

    test "write function (single_use_link.create) outside an active task is refused",
         %{admin_id: admin_id} do
      assert {:error, %{error: "write_requires_task", function: "calendly.single_use_link.create"}} =
               Dispatcher.call("calendly.single_use_link.create",
                               %{"event_type_uri" => "https://api.calendly.com/event_types/et-1"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "calendly", "single_use_link.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"booking_url" => "https://calendly.com/d/abc"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-single-link", step_seq: 0}

      assert {:ok, %{"booking_url" => "https://calendly.com/d/abc"}} =
               Dispatcher.call("calendly.single_use_link.create",
                               %{"event_type_uri" => "https://api.calendly.com/event_types/et-1"},
                               ctx)
    end

    test "404 on cancel surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "calendly", "event.cancel", _args, _creds ->
        {:error, {:http, 404, ~s({"title":"Resource Not Found"})}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-cancel", step_seq: 0}

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("calendly.event.cancel",
                               %{"event_uri" => "https://api.calendly.com/scheduled_events/deleted"},
                               ctx)
    end
  end
end
