# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.PoliceWorkflowBuildContinuityTest do
  @moduledoc """
  Pins `Police.check_workflow_build_continuity/2`. The gate blocks
  external connector dispatches that follow a failed / incomplete
  `upsert_workflow` — the safety net for the "small model lost the
  workflow-build context after `request_input` and ran the real
  action instead of baking the value into the IR" failure mode.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Agent.Police

  describe "fires on connector function after a failed upsert" do
    test "rejects connector dispatch when last upsert_workflow result was an error" do
      prior = [
        %{role: "assistant", tool_calls: [%{"function" => %{"name" => "upsert_workflow"}}]},
        %{role: "tool", name: "upsert_workflow",
          content: "upsert_workflow: node 1 required arg `amount` has a placeholder-shaped value 0…"}
      ]

      assert {:rejected, {:workflow_build_continuity, msg}} =
               Police.check_workflow_build_continuity("hubspot.deal.create", prior)

      assert msg =~ "started a workflow build"
      assert msg =~ "re-call `upsert_workflow`"
    end

    test "rejects after request_input followed an upsert attempt" do
      prior = [
        %{role: "assistant", tool_calls: [%{"function" => %{"name" => "upsert_workflow"}}]},
        %{role: "tool", name: "upsert_workflow",
          content: "upsert_workflow: required arg `amount` has placeholder value"},
        %{role: "assistant", tool_calls: [%{"function" => %{"name" => "request_input"}}]},
        %{role: "user", content: "[input submitted via request_input form]\namount: 100"}
      ]

      assert {:rejected, _} =
               Police.check_workflow_build_continuity("hubspot.deal.create", prior)
    end
  end

  describe "allows connector dispatch when not in build mode" do
    test "no upsert_workflow in history → connector call passes" do
      prior = [
        %{role: "user",      content: "find the hubspot contact for alice"},
        %{role: "assistant", tool_calls: [%{"function" => %{"name" => "connect_mcp"}}]},
        %{role: "tool",      name: "connect_mcp", content: ~s({"status":"connected"})}
      ]

      assert :ok = Police.check_workflow_build_continuity("hubspot.contact.find", prior)
    end

    test "upsert_workflow succeeded (saved IR) → subsequent connector call passes" do
      prior = [
        %{role: "assistant", tool_calls: [%{"function" => %{"name" => "upsert_workflow"}}]},
        %{role: "tool", name: "upsert_workflow",
          content: ~s({"name":"workflow_xyz","version":0,"url":"/workflows/workflow_xyz/0","display_name":"X"})}
      ]

      assert :ok = Police.check_workflow_build_continuity("hubspot.deal.create", prior)
    end
  end

  describe "skips for non-connector tools" do
    test "internal tools pass through regardless of prior upsert state" do
      prior = [
        %{role: "tool", name: "upsert_workflow",
          content: "upsert_workflow: rejected (placeholder)"}
      ]

      assert :ok = Police.check_workflow_build_continuity("create_task",        prior)
      assert :ok = Police.check_workflow_build_continuity("upsert_workflow",    prior)
      assert :ok = Police.check_workflow_build_continuity("inspect_function",   prior)
      assert :ok = Police.check_workflow_build_continuity("request_input",      prior)
      assert :ok = Police.check_workflow_build_continuity("read_workflow",      prior)
      assert :ok = Police.check_workflow_build_continuity("connect_mcp",        prior)
    end

    test "unknown slug → not treated as connector function → passes" do
      prior = [
        %{role: "tool", name: "upsert_workflow", content: "upsert_workflow: error"}
      ]

      assert :ok = Police.check_workflow_build_continuity("nonexistent.thing", prior)
    end
  end
end
