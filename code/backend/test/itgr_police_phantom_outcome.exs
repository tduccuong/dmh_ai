# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.PolicePhantomOutcomeTest do
  @moduledoc """
  Pins the phantom-outcome guard + the outcome-write split.

  Regression: a successful `connect_mcp` (write-class) once masked a
  chain whose every `upsert_workflow` failed — the guard pooled all
  write-class tools, saw `failures < attempts`, and waved a fabricated
  "I built the workflow" reply through. The outcome tally excludes
  setup/connection writes so only user-requested outcomes count.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Agent.Police

  describe "check_no_phantom_outcome/2 (outcome tally)" do
    test "no outcome-write attempted → passes (read-only chain)" do
      assert :ok = Police.check_no_phantom_outcome(0, 0)
    end

    test "at least one outcome-write landed → passes" do
      assert :ok = Police.check_no_phantom_outcome(2, 1)
    end

    test "every outcome-write errored → rejected, with blocker-type routing" do
      assert {:rejected, {:phantom_outcome, msg}} =
               Police.check_no_phantom_outcome(2, 2)

      assert msg =~ "errored"
      # Routes the remedy by blocker type: a capability gap must be
      # surfaced as plain text, not bounced back as a request_input form.
      assert msg =~ "plain text"
      assert msg =~ "request_input"
    end

    test "single failed outcome-write → rejected" do
      assert {:rejected, {:phantom_outcome, _}} =
               Police.check_no_phantom_outcome(1, 1)
    end
  end

  describe "outcome_write?/1 vs write_class?/1" do
    test "connect_mcp is write-class (budget) but NOT an outcome-write" do
      assert Police.write_class?("connect_mcp")
      refute Police.outcome_write?("connect_mcp")
    end

    test "upsert_workflow is both write-class and an outcome-write" do
      assert Police.write_class?("upsert_workflow")
      assert Police.outcome_write?("upsert_workflow")
    end

    test "a read tool is neither" do
      refute Police.write_class?("fetch_index")
      refute Police.outcome_write?("fetch_index")
    end

    test "nil / unknown tool → neither" do
      refute Police.outcome_write?(nil)
      refute Police.outcome_write?("definitely_not_a_tool")
    end
  end
end
