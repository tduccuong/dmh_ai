# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.P02AssistantAutoFetchTest do
  @moduledoc """
  Pins the Assistant-mode auto-fetch contract added in 2026-05-14:

    * `<augmented_facts type="indexed">` block appears in the user
      message when `indexed_context` opt is non-empty.
    * `<augmented_facts type="memo">` block appears when
      `memo_context` opt is non-empty.
    * Both absent when opts are nil/empty.
    * Order on combined turns: indexed BEFORE memo BEFORE the
      user's text — encoding the precedence rule
      `indexed > memo > web > training` as positional authority
      so a model scanning top-down hits the highest-priority
      source first.
    * Per-turn flush: building a fresh message with no contexts
      doesn't carry forward blocks from a prior build.
    * Confidant pipeline (the OTHER caller of build_core) is
      untouched — its existing memo + web behaviour preserved.
  """

  use ExUnit.Case, async: false

  alias DmhAi.Agent.ContextEngine

  @session_id "S_p02_autofetch"

  defp session_data(user_text) do
    %{
      "id" => @session_id,
      "messages" => [
        %{"role" => "user", "content" => user_text, "ts" => 1}
      ],
      "context" => nil
    }
  end

  defp last_user(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn m -> m["role"] == "user" or m[:role] == "user" end)
    |> case do
      nil -> nil
      m   -> m[:content] || m["content"]
    end
  end

  describe "indexed_context block" do
    test "appears when opt is non-empty" do
      msgs =
        ContextEngine.build_assistant_messages(session_data("Wie viel Urlaub?"),
          indexed_context: "- The handbook says 28 days after 3 years.\n- Carry-over to 2027 allowed."
        )

      user = last_user(msgs)
      assert user =~ ~r/<augmented_facts type="indexed">/
      assert user =~ "28 days after 3 years"
      assert user =~ "</augmented_facts>"
    end

    test "absent when opt is nil" do
      msgs = ContextEngine.build_assistant_messages(session_data("hi"))
      user = last_user(msgs)
      refute user =~ ~r/<augmented_facts type="indexed">/
    end

    test "absent when opt is empty string" do
      msgs =
        ContextEngine.build_assistant_messages(session_data("hi"),
          indexed_context: ""
        )

      user = last_user(msgs)
      refute user =~ ~r/<augmented_facts type="indexed">/
    end
  end

  describe "memo_context block" do
    test "appears when opt is non-empty" do
      msgs =
        ContextEngine.build_assistant_messages(session_data("Was ist mein Vertrag?"),
          memo_context: "- User saved: my contracted leave is 30 days."
        )

      user = last_user(msgs)
      assert user =~ ~r/<augmented_facts type="memo">/
      assert user =~ "30 days"
    end

    test "absent when opt is nil" do
      msgs = ContextEngine.build_assistant_messages(session_data("hi"))
      user = last_user(msgs)
      refute user =~ ~r/<augmented_facts type="memo">/
    end
  end

  describe "precedence ordering" do
    test "indexed block precedes memo block in the user message" do
      msgs =
        ContextEngine.build_assistant_messages(session_data("Wie viele Urlaubstage?"),
          indexed_context: "INDEXED-AUTHORITY-MARKER: handbook says 28 days.",
          memo_context:    "MEMO-MARKER: my contract says 30 days."
        )

      user = last_user(msgs)
      idx_pos  = :binary.match(user, "INDEXED-AUTHORITY-MARKER") |> elem(0)
      memo_pos = :binary.match(user, "MEMO-MARKER")              |> elem(0)
      base_pos = :binary.match(user, "Wie viele Urlaubstage?")   |> elem(0)

      assert idx_pos < memo_pos,
             "indexed block MUST appear before memo block (encodes precedence: indexed > memo)"
      assert memo_pos < base_pos,
             "memo block MUST appear before the user's text (so the model reads context first)"
    end

    test "indexed-only turn still wraps with augmented_facts tag" do
      msgs =
        ContextEngine.build_assistant_messages(session_data("q"),
          indexed_context: "X"
        )

      user = last_user(msgs)
      assert user =~ ~r|<augmented_facts type="indexed">\nX\n</augmented_facts>|
    end
  end

  describe "per-turn flush" do
    test "a second build with no contexts emits no stale blocks" do
      msgs1 =
        ContextEngine.build_assistant_messages(session_data("turn 1"),
          indexed_context: "PRIOR-TURN-INDEXED",
          memo_context:    "PRIOR-TURN-MEMO"
        )

      assert last_user(msgs1) =~ "PRIOR-TURN-INDEXED"

      msgs2 = ContextEngine.build_assistant_messages(session_data("turn 2"))
      user2 = last_user(msgs2)

      refute user2 =~ "PRIOR-TURN-INDEXED",
             "prior turn's indexed block must NOT leak into the next build"
      refute user2 =~ "PRIOR-TURN-MEMO"
      refute user2 =~ ~r/<augmented_facts /
    end
  end

  describe "Confidant path untouched" do
    test "build_confidant_messages still emits memo + web blocks (no indexed leakage)" do
      msgs =
        ContextEngine.build_confidant_messages(session_data("hi"),
          memo_context: "MEMO-CONFIDANT-MARKER",
          web_context:  "WEB-CONFIDANT-MARKER"
        )

      user = last_user(msgs)
      assert user =~ "MEMO-CONFIDANT-MARKER"
      assert user =~ "WEB-CONFIDANT-MARKER"
      # Indexed auto-fetch is Assistant-only.
      refute user =~ ~r/<augmented_facts type="indexed">/
    end
  end
end
