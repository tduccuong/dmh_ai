# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Layer-3 deterministic replay tests for the Set-of-Marks
# `Browser.Loop`.
#
# Each scenario has a `<name>.trace.json` fixture under
# `test/fixtures/browser_traces/`. The test:
#
#   1. Loads the trace.
#   2. Installs `AgentStub` in replay mode (daemon + LLM stubbed).
#   3. Runs `Browser.Loop.run/4` with the trace's url / goal /
#      constraints / client_viewport.
#   4. Asserts terminal result matches the trace's `expected` block.
#
# Drift in the rendered observation text (system-prompt change,
# observation-builder change, ELEMENTS-list change, action-sequence
# change) trips a byte-level assertion inside `AgentStub`. Image
# bytes in the multimodal user message are passed through but NOT
# compared — the text frame is the deterministic signal. Re-record
# with:
#
#     REGENERATE_TRACES=1 mix test test/itgr_browser_replay.exs

defmodule DmhAi.Browser.AgentReplayTest do
  use ExUnit.Case, async: false

  alias DmhAi.Browser.{AgentStub, Loop}

  @fixtures_dir Path.join([__DIR__, "fixtures", "browser_traces"])

  # 1×1 white JPEG, base64-encoded. The Navigator gets this as the
  # image content in every stubbed turn — the loop doesn't
  # introspect image bytes, and replay assertions are on the text
  # frame only.
  @tiny_jpeg_b64 "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AVN//2Q=="

  setup do
    on_exit(fn -> _ = AgentStub.uninstall() end)
    :ok
  end

  describe "read_only_extract" do
    @scenario "read_only_extract"
    @trace_path Path.join(@fixtures_dir, "#{@scenario}.trace.json")

    test "observe → extract_text → complete (2 turns)" do
      maybe_regenerate(@scenario)
      run_scenario(@trace_path)
    end
  end

  describe "cookie_modal_dismiss" do
    @scenario "cookie_modal_dismiss"
    @trace_path Path.join(@fixtures_dir, "#{@scenario}.trace.json")

    test "observe → click {idx 1} → complete (2 turns)" do
      maybe_regenerate(@scenario)
      run_scenario(@trace_path)
    end
  end

  describe "stuck_action_halt" do
    @scenario "stuck_action_halt"
    @trace_path Path.join(@fixtures_dir, "#{@scenario}.trace.json")

    test "same failing click twice → stuck_action halt" do
      maybe_regenerate(@scenario)
      run_scenario(@trace_path)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp run_scenario(trace_path) do
    trace = AgentStub.install_replay(trace_path)
    viewport = atomize_viewport(trace["client_viewport"])

    {:ok, result} =
      Loop.run(
        trace["url"],
        trace["goal"],
        trace["constraints"],
        test_ctx(viewport)
      )

    expected = trace["expected"] || %{}
    assert result.status == expected["status"]
    assert result.turns == expected["turns"]

    assert AgentStub.uninstall() == :ok
  end

  defp test_ctx(viewport) do
    %{
      user_id: "u_replay_test",
      user_email: "replay@dmhai.test",
      session_id: "s_replay_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
      task_id: nil,
      progress_row_id: nil,
      client_viewport: viewport
    }
  end

  defp atomize_viewport(nil), do: nil
  defp atomize_viewport(%{"w" => w, "h" => h, "is_mobile" => m}),
    do: %{w: w, h: h, is_mobile: m}

  defp atomize_viewport(_), do: nil

  # ── trace regeneration ─────────────────────────────────────────────────

  defp maybe_regenerate("read_only_extract" = scenario) do
    if System.get_env("REGENERATE_TRACES") == "1" do
      url = "https://example.test/article"
      goal = "Describe the front-page content."
      viewport = %{w: 390, h: 844, is_mobile: true}

      page_text =
        "Welcome to ExampleTest — a demo site. Featured today: " <>
          "widget engineering, a CEO interview, the weekly roundup. " <>
          "Sign up for the newsletter at the bottom."

      page_elements = [
        %{"idx" => 1, "tag" => "a",      "text" => "Read more",
          "x" => 20, "y" => 100, "w" => 80, "h" => 24},
        %{"idx" => 2, "tag" => "button", "text" => "Subscribe",
          "x" => 20, "y" => 140, "w" => 100, "h" => 36}
      ]

      daemon_calls = [
        # Initial navigation.
        %{"command" => "navigate",
          "result" => %{"url" => url, "title" => "ExampleTest", "status" => 200}},
        # Turn 0: observe + extract_text {body} + (next turn) observe again.
        observe_call(url, "ExampleTest", viewport, page_elements),
        %{"command" => "extract_text",
          "result" => %{"text" => page_text, "url" => url, "matches" => 1}},
        # Turn 1: observe (EXTRACTED_TEXT now in the observation text frame).
        observe_call(url, "ExampleTest", viewport, page_elements)
        # Turn 1: model emits complete — no daemon call.
      ]

      llm_responses = [
        Jason.encode!(%{
          "action" => "extract_text",
          "args" => %{},
          "reason" => "Read the page to satisfy the describe goal."
        }),
        Jason.encode!(%{
          "action" => "complete",
          "args" => %{
            "reason" => "Content read; goal satisfied.",
            "result" =>
              "ExampleTest features widget engineering, a CEO interview, and the weekly roundup."
          }
        })
      ]

      regenerate(scenario,
        url: url, goal: goal, constraints: nil,
        viewport: viewport,
        daemon_calls: daemon_calls, llm_responses: llm_responses
      )
    end
  end

  defp maybe_regenerate("cookie_modal_dismiss" = scenario) do
    if System.get_env("REGENERATE_TRACES") == "1" do
      url = "https://example.test/consent"
      goal = "Accept cookies so the page is usable."
      viewport = %{w: 390, h: 844, is_mobile: true}

      pre_dismiss = [
        %{"idx" => 1, "tag" => "button", "text" => "Accept",
          "x" => 130, "y" => 600, "w" => 130, "h" => 40},
        %{"idx" => 2, "tag" => "button", "text" => "Reject",
          "x" => 20, "y" => 600, "w" => 100, "h" => 40}
      ]

      post_dismiss = [
        %{"idx" => 1, "tag" => "a", "text" => "Read article",
          "x" => 20, "y" => 200, "w" => 120, "h" => 24}
      ]

      daemon_calls = [
        %{"command" => "navigate",
          "result" => %{"url" => url, "title" => "Consent gate", "status" => 200}},
        # Turn 0: observe — Accept at idx 1.
        observe_call(url, "Consent gate", viewport, pre_dismiss),
        # Turn 0: click {index: 1}.
        %{"command" => "click",
          "result" => %{"clicked" => 1, "tag" => "button"}},
        # Turn 1: observe — modal gone, content visible.
        observe_call(url, "Consent gate — content", viewport, post_dismiss)
        # Turn 1: model emits complete — no daemon call.
      ]

      llm_responses = [
        Jason.encode!(%{
          "action" => "click",
          "args" => %{"index" => 1},
          "reason" => "Click the Accept button to dismiss the cookie modal."
        }),
        Jason.encode!(%{
          "action" => "complete",
          "args" => %{
            "reason" => "Cookie modal dismissed; page is usable.",
            "result" => "Cookies accepted."
          }
        })
      ]

      regenerate(scenario,
        url: url, goal: goal, constraints: nil,
        viewport: viewport,
        daemon_calls: daemon_calls, llm_responses: llm_responses
      )
    end
  end

  defp maybe_regenerate("stuck_action_halt" = scenario) do
    if System.get_env("REGENERATE_TRACES") == "1" do
      url = "https://example.test/stuck"
      goal = "Click the right button to proceed."
      viewport = %{w: 390, h: 844, is_mobile: true}

      # Page consistently has 2 elements. The model emits `click {idx 99}`
      # repeatedly; the daemon returns `stale_index` each time. The
      # Loop's stuck-action detector halts after
      # `browserStuckActionLimit` consecutive identical-args failures
      # (currently 3 strikes).
      elements = [
        %{"idx" => 1, "tag" => "button", "text" => "A",
          "x" => 20, "y" => 200, "w" => 60, "h" => 36},
        %{"idx" => 2, "tag" => "button", "text" => "B",
          "x" => 100, "y" => 200, "w" => 60, "h" => 36}
      ]

      stale_envelope = %{"error" => "stale_index",
                          "reason" => "no element 99 in current observation"}

      daemon_calls = [
        %{"command" => "navigate",
          "result" => %{"url" => url, "title" => "Stuck page", "status" => 200}},
        observe_call(url, "Stuck page", viewport, elements),
        %{"command" => "click", "result" => stale_envelope},
        observe_call(url, "Stuck page", viewport, elements),
        %{"command" => "click", "result" => stale_envelope},
        observe_call(url, "Stuck page", viewport, elements),
        %{"command" => "click", "result" => stale_envelope}
      ]

      click_99 =
        Jason.encode!(%{
          "action" => "click",
          "args" => %{"index" => 99},
          "reason" => "Try idx 99 (model out-of-range)."
        })

      llm_responses = [click_99, click_99, click_99]

      regenerate(scenario,
        url: url, goal: goal, constraints: nil,
        viewport: viewport,
        daemon_calls: daemon_calls, llm_responses: llm_responses
      )
    end
  end

  defp regenerate(scenario, opts) do
    AgentStub.install_capture(opts[:daemon_calls], opts[:llm_responses])

    {:ok, result} =
      Loop.run(opts[:url], opts[:goal], opts[:constraints],
        test_ctx(opts[:viewport]))

    trace =
      AgentStub.captured_trace(%{
        scenario: scenario,
        url: opts[:url],
        goal: opts[:goal],
        constraints: opts[:constraints],
        client_viewport: %{"w" => opts[:viewport].w, "h" => opts[:viewport].h,
                            "is_mobile" => opts[:viewport].is_mobile},
        expected: %{"status" => result.status, "turns" => result.turns}
      })

    path = Path.join(@fixtures_dir, "#{scenario}.trace.json")
    File.write!(path, Jason.encode_to_iodata!(trace, pretty: true))
    IO.puts("[AgentReplayTest] regenerated #{path}")

    _ = AgentStub.uninstall()
    :ok
  end

  defp observe_call(url, title, viewport, elements) do
    %{
      "command" => "observe",
      "result" => %{
        "image_b64" => @tiny_jpeg_b64,
        "mime" => "image/jpeg",
        "viewport" => %{"w" => viewport.w, "h" => viewport.h},
        "url" => url,
        "title" => title,
        "elements" => elements
      }
    }
  end
end
