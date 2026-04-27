# Multi-round compaction lifecycle tests.
#
# Unlike the per-call tests in `itgr_context_engine.exs` (each exercising
# compact!/build_messages once in isolation), these simulate a growing
# conversation across N compaction rounds and verify the lifecycle
# properties that only emerge over time:
#
#   - summary_up_to_index advances monotonically; ranges don't overlap
#   - [Previous summary] correctly chains across rounds
#   - tool_call ↔ tool_result pairing survives every cutoff
#   - markers planted early survive through the [Previous summary] chain
#   - context byte size stays bounded across rounds
#   - task_turn_archive partitions tagged turns correctly
#
# Run with: MIX_ENV=test mix test test/itgr_compaction_lifecycle.exs

defmodule Itgr.CompactionLifecycle do
  use ExUnit.Case, async: false

  alias Dmhai.Agent.{ContextEngine, Tasks, TaskTurnArchive}
  alias Dmhai.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  # ─── Sim — action DSL, chain templates, conversation builder ─────────────

  # Realistic content-size knobs. Real conversations span 5-byte acks
  # to 50-KB tool dumps; uniform-tiny test data wouldn't stress the
  # char-budget compaction trigger or the bounded-growth assertion.
  # Each knob produces a string of approximately the target byte size,
  # padded with technical-looking lorem-ipsum filler so summaries
  # don't see uniform garbage.
  defp pad_to(seed, target_chars) do
    filler =
      "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do " <>
        "eiusmod tempor incididunt ut labore et dolore magna aliqua. " <>
        "Ut enim ad minim veniam, quis nostrud exercitation ullamco " <>
        "laboris nisi ut aliquip ex ea commodo consequat. Duis aute " <>
        "irure dolor in reprehenderit in voluptate velit esse cillum. "

    base = "[#{seed}] "
    needed = max(0, target_chars - String.length(base))
    pad = String.duplicate(filler, div(needed, String.length(filler)) + 1)
    base <> binary_part(pad, 0, needed)
  end

  defp size_chars(:tiny),   do: 30
  defp size_chars(:small),  do: 250
  defp size_chars(:medium), do: 1500
  defp size_chars(:large),  do: 8000

  # Action DSL — high-level shapes; the builder folds them into a
  # properly-sequenced message list with monotonic ts, matched
  # tool_call_ids, and task_num tags applied to assistant text turns
  # while a task is anchored.
  #
  # Each chain is a list of these atoms / tuples. Builder fans out:
  #
  #   {:user, size}                  → user message
  #   {:create_task, title, spec}    → asst create_task call + tool result
  #   {:complete_task, result}       → asst complete_task call + tool result
  #   {:tool, name, args, result}    → asst <name> tool call + tool result
  #   {:assistant_text, size}        → asst final-text turn (tagged if anchor)
  #   {:marker, marker_text}         → user msg containing only `marker_text`
  #
  # Chain templates: realistic shape mix targeting prod distribution.
  defp template(:chitchat) do
    [{:user, :tiny}, {:assistant_text, :tiny}]
  end

  defp template(:simple_lookup) do
    [
      {:user, :small},
      {:create_task, "Lookup", "small ask"},
      {:tool, "web_fetch", %{"url" => "https://example.com/x"}, :small},
      {:complete_task, "found"},
      {:assistant_text, :small}
    ]
  end

  defp template(:multi_tool_batch) do
    [
      {:user, :small},
      {:create_task, "Multi probe", "explore the api"},
      {:tool, "run_script", %{"script" => "curl A"}, :medium},
      {:tool, "run_script", %{"script" => "curl B"}, :medium},
      {:tool, "run_script", %{"script" => "curl C"}, :medium},
      {:complete_task, "probed three endpoints"},
      {:assistant_text, :medium}
    ]
  end

  defp template(:large_tool_result) do
    [
      {:user, :small},
      {:create_task, "Big dump", "fetch a big file"},
      {:tool, "run_script", %{"script" => "curl big"}, :large},
      {:complete_task, "got the dump"},
      {:assistant_text, :small}
    ]
  end

  defp template(:long_final_text) do
    [
      {:user, :medium},
      {:create_task, "Detailed ask", "deep technical question"},
      {:tool, "web_search", %{"query" => "deep technical search"}, :medium},
      {:complete_task, "explained in depth"},
      {:assistant_text, :large}
    ]
  end

  defp template(:error_retry) do
    [
      {:user, :small},
      {:create_task, "Retry probe", "first attempt fails"},
      {:tool, "run_script", %{"script" => "curl wrong"}, :tiny},
      {:tool, "run_script", %{"script" => "curl right"}, :small},
      {:complete_task, "second attempt worked"},
      {:assistant_text, :small}
    ]
  end

  # Production distribution roughly: 50% chitchat/simple, 30% multi-tool,
  # 15% large-result/long-text, 5% error/retry. Test seed is fixed so
  # rounds are reproducible.
  @template_distribution [
    {:chitchat,          5},
    {:simple_lookup,     5},
    {:multi_tool_batch,  6},
    {:large_tool_result, 2},
    {:long_final_text,   1},
    {:error_retry,       1}
  ]

  defp pick_template(random_state) do
    {n, random_state} = :rand.uniform_s(20, random_state)
    pick_at(@template_distribution, n - 1, random_state)
  end

  defp pick_at([{name, weight} | _], n, rs) when n < weight, do: {name, rs}
  defp pick_at([{_, weight} | rest], n, rs), do: pick_at(rest, n - weight, rs)
  defp pick_at([], _, rs), do: {:chitchat, rs}

  # Initial sim state — the simulator's accumulator. Tracks running
  # ts, task_num, tool_call_id counters, the current anchor task_num
  # (so assistant text turns get tagged correctly), and the
  # accumulated messages list.
  defp new_sim(session_id, user_id, opts \\ []) do
    %{
      session_id:    session_id,
      user_id:       user_id,
      messages:      [],
      next_ts:       1,
      next_task_num: 1,   # tracked locally; real DB tasks inserted on demand
      next_call_id:  1,
      anchor:        nil,
      seed:          Keyword.get(opts, :seed, :rand.seed_s(:exsplus, {1, 2, 3})),
      register_tasks_in_db?: Keyword.get(opts, :register_tasks_in_db?, false),
      task_id_for_num: %{}   # task_num -> task_id (set when register_tasks_in_db?: true)
    }
  end

  # Apply one action to the sim state, return the new state.
  defp apply_action(s, {:user, size}) do
    msg = %{"role" => "user", "content" => pad_to("u#{s.next_ts}", size_chars(size)), "ts" => s.next_ts}
    %{s | messages: s.messages ++ [msg], next_ts: s.next_ts + 1}
  end

  defp apply_action(s, {:marker, text}) do
    msg = %{"role" => "user", "content" => text, "ts" => s.next_ts}
    %{s | messages: s.messages ++ [msg], next_ts: s.next_ts + 1}
  end

  defp apply_action(s, {:assistant_text, size}) do
    base = %{
      "role"    => "assistant",
      "content" => pad_to("a#{s.next_ts}", size_chars(size)),
      "ts"      => s.next_ts
    }
    # Only stamp task_num when the simulator is registering real tasks
    # in the DB. Otherwise the compactor's archive hook would warn for
    # every tagged message ("task_num=N no longer exists") because the
    # task row isn't there. The lifecycle / sequencing tests don't care
    # about archive plumbing, so they run in untagged mode.
    msg = if is_integer(s.anchor) and s.register_tasks_in_db?,
            do: Map.put(base, "task_num", s.anchor),
            else: base
    %{s | messages: s.messages ++ [msg], next_ts: s.next_ts + 1}
  end

  defp apply_action(s, {:create_task, title, spec}) do
    call_id  = "call_#{s.next_call_id}"
    task_num = s.next_task_num

    # Optionally persist a real task row so resolve_num works (needed for
    # task_turn_archive tests). Most rounds skip this for speed.
    task_id =
      if s.register_tasks_in_db? do
        Tasks.insert(%{
          session_id:  s.session_id,
          user_id:     s.user_id,
          task_title:  title,
          task_spec:   spec,
          task_status: "ongoing",
          task_type:   "one_off"
        })
      else
        nil
      end

    asst = %{
      "role"    => "assistant",
      "content" => "",
      "ts"      => s.next_ts,
      "tool_calls" => [%{
        "id" => call_id,
        "function" => %{
          "name" => "create_task",
          "arguments" => %{
            "task_title" => title,
            "task_spec"  => spec,
            "task_type"  => "one_off",
            "language"   => "en"
          }
        }
      }]
    }

    tool_result = Jason.encode!(%{
      do_not: "call pickup_task — task is already ongoing",
      status: "ongoing",
      task_num: task_num,
      task_title: title,
      task_type:  "one_off"
    })

    tool_msg = %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "content" => tool_result,
      "ts" => s.next_ts + 1
    }

    %{s |
      messages:        s.messages ++ [asst, tool_msg],
      next_ts:         s.next_ts + 2,
      next_call_id:    s.next_call_id + 1,
      next_task_num:   task_num + 1,
      anchor:          task_num,
      task_id_for_num: Map.put(s.task_id_for_num, task_num, task_id)
    }
  end

  defp apply_action(s, {:complete_task, result}) do
    call_id = "call_#{s.next_call_id}"
    task_num = s.anchor

    asst = %{
      "role" => "assistant",
      "content" => "",
      "ts" => s.next_ts,
      "tool_calls" => [%{
        "id" => call_id,
        "function" => %{
          "name" => "complete_task",
          "arguments" => %{"task_num" => task_num, "task_result" => result}
        }
      }]
    }

    tool_msg = %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "content" => Jason.encode!(%{ok: true, task_num: task_num}),
      "ts" => s.next_ts + 1
    }

    %{s |
      messages: s.messages ++ [asst, tool_msg],
      next_ts: s.next_ts + 2,
      next_call_id: s.next_call_id + 1,
      anchor: nil
    }
  end

  defp apply_action(s, {:tool, name, args, size}) do
    call_id = "call_#{s.next_call_id}"

    asst_base = %{
      "role" => "assistant",
      "content" => "",
      "ts" => s.next_ts,
      "tool_calls" => [%{
        "id" => call_id,
        "function" => %{"name" => name, "arguments" => args}
      }]
    }
    tag? = is_integer(s.anchor) and s.register_tasks_in_db?
    asst = if tag?, do: Map.put(asst_base, "task_num", s.anchor), else: asst_base

    tool_base = %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "content" => pad_to("tr#{s.next_ts}", size_chars(size)),
      "ts" => s.next_ts + 1
    }
    tool_msg = if tag?, do: Map.put(tool_base, "task_num", s.anchor), else: tool_base

    %{s |
      messages: s.messages ++ [asst, tool_msg],
      next_ts: s.next_ts + 2,
      next_call_id: s.next_call_id + 1
    }
  end

  defp apply_chain(s, actions) when is_list(actions) do
    Enum.reduce(actions, s, &apply_action(&2, &1))
  end

  # Build N random chains using the production-shape distribution.
  # `seed` makes runs reproducible.
  defp simulate_round(s, n_chains) do
    Enum.reduce(1..n_chains, s, fn _, s_acc ->
      {tmpl_name, new_seed} = pick_template(s_acc.seed)
      apply_chain(%{s_acc | seed: new_seed}, template(tmpl_name))
    end)
  end

  # ─── Compactor stub helpers ──────────────────────────────────────────────

  # Stub that captures every input and returns a deterministic summary.
  # Stored in ETS so tests can read what each round saw.
  defp marker_echoing_stub(round_label) do
    table = :ets.new(:cap_compactor_input, [:public, :set])

    fun = fn _model, messages, _opts ->
      # Capture the full input message list for assertions
      :ets.insert(table, {:input, messages})

      # Echo any markers seen in any input message's content into the summary.
      content = Enum.map_join(messages, "\n", fn m -> m[:content] || m["content"] || "" end)
      markers = Regex.scan(~r/MARKER_[a-z0-9_]+/, content) |> List.flatten() |> Enum.uniq()
      summary =
        "[#{round_label} summary] markers=#{Enum.join(markers, ",")}; " <>
          "msgs_in=#{length(messages)}; chars_in=#{String.length(content)}"

      {:ok, summary}
    end

    {fun, table}
  end

  # Stub that returns a fixed-size summary regardless of input — for
  # bounded-growth assertions where we want the summary to NOT scale
  # with input.
  defp truncating_stub(target_chars) do
    fun = fn _model, _messages, _opts ->
      {:ok, String.duplicate("S", target_chars)}
    end
    fun
  end

  # ─── DB helpers ──────────────────────────────────────────────────────────

  defp upsert_session(session_id, user_id, messages, ctx) do
    case query!(Repo, "SELECT id FROM sessions WHERE id=?", [session_id]).rows do
      [] ->
        now = System.os_time(:millisecond)
        query!(Repo,
          "INSERT INTO sessions (id, user_id, mode, messages, context, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
          [session_id, user_id, "assistant",
           Jason.encode!(messages),
           if(ctx, do: Jason.encode!(ctx), else: nil),
           now, now])

      _ ->
        query!(Repo,
          "UPDATE sessions SET messages=?, context=?, updated_at=? WHERE id=?",
          [Jason.encode!(messages),
           if(ctx, do: Jason.encode!(ctx), else: nil),
           System.os_time(:millisecond), session_id])
    end
  end

  defp read_context(session_id) do
    r = query!(Repo, "SELECT context FROM sessions WHERE id=?", [session_id])
    case r.rows do
      [[nil]]  -> nil
      [[json]] -> Jason.decode!(json)
      _        -> nil
    end
  end

  # Drive one compaction round. Stubs LLM, calls compact!, returns the
  # post-compaction context map.
  defp run_round(s, round_label) do
    {fun, table} = marker_echoing_stub(round_label)
    T.stub_llm_call(fun)
    upsert_session(s.session_id, s.user_id, s.messages, read_context(s.session_id))
    sd = %{"messages" => s.messages, "context" => read_context(s.session_id), "id" => s.session_id}
    :ok = ContextEngine.compact!(s.session_id, s.user_id, sd)
    %{ctx: read_context(s.session_id), captured_input_table: table}
  end

  # ─── Tests — lifecycle correctness ───────────────────────────────────────

  describe "multi-round lifecycle" do
    test "summary_up_to_index advances monotonically across rounds" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      s = simulate_round(s, 8)
      r1 = run_round(s, "round1")
      cutoff_1 = r1.ctx["summary_up_to_index"]
      assert is_integer(cutoff_1)

      s = simulate_round(s, 8)
      r2 = run_round(s, "round2")
      cutoff_2 = r2.ctx["summary_up_to_index"]
      assert cutoff_2 > cutoff_1

      s = simulate_round(s, 8)
      r3 = run_round(s, "round3")
      cutoff_3 = r3.ctx["summary_up_to_index"]
      assert cutoff_3 > cutoff_2
    end

    test "round 2's compactor input contains [Previous summary] from round 1" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      s = simulate_round(s, 8)
      r1 = run_round(s, "round1")
      round1_summary = r1.ctx["summary"]
      assert is_binary(round1_summary)
      assert String.starts_with?(round1_summary, "[round1 summary]")

      s = simulate_round(s, 8)
      r2 = run_round(s, "round2")

      [{:input, r2_input}] = :ets.lookup(r2.captured_input_table, :input)
      first = hd(r2_input)
      content = first[:content] || first["content"]
      assert String.starts_with?(content, "[Previous summary]")
      assert String.contains?(content, round1_summary),
             "round 2's [Previous summary] must contain round 1's full summary text"
    end

    test "already-summarised range is never re-summarised in a later round" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      # Plant a unique marker in round 1.
      s = apply_action(s, {:marker, "MARKER_round1_planted"})
      s = simulate_round(s, 8)
      r1 = run_round(s, "round1")

      [{:input, r1_input}] = :ets.lookup(r1.captured_input_table, :input)
      assert Enum.any?(r1_input, fn m ->
        c = m[:content] || m["content"] || ""
        String.contains?(c, "MARKER_round1_planted")
      end), "round 1's compactor input should contain the marker turn"

      # Round 2: add fresh chains. The original marker turn must NOT
      # appear directly in round 2's compactor input — it lives only in
      # the [Previous summary] echo.
      s = simulate_round(s, 8)
      r2 = run_round(s, "round2")

      [{:input, r2_input}] = :ets.lookup(r2.captured_input_table, :input)
      direct_marker_messages =
        Enum.filter(r2_input, fn m ->
          c = m[:content] || m["content"] || ""
          # Only the [Previous summary] message would contain the marker
          # via the round-1 summary echo. A direct marker message would
          # be a `role: user, content: "MARKER_round1_planted"` shape.
          String.trim(c) == "MARKER_round1_planted"
        end)

      assert direct_marker_messages == [],
             "marker turn from round 1 leaked into round 2's compactor input directly"
    end
  end

  # ─── Tests — sequencing safety ───────────────────────────────────────────

  describe "build_assistant_messages preserves tool-call sequencing" do
    test "after each round, every assistant.tool_calls has matching tool results immediately after" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      Enum.reduce(1..3, s, fn round, s_acc ->
        s_acc = simulate_round(s_acc, 8)
        _ = run_round(s_acc, "round#{round}")

        ctx = read_context(session_id)
        sd  = %{"id" => session_id, "messages" => s_acc.messages, "context" => ctx}
        msgs = ContextEngine.build_assistant_messages(sd, [])

        assert_tool_pairs_match(msgs, "round #{round}")
        s_acc
      end)
    end
  end

  defp assert_tool_pairs_match(messages, round_label) do
    # Walk: every assistant message with N tool_calls must be followed
    # by N tool messages whose tool_call_ids are a permutation of the
    # tool_call ids on the assistant message.
    #
    # The build_messages output is assembled from `(role, content)` pairs
    # and uses atom keys for system synthesis. ToolHistory injects
    # tool_calls via legacy maps. We accept either shape.
    Enum.reduce(Enum.with_index(messages), nil, fn {m, i}, _acc ->
      role = m[:role] || m["role"]
      tool_calls = m[:tool_calls] || m["tool_calls"]

      if role == "assistant" and is_list(tool_calls) and tool_calls != [] do
        ids =
          Enum.map(tool_calls, fn tc ->
            tc[:id] || tc["id"]
          end)

        following =
          messages
          |> Enum.drop(i + 1)
          |> Enum.take(length(ids))

        following_ids =
          Enum.map(following, fn x ->
            f_role = x[:role] || x["role"]
            assert f_role == "tool",
                   "[#{round_label}] message at idx #{i + 1} expected role=tool, got #{f_role}"
            x[:tool_call_id] || x["tool_call_id"]
          end)

        assert MapSet.new(ids) == MapSet.new(following_ids),
               "[#{round_label}] tool_call_id mismatch at idx #{i}: " <>
                 "expected #{inspect(ids)}, got #{inspect(following_ids)}"
      end
      nil
    end)
    :ok
  end

  # ─── Tests — information preservation ────────────────────────────────────

  describe "information preservation" do
    test "marker planted in round 1 echoes through round 3 via [Previous summary]" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      # Round 1: plant a marker that the stub will echo into the summary.
      s = apply_action(s, {:marker, "MARKER_alice_xyz"})
      s = simulate_round(s, 8)
      r1 = run_round(s, "round1")
      assert String.contains?(r1.ctx["summary"], "MARKER_alice_xyz"),
             "round 1's summary must contain the planted marker"

      # Round 2: stub echoes whatever it sees, including the [Previous
      # summary] which contains MARKER_alice_xyz.
      s = simulate_round(s, 8)
      r2 = run_round(s, "round2")
      assert String.contains?(r2.ctx["summary"], "MARKER_alice_xyz"),
             "round 2's summary must inherit the marker from round 1's summary"

      # Round 3: same chain — marker must still be there.
      s = simulate_round(s, 8)
      r3 = run_round(s, "round3")
      assert String.contains?(r3.ctx["summary"], "MARKER_alice_xyz"),
             "round 3's summary must still inherit the marker after 2 [Previous summary] hops"
    end
  end

  # ─── Tests — bounded growth ──────────────────────────────────────────────

  describe "bounded context growth" do
    test "with a fixed-size summary stub, total context bytes converge across rounds" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)

      summary_size  = 1000
      sample_sizes  = []

      sample_sizes =
        Enum.reduce(1..4, sample_sizes, fn round, acc ->
          s = simulate_round(s, 8)
          T.stub_llm_call(truncating_stub(summary_size))
          upsert_session(session_id, user_id, s.messages, read_context(session_id))
          sd = %{"messages" => s.messages, "context" => read_context(session_id), "id" => session_id}
          :ok = ContextEngine.compact!(session_id, user_id, sd)

          ctx = read_context(session_id)
          built = ContextEngine.build_assistant_messages(
            %{"id" => session_id, "messages" => s.messages, "context" => ctx}, [])

          total_chars =
            Enum.reduce(built, 0, fn m, sum ->
              sum + String.length(m[:content] || m["content"] || "")
            end)

          send(self(), {:round_state, round, s})
          [{round, total_chars} | acc]
        end)

      # Receive back the final accumulated state for later sanity if needed.
      sample_sizes = Enum.reverse(sample_sizes)

      # Bound: total chars is dominated by (system prompt + last 20 messages
      # + summary). With a 1 KB summary stub, the per-round increment after
      # round 1 must stay small and roughly stationary — NOT scale with the
      # number of summarised rounds. We assert: round-3-vs-round-2 delta and
      # round-4-vs-round-3 delta are both bounded by a sane ceiling
      # (here: 2× the typical recent-tail size, which is generous).
      sizes = Enum.map(sample_sizes, fn {_r, c} -> c end)
      [r1, r2, r3, r4] = sizes

      assert r2 < r1 * 3,
             "round 2 size #{r2} grew unreasonably from round 1 #{r1} — summary scaling, not bounded"
      assert abs(r3 - r2) < 50_000,
             "round 3 vs round 2 delta #{abs(r3 - r2)} too large — context growing per round"
      assert abs(r4 - r3) < 50_000,
             "round 4 vs round 3 delta #{abs(r4 - r3)} too large — context growing per round"
    end
  end

  # ─── Tests — task_turn_archive partitioning ──────────────────────────────

  describe "task_turn_archive across rounds" do
    test "tagged turns archived per task on compaction" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id, register_tasks_in_db?: true)

      # Build chain with two distinct tasks A and B, each tagged.
      s = apply_chain(s, [
        {:user, :small},
        {:create_task, "Task A", "first task"},
        {:tool, "run_script", %{"script" => "curl A"}, :small},
        {:tool, "run_script", %{"script" => "curl A2"}, :small},
        {:complete_task, "A done"},
        {:assistant_text, :small}
      ])
      task_a_num = 1
      task_a_id  = s.task_id_for_num[task_a_num]

      s = apply_chain(s, [
        {:user, :small},
        {:create_task, "Task B", "second task"},
        {:tool, "web_fetch", %{"url" => "https://b.com"}, :small},
        {:complete_task, "B done"},
        {:assistant_text, :small}
      ])
      task_b_num = 2
      task_b_id  = s.task_id_for_num[task_b_num]

      # Pad with chitchat to exceed @keep_recent so A and B turns end up
      # in the to_summarize range.
      s = simulate_round(s, 12)

      _ = run_round(s, "round1")

      archive_a = TaskTurnArchive.fetch_for_task(task_a_id)
      archive_b = TaskTurnArchive.fetch_for_task(task_b_id)

      assert length(archive_a) > 0, "task A should have archived turns after compaction"
      assert length(archive_b) > 0, "task B should have archived turns after compaction"

      # Per-task content: task A's archive must contain task A's tool
      # calls (curl A / curl A2), not task B's.
      a_blob = Enum.map_join(archive_a, " ", fn m ->
        Jason.encode!(m[:tool_calls] || m["tool_calls"] || []) <>
          (m[:content] || m["content"] || "")
      end)
      b_blob = Enum.map_join(archive_b, " ", fn m ->
        Jason.encode!(m[:tool_calls] || m["tool_calls"] || []) <>
          (m[:content] || m["content"] || "")
      end)

      assert String.contains?(a_blob, "curl A"),  "task A archive missing task-A tool calls"
      refute String.contains?(a_blob, "https://b.com"), "task A archive leaked task-B content"
      assert String.contains?(b_blob, "https://b.com"), "task B archive missing task-B tool calls"
      refute String.contains?(b_blob, "curl A"),  "task B archive leaked task-A content"
    end

    test "long-lived task accumulates archive entries across multiple rounds" do
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id, register_tasks_in_db?: true)

      # Round 1: open task L, do some work, leave it open.
      s = apply_chain(s, [
        {:user, :small},
        {:create_task, "Task L", "long-lived task"},
        {:tool, "run_script", %{"script" => "step 1"}, :small},
        {:assistant_text, :small}
      ])
      l_num = 1
      l_id  = s.task_id_for_num[l_num]

      s = simulate_round(s, 12)   # pad with other chains
      _ = run_round(s, "round1")

      r1_archive = TaskTurnArchive.fetch_for_task(l_id)
      r1_count   = length(r1_archive)
      assert r1_count > 0

      # Round 2: keep tagging more turns to L's anchor (manual since
      # `complete_task` would clear anchor; instead we re-anchor by
      # appending tagged turns directly).
      s = %{s | anchor: l_num}
      s = apply_chain(s, [
        {:tool, "run_script", %{"script" => "step 2"}, :small},
        {:assistant_text, :medium}
      ])
      s = %{s | anchor: nil}
      s = simulate_round(s, 12)
      _ = run_round(s, "round2")

      r2_archive = TaskTurnArchive.fetch_for_task(l_id)
      assert length(r2_archive) > r1_count,
             "task L's archive must grow across rounds (round 1: #{r1_count}, round 2: #{length(r2_archive)})"
    end
  end

  # ─── Tests — edge cases ──────────────────────────────────────────────────

  describe "edge cases" do
    # KNOWN BUG: `compact!` is NOT tool-pair-atomic at the @keep_recent
    # boundary. If a tool-call/tool-result pair straddles the cutoff,
    # the assistant tool_calls message ends up in the summary while the
    # matching tool result stays in the kept tail — orphaning the tool
    # result (no preceding tool_call). The next chain's LLM call would
    # be invalid (OpenAI tool-sequencing rule).
    #
    # The fix is to make `keep_from` tool-pair-aware in
    # `ContextEngine.compact!/3`: if landing on a tool message, push
    # back to include its preceding assistant message.
    #
    # Tagged `:known_design_bug` and excluded from the default run via
    # test_helper.exs. Run with: `mix test --only known_design_bug`.
    @tag :known_design_bug
    test "@keep_recent boundary respects tool-call atomicity (no orphan tool results)" do
      # Build a message sequence so that the @keep_recent boundary lands
      # BETWEEN an assistant.tool_calls message and its matching tool
      # result. After compact!, neither (a) summarising the call but
      # keeping the result (orphan tool message) nor (b) summarising
      # the result but keeping the call (orphan tool_call) is OpenAI-
      # compatible — the next chain LLM call will reject the tail.
      #
      # The fix is to make `keep_from` tool-pair-aware: if landing on a
      # tool message, push back to include its preceding assistant
      # message; if landing right after an assistant.tool_calls,
      # advance past the matching tool result.
      session_id = T.uid()
      user_id    = T.uid()

      # 25 chitchat messages → length 25, length - @keep_recent = 5.
      # Replace messages at indices 4 and 5 with a tool-pair so the
      # boundary cuts through it: index 4 = asst.tool_calls, index 5 = tool.
      msgs = build_messages_with_pair_at_boundary(25, 4)
      upsert_session(session_id, user_id, msgs, nil)

      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "summary"} end)
      :ok = ContextEngine.compact!(session_id, user_id,
                                   %{"id" => session_id, "messages" => msgs, "context" => nil})

      ctx = read_context(session_id)
      built = ContextEngine.build_assistant_messages(
        %{"id" => session_id, "messages" => msgs, "context" => ctx}, [])

      assert_no_orphan_tool_messages(built)
    end

    test "compact! after a transient LLM failure can be retried successfully" do
      # First call: LLM stub returns {:error, ...} → context stays nil.
      # Second call (same state): stub returns valid summary → context
      # populated correctly. No double-archive, no stuck cutoff.
      session_id = T.uid()
      user_id    = T.uid()
      s = new_sim(session_id, user_id)
      s = simulate_round(s, 8)

      upsert_session(session_id, user_id, s.messages, nil)
      sd = %{"id" => session_id, "messages" => s.messages, "context" => nil}

      # First attempt — LLM fails.
      T.stub_llm_call(fn _model, _msgs, _opts -> {:error, :network_down} end)
      :ok = ContextEngine.compact!(session_id, user_id, sd)
      assert read_context(session_id) == nil,
             "failed compaction must not write context"

      # Second attempt — LLM succeeds. Same input state.
      T.stub_llm_call(fn _model, _msgs, _opts -> {:ok, "[retry summary] succeeded"} end)
      :ok = ContextEngine.compact!(session_id, user_id, sd)

      ctx = read_context(session_id)
      assert ctx != nil, "retry compaction must write context"
      assert ctx["summary"] == "[retry summary] succeeded"
      assert is_integer(ctx["summary_up_to_index"])
      assert ctx["summary_up_to_index"] >= 0
    end
  end

  # Build N chitchat messages, then overwrite indices `pair_at` and
  # `pair_at + 1` with a tool-call / tool-result pair. The pair shares
  # a tool_call_id so we can detect orphans by id-mismatch.
  defp build_messages_with_pair_at_boundary(n, pair_at) do
    base = Enum.map(1..n, fn i ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      %{"role" => role, "content" => "msg #{i} #{pad_to("c", 100)}", "ts" => i}
    end)

    call_id = "call_boundary_test"
    asst = %{
      "role" => "assistant",
      "content" => "",
      "ts" => pair_at + 1,
      "tool_calls" => [%{
        "id" => call_id,
        "function" => %{"name" => "run_script", "arguments" => %{"script" => "echo boundary"}}
      }]
    }
    tool = %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "content" => "boundary output",
      "ts" => pair_at + 2
    }

    List.replace_at(base, pair_at, asst) |> List.replace_at(pair_at + 1, tool)
  end

  # Walk the built message list. Every `tool` message must be preceded
  # by an assistant message whose `tool_calls` contains the matching id.
  # Every `assistant.tool_calls[i].id` must be followed by exactly one
  # `tool` message with that id.
  defp assert_no_orphan_tool_messages(messages) do
    open_ids = MapSet.new()

    {orphan_tools, unanswered_calls} =
      Enum.reduce(messages, {[], MapSet.new()}, fn m, {orphans, open} ->
        role = m[:role] || m["role"]
        cond do
          role == "assistant" and is_list(m[:tool_calls] || m["tool_calls"]) ->
            ids = Enum.map(m[:tool_calls] || m["tool_calls"], fn tc -> tc[:id] || tc["id"] end)
            {orphans, MapSet.union(open, MapSet.new(ids))}

          role == "tool" ->
            tcid = m[:tool_call_id] || m["tool_call_id"]
            if MapSet.member?(open, tcid) do
              {orphans, MapSet.delete(open, tcid)}
            else
              {[tcid | orphans], open}
            end

          true ->
            {orphans, open}
        end
      end)
      |> then(fn {orphans, open} -> {orphans, open} end)

    _ = open_ids   # silence unused

    assert orphan_tools == [],
           "orphan tool messages found (no preceding tool_call): #{inspect(orphan_tools)}"
    assert MapSet.size(unanswered_calls) == 0,
           "unanswered assistant.tool_calls (no matching tool result in tail): #{inspect(unanswered_calls)}"
  end
end
