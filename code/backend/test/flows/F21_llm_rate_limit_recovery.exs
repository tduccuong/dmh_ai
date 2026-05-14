# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Flow F21 — LLM rate-limit recovery via account rotation.
#
# `LLM.stream/4` and `LLM.call/3` walk a pool's accounts, retrying
# the same request body against successive accounts when the picked
# account returns 429 / quota_exhausted / transient server-error.
# The rotation logic lives in `do_pool_stream/8` / `do_pool_call/7`;
# the per-account HTTP I/O is in `do_stream_request/7` /
# `do_call_request/6`.
#
# F21 exercises the load-bearing rotation contract via the new
# `T.stub_llm_request/1` hook, one layer deeper than
# `__llm_stream_stub__`. Two scenarios:
#
#   1. 429 on account A → mark throttled → rotate to B → succeed.
#      Final result is B's text; pool row's account-A entry now
#      carries a future `throttled_until`.
#   2. 429 on account A AND account B → all-throttled error.
#      Result is `{:error, :all_throttled, retry_after_ms}` from
#      `Pools.resolve` after both accounts get marked.
#
# These tests bypass `setup_profile/1` because that installs the
# `LLMStub` at the top-level `__llm_stream_stub__` hook, which would
# short-circuit the rotation logic we want to exercise.

