# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.LogTrace do
  @moduledoc """
  Verbatim LLM call trace logger for worker jobs.

  When `log_trace: true` is set in the worker ctx, every LLM prompt and
  response is appended verbatim to `<session_root>/log_traces/<job_id>.log`.

  Enabled/disabled via the `logTrace` admin setting (default: false).
  Persists across restarts because the setting lives in the DB.
  """

  @doc "Returns true when tracing is enabled for this job ctx."
  def enabled?(%{log_trace: true}), do: true
  def enabled?(_), do: false

  @doc "Create the log file and write a header. Called once when a worker starts."
  def init_log(ctx) do
    if enabled?(ctx) do
      path = log_path(ctx)
      File.mkdir_p!(Path.dirname(path))
      header = "=== Worker trace job_id=#{ctx.job_id} worker_id=#{Map.get(ctx, :worker_id, "?")} ===\nStarted: #{iso_now()}\n\n"
      File.write!(path, header)
    end
    :ok
  end

  @doc "Append a labelled section to the trace log."
  def trace(ctx, label, content) when is_binary(content) do
    if enabled?(ctx) do
      path = log_path(ctx)
      entry = "--- [#{iso_now()}] #{label} ---\n#{content}\n\n"
      File.write!(path, entry, [:append])
    end
    :ok
  end

  @doc "Log the messages array sent to the LLM before a call."
  def trace_call(ctx, iter, messages, tools) do
    if enabled?(ctx) do
      msgs_text = format_messages(messages)
      tool_names = Enum.map_join(tools, ", ", fn t -> t[:name] || t["name"] || "?" end)
      content = "tools=[#{tool_names}]\n\n#{msgs_text}"
      trace(ctx, "LLM CALL iter=#{iter}", content)
    end
    :ok
  end

  @doc "Log the raw LLM response after a call."
  def trace_response(ctx, iter, result) do
    if enabled?(ctx) do
      text =
        case result do
          {:ok, {:tool_calls, calls}} ->
            Enum.map_join(calls, "\n", fn c ->
              name = get_in(c, ["function", "name"]) || "?"
              args = get_in(c, ["function", "arguments"]) || %{}
              "tool_call: #{name}(#{inspect(args)})"
            end)
          {:ok, text} when is_binary(text) ->
            text
          {:error, reason} ->
            "ERROR: #{inspect(reason)}"
        end
      trace(ctx, "LLM RESPONSE iter=#{iter}", text)
    end
    :ok
  end

  defp log_path(%{session_root: root, job_id: job_id}) do
    Path.join([root, "log_traces", "#{job_id}.log"])
  end

  defp log_path(%{job_id: job_id}) do
    Path.join([System.tmp_dir!(), "dmhai_traces", "#{job_id}.log"])
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601() |> String.slice(0, 19)
  end

  defp format_messages(messages) do
    Enum.map_join(messages, "\n\n", fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role") || "?"
      content = Map.get(msg, :content) || Map.get(msg, "content") || ""
      "[#{String.upcase(role)}]\n#{content}"
    end)
  end
end
