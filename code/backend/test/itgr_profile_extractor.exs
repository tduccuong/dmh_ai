# Integration tests: ProfileExtractor — batched cross-session profile
# extraction with watermark-driven forward progress.
#
# Coverage:
#   - under-threshold → no LLM call, watermark untouched
#   - threshold met → LLM call fires with the OLDEST N messages,
#     watermark bumps to the Nth's ts
#   - cross-session aggregation in chronological order
#   - /memo and /wiki excluded from LLM input but still bump watermark
#   - all-slash batch → watermark bumps without an LLM call
#   - NULL watermark on first run treats as 0
#   - drift cap: excess unprocessed waits for the next call
#   - LLM failure → watermark stays put for retry
#   - existing profile feeds the "Already known" block
#
# Run with:   MIX_ENV=test mix test test/itgr_profile_extractor.exs

defmodule Itgr.ProfileExtractor do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.ProfileExtractor
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  defp uid, do: T.uid()

  defp seed_user(user_id, opts \\ []) do
    now = System.os_time(:millisecond)
    profile = Keyword.get(opts, :profile, "")
    watermark = Keyword.get(opts, :watermark, nil)

    query!(Repo,
      """
      INSERT OR IGNORE INTO users (id, email, password_hash, role, created_at, profile, last_profile_extracted_msg_ts)
      VALUES (?,?,?,?,?,?,?)
      """,
      [user_id, "pe_#{user_id}@itgr.local", "", "user", now, profile, watermark])
  end

  defp seed_session(session_id, user_id, msgs) do
    now = System.os_time(:millisecond)
    query!(Repo,
      "INSERT INTO sessions (id, user_id, mode, messages, created_at, updated_at) VALUES (?,?,?,?,?,?)",
      [session_id, user_id, "confidant", Jason.encode!(msgs), now, now])
  end

  defp user_msg(ts, content), do: %{"role" => "user", "content" => content, "ts" => ts}
  defp assistant_msg(ts, content), do: %{"role" => "assistant", "content" => content, "ts" => ts}

  defp watermark_of(user_id) do
    %{rows: [[ts]]} =
      query!(Repo, "SELECT last_profile_extracted_msg_ts FROM users WHERE id=?", [user_id])
    ts
  end

  defp profile_of(user_id) do
    %{rows: [[p]]} =
      query!(Repo, "SELECT profile FROM users WHERE id=?", [user_id])
    p || ""
  end

  # Captures every LLM call's prompt into a per-test agent so assertions
  # can inspect what the extractor sent. The reply is configurable —
  # default `{:ok, "[FACTS]\nNONE\n[CANDIDATES]\nNONE\n"}` so the
  # round-trip succeeds without mutating the profile.
  defp capture_llm_calls(reply \\ {:ok, "[FACTS]\nNONE\n[CANDIDATES]\nNONE\n"}) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    T.stub_llm_call(fn _model, msgs, _opts ->
      Agent.update(agent, fn calls -> calls ++ [msgs] end)
      reply
    end)

    agent
  end

  defp captured_calls(agent), do: Agent.get(agent, & &1)

  defp prompt_text(messages) do
    messages |> Enum.map_join("\n", fn %{content: c} -> c end)
  end

  # ─── under-threshold ────────────────────────────────────────────────────────

  test "below batch_size: no LLM call, watermark unchanged" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "hi"),
      user_msg(2000, "what's the weather"),
      user_msg(3000, "thanks")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    assert captured_calls(agent) == []
    assert watermark_of(user_id) == nil
    assert profile_of(user_id) == ""
  end

  # ─── threshold met ─────────────────────────────────────────────────────────

  test "at batch_size: fires once, watermark bumps to Nth ts, profile updates" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "I live in Berlin"),
      user_msg(2000, "I work as a developer"),
      user_msg(3000, "I have two kids"),
      user_msg(4000, "I enjoy hiking on weekends")
    ])

    agent = capture_llm_calls(
      {:ok, "[FACTS]\n- Location: Berlin\n- Hobbies: hiking\n[CANDIDATES]\nNONE\n"}
    )
    :ok = ProfileExtractor.extract_and_merge(user_id)

    calls = captured_calls(agent)
    assert length(calls) == 1
    text = prompt_text(hd(calls))
    assert text =~ "I live in Berlin"
    assert text =~ "I enjoy hiking on weekends"

    assert watermark_of(user_id) == 4000
    profile = profile_of(user_id)
    assert profile =~ "- Location: Berlin"
    assert profile =~ "- Hobbies: hiking"
  end

  # ─── cross-session ─────────────────────────────────────────────────────────

  test "cross-session: messages from different sessions feed one chronological batch" do
    user_id = uid(); sa = uid(); sb = uid()
    seed_user(user_id)
    seed_session(sa, user_id, [user_msg(1000, "msg A1"), user_msg(3000, "msg A2")])
    seed_session(sb, user_id, [user_msg(2000, "msg B1"), user_msg(4000, "msg B2")])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    calls = captured_calls(agent)
    assert length(calls) == 1
    text = prompt_text(hd(calls))

    # All four present, numbered in chronological order.
    assert text =~ "1. \"msg A1\""
    assert text =~ "2. \"msg B1\""
    assert text =~ "3. \"msg A2\""
    assert text =~ "4. \"msg B2\""
    assert watermark_of(user_id) == 4000
  end

  # ─── slash-command handling ────────────────────────────────────────────────

  test "/memo and /wiki excluded from prompt but counted in watermark" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "/memo I love coffee"),
      user_msg(2000, "I'm going hiking next weekend"),
      user_msg(3000, "/wiki https://example.com/api"),
      user_msg(4000, "what time is it in Tokyo")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    calls = captured_calls(agent)
    assert length(calls) == 1
    text = prompt_text(hd(calls))

    refute text =~ "/memo"
    refute text =~ "/wiki"
    assert text =~ "I'm going hiking next weekend"
    assert text =~ "what time is it in Tokyo"

    # Watermark MUST cover all 4 messages — slash commands count.
    assert watermark_of(user_id) == 4000
  end

  test "all-slash batch: watermark bumps without an LLM call" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "/memo a"),
      user_msg(2000, "/memo b"),
      user_msg(3000, "/wiki c"),
      user_msg(4000, "/memo d")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    assert captured_calls(agent) == []
    assert watermark_of(user_id) == 4000
  end

  # ─── NULL watermark ────────────────────────────────────────────────────────

  test "NULL watermark: every message is unprocessed on first run" do
    user_id = uid(); sid = uid()
    seed_user(user_id, watermark: nil)
    seed_session(sid, user_id, [
      user_msg(100, "a"), user_msg(200, "b"),
      user_msg(300, "c"), user_msg(400, "d")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    assert length(captured_calls(agent)) == 1
    assert watermark_of(user_id) == 400
  end

  # ─── drift cap ─────────────────────────────────────────────────────────────

  test "excess unprocessed: takes oldest N, leaves the rest for next run" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "m1"), user_msg(2000, "m2"),
      user_msg(3000, "m3"), user_msg(4000, "m4"),
      user_msg(5000, "m5"), user_msg(6000, "m6")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    text = prompt_text(hd(captured_calls(agent)))
    # Oldest 4 in batch.
    assert text =~ "\"m1\""
    assert text =~ "\"m4\""
    # Newer two stayed back.
    refute text =~ "\"m5\""
    refute text =~ "\"m6\""

    assert watermark_of(user_id) == 4000
  end

  # ─── failure: no watermark bump ────────────────────────────────────────────

  test "LLM failure: watermark stays put so the same batch retries next call" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    seed_session(sid, user_id, [
      user_msg(1000, "a"), user_msg(2000, "b"),
      user_msg(3000, "c"), user_msg(4000, "d")
    ])

    capture_llm_calls({:error, :transport_error})
    :ok = ProfileExtractor.extract_and_merge(user_id)

    # Failure path leaves watermark exactly as seeded (NULL → still NULL).
    assert watermark_of(user_id) == nil
  end

  # ─── existing profile injection ────────────────────────────────────────────

  test "existing profile feeds the 'Already known' block" do
    user_id = uid(); sid = uid()
    seed_user(user_id, profile: "- Location: Berlin\n- Hobbies: hiking")
    seed_session(sid, user_id, [
      user_msg(1000, "I'm a developer"),
      user_msg(2000, "I prefer Tailwind"),
      user_msg(3000, "I have a cat named Mochi"),
      user_msg(4000, "I read a lot of sci-fi")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    text = prompt_text(hd(captured_calls(agent)))
    assert text =~ "Already known:"
    assert text =~ "- Location: Berlin"
    assert text =~ "- Hobbies: hiking"
  end

  # ─── assistant messages are ignored as input ───────────────────────────────

  test "only user-role messages count toward the batch" do
    user_id = uid(); sid = uid()
    seed_user(user_id)
    # 3 user + 5 assistant. Total 8, but only 3 user → below threshold.
    seed_session(sid, user_id, [
      user_msg(1000, "a"),
      assistant_msg(1100, "ar1"), assistant_msg(1200, "ar2"),
      user_msg(2000, "b"),
      assistant_msg(2100, "ar3"), assistant_msg(2200, "ar4"),
      user_msg(3000, "c"),
      assistant_msg(3100, "ar5")
    ])

    agent = capture_llm_calls()
    :ok = ProfileExtractor.extract_and_merge(user_id)

    assert captured_calls(agent) == []
    assert watermark_of(user_id) == nil
  end
end
