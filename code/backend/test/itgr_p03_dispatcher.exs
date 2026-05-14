# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P03DispatcherTest do
  @moduledoc """
  Integration tests for Primitive 0.3's Dispatcher + Manifest contract.

  Covers: manifest validation (4 rules), registration table, dispatch
  branching (chat vs task, permission check, idempotency injection).
  Uses a stub connector module so the test doesn't depend on any
  real Case-B vendor MCP.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Repo
  alias DmhAi.Tools.{Dispatcher, Manifest}
  alias DmhAi.Tools.Manifest.Verb
  import Ecto.Adapters.SQL, only: [query!: 3]

  @org_id DmhAi.Constants.default_org_id()

  # ─── Stub connector modules ──────────────────────────────────────────────

  defmodule GoodStub do
    alias DmhAi.Tools.Manifest
    alias DmhAi.Tools.Manifest.Verb

    def manifest do
      %Manifest{
        connector: "stub",
        region:    "test",
        verbs: %{
          "read_thing" => %Verb{
            permission:    :read,
            callable_from: [:chat, :task],
            args:          %{"q" => %{type: :string, required: true}}
          },
          "write_thing" => %Verb{
            permission:      :write,
            callable_from:   [:task],
            idempotency_key: :required,
            args:            %{"value" => %{type: :string, required: true}}
          }
        }
      }
    end

    # The dispatcher calls module.call/3 once the gates pass. Echo
    # back via `:test_observer_pid` set in the test's setup so the
    # test can assert what the dispatcher forwarded (e.g.
    # idempotency_key injected on writes).
    def call(verb_path, args, _ctx) do
      case Process.get(:test_observer_pid) do
        pid when is_pid(pid) -> send(pid, {:stub_called, verb_path, args})
        _ -> :noop
      end

      {:ok, %{verb: verb_path, args: args}}
    end
  end

  defmodule MissingCallableFromForWriteStub do
    alias DmhAi.Tools.Manifest
    alias DmhAi.Tools.Manifest.Verb

    def manifest do
      %Manifest{
        connector: "broken_a",
        region:    "test",
        verbs: %{
          "bad_write" => %Verb{
            permission:    :write,
            callable_from: [:chat, :task],   # violates HARD rule
            idempotency_key: :required
          }
        }
      }
    end

    def call(_, _, _), do: {:ok, %{}}
  end

  defmodule MissingIdempotencyForWriteStub do
    alias DmhAi.Tools.Manifest
    alias DmhAi.Tools.Manifest.Verb

    def manifest do
      %Manifest{
        connector: "broken_b",
        region:    "test",
        verbs: %{
          "bad_write" => %Verb{
            permission:    :write,
            callable_from: [:task]
            # idempotency_key defaults to :none → violates Rule 3
          }
        }
      }
    end

    def call(_, _, _), do: {:ok, %{}}
  end

  # ─── Setup ───────────────────────────────────────────────────────────────

  setup do
    Dispatcher.reset()
    # The stub `call/3` reads this from the calling process's dict
    # to know where to forward observation messages. Each test's
    # process dict is isolated, so no leakage across tests.
    Process.put(:test_observer_pid, self())

    # An admin user in the default org for permission checks.
    admin_id = T.uid()
    query!(Repo,
      "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [admin_id, "admin-#{admin_id}@test.local", "Admin", "x:y", "user",
       @org_id, "admin", :os.system_time(:second)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM users WHERE id=?", [admin_id])
      query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [admin_id])
    end)

    {:ok, %{admin_id: admin_id}}
  end

  describe "Manifest.validate/1" do
    test "good manifest passes" do
      assert :ok = Manifest.validate(GoodStub.manifest())
    end

    test "write verb without callable_from: [:task] fails (Rule 2 HARD)" do
      assert {:error, {:manifest_violation, "broken_a", reason}} =
               Manifest.validate(MissingCallableFromForWriteStub.manifest())

      assert reason =~ "write verb must declare `callable_from: [:task]`"
    end

    test "write verb without idempotency_key fails (Rule 3)" do
      assert {:error, {:manifest_violation, "broken_b", reason}} =
               Manifest.validate(MissingIdempotencyForWriteStub.manifest())

      assert reason =~ "idempotency_key"
    end
  end

  describe "Dispatcher.register/1" do
    test "good module registers" do
      assert :ok = Dispatcher.register(GoodStub)
      assert "stub" in Dispatcher.connectors()
    end

    test "violating manifest is rejected, not registered" do
      assert {:error, _} = Dispatcher.register(MissingCallableFromForWriteStub)
      refute "broken_a" in Dispatcher.connectors()
    end
  end

  describe "Dispatcher.call/3 — read verb (Rule 1, free chat)" do
    setup do
      :ok = Dispatcher.register(GoodStub)
      :ok
    end

    test "callable from chat (no task) — succeeds", %{admin_id: admin_id} do
      ctx = %{user_id: admin_id}

      assert {:ok, %{verb: "read_thing", args: %{"q" => "hello"}}} =
               Dispatcher.call("stub.read_thing", %{"q" => "hello"}, ctx)

      assert_received {:stub_called, "read_thing", %{"q" => "hello"}}
    end
  end

  describe "Dispatcher.call/3 — write verb (Rule 2 HARD)" do
    setup do
      :ok = Dispatcher.register(GoodStub)
      :ok
    end

    test "write from free chat (no task) → write_requires_task envelope", %{admin_id: admin_id} do
      ctx = %{user_id: admin_id}

      assert {:error, %{error: "write_requires_task", verb: "stub.write_thing"}} =
               Dispatcher.call("stub.write_thing", %{"value" => "x"}, ctx)

      refute_received {:stub_called, _, _}
    end

    test "write inside active task → idempotency_key injected → succeeds", %{admin_id: admin_id} do
      ctx = %{user_id: admin_id, task_id: "task-abc", step_seq: 3}

      assert {:ok, %{verb: "write_thing", args: args}} =
               Dispatcher.call("stub.write_thing", %{"value" => "x"}, ctx)

      assert is_binary(args["__idempotency_key"]),
             "idempotency_key must be injected on write inside active task"

      # Same (task_id, step_seq, verb) → deterministic key
      assert_received {:stub_called, "write_thing", call_args}
      assert call_args["__idempotency_key"] == args["__idempotency_key"]
    end
  end

  describe "Dispatcher.call/3 — unknown verb / connector" do
    setup do
      :ok = Dispatcher.register(GoodStub)
      :ok
    end

    test "unknown connector → connector_not_registered", %{admin_id: admin_id} do
      assert {:error, %{error: "connector_not_registered", connector: "nope"}} =
               Dispatcher.call("nope.something", %{}, %{user_id: admin_id})
    end

    test "unknown verb within registered connector → unknown_verb", %{admin_id: admin_id} do
      assert {:error, %{error: "unknown_verb", verb: "ghost"}} =
               Dispatcher.call("stub.ghost", %{}, %{user_id: admin_id})
    end

    test "malformed verb (no dot) → unknown_verb", %{admin_id: admin_id} do
      assert {:error, %{error: "unknown_verb"}} =
               Dispatcher.call("bareverb", %{}, %{user_id: admin_id})
    end
  end

  describe "Dispatcher.call/3 — Rule 1 permission" do
    setup %{admin_id: _admin_id} do
      :ok = Dispatcher.register(GoodStub)

      member_id = T.uid()
      query!(Repo,
        "INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [member_id, "member-#{member_id}@test.local", "Member", "x:y", "user",
         @org_id, "member", :os.system_time(:second)])

      on_exit(fn ->
        query!(Repo, "DELETE FROM users WHERE id=?", [member_id])
        query!(Repo, "DELETE FROM audit_log WHERE user_id=?", [member_id])
      end)

      {:ok, %{member_id: member_id}}
    end

    test "member can call a :read verb", %{member_id: member_id} do
      assert {:ok, _} = Dispatcher.call("stub.read_thing", %{"q" => "x"},
                                        %{user_id: member_id})
    end

    test "member can call a :write verb inside a task (members have :write by default)",
         %{member_id: member_id} do
      assert {:ok, _} =
               Dispatcher.call("stub.write_thing", %{"value" => "x"},
                               %{user_id: member_id, task_id: "t1", step_seq: 0})
    end
  end
end