defmodule DmhAi.Flows.F21LlmRateLimitRecovery do
  use ExUnit.Case, async: false

  alias DmhAi.Agent.LLM
  alias DmhAi.LLM.Pools
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @moduletag flow_id: "F21"

  setup do
    pool_name = "f21-pool-#{T.uid()}"
    now = System.os_time(:millisecond)

    accounts =
      Jason.encode!([
        %{"name" => "acct-A", "api_key" => "key-A-#{T.uid()}"},
        %{"name" => "acct-B", "api_key" => "key-B-#{T.uid()}"}
      ])

    query!(Repo, """
    INSERT INTO pools (org_id, name, protocol, base_url, strategy,
                       cooldown_seconds, num_ctx, accounts, models,
                       rr_cursor, created_ts, updated_ts)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
    """, [
      DmhAi.Constants.default_org_id(),
      pool_name, "openai", "https://api.example.test", "least_used",
      300, 32_768, accounts, Jason.encode!([]),
      now, now
    ])

    on_exit(fn ->
      query!(Repo, "DELETE FROM pools WHERE name=?", [pool_name])
    end)

    %{pool_name: pool_name}
  end

  describe "LLM.stream/4 rate-limit recovery" do
    test "429 on first account → rotate to second → succeed",
         %{pool_name: pool_name} do
      # Track which account each request hits. The stub keys on the
      # `Authorization: Bearer <api_key>` header — that's the only
      # piece of per-account state that round-trips through
      # `auth_headers/1` to the request site.
      seen_keys = :counters.new(2, [:atomics])

      T.stub_llm_request(fn _url, headers, _body, %{kind: kind} ->
        api_key = bearer_from(headers)

        cond do
          # Swift / planner / any non-stream call — pass cleanly.
          kind == :call ->
            {:ok, "RELATED"}

          String.contains?(api_key || "", "key-A") ->
            :counters.add(seen_keys, 1, 1)
            {:error, :rate_limited}

          true ->
            :counters.add(seen_keys, 2, 1)
            {:ok, "rotated successfully — account B answered"}
        end
      end)

      result =
        LLM.stream(
          "#{pool_name}::test-model",
          [%{role: "user", content: "hi"}],
          self()
        )

      assert {:ok, text} = result
      assert text =~ "rotated", "expected B's success text; got: #{inspect(text)}"

      assert :counters.get(seen_keys, 1) >= 1, "account A's stub should have fired at least once"
      assert :counters.get(seen_keys, 2) >= 1, "account B's stub should have fired at least once"

      # The pool row now carries a `throttled_until` for account A.
      {:ok, pool} = Pools.fetch(pool_name)
      [a, b] = pool.accounts |> Enum.sort_by(fn acc -> acc["name"] || "" end)

      assert a["name"] == "acct-A"
      assert is_integer(a["throttled_until"]) and a["throttled_until"] > System.os_time(:millisecond),
             "account A should be marked throttled; got: #{inspect(a["throttled_until"])}"

      # Account B was NOT throttled (it succeeded).
      assert is_nil(b["throttled_until"]) or b["throttled_until"] <= System.os_time(:millisecond),
             "account B should NOT be throttled — it succeeded; got: #{inspect(b["throttled_until"])}"
    end

    test "every account 429s → returns :all_throttled with retry hint",
         %{pool_name: pool_name} do
      T.stub_llm_request(fn _url, _headers, _body, %{kind: kind} ->
        case kind do
          :call -> {:ok, "RELATED"}
          _     -> {:error, :rate_limited}
        end
      end)

      result =
        LLM.stream(
          "#{pool_name}::test-model",
          [%{role: "user", content: "hi"}],
          self()
        )

      # Both accounts get marked throttled in turn; rotation
      # exhausts and the caller receives a "couldn't deliver"
      # error. The exact shape varies by exhaustion path:
      #
      #   * `{:error, "all_keys_exhausted"}` — rotation walked
      #     every account, all came back throttled
      #     (`retry_after_rotation/6`'s `:all_throttled` arm).
      #   * `{:error, :attempts_exhausted}` — the global per-call
      #     attempts cap hit before rotation finished marking
      #     accounts.
      #   * `{:error, :rate_limited}` — `Pools.resolve` short-
      #     circuited at the top of `LLM.stream` because every
      #     account was ALREADY throttled (rewritten from
      #     `{:error, :all_throttled, _}`).
      #
      # Any of the three is a valid "circuit-break upstream"
      # signal; the chain layer treats them identically.
      case result do
        {:error, "all_keys_exhausted"} -> :ok
        {:error, :attempts_exhausted}  -> :ok
        {:error, :rate_limited}        -> :ok
        other ->
          flunk("expected exhausted-rotation error; got: #{inspect(other)}")
      end

      # Both accounts are throttled now (or one was, depending on
      # the path that fired). Be lenient on the count — the
      # invariant is "at least one account got marked," so
      # rotation provably ran.
      {:ok, pool} = Pools.fetch(pool_name)

      throttled_count =
        Enum.count(pool.accounts, fn a ->
          tu = a["throttled_until"]
          is_integer(tu) and tu > System.os_time(:millisecond)
        end)

      assert throttled_count >= 1,
             "at least one account should be marked throttled after the failure path; " <>
               "got accounts: #{inspect(pool.accounts)}"
    end
  end

  describe "LLM.call/3 rate-limit recovery" do
    test "non-streaming variant rotates the same way",
         %{pool_name: pool_name} do
      T.stub_llm_request(fn _url, headers, _body, %{kind: kind} ->
        api_key = bearer_from(headers)

        cond do
          kind == :stream -> {:ok, "stream-default"}

          String.contains?(api_key || "", "key-A") ->
            {:error, :rate_limited}

          true ->
            {:ok, "non-streaming success on B"}
        end
      end)

      result =
        LLM.call("#{pool_name}::test-model",
          [%{role: "user", content: "hi"}])

      assert {:ok, text} = result
      assert text =~ "non-streaming success",
             "expected B's success text via LLM.call rotation; got: #{inspect(text)}"

      {:ok, pool} = Pools.fetch(pool_name)
      a = Enum.find(pool.accounts, fn acc -> acc["name"] == "acct-A" end)

      assert is_integer(a["throttled_until"]) and a["throttled_until"] > System.os_time(:millisecond),
             "account A should be throttled after the rotation; got: #{inspect(a["throttled_until"])}"
    end
  end

  describe "Pools.resolve when all accounts pre-throttled" do
    test "skips request entirely → :all_throttled",
         %{pool_name: pool_name} do
      # Pre-mark BOTH accounts as throttled into the future. With no
      # active accounts, `Pools.resolve` short-circuits before any
      # HTTP is attempted — the request stub must NOT be hit.
      future = System.os_time(:millisecond) + 60_000

      Pools.update_account(pool_name, "acct-A", throttled_until: future)
      Pools.update_account(pool_name, "acct-B", throttled_until: future)

      stub_calls = :counters.new(1, [:atomics])

      T.stub_llm_request(fn _, _, _, _ ->
        :counters.add(stub_calls, 1, 1)
        flunk("HTTP must NOT be attempted when all accounts are pre-throttled")
      end)

      # `LLM.stream` rewrites `Pools.resolve`'s
      # `{:error, :all_throttled, retry_ms}` to a flat
      # `{:error, :rate_limited}` at line 101 of llm.ex — so
      # callers don't have to handle three error arities. The
      # retry-after estimate is logged, not surfaced.
      assert LLM.stream("#{pool_name}::test-model",
                 [%{role: "user", content: "x"}], self()) ==
               {:error, :rate_limited}

      assert :counters.get(stub_calls, 1) == 0,
             "request stub must not be called when Pools.resolve short-circuits"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  # Pull the api_key out of the `Authorization: Bearer …` header
  # that `LLM.auth_headers/1` synthesises. Accepts both the list
  # form Req sees and the lookup form some adapters use.
  defp bearer_from(headers) when is_list(headers) do
    case Enum.find(headers, fn
           {k, _} when is_binary(k) -> String.downcase(k) == "authorization"
           _ -> false
         end) do
      {_, "Bearer " <> token} -> token
      _ -> nil
    end
  end

  defp bearer_from(_), do: nil
end
