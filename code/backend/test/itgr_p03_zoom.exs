# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03ZoomTest do
  @moduledoc """
  Integration tests for the Zoom connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: Zoom answers normal HTTP status codes
      with a JSON body `%{"code" => <int>, "message" => ...}`; the
      numeric code maps to the canonical class (`:unauthorised` /
      `:not_found` / etc.).
    * The connector resolves via dispatcher namespace `zoom.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Zoom
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Zoom)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "zm-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Zoom.manifest())
    end

    test "declares 17 functions at the Primitive 0.3 surface" do
      functions = Zoom.manifest().functions

      # Original 8
      assert Map.has_key?(functions, "meeting.create")
      assert Map.has_key?(functions, "meeting.find")
      assert Map.has_key?(functions, "meeting.get")
      assert Map.has_key?(functions, "meeting.update")
      assert Map.has_key?(functions, "meeting.delete")
      assert Map.has_key?(functions, "recording.find")
      assert Map.has_key?(functions, "user.find")
      assert Map.has_key?(functions, "webinar.create")

      # +8 from the Zoom expansion
      assert Map.has_key?(functions, "meeting.list_registrants")
      assert Map.has_key?(functions, "meeting.add_registrant")
      assert Map.has_key?(functions, "meeting.list_participants")
      assert Map.has_key?(functions, "recording.get")
      assert Map.has_key?(functions, "recording.delete")
      assert Map.has_key?(functions, "webinar.find")
      assert Map.has_key?(functions, "webinar.add_registrant")
      assert Map.has_key?(functions, "webinar.update")

      # +1 identity pivot
      assert Map.has_key?(functions, "user.find_by_email")

      assert map_size(functions) == 17
    end

    test "identity_lookup pivots Zoom user lookup to the user id" do
      assert %{function: "zoom.user.find_by_email",
               by_arg: :email,
               emit_field: "id"} = Zoom.identity_lookup()
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Zoom.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = Zoom.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares at least one OAuth scope" do
      Zoom.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert is_list(v.scopes) and v.scopes != [],
               "function #{name} must declare a non-empty scopes list; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Zoom.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "zoom" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Zoom" do
      assert Zoom in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap (Zoom numeric code body — normal HTTP status)" do
    test "code 124 (invalid access token) maps to :unauthorised" do
      assert :unauthorised = Zoom.remap_error(%{"code" => 124})
    end

    test "code 1001 (user not found) maps to :not_found" do
      assert :not_found = Zoom.remap_error(%{"code" => 1001})
    end

    test "code 3001 (meeting not found) maps to :not_found" do
      assert :not_found = Zoom.remap_error(%{"code" => 3001})
    end

    test "an unrecognised numeric code falls through to :passthrough" do
      assert :passthrough = Zoom.remap_error(%{"code" => 300})
      assert :passthrough = Zoom.remap_error(%{"code" => 9999})
    end

    test "HTTP-status tuples (transport-level) still classify" do
      assert :unauthorised = Zoom.remap_error({:http, 401, "x"})
      assert :unauthorised = Zoom.remap_error({:http, 403, "x"})
      assert :not_found    = Zoom.remap_error({:http, 404, "x"})
      assert :rate_limited = Zoom.remap_error({:http, 429, "x"})
      assert :passthrough  = Zoom.remap_error({:http, 500, "boom"})
    end
  end

  describe "dispatcher → Zoom end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:zoom", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-zoom-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (meeting.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "zoom", "meeting.find", args, _creds ->
        assert args["limit"] == 5
        {:ok, %{"meetings" => [%{"id" => "99MOCKMTG0001", "topic" => "Beispiel-Besprechung Demo"}]}}
      end)

      assert {:ok, %{"meetings" => [%{"id" => "99MOCKMTG0001"}]}} =
               Dispatcher.call("zoom.meeting.find",
                               %{"limit" => 5},
                               %{user_id: admin_id})
    end

    test "write function (meeting.create) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("zoom.meeting.create",
                               %{"topic" => "Demo"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "zoom", "meeting.create", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"meeting_id" => "99MOCKMTG0001", "join_url" => "https://zoom.us/j/99MOCKMTG0001"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-create-mtg", step_seq: 0}

      assert {:ok, %{"meeting_id" => "99MOCKMTG0001"}} =
               Dispatcher.call("zoom.meeting.create",
                               %{"topic" => "Demo"},
                               ctx)
    end

    test "a not-found numeric-code body surfaces as canonical :not_found envelope",
         %{admin_id: admin_id} do
      # The MCPHandler surfaces Zoom's 4xx `{"code": 3001, ...}` body as
      # `{:error, body}`; the dispatcher pipes that body through
      # `Zoom.remap_error/1`, which maps the numeric code to the
      # canonical `:not_found` class. This is the Zoom-specific risk —
      # assert the full path here.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "zoom", "meeting.get", _args, _creds ->
        {:error, %{"code" => 3001, "message" => "Meeting does not exist."}}
      end)

      assert {:error, %{error: "not_found"}} =
               Dispatcher.call("zoom.meeting.get",
                               %{"meeting_id" => "99MOCKMTG0001"},
                               %{user_id: admin_id})
    end

    test "an auth-failure numeric-code body surfaces as canonical :unauthorised envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "zoom", "meeting.create", _args, _creds ->
        {:error, %{"code" => 124, "message" => "Invalid access token."}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-auth", step_seq: 0}

      assert {:error, %{error: "unauthorised"}} =
               Dispatcher.call("zoom.meeting.create",
                               %{"topic" => "Demo"},
                               ctx)
    end

    test "read function (recording.get) from free chat returns the recording map",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "zoom", "recording.get", args, _creds ->
          assert args["meeting_id"] == "99MOCKMTG0001"

          {:ok,
           %{
             "recording" => %{
               "id"              => "99MOCKMTG0001",
               "topic"           => "Beispiel-Besprechung Demo",
               "recording_count" => 1,
               "recording_files" => [
                 %{
                   "id"           => "MOCKREC0001",
                   "file_type"    => "MP4",
                   "download_url" => "https://zoom.us/rec/download/MOCKREC0001"
                 }
               ]
             }
           }}
        end)

      assert {:ok, %{"recording" => %{"id" => "99MOCKMTG0001"}}} =
               Dispatcher.call("zoom.recording.get",
                               %{"meeting_id" => "99MOCKMTG0001"},
                               %{user_id: admin_id})
    end

    test "write function (webinar.add_registrant) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "zoom", "webinar.add_registrant", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["webinar_id"] == "88MOCKWEB0001"
          assert args["email"]      == "klara.beispiel@beispiel-team-demo.example"
          assert args["first_name"] == "Klara"

          {:ok,
           %{
             "registrant_id" => "MOCKREG0001",
             "join_url"      => "https://zoom.us/webinar/register/confirm/88MOCKWEB0001"
           }}
        end)

      ctx = %{user_id: admin_id, task_id: "t-add-webreg", step_seq: 0}

      assert {:ok, %{"registrant_id" => "MOCKREG0001"}} =
               Dispatcher.call("zoom.webinar.add_registrant",
                               %{
                                 "webinar_id" => "88MOCKWEB0001",
                                 "email"      => "klara.beispiel@beispiel-team-demo.example",
                                 "first_name" => "Klara"
                               },
                               ctx)
    end
  end
end
