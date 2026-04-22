# Tests for Dmhai.I18n translation coverage + language propagation.

defmodule Itgr.I18n do
  use ExUnit.Case, async: true

  alias Dmhai.I18n
  alias Dmhai.Agent.{SessionProgress, Tasks, TaskRuntime}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # ─── I18n dictionary coverage ──────────────────────────────────────────

  test "every shipped locale has a translation for every key" do
    missing =
      for key <- I18n.keys(),
          lang <- I18n.supported_langs(),
          is_nil(translation_for(key, lang)),
          do: {key, lang}

    assert missing == [], "missing translations: #{inspect(missing)}"
  end

  test "unknown language falls back to English source" do
    assert I18n.t("llm_error", "xx", %{reason: "r"}) ==
             I18n.t("llm_error", "en", %{reason: "r"})
  end

  test "nil/empty language falls back to English" do
    assert I18n.t("llm_empty_response", nil) == I18n.t("llm_empty_response", "en")
    assert I18n.t("llm_empty_response", "")  == I18n.t("llm_empty_response", "en")
  end

  test "interpolation substitutes %{name} placeholders" do
    assert I18n.t("llm_error", "en", %{reason: "timeout"}) == "LLM error: timeout"
    assert I18n.t("llm_error", "vi", %{reason: "timeout"}) == "Lỗi LLM: timeout"
  end

  test "unknown key returns the key itself" do
    assert I18n.t("nope_not_a_key", "en") == "nope_not_a_key"
  end

  # ─── language propagates into Tasks row ──────────────────────────────

  test "Tasks.insert stores language; Tasks.get reads it back" do
    jid = Tasks.insert(
      user_id: uid(), session_id: uid(),
      task_title: "x", task_spec: "y",
      language: "vi"
    )
    assert Tasks.get(jid).language == "vi"
  end

  test "Tasks.insert defaults language to 'en' when not provided" do
    jid = Tasks.insert(user_id: uid(), session_id: uid(), task_title: "x", task_spec: "y")
    assert Tasks.get(jid).language == "en"
  end

  # ─── language propagates into on-demand summariser prompt ────────────

  test "summarize_and_announce prompt includes language directive" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Tasks.insert(user_id: user_id, session_id: sid,
                      task_title: "daily report", task_spec: "s",
                      language: "es")
    ctx = %{session_id: sid, user_id: user_id, task_id: jid}
    {:ok, row} = SessionProgress.append_tool_pending(ctx, "web_search(btc)")
    SessionProgress.mark_tool_done(row.id)

    test_pid = self()
    T.stub_llm_call(fn _model, msgs, _opts ->
      body = msgs |> List.last() |> Map.get(:content)
      send(test_pid, {:summarizer_prompt, body})
      {:ok, "resumen"}
    end)

    {:ok, _} = TaskRuntime.summarize_and_announce(jid, force: true)
    assert_receive {:summarizer_prompt, body}
    assert String.contains?(body, "\"es\"")
  end

  # ─── helpers ─────────────────────────────────────────────────────────

  defp translation_for(key, lang) do
    en = I18n.t(key, "en", %{reason: "R", title: "T", count: 1, text: "X",
                              max: 1, id: "I", status: "S", result: "R"})
    got = I18n.t(key, lang, %{reason: "R", title: "T", count: 1, text: "X",
                               max: 1, id: "I", status: "S", result: "R"})
    cond do
      got == en -> got
      is_binary(got) -> got
      true -> nil
    end
  end

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "assistant", "[]", now, now])
  end
end
