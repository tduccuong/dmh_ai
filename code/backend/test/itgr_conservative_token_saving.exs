defmodule Itgr.ConservativeTokenSaving do
  @moduledoc """
  Locks in the per-user "Conservative token saving" filter rules:

    * Toggle off (default): `ContextEngine.build_assistant_messages`
      passes the full persisted-message history through, exactly as
      pre-feature builds.

    * Toggle on, anchor=N: drop persisted messages tagged with
      `task_num != N`. Untagged messages stay (free-mode chats,
      system blocks, in-chain pairs added later by the chain loop).

    * Toggle on, anchor=nil: NO filter. Free-mode / just-completed-
      follow-up keeps full context. Pulling the rug under follow-up
      would lose user-visible context that has no fetch_task path.

  Also pins `ContextEngine.filter_other_tasks/2` as the canonical
  implementation of the rule — both chain-start and mid-chain re-
  filter call into it, so a single regression here surfaces in both
  paths.
  """

  use ExUnit.Case, async: true

  alias DmhAi.Agent.ContextEngine

  describe "filter_other_tasks/2 — canonical filter rule" do
    test "anchor nil → returns the list unchanged" do
      msgs = [
        %{"role" => "user", "content" => "free mode hi", "task_num" => 1},
        %{"role" => "assistant", "content" => "hi back"}
      ]

      assert ContextEngine.filter_other_tasks(msgs, nil) == msgs
    end

    test "anchor N → drops messages tagged with other task_nums" do
      msgs = [
        %{"role" => "user", "content" => "for task 1", "task_num" => 1},
        %{"role" => "assistant", "content" => "answering 1", "task_num" => 1},
        %{"role" => "user", "content" => "free chitchat"},
        %{"role" => "user", "content" => "for task 2", "task_num" => 2}
      ]

      filtered = ContextEngine.filter_other_tasks(msgs, 2)

      contents = Enum.map(filtered, & &1["content"])
      assert contents == ["free chitchat", "for task 2"]
    end

    test "anchor N → keeps untagged in-chain pairs (no task_num field)" do
      msgs = [
        %{"role" => "assistant", "tool_calls" => [%{"id" => "abc"}]},
        %{"role" => "tool", "content" => "tool result", "tool_call_id" => "abc"}
      ]

      assert ContextEngine.filter_other_tasks(msgs, 9) == msgs
    end

    test "anchor N — atom-keyed task_num also recognised" do
      msgs = [
        %{role: "user", content: "for task 1", task_num: 1},
        %{role: "user", content: "for task 2", task_num: 2}
      ]

      filtered = ContextEngine.filter_other_tasks(msgs, 2)

      assert length(filtered) == 1
      [only] = filtered
      assert only.task_num == 2
    end
  end

  describe "build_assistant_messages — toggle-aware filter" do
    setup do
      # Minimal user row so the preferences read path works. Uses the
      # same Repo the production code uses; cleaned up via on_exit.
      {:ok, user_id} = create_throwaway_user()
      session_id = "sess-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        Ecto.Adapters.SQL.query!(DmhAi.Repo, "DELETE FROM users WHERE id=?", [user_id])
      end)

      {:ok, user_id: user_id, session_id: session_id}
    end

    test "toggle OFF (default) — full history passes through", c do
      session_data = %{
        "id" => c.session_id,
        "messages" => [
          %{"role" => "user", "content" => "task 1 ask", "task_num" => 1, "ts" => 1},
          %{"role" => "assistant", "content" => "task 1 answer", "task_num" => 1, "ts" => 2},
          %{"role" => "user", "content" => "current ask"}
        ]
      }

      built =
        ContextEngine.build_assistant_messages(session_data,
          user_id:         c.user_id,
          anchor_task_num: 2
        )

      assistant_text = Enum.find(built, fn m ->
        Map.get(m, :role) == "assistant" and Map.get(m, :content) =~ "task 1 answer"
      end)

      assert assistant_text != nil, "default behaviour drops nothing"
    end

    test "toggle ON + anchor=N — other-task messages dropped, untagged stay", c do
      :ok = DmhAi.Auth.UserPreferences.put_conservative_token_saving(c.user_id, true)

      session_data = %{
        "id" => c.session_id,
        "messages" => [
          %{"role" => "user", "content" => "task 1 ask", "task_num" => 1, "ts" => 1},
          %{"role" => "assistant", "content" => "task 1 answer", "task_num" => 1, "ts" => 2},
          %{"role" => "user", "content" => "free-mode chitchat", "ts" => 3},
          %{"role" => "user", "content" => "current ask"}
        ]
      }

      built =
        ContextEngine.build_assistant_messages(session_data,
          user_id:         c.user_id,
          anchor_task_num: 2
        )

      flat = Enum.map(built, fn m -> Map.get(m, :content) || "" end) |> Enum.join("\n")

      refute flat =~ "task 1 ask"
      refute flat =~ "task 1 answer"
      assert flat =~ "free-mode chitchat"
      assert flat =~ "current ask"
    end

    test "toggle ON + anchor=nil — full history kept (follow-up case)", c do
      :ok = DmhAi.Auth.UserPreferences.put_conservative_token_saving(c.user_id, true)

      session_data = %{
        "id" => c.session_id,
        "messages" => [
          %{"role" => "user", "content" => "task 1 ask", "task_num" => 1, "ts" => 1},
          %{"role" => "assistant", "content" => "task 1 answer", "task_num" => 1, "ts" => 2},
          %{"role" => "user", "content" => "follow-up please"}
        ]
      }

      built =
        ContextEngine.build_assistant_messages(session_data,
          user_id:         c.user_id,
          anchor_task_num: nil
        )

      flat = Enum.map(built, fn m -> Map.get(m, :content) || "" end) |> Enum.join("\n")

      assert flat =~ "task 1 ask"
      assert flat =~ "task 1 answer"
      assert flat =~ "follow-up please"
    end
  end

  defp create_throwaway_user do
    user_id = "u-#{System.unique_integer([:positive])}"
    email   = "ctoken-#{user_id}@test.local"

    Ecto.Adapters.SQL.query!(
      DmhAi.Repo,
      "INSERT INTO users (id, email, password_hash, role) VALUES (?, ?, ?, ?)",
      [user_id, email, "x", "user"]
    )

    {:ok, user_id}
  end
end
