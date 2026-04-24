# Integration tests: ModelBehaviorStats counter upsert + list + gating.
# Run with: MIX_ENV=test mix test test/itgr_model_behavior_stats.exs

defmodule Itgr.ModelBehaviorStats do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.ModelBehaviorStats
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Writes the `modelBehaviorTelemetryEnabled` flag into admin settings
  # so we can toggle telemetry per-test. Restored in on_exit.
  defp set_telemetry(enabled) do
    prev =
      case query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"]) do
        %{rows: [[v]]} -> Jason.decode!(v || "{}")
        _              -> %{}
      end

    next = Map.put(prev, "modelBehaviorTelemetryEnabled", enabled)

    query!(Repo,
      "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      ["admin_cloud_settings", Jason.encode!(next)])

    on_exit(fn ->
      query!(Repo,
        "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        ["admin_cloud_settings", Jason.encode!(prev)])
    end)
  end

  defp fetch_row(role, model, issue_type, tool_name) do
    r = query!(Repo, """
    SELECT count, first_seen_at, last_seen_at
    FROM model_behavior_stats
    WHERE role=? AND model=? AND issue_type=? AND tool_name=?
    """, [role, model, issue_type, tool_name])

    case r.rows do
      [[count, first, last]] -> %{count: count, first_seen_at: first, last_seen_at: last}
      _ -> nil
    end
  end

  # ─── Fresh upsert ────────────────────────────────────────────────────────

  test "record/4 inserts a fresh row with count=1 and both timestamps" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::gpt-oss:120b-cloud-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "tool_call_schema", "create_task")

    row = fetch_row(role, model, "tool_call_schema", "create_task")
    assert row != nil
    assert row.count == 1
    assert is_integer(row.first_seen_at) and row.first_seen_at > 0
    assert row.last_seen_at == row.first_seen_at
  end

  # ─── Repeated upsert ─────────────────────────────────────────────────────

  test "record/4 increments count on same key and preserves first_seen_at" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::nemotron-3-nano:30b-cloud-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "task_discipline", "web_search")

    row1 = fetch_row(role, model, "task_discipline", "web_search")

    # Ensure a visible time delta so last_seen_at moves forward.
    Process.sleep(5)

    :ok = ModelBehaviorStats.record(role, model, "task_discipline", "web_search")
    :ok = ModelBehaviorStats.record(role, model, "task_discipline", "web_search")

    row3 = fetch_row(role, model, "task_discipline", "web_search")

    assert row3.count == 3
    assert row3.first_seen_at == row1.first_seen_at
    assert row3.last_seen_at >= row1.first_seen_at
  end

  # ─── Cardinality ─────────────────────────────────────────────────────────

  test "different tool_name creates a separate counter row" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::gpt-oss:120b-cloud-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "tool_call_schema", "create_task")
    :ok = ModelBehaviorStats.record(role, model, "tool_call_schema", "complete_task")

    assert fetch_row(role, model, "tool_call_schema", "create_task").count == 1
    assert fetch_row(role, model, "tool_call_schema", "complete_task").count == 1
  end

  test "different issue_type creates a separate counter row (same model + tool)" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::gemini-3-flash-preview:cloud-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "tool_call_schema", "create_task")
    :ok = ModelBehaviorStats.record(role, model, "task_discipline",  "create_task")

    assert fetch_row(role, model, "tool_call_schema", "create_task").count == 1
    assert fetch_row(role, model, "task_discipline",  "create_task").count == 1
  end

  test "different role creates a separate counter row" do
    set_telemetry(true)

    model = "ollama::cloud::same-model-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record("assistant", model, "fresh_attachments_unread", "")
    :ok = ModelBehaviorStats.record("confidant", model, "fresh_attachments_unread", "")

    assert fetch_row("assistant", model, "fresh_attachments_unread", "").count == 1
    assert fetch_row("confidant", model, "fresh_attachments_unread", "").count == 1
  end

  # ─── Non-tool issues ─────────────────────────────────────────────────────

  test "record/4 accepts empty tool_name and stores '' literally" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::some-model-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "assistant_text_bookkeeping", "")

    assert fetch_row(role, model, "assistant_text_bookkeeping", "").count == 1
  end

  test "record/4 accepts atom issue_type and coerces to string" do
    set_telemetry(true)

    role = "assistant"
    model = "ollama::cloud::some-model-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, :tool_call_schema, "create_task")

    assert fetch_row(role, model, "tool_call_schema", "create_task").count == 1
  end

  # ─── Telemetry toggle ───────────────────────────────────────────────────

  test "record/4 is a no-op when telemetry is disabled" do
    set_telemetry(false)

    role = "assistant"
    model = "ollama::cloud::disabled-telemetry-test-#{T.uid()}"

    :ok = ModelBehaviorStats.record(role, model, "tool_call_schema", "create_task")

    # Nothing written.
    assert fetch_row(role, model, "tool_call_schema", "create_task") == nil
  end

  # ─── list_all ───────────────────────────────────────────────────────────

  test "list_all/0 returns rows sorted by count DESC" do
    set_telemetry(true)

    tag = T.uid()
    model_high = "ollama::cloud::high-count-#{tag}"
    model_low  = "ollama::cloud::low-count-#{tag}"

    Enum.each(1..3, fn _ ->
      :ok = ModelBehaviorStats.record("assistant", model_high, "tool_call_schema", "create_task")
    end)
    :ok = ModelBehaviorStats.record("assistant", model_low, "tool_call_schema", "create_task")

    rows = ModelBehaviorStats.list_all()

    # Our two test rows both appear; the 3-count one precedes the 1-count.
    ours = Enum.filter(rows, fn r -> String.ends_with?(r.model, tag) end)
    assert length(ours) == 2
    assert Enum.map(ours, & &1.count) == [3, 1]
  end
end
