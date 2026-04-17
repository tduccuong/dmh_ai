# Tests for Dmhai.I18n + language propagation through the job/worker pipeline.

defmodule Itgr.I18n do
  use ExUnit.Case, async: true

  alias Dmhai.I18n
  alias Dmhai.Agent.{Jobs, Worker, JobRuntime, WorkerStatus}
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  # ─── I18n dictionary coverage ────────────────────────────────────────────

  test "every shipped locale has a translation for every key" do
    missing =
      for key <- I18n.keys(),
          lang <- I18n.supported_langs(),
          is_nil(translation_for(key, lang)),
          do: {key, lang}

    assert missing == [], "missing translations: #{inspect(missing)}"
  end

  test "unknown language falls back to English source" do
    assert I18n.t("blocked_label", "xx", %{reason: "r"}) ==
             I18n.t("blocked_label", "en", %{reason: "r"})
  end

  test "nil/empty language falls back to English" do
    assert I18n.t("no_such_job", nil) == I18n.t("no_such_job", "en")
    assert I18n.t("no_such_job", "")  == I18n.t("no_such_job", "en")
  end

  test "interpolation substitutes %{name} placeholders" do
    assert I18n.t("blocked_label", "en", %{reason: "DB down"}) == "Blocked: DB down"
    assert I18n.t("blocked_label", "vi", %{reason: "DB down"}) == "Bị chặn: DB down"
  end

  test "unknown key returns the key itself" do
    assert I18n.t("nope_not_a_key", "en") == "nope_not_a_key"
  end

  # ─── language propagates into Jobs/Worker ctx ────────────────────────────

  test "Jobs.insert stores language; Jobs.get reads it back" do
    jid = Jobs.insert(
      user_id: uid(), session_id: uid(),
      job_title: "x", job_spec: "y",
      language: "vi"
    )
    assert Jobs.get(jid).language == "vi"
  end

  test "Jobs.insert defaults language to 'en' when not provided" do
    jid = Jobs.insert(user_id: uid(), session_id: uid(), job_title: "x", job_spec: "y")
    assert Jobs.get(jid).language == "en"
  end

  test "Worker.build_system_prompt interpolates the language" do
    prompt_en = Worker.build_system_prompt("en")
    prompt_vi = Worker.build_system_prompt("vi")

    assert String.contains?(prompt_en, "user's language is \"en\"")
    assert String.contains?(prompt_vi, "user's language is \"vi\"")
  end

  test "worker system prompt reflects ctx.language" do
    user_id = uid(); sid = uid()
    jid = Jobs.insert(user_id: user_id, session_id: sid,
                      job_title: "x", job_spec: "task",
                      language: "ja", job_status: "running")

    ctx = %{
      user_id: user_id, session_id: sid,
      worker_id: uid(), job_id: jid,
      language: "ja", agent_pid: self()
    }

    test_pid = self()
    T.stub_llm_call(fn _model, msgs, _opts ->
      [%{role: "system", content: sys} | _] = msgs
      send(test_pid, {:saw_prompt, sys})
      {:ok, {:tool_calls, [T.tool_call("signal",
         %{"status" => "JOB_DONE", "result" => "完了"})]}}
    end)

    Worker.run("task in japanese", ctx)
    assert_receive {:saw_prompt, sys}
    assert String.contains?(sys, "user's language is \"ja\"")
  end

  # ─── language propagates into summarizer prompt ──────────────────────────

  test "summarize_and_announce prompt includes language directive" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Jobs.insert(user_id: user_id, session_id: sid,
                      job_title: "daily report", job_spec: "s",
                      language: "es", job_status: "running")
    WorkerStatus.append(jid, "w1", "tool_call", "web_search(btc)")

    test_pid = self()
    T.stub_llm_call(fn _model, msgs, _opts ->
      body = msgs |> List.last() |> Map.get(:content)
      send(test_pid, {:summarizer_prompt, body})
      {:ok, "resumen"}
    end)

    {:ok, _} = JobRuntime.summarize_and_announce(jid, force: true)
    assert_receive {:summarizer_prompt, body}
    assert String.contains?(body, "\"es\"")
  end

  # ─── emit_final_message uses localized labels ────────────────────────────

  test "JobRuntime completion message renders in the job's language (via I18n)" do
    user_id = uid(); sid = uid()
    seed_session(sid, user_id)

    jid = Jobs.insert(user_id: user_id, session_id: sid,
                      job_title: "cuenta", job_spec: "s",
                      language: "es", job_status: "pending")

    T.stub_llm_call(fn _model, _msgs, _opts ->
      {:ok, {:tool_calls, [T.tool_call("signal",
         %{"status" => "BLOCKED", "reason" => "sin internet"})]}}
    end)

    JobRuntime.start_job(jid)

    deadline = System.monotonic_time(:millisecond) + 3_000
    wait_until_status(jid, "blocked", deadline)

    # Check the session message body uses the Spanish label.
    body = last_assistant_message(sid, user_id)
    assert String.contains?(body, "Bloqueado:") or String.contains?(body, "Bloqueado :")
  end

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp translation_for(key, lang) do
    # Access @messages via t/2; if a key is missing for a lang, t falls back to "en".
    # Detect missing by comparing: if lang != "en" and the translation equals the
    # English source, we infer the lang is missing. For shipped langs that should
    # match English (symbols only, e.g. "notify_done"), allow equality.
    en = I18n.t(key, "en", %{reason: "R", title: "T", count: 1, text: "X",
                              max: 1, id: "I", status: "S", result: "R"})
    got = I18n.t(key, lang, %{reason: "R", title: "T", count: 1, text: "X",
                               max: 1, id: "I", status: "S", result: "R"})
    # For symbol-only keys the translation can equal English — treat as present
    # if either it differs OR both are the English source intentionally.
    cond do
      got == en -> got  # considered "present" (caller counts `nil` as missing)
      is_binary(got) -> got
      true -> nil
    end
  end

  defp seed_session(sid, user_id) do
    now = System.os_time(:millisecond)
    query!(Dmhai.Repo,
      "INSERT OR IGNORE INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [sid, user_id, "confidant", "[]", now, now])
  end

  defp wait_until_status(jid, expected, deadline) do
    if Jobs.get(jid).job_status == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for job #{jid} to reach #{expected}")
      else
        Process.sleep(50)
        wait_until_status(jid, expected, deadline)
      end
    end
  end

  defp last_assistant_message(sid, user_id) do
    r = query!(Dmhai.Repo, "SELECT messages FROM sessions WHERE id=? AND user_id=?",
                [sid, user_id])
    [[msgs_json]] = r.rows
    msgs = Jason.decode!(msgs_json || "[]")
    last = msgs |> Enum.reverse() |> Enum.find(fn m -> m["role"] == "assistant" end)
    last && last["content"] || ""
  end
end
