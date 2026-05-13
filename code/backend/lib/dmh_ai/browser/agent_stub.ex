# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.AgentStub do
  @moduledoc """
  Test harness for `Browser.Loop`. Plugs the LLM and DaemonClient
  stub seams so a replay test can drive the action loop without a
  real Chromium or a real Navigator-model call. Two modes:

    - `:replay` — load a `.trace.json` and assert each LLM call sees
      the same OBSERVATION TEXT as recorded. Daemon responses are
      replayed in order. Image bytes in the user message are passed
      through but NOT compared (binary equality is fragile across
      browser-engine versions; the text frame is the signal).

    - `:capture` — supply pre-written daemon responses and LLM
      action JSONs; the harness records the rendered observations
      so they can be exported into a new `.trace.json`.

  Trace shape:

      {
        "scenario":         "<human label>",
        "url":              "https://...",
        "goal":             "...",
        "constraints":      "...",
        "client_viewport":  {"w": ..., "h": ..., "is_mobile": ...},
        "daemon_calls": [
          { "command": "navigate", "result": {"url": "...", "title": "..."} },
          { "command": "observe",  "result": {"image_b64": "...", "mime": "image/jpeg",
                                              "viewport": {"w": ..., "h": ...},
                                              "url": "...", "title": "...",
                                              "elements": [{"idx": 1, "tag": "button",
                                                            "text": "Accept", ...}]} },
          { "command": "click",    "result": {"clicked": 1, "tag": "button"} },
          ...
        ],
        "llm_pairs": [
          { "observation": "URL: ...\\n...", "response": "{\\"action\\":...}" },
          ...
        ],
        "expected": { "status": "completed", "turns": 2 }
      }

  Stubs read sequential counters from the calling process's process
  dictionary; replay tests should run `async: false`.
  """

  @doc """
  Install replay stubs against the trace at `path`. Returns the
  parsed trace map.
  """
  @spec install_replay(Path.t()) :: map()
  def install_replay(path) when is_binary(path) do
    trace = path |> File.read!() |> Jason.decode!()
    do_install(:replay, trace)
    trace
  end

  @doc """
  Install capture stubs with pre-written daemon responses and LLM
  action JSONs. Observations sent to the LLM are captured for later
  export via `captured_trace/1`.
  """
  @spec install_capture([map()], [String.t()]) :: :ok
  def install_capture(daemon_calls, llm_responses)
      when is_list(daemon_calls) and is_list(llm_responses) do
    state = %{
      "daemon_calls" => daemon_calls,
      "_llm_responses" => llm_responses
    }

    do_install(:capture, state)
    Process.put(:agent_stub_captured_obs, [])
    :ok
  end

  @doc """
  Export a `.trace.json`-shaped map from the captured run. `meta`
  supplies scenario / url / goal / constraints / expected. Only
  valid after `install_capture/2` + a `Browser.Loop.run/4` call.
  """
  @spec captured_trace(map()) :: map()
  def captured_trace(meta) when is_map(meta) do
    state = Process.get(:agent_stub_trace) || %{}
    observations = Process.get(:agent_stub_captured_obs) || []
    responses = state["_llm_responses"] || []

    pairs =
      observations
      |> Enum.with_index()
      |> Enum.map(fn {obs, i} ->
        %{"observation" => obs, "response" => Enum.at(responses, i)}
      end)

    %{
      "scenario" => meta[:scenario] || meta["scenario"],
      "url" => meta[:url] || meta["url"],
      "goal" => meta[:goal] || meta["goal"],
      "constraints" => meta[:constraints] || meta["constraints"],
      "client_viewport" => meta[:client_viewport] || meta["client_viewport"],
      "daemon_calls" => state["daemon_calls"],
      "llm_pairs" => pairs,
      "expected" => meta[:expected] || meta["expected"]
    }
  end

  @doc """
  Tear down stubs. In `:replay` mode asserts the trace was fully
  consumed; returns `{:error, msg}` if the loop terminated early.
  """
  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    mode = Process.get(:agent_stub_mode)
    trace = Process.get(:agent_stub_trace)
    daemon_idx = Process.get(:agent_stub_daemon_idx) || 0
    llm_idx = Process.get(:agent_stub_llm_idx) || 0

    Application.delete_env(:dmh_ai, :__llm_call_stub__)
    Application.delete_env(:dmh_ai, :__daemon_client_stub__)
    Process.delete(:agent_stub_mode)
    Process.delete(:agent_stub_trace)
    Process.delete(:agent_stub_daemon_idx)
    Process.delete(:agent_stub_llm_idx)
    Process.delete(:agent_stub_captured_obs)

    if mode == :replay and is_map(trace) do
      daemon_total = length(trace["daemon_calls"] || [])
      llm_total = length(trace["llm_pairs"] || [])

      cond do
        daemon_idx < daemon_total ->
          {:error,
           "trace under-consumed: daemon_calls #{daemon_idx}/#{daemon_total}"}

        llm_idx < llm_total ->
          {:error,
           "trace under-consumed: llm_pairs #{llm_idx}/#{llm_total}"}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc "Inspect how many trace entries have been consumed so far."
  @spec consumed() :: %{daemon: non_neg_integer(), llm: non_neg_integer()}
  def consumed do
    %{
      daemon: Process.get(:agent_stub_daemon_idx) || 0,
      llm: Process.get(:agent_stub_llm_idx) || 0
    }
  end

  # ── install / dispatch ────────────────────────────────────────────────────

  defp do_install(mode, state) do
    Process.put(:agent_stub_mode, mode)
    Process.put(:agent_stub_trace, state)
    Process.put(:agent_stub_daemon_idx, 0)
    Process.put(:agent_stub_llm_idx, 0)

    Application.put_env(:dmh_ai, :__llm_call_stub__, &llm_stub/3)
    Application.put_env(:dmh_ai, :__daemon_client_stub__, &daemon_stub/3)
  end

  defp llm_stub(_model, messages, _opts) do
    case Process.get(:agent_stub_mode) do
      :replay -> llm_replay(messages)
      :capture -> llm_capture(messages)
    end
  end

  defp daemon_stub(command, _args, _ctx) do
    state = Process.get(:agent_stub_trace)
    idx = Process.get(:agent_stub_daemon_idx)
    calls = state["daemon_calls"] || []
    entry = Enum.at(calls, idx)

    if entry == nil do
      raise "AgentStub: daemon_calls exhausted at idx=#{idx} (loop made more daemon calls than recorded)"
    end

    expected_cmd = entry["command"]

    if expected_cmd != command do
      raise "AgentStub: daemon command drift at idx=#{idx} — expected #{inspect(expected_cmd)}, got #{inspect(command)}"
    end

    Process.put(:agent_stub_daemon_idx, idx + 1)

    case entry["result"] do
      %{"error" => err_type} = err ->
        msg = err["reason"] || err["message"] || err_type
        {:error, {:daemon_error, %{type: err_type, message: to_string(msg)}}}

      result when is_map(result) ->
        {:ok, result}

      nil ->
        {:error, {:daemon_error, %{type: "stub_null", message: "trace entry has no result"}}}
    end
  end

  # ── LLM modes ─────────────────────────────────────────────────────────────

  defp llm_replay(messages) do
    state = Process.get(:agent_stub_trace)
    idx = Process.get(:agent_stub_llm_idx)
    pairs = state["llm_pairs"] || []
    pair = Enum.at(pairs, idx)

    if pair == nil do
      raise "AgentStub: llm_pairs exhausted at idx=#{idx} (loop made more LLM calls than recorded)"
    end

    actual_obs = extract_observation_text(messages)
    expected_obs = pair["observation"]

    if actual_obs != expected_obs do
      diff = first_diff(expected_obs, actual_obs)

      raise """
      AgentStub: Navigator observation drift at idx=#{idx} of #{length(pairs)}.

      First difference at byte offset #{diff.offset}:
        expected: …#{diff.expected_window}…
        actual:   …#{diff.actual_window}…

      Re-record with `REGENERATE_TRACES=1 mix test test/itgr_browser_replay.exs`
      if this drift is intentional.
      """
    end

    Process.put(:agent_stub_llm_idx, idx + 1)
    {:ok, pair["response"]}
  end

  defp llm_capture(messages) do
    state = Process.get(:agent_stub_trace)
    idx = Process.get(:agent_stub_llm_idx)
    responses = state["_llm_responses"] || []
    response = Enum.at(responses, idx)

    if response == nil do
      raise "AgentStub capture: ran out of pre-supplied LLM responses at idx=#{idx}"
    end

    actual_obs = extract_observation_text(messages)
    captured = Process.get(:agent_stub_captured_obs) || []
    Process.put(:agent_stub_captured_obs, captured ++ [actual_obs])

    Process.put(:agent_stub_llm_idx, idx + 1)
    {:ok, response}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Pull the text portion of the user message. The Navigator gets a
  # multimodal content list (image + text) — we record/replay only
  # the text; image binary equality is fragile.
  defp extract_observation_text(messages) do
    last = List.last(messages) || %{}
    content = Map.get(last, "content") || Map.get(last, :content) || ""

    cond do
      is_binary(content) ->
        content

      is_list(content) ->
        content
        |> Enum.find_value("", fn part ->
          type = Map.get(part, "type") || Map.get(part, :type)

          cond do
            type == "text" -> Map.get(part, "text") || Map.get(part, :text)
            true -> false
          end
        end)

      true ->
        ""
    end
  end

  defp first_diff(expected, actual) when is_binary(expected) and is_binary(actual) do
    offset = first_diff_offset(expected, actual, 0)
    window = 60

    %{
      offset: offset,
      expected_window: snippet(expected, offset, window),
      actual_window: snippet(actual, offset, window)
    }
  end

  defp first_diff(_, _), do: %{offset: 0, expected_window: "", actual_window: ""}

  defp first_diff_offset("", "", off), do: off
  defp first_diff_offset("", _, off), do: off
  defp first_diff_offset(_, "", off), do: off

  defp first_diff_offset(<<a, ra::binary>>, <<b, rb::binary>>, off) do
    if a == b do
      first_diff_offset(ra, rb, off + 1)
    else
      off
    end
  end

  defp snippet(s, offset, window) when is_binary(s) do
    start = max(0, offset - div(window, 2))
    len = min(byte_size(s) - start, window)

    if len <= 0 do
      ""
    else
      :binary.part(s, start, len) |> String.replace("\n", "\\n")
    end
  end
end
