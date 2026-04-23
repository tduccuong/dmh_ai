# Integration tests: Police.check_tool_call_schema and nudge escalation plumbing.
# Run with: MIX_ENV=test mix test test/itgr_police_schema.exs
#
# Covers:
#  - schema validation: required-field detection + type mismatch detection
#  - nudge example generation uses tool's own description text (no
#    hardcoded values like "en")
#  - tagged-rejection tuple shape compatibility for downstream counter

defmodule Itgr.PoliceSchema do
  use ExUnit.Case, async: true

  alias Dmhai.Agent.Police

  # ─── Happy path ──────────────────────────────────────────────────────────

  test "passes a well-formed create_task call" do
    args = %{
      "task_title" => "Summarise the doc",
      "task_spec"  => "What is this document about?",
      "task_type"  => "one_off",
      "language"   => "vi"
    }
    assert Police.check_tool_call_schema("create_task", args) == :ok
  end

  # ─── Missing required fields ─────────────────────────────────────────────

  test "rejects create_task when a required field is missing" do
    # Missing task_title.
    args = %{
      "task_spec" => "...",
      "task_type" => "one_off",
      "language"  => "en"
    }

    result = Police.check_tool_call_schema("create_task", args)
    assert {:rejected, {:tool_call_schema, reason}} = result
    assert String.contains?(reason, "task_title")
    assert String.contains?(reason, "missing required")
  end

  test "rejects create_task when a required field is empty-string" do
    args = %{
      "task_title" => "",
      "task_spec"  => "x",
      "task_type"  => "one_off",
      "language"   => "en"
    }

    result = Police.check_tool_call_schema("create_task", args)
    assert {:rejected, {:tool_call_schema, reason}} = result
    assert String.contains?(reason, "task_title")
  end

  # ─── Type mismatches ─────────────────────────────────────────────────────

  test "rejects create_task when intvl_sec is a wrong type" do
    # intvl_sec is declared integer in the schema.
    args = %{
      "task_title" => "x",
      "task_spec"  => "x",
      "task_type"  => "one_off",
      "language"   => "en",
      "intvl_sec"  => ["array", "instead"]
    }

    result = Police.check_tool_call_schema("create_task", args)
    assert {:rejected, {:tool_call_schema, reason}} = result
    assert String.contains?(reason, "intvl_sec")
    assert String.contains?(reason, "integer")
    assert String.contains?(reason, "array")
  end

  test "accepts integer passed as a numeric string (forgiving parse)" do
    args = %{
      "task_title" => "x",
      "task_spec"  => "x",
      "task_type"  => "periodic",
      "language"   => "en",
      "intvl_sec"  => "3600"
    }
    assert Police.check_tool_call_schema("create_task", args) == :ok
  end

  test "rejects wrong type on attachments (not an array)" do
    args = %{
      "task_title"  => "x",
      "task_spec"   => "x",
      "task_type"   => "one_off",
      "language"    => "en",
      "attachments" => "workspace/foo.pdf"  # string instead of [string]
    }

    result = Police.check_tool_call_schema("create_task", args)
    assert {:rejected, {:tool_call_schema, reason}} = result
    assert String.contains?(reason, "attachments")
    assert String.contains?(reason, "array")
  end

  # ─── Nudge quality ───────────────────────────────────────────────────────

  test "nudge example is generic: placeholders, not hardcoded values" do
    args = %{}  # missing everything
    {:rejected, {:tool_call_schema, reason}} = Police.check_tool_call_schema("create_task", args)

    # Placeholders present.
    assert String.contains?(reason, "<string>")
    assert String.contains?(reason, "<integer>")
    # No hardcoded example language or path — must be generic.
    refute String.contains?(reason, ~s("en"))
    refute String.contains?(reason, "workspace/foo.pdf")
    refute String.contains?(reason, "Hop_dong")
  end

  test "nudge renders required/optional markers per field" do
    args = %{}
    {:rejected, {:tool_call_schema, reason}} = Police.check_tool_call_schema("create_task", args)
    assert String.contains?(reason, "(required)")
    assert String.contains?(reason, "(optional)")
  end

  test "nudge includes the tool's own property description as inline comment" do
    args = %{}
    {:rejected, {:tool_call_schema, reason}} = Police.check_tool_call_schema("create_task", args)
    # The description for task_title in CreateTask.definition/0 starts with
    # "Short 2-6 word title". Schema-driven nudge surfaces it verbatim.
    assert String.contains?(reason, "Short 2-6 word title")
  end

  # ─── Other tools — generic behaviour ─────────────────────────────────────

  test "rejects extract_content missing required 'path'" do
    result = Police.check_tool_call_schema("extract_content", %{})
    assert {:rejected, {:tool_call_schema, reason}} = result
    assert String.contains?(reason, "path")
    assert String.contains?(reason, "missing required")
  end

  test "unknown tool name → :ok (different Police check handles that)" do
    # `check_tool_known/1` is responsible for name validity; schema check
    # has nothing to validate against when it can't find a definition.
    assert Police.check_tool_call_schema("no_such_tool", %{}) == :ok
  end

  test "invalid argument types returns :ok (guard clause)" do
    # Defensive: non-map args shouldn't crash the check.
    assert Police.check_tool_call_schema("create_task", nil) == :ok
    assert Police.check_tool_call_schema(123, %{}) == :ok
  end
end
