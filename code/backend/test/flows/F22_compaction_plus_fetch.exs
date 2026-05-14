# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F22 — compaction snapshots task-tagged messages to
# `task_chain_archive`, then `fetch_task` returns the archived rows.
#
# `ContextEngine.compact!/3` walks `to_summarize` (older than
# `@keep_recent`), groups by `task_num`, snapshots each group
# verbatim into `task_chain_archive` BEFORE invoking the compactor
# LLM. The compactor LLM is stubbed.
#
# Asserts: archive populated; rows ordered chronologically;
# `fetch_task(N)` surfaces the archive; session.messages shrinks;
# session.context.summary is set.

defmodule DmhAi.Flows.F22CompactionPlusFetch do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.{ContextEngine, Tasks, TaskChainArchive}
  alias DmhAi.Tools.FetchTask
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F22"

  setup_all do
    teardown = DmhAi.Test.FlowHelper.setup_profile("F22")
    on_exit(teardown)
    :ok
  end

  setup do
    user_id    = T.uid()
    session_id = T.uid()

    query!(Repo,
      "INSERT INTO users (id, email, name, role, password_hash, org_id, org_role, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [user_id, "u-#{user_id}@test.local", "Test User", "user", "x",
       DmhAi.Constants.default_org_id(), "admin",
       System.os_time(:millisecond)])

    on_exit(fn ->
      query!(Repo, "DELETE FROM task_chain_archive WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])
      query!(Repo, "DELETE FROM users WHERE id=?", [user_id])
    end)

    %{user_id: user_id, session_id: session_id}
  end

  test "compact! snapshots task-tagged messages → archive populated → fetch_task surfaces them",
       %{user_id: user_id, session_id: session_id} do
    task_id =
      Tasks.insert(%{
        user_id:    user_id,
        session_id: session_id,
        task_type:  "one_off",
        task_title: "deploy app",
        task_spec:  "deploy the app to staging",
        task_status: "ongoing",
        language:   "en"
      })

    %{task_num: task_num} = Tasks.get(task_id)

    archived_pairs =
      for i <- 1..30 do
        ts = i * 10
        [
          %{"role" => "user",
            "content" => "old user msg #{i}",
            "task_num" => task_num,
            "ts" => ts},
          %{"role" => "assistant",
            "content" => "old assistant reply #{i} — long enough to push compaction past the byte budget #{String.duplicate("…", 200)}",
            "task_num" => task_num,
            "ts" => ts + 1}
        ]
      end
      |> List.flatten()

    fresh_pairs = [
      %{"role" => "user", "content" => "recent msg", "task_num" => task_num, "ts" => 9_000},
      %{"role" => "assistant", "content" => "recent reply", "task_num" => task_num, "ts" => 9_001}
    ]

    all_msgs = archived_pairs ++ fresh_pairs

    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, tool_history, created_at, updated_at) " <>
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [session_id, user_id, "assistant", Jason.encode!(all_msgs), "[]",
       System.os_time(:millisecond), System.os_time(:millisecond)])

    # Stub the compactor LLM with a canned summary.
    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, "[Summary] task #{task_num} ran 30 prior turns; details now in archive."}
    end)

    assert TaskChainArchive.fetch_for_task(task_id) == []

    %{rows: [[messages_json, context_json]]} =
      query!(Repo, "SELECT messages, context FROM sessions WHERE id=?", [session_id])

    session_data = %{
      "id"       => session_id,
      "user_id"  => user_id,
      "messages" => Jason.decode!(messages_json || "[]"),
      "context"  => if(context_json, do: Jason.decode!(context_json), else: nil),
      "mode"     => "assistant"
    }

    assert ContextEngine.should_compact?(session_data),
           "session should be over the compaction threshold given 60+ messages"

    :ok = ContextEngine.compact!(session_id, user_id, session_data)

    archive = TaskChainArchive.fetch_for_task(task_id)
    refute archive == [], "expected archive rows for task #{task_num} after compact!"

    timestamps = Enum.map(archive, &Map.get(&1, :ts))
    assert timestamps == Enum.sort(timestamps),
           "archive rows should be in chronological order; got: #{inspect(timestamps)}"

    refute Enum.any?(archive, fn r -> Map.get(r, :ts) >= 9_000 end),
           "compact! must keep the fresh @keep_recent pairs in live messages, not archive"

    {:ok, fetched} = FetchTask.execute(%{"task_num" => task_num},
                                       %{session_id: session_id})

    assert fetched.task_num == task_num
    assert fetched.task_status == "ongoing"
    refute fetched.archive == [],
           "fetch_task should return non-empty archive after compaction"

    # Compaction does NOT mutate session.messages — it advances
    # `context.summary_up_to_index` so subsequent chain assemblies
    # skip already-summarised messages and read from the summary
    # instead. Audit-trail-friendly: original messages stay in DB.
    %{rows: [[updated_context_json]]} =
      query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id])

    updated_context = Jason.decode!(updated_context_json || "{}")

    assert is_binary(updated_context["summary"]),
           "context.summary should be set after compact!"

    assert is_integer(updated_context["summary_up_to_index"]) and
             updated_context["summary_up_to_index"] >= 0,
           "context.summary_up_to_index should advance; got: #{inspect(updated_context["summary_up_to_index"])}"
  end
end
