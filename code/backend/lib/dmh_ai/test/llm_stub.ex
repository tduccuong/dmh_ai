# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Test.LLMStub do
  @moduledoc """
  Tape-playback LLM stub used by `mix flow --profile stub` to drive
  end-to-end flow tests without hitting real LLMs.

  A tape is an ordered list of canned responses. Each `LLM.call/3` and
  `LLM.stream/4` hits the next entry in the tape (sequential cursor).
  Match-by-position is intentional — content matching would require a
  real semantic comparator and would defeat the determinism the stub
  exists to provide.

  Tape miss (cursor past end of tape) raises a fail-loud error with a
  "rerun with `--record` to refresh" hint. Drift surfaces immediately
  rather than silently producing nil/empty responses.

  Wired in via the existing `Application.get_env(:dmh_ai,
  :__llm_call_stub__)` and `:__llm_stream_stub__` hooks already present
  in `DmhAi.Agent.LLM`. Test setup installs the GenServer's stub
  closures; teardown clears them.
  """

  use GenServer

  defstruct [:flow_id, :turns, :cursor, :record_path, :recorded]

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Start a stub holding `tape` (list of turn maps) for the named flow.
  Installs the call/stream stubs into Application env. Returns the
  stub's pid; pass it to `stop/1` in `on_exit`.
  """
  def install(flow_id, tape, opts \\ []) do
    record_path = Keyword.get(opts, :record_path)
    {:ok, pid} = GenServer.start_link(__MODULE__,
      %__MODULE__{flow_id: flow_id, turns: tape, cursor: 0,
                  record_path: record_path, recorded: []})

    Application.put_env(:dmh_ai, :__llm_call_stub__, fn model, msgs, opts ->
      GenServer.call(pid, {:call, model, msgs, opts}, 30_000)
    end)

    Application.put_env(:dmh_ai, :__llm_stream_stub__, fn model, msgs, reply_pid, opts ->
      GenServer.call(pid, {:stream, model, msgs, reply_pid, opts}, 30_000)
    end)

    pid
  end

  @doc """
  Stop the stub and clear the Application-env hooks. If the stub was
  recording, flushes the captured tape to disk.
  """
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      :ok = GenServer.call(pid, :stop_and_flush, 5_000)
      GenServer.stop(pid)
    end

    Application.delete_env(:dmh_ai, :__llm_call_stub__)
    Application.delete_env(:dmh_ai, :__llm_stream_stub__)
    :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:call, _model, _msgs, _opts}, _from, %{cursor: c, turns: turns} = state)
      when c >= length(turns) do
    raise tape_miss_error(state, "call")
  end

  def handle_call({:call, model, _msgs, _opts}, _from, state) do
    turn = Enum.at(state.turns, state.cursor)
    response = turn_to_call_response(turn)
    state = record_if_needed(state, %{kind: "call", model: model, response: turn})
    {:reply, response, %{state | cursor: state.cursor + 1}}
  end

  def handle_call({:stream, _model, _msgs, _reply_pid, _opts}, _from, %{cursor: c, turns: turns} = state)
      when c >= length(turns) do
    raise tape_miss_error(state, "stream")
  end

  def handle_call({:stream, model, _msgs, reply_pid, _opts}, _from, state) do
    turn = Enum.at(state.turns, state.cursor)
    deliver_stream_chunks(turn, reply_pid)
    response = turn_to_call_response(turn)
    state = record_if_needed(state, %{kind: "stream", model: model, response: turn})
    {:reply, response, %{state | cursor: state.cursor + 1}}
  end

  def handle_call(:stop_and_flush, _from, state) do
    if state.record_path && state.recorded != [] do
      File.write!(state.record_path,
        Jason.encode!(%{flow_id: state.flow_id, turns: Enum.reverse(state.recorded)},
          pretty: true))
    end

    {:reply, :ok, state}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp turn_to_call_response(%{"error" => err}), do: {:error, err_atom(err)}
  defp turn_to_call_response(%{error: err}),     do: {:error, err_atom(err)}

  defp turn_to_call_response(%{"tool_calls" => tcs}) when is_list(tcs) and tcs != [] do
    {:ok, {:tool_calls, normalize_tool_calls(tcs)}}
  end
  defp turn_to_call_response(%{tool_calls: tcs}) when is_list(tcs) and tcs != [] do
    {:ok, {:tool_calls, normalize_tool_calls(tcs)}}
  end

  defp turn_to_call_response(%{"text" => t}) when is_binary(t), do: {:ok, t}
  defp turn_to_call_response(%{text: t}) when is_binary(t),     do: {:ok, t}
  defp turn_to_call_response(%{"content" => t}) when is_binary(t), do: {:ok, t}
  defp turn_to_call_response(%{content: t}) when is_binary(t),     do: {:ok, t}

  defp turn_to_call_response(turn) do
    raise "LLMStub: tape entry missing 'text', 'tool_calls', or 'error'. Got: #{inspect(turn)}"
  end

  defp normalize_tool_calls(tcs) do
    Enum.map(tcs, fn tc ->
      %{
        "id" => Map.get(tc, "id") || Map.get(tc, :id) || "stub-tc-#{:rand.uniform(1_000_000)}",
        "type" => "function",
        "function" => %{
          "name"      => Map.get(tc, "name") || Map.get(tc, :name) || raise("tool_call missing name"),
          "arguments" => Map.get(tc, "args") || Map.get(tc, :args) || %{}
        }
      }
    end)
  end

  defp err_atom(s) when is_binary(s), do: String.to_atom(s)
  defp err_atom(a) when is_atom(a), do: a

  # Stream stubs reply with `{:llm_chunk, ...}` messages to the reply_pid
  # so callers that expect the streaming protocol get the same shape.
  # For simplicity we emit one chunk with the full text (or tool_call
  # signal) and one :done marker — flow tests don't depend on chunk
  # granularity.
  defp deliver_stream_chunks(turn, reply_pid) do
    cond do
      txt = Map.get(turn, "text") || Map.get(turn, :text) ->
        send(reply_pid, {:llm_chunk, %{"text" => txt}})

      tcs = Map.get(turn, "tool_calls") || Map.get(turn, :tool_calls) ->
        send(reply_pid, {:llm_chunk, %{"tool_calls" => normalize_tool_calls(tcs)}})

      true -> :ok
    end

    send(reply_pid, :llm_done)
  end

  defp record_if_needed(%{record_path: nil} = state, _entry), do: state
  defp record_if_needed(state, entry) do
    %{state | recorded: [entry | state.recorded]}
  end

  defp tape_miss_error(state, kind) do
    "LLMStub tape miss (flow=#{state.flow_id}, kind=#{kind}, cursor=#{state.cursor}, " <>
      "tape_size=#{length(state.turns)}). The test made more LLM calls than the tape covers — " <>
      "either the implementation drifted, or the tape needs refreshing. " <>
      "Re-record with: mix flow #{state.flow_id} --profile llm --record"
  end
end
