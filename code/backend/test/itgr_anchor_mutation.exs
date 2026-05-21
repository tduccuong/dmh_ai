# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.AnchorMutationTest do
  @moduledoc """
  Pins the contract of `UserAgent.maybe_mutate_anchor/4`: it
  pattern-matches on the NATIVE `exec_result` tuple
  ({:ok, term} / {:error, term} / {:rejected, term}) and never
  re-parses the stringified tool_msg.content.

  This test exists because a prior version sniffed the JSON-
  encoded form for `"ok": true` — which silently broke when
  `pickup_task` returned a raw string envelope instead of a map.
  After a successful `pickup_task`, the anchor stayed nil, and
  every follow-up `connect_mcp` failed with "requires an anchor
  task". See arch_wiki/dmh_ai/known_issues.md.

  Reachability: this is a private-helper unit test. We import the
  module's private function via a small wrapper test module so the
  contract stays expressive.
  """

  use ExUnit.Case, async: false

  alias DmhAi.{Repo, Agent.UserAgent, Agent.Tasks}
  import Ecto.Adapters.SQL, only: [query!: 3]

  @default_org DmhAi.Constants.default_org_id()

  setup do
    now = System.os_time(:second)
    uid = "anchor_user_" <> T.uid()
    sid = "anchor_sess_" <> T.uid()

    query!(Repo, """
    INSERT INTO users (id, email, name, password_hash, role, org_id, org_role, created_at)
    VALUES (?, ?, NULL, 'x', 'user', ?, 'member', ?)
    """, [uid, "#{uid}@test.local", @default_org, now])

    on_exit(fn ->
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [sid])
      query!(Repo, "DELETE FROM users WHERE id=?", [uid])
    end)

    {:ok, %{user_id: uid, session_id: sid}}
  end

  describe "pickup_task — exec_result native shape" do
    test "successful pickup advances ctx.anchor_task_num to the task's number",
         %{user_id: uid, session_id: sid} do
      # Seed a paused task for pickup.
      task_id =
        Tasks.insert(
          user_id:     uid,
          session_id:  sid,
          task_type:   "one_off",
          intvl_sec:   0,
          task_title:  "Pickup target",
          task_spec:   "anchor mutation test",
          attachments: [],
          task_status: "paused",
          language:    "en"
        )

      %{rows: [[task_num]]} = query!(Repo, "SELECT task_num FROM tasks WHERE task_id=?", [task_id])

      # Initial ctx — no anchor (the exact shape from the failing UAT).
      ctx0 = %{session_id: sid, user_id: uid, anchor_task_num: nil}

      # Native exec_result shape per pickup_task.ex.
      exec_result =
        {:ok, %{task_num: task_num, was_already_ongoing: false,
                envelope: "<requested_task_content number=\"#{task_num}\">…</requested_task_content>"}}

      ctx1 = UserAgent.__mutate_anchor_for_test__(ctx0, "pickup_task",
                                                  %{"task_num" => task_num}, exec_result)

      assert ctx1.anchor_task_num == task_num,
             "after pickup_task {:ok, _}, anchor must advance to task_num=#{task_num}"
    end

    test "rejected pickup leaves the anchor unchanged",
         %{user_id: uid, session_id: sid} do
      ctx0 = %{session_id: sid, user_id: uid, anchor_task_num: nil}
      ctx1 = UserAgent.__mutate_anchor_for_test__(ctx0, "pickup_task",
                                                  %{"task_num" => 99},
                                                  {:rejected, "Police: bad gate"})
      assert ctx1.anchor_task_num == nil
    end

    test "error from pickup leaves the anchor unchanged",
         %{user_id: uid, session_id: sid} do
      ctx0 = %{session_id: sid, user_id: uid, anchor_task_num: nil}
      ctx1 = UserAgent.__mutate_anchor_for_test__(ctx0, "pickup_task",
                                                  %{"task_num" => 99},
                                                  {:error, "boom"})
      assert ctx1.anchor_task_num == nil
    end
  end

  describe "extract_form_from_results — native exec_result shape" do
    test "picks the form from {:ok, %{form: %{...}}}" do
      form = %{kind: "request_input", fields: [%{name: "x", label: "X", type: "text"}]}
      results = [
        {:ok, %{token: "t1", expires_at: 1, form: form}},
        {:ok, %{some_other_tool: "result"}}
      ]

      assert UserAgent.__extract_form_for_test__(results) == form
    end

    test "returns nil when no result carries a form" do
      results = [{:ok, %{anything: "else"}}, {:error, "boom"}, {:rejected, "blocked"}]
      assert UserAgent.__extract_form_for_test__(results) == nil
    end

    test "legacy JSON-string content is firmly NOT recognised" do
      # If a regression re-introduces stringified content into the
      # exec_result slot, the native pattern-match refuses to find
      # the form — surfacing the regression as a missing form prompt
      # rather than silent JSON-decode acceptance.
      stringified = ~s({"token": "t", "expires_at": 1, "form": {"kind": "request_input"}})
      assert UserAgent.__extract_form_for_test__([stringified]) == nil
    end
  end

  describe "pause_or_cancel_succeeded?" do
    test ":ok with task_num is success" do
      assert UserAgent.pause_or_cancel_succeeded?({:ok, %{task_num: 1}})
    end

    test ":error / :rejected are failure" do
      refute UserAgent.pause_or_cancel_succeeded?({:error, "boom"})
      refute UserAgent.pause_or_cancel_succeeded?({:rejected, "blocked"})
    end

    test "old JSON-string shape that the legacy code matched is now firmly NOT a success" do
      refute UserAgent.pause_or_cancel_succeeded?(~s({"task_num": 1, "ok": true}))
      refute UserAgent.pause_or_cancel_succeeded?("anything stringy")
    end
  end
end
