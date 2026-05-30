# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03SlackTest do
  @moduledoc """
  Integration tests for the Slack connector (Universal Region,
  Case B). Asserts:

    * Manifest passes `Manifest.validate/1` — every write function has
      `callable_from: [:task]` + `idempotency_key: :required`.
    * Connector registers with the Dispatcher (no `manifest_violation`).
    * Vendor-specific error remap: Slack answers HTTP 200 on failure
      with `%{"ok" => false, "error" => "<code>"}`; that shape maps to
      the canonical class (`:duplicate` / `:unauthorised` / etc.).
    * The connector resolves via dispatcher namespace `slack.*`.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Connectors.Slack
  alias DmhAi.Tools.{Dispatcher, Manifest}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  setup do
    Dispatcher.reset()
    :ok = Dispatcher.register(Slack)

    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "sl-#{admin_id}@test.local", "Admin", "x:y", "user",
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
      assert :ok = Manifest.validate(Slack.manifest())
    end

    test "declares 16 functions at the Primitive 0.3 surface" do
      functions = Slack.manifest().functions

      # Original 8
      assert Map.has_key?(functions, "message.send")
      assert Map.has_key?(functions, "message.update")
      assert Map.has_key?(functions, "channel.find")
      assert Map.has_key?(functions, "channel.history")
      assert Map.has_key?(functions, "message.find")
      assert Map.has_key?(functions, "user.find_by_email")
      assert Map.has_key?(functions, "user.list")
      assert Map.has_key?(functions, "reaction.add")

      # +8 from the Slack expansion
      assert Map.has_key?(functions, "channel.create")
      assert Map.has_key?(functions, "channel.invite")
      assert Map.has_key?(functions, "channel.archive")
      assert Map.has_key?(functions, "message.schedule")
      assert Map.has_key?(functions, "message.delete")
      assert Map.has_key?(functions, "file.upload")
      assert Map.has_key?(functions, "pin.add")
      assert Map.has_key?(functions, "user.set_status")

      assert map_size(functions) == 16
    end

    test "every write function is `callable_from: [:task]` (HARD Rule 2)" do
      Slack.manifest().functions
      |> Enum.filter(fn {_, v} -> v.permission == :write end)
      |> Enum.each(fn {name, v} ->
        assert v.callable_from == [:task],
               "function #{name} must be callable_from: [:task] only; got #{inspect(v.callable_from)}"

        assert v.idempotency_key == :required,
               "function #{name} must declare idempotency_key: :required"
      end)
    end

    test "read functions are callable from free chat" do
      reads = Slack.manifest().functions |> Enum.filter(fn {_, v} -> v.permission == :read end)

      assert reads != []

      Enum.each(reads, fn {name, v} ->
        assert :chat in v.callable_from,
               "read function #{name} should be callable_from chat; got #{inspect(v.callable_from)}"
      end)
    end

    test "every function declares at least one OAuth scope" do
      Slack.manifest().functions
      |> Enum.each(fn {name, v} ->
        assert is_list(v.scopes) and v.scopes != [],
               "function #{name} must declare a non-empty scopes list; got #{inspect(v.scopes)}"
      end)
    end

    test "region tag is `universal`" do
      assert Slack.manifest().region == "universal"
    end
  end

  describe "dispatcher registration" do
    test "shows up in the registry" do
      assert "slack" in Dispatcher.connectors()
    end

    test "Connectors.Registry.universal_modules/0 lists Slack" do
      assert Slack in DmhAi.Connectors.Registry.universal_modules()
    end
  end

  describe "error remap (Slack ok:false body — HTTP 200 on failure)" do
    test "already_reacted / name_taken map to :duplicate" do
      assert :duplicate =
               Slack.remap_error(%{"ok" => false, "error" => "already_reacted"})

      assert :duplicate =
               Slack.remap_error(%{"ok" => false, "error" => "name_taken"})
    end

    test "auth error codes map to :unauthorised" do
      for code <- ["not_authed", "invalid_auth", "token_revoked", "account_inactive"] do
        assert :unauthorised =
                 Slack.remap_error(%{"ok" => false, "error" => code}),
               "code #{code} should map to :unauthorised"
      end
    end

    test "not-found / not-in-channel codes map to :not_found" do
      for code <- ["channel_not_found", "user_not_found", "message_not_found", "not_in_channel"] do
        assert :not_found =
                 Slack.remap_error(%{"ok" => false, "error" => code}),
               "code #{code} should map to :not_found"
      end
    end

    test "rate-limit codes map to :rate_limited" do
      assert :rate_limited = Slack.remap_error(%{"ok" => false, "error" => "rate_limited"})
      assert :rate_limited = Slack.remap_error(%{"ok" => false, "error" => "ratelimited"})
    end

    test "an unrecognised ok:false code falls through to :passthrough" do
      assert :passthrough = Slack.remap_error(%{"ok" => false, "error" => "no_text"})
      assert :passthrough = Slack.remap_error(%{"ok" => false})
    end

    test "HTTP-status tuples (transport-level) still classify" do
      assert :unauthorised = Slack.remap_error({:http, 401, "x"})
      assert :unauthorised = Slack.remap_error({:http, 403, "x"})
      assert :not_found    = Slack.remap_error({:http, 404, "x"})
      assert :rate_limited = Slack.remap_error({:http, 429, "x"})
      assert :passthrough  = Slack.remap_error({:http, 500, "boom"})
    end
  end

  describe "dispatcher → Slack end-to-end (stubbed Caller)" do
    setup %{admin_id: admin_id} do
      # Seed an OAuth credential so lookup_credentials returns ok.
      query!(Repo,
        "INSERT INTO user_credentials (user_id, target, account, kind, payload, created_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [admin_id, "oauth:slack", "", "oauth2",
         Jason.encode!(%{"access_token" => "fake-slack-token"}),
         :os.system_time(:millisecond), :os.system_time(:millisecond)])

      :ok
    end

    test "read function (channel.find) from free chat succeeds", %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "slack", "channel.find", args, _creds ->
        assert args["query"] == "beispiel"
        {:ok, %{"channels" => [%{"id" => "C0MOCKCHAN001", "name" => "beispiel-team-demo"}]}}
      end)

      assert {:ok, %{"channels" => [%{"id" => "C0MOCKCHAN001"}]}} =
               Dispatcher.call("slack.channel.find",
                               %{"query" => "beispiel"},
                               %{user_id: admin_id})
    end

    test "write function (message.send) without a caller stub does not silently succeed",
         %{admin_id: admin_id} do
      # No `__mcp_caller_stub__` set: the write threads all dispatcher
      # gates (the admin caller passes the permission + capability
      # checks) and reaches the transport, which has no MCP alias for
      # the slug in the test env. The contract is that it surfaces an
      # error envelope rather than a phantom success.
      assert {:error, %{error: _}} =
               Dispatcher.call("slack.message.send",
                               %{"channel" => "C0MOCKCHAN001", "text" => "hallo"},
                               %{user_id: admin_id})
    end

    test "write function inside an active task carries the injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "slack", "message.send", args, _creds ->
        assert is_binary(args["__idempotency_key"]),
               "writes must carry idempotency_key injected by Dispatcher"
        {:ok, %{"ts" => "1700000000.000999", "channel" => "C0MOCKCHAN001"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-send-msg", step_seq: 0}

      assert {:ok, %{"ts" => "1700000000.000999"}} =
               Dispatcher.call("slack.message.send",
                               %{"channel" => "C0MOCKCHAN001", "text" => "hallo"},
                               ctx)
    end

    test "duplicate reaction (Slack ok:false body) surfaces as canonical :duplicate envelope",
         %{admin_id: admin_id} do
      # The MCPHandler turns Slack's HTTP-200 `{"ok": false, "error":
      # "already_reacted"}` into `{:error, body}`; the dispatcher pipes
      # that body through `Slack.remap_error/1`, which maps the code to
      # the canonical `:duplicate` class. This is the Slack-specific
      # risk — assert the full path here.
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "slack", "reaction.add", _args, _creds ->
        {:error, %{"ok" => false, "error" => "already_reacted"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-react", step_seq: 0}

      assert {:error, %{error: "duplicate"}} =
               Dispatcher.call("slack.reaction.add",
                               %{"channel" => "C0MOCKCHAN001",
                                 "timestamp" => "1700000000.000100",
                                 "name" => "thumbsup"},
                               ctx)
    end

    test "an auth-failure ok:false body surfaces as canonical :unauthorised envelope",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__, fn "slack", "message.send", _args, _creds ->
        {:error, %{"ok" => false, "error" => "invalid_auth"}}
      end)

      ctx = %{user_id: admin_id, task_id: "t-auth", step_seq: 0}

      assert {:error, %{error: "unauthorised"}} =
               Dispatcher.call("slack.message.send",
                               %{"channel" => "C0MOCKCHAN001", "text" => "hallo"},
                               ctx)
    end

    test "write function (channel.create) in-task carries injected idempotency_key",
         %{admin_id: admin_id} do
      Application.put_env(:dmh_ai, :__mcp_caller_stub__,
        fn "slack", "channel.create", args, _creds ->
          assert is_binary(args["__idempotency_key"]),
                 "writes must carry idempotency_key injected by Dispatcher"
          assert args["name"] == "neuer-demo-kanal"
          {:ok, %{"channel_id" => "C0NEWMOCK001"}}
        end)

      ctx = %{user_id: admin_id, task_id: "t-create-chan", step_seq: 0}

      assert {:ok, %{"channel_id" => "C0NEWMOCK001"}} =
               Dispatcher.call("slack.channel.create",
                               %{"name" => "neuer-demo-kanal"},
                               ctx)
    end
  end
end
