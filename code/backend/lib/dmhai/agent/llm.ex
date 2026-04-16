# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Agent.LLM do
  @moduledoc """
  Unified LLM client using direct Req.post to provider APIs.

  ## Model string format

      "<provider>::<pool>::<model>"

  | provider  | pool  | Endpoint                              | Auth                             |
  |-----------|-------|---------------------------------------|----------------------------------|
  | ollama    | cloud | https://ollama.com/api/chat           | Bearer from accounts pool        |
  | ollama    | local | ollamaEndpoint/api/chat               | none                             |
  | openai    | any   | https://api.openai.com/v1/chat/...    | Bearer openaiKey                 |
  | google    | any   | Google Gemini (TODO)                  | googleKey                        |
  | anthropic | any   | Anthropic (TODO)                      | anthropicKey                     |

  ### Examples

      "ollama::cloud::gemini-3-flash-preview:cloud"
      "ollama::local::llama3.2:3b"
      "openai::default::gpt-4o"

  ## Entry points

  - `stream/4` — streaming; sends `{:chunk, token}` to reply_pid.
                 Returns `{:ok, full_text}` or `{:ok, {:tool_calls, calls}}`.
  - `call/3`   — non-streaming; returns `{:ok, text}` or `{:ok, {:tool_calls, calls}}`.
  """

  import Ecto.Adapters.SQL, only: [query!: 3]
  alias Dmhai.Repo
  require Logger

  @ollama_cloud_url "https://ollama.com/api/chat"

  # ─── Public API ────────────────────────────────────────────────────────────

  @spec stream(String.t(), list(map()), pid(), keyword()) ::
          {:ok, String.t() | {:tool_calls, list()}} | {:error, term()}
  def stream(model_str, messages, reply_pid, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    on_tokens = Keyword.get(opts, :on_tokens, nil)
    Logger.info("[LLM] stream #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")

    case String.split(model_str, "::", parts: 3) do
      ["ollama", "cloud", model_name] ->
        settings = load_settings()
        {active, throttled} = partition_accounts(settings["accounts"] || [])
        body = build_body(model_name, messages, tools, true)
        do_cloud_stream(Enum.shuffle(active) ++ Enum.shuffle(throttled), model_name, body, reply_pid, model_str, on_tokens)

      _ ->
        {url, headers, model_name} = resolve(model_str)
        body = build_body(model_name, messages, tools, true)
        do_stream_request(url, headers, body, reply_pid, model_str, on_tokens)
    end
  end

  @spec call(String.t(), list(map()), keyword()) ::
          {:ok, String.t() | {:tool_calls, list()}} | {:error, term()}
  def call(model_str, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    llm_options = Keyword.get(opts, :options, %{})
    on_tokens = Keyword.get(opts, :on_tokens, nil)
    Logger.info("[LLM] call #{model_str} msgs=#{length(messages)} tools=#{length(tools)}")

    case String.split(model_str, "::", parts: 3) do
      ["ollama", "cloud", model_name] ->
        settings = load_settings()
        {active, throttled} = partition_accounts(settings["accounts"] || [])
        body = build_body(model_name, messages, tools, false, llm_options)
        do_cloud_call(Enum.shuffle(active) ++ Enum.shuffle(throttled), model_name, body, model_str, on_tokens)

      _ ->
        {url, headers, model_name} = resolve(model_str)
        body = build_body(model_name, messages, tools, false, llm_options)
        do_call_request(url, headers, body, model_str, on_tokens)
    end
  end

  # ─── Resolution ────────────────────────────────────────────────────────────

  # Returns {url, headers, model_name}.
  defp resolve(model_str) do
    case String.split(model_str, "::", parts: 3) do
      [provider, pool, model] when provider != "" and pool != "" and model != "" ->
        settings = load_settings()
        endpoint(provider, pool, model, settings)

      _ ->
        raise ArgumentError,
              "Invalid model format: #{inspect(model_str)}. Expected \"provider::pool::model\"."
    end
  end

  defp endpoint("ollama", "cloud", model, settings) do
    key = pick_pool_key(settings)
    headers = if key != "", do: [{"authorization", "Bearer #{key}"}], else: []
    {@ollama_cloud_url, headers, model}
  end

  defp endpoint("ollama", _pool, model, settings) do
    ep = String.trim(settings["ollamaEndpoint"] || "") |> String.trim_trailing("/")
    ep = if ep == "", do: "http://127.0.0.1:11434", else: ep
    {ep <> "/api/chat", [], model}
  end

  defp endpoint("openai", _pool, model, settings) do
    key = String.trim(settings["openaiKey"] || "")
    {"https://api.openai.com/v1/chat/completions",
     [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}], model}
  end

  defp endpoint(provider, pool, model, _settings) do
    raise ArgumentError,
          "Unsupported provider/pool: #{provider}::#{pool} (model: #{model}). " <>
            "Supported: ollama::cloud, ollama::local, openai::*"
  end

  # ─── Body / response ───────────────────────────────────────────────────────

  defp build_body(model, messages, tools, stream, options \\ %{}) do
    base = %{model: model, messages: messages, stream: stream}

    base =
      if tools != [] do
        wrapped = Enum.map(tools, fn t -> %{type: "function", function: t} end)
        Map.put(base, :tools, wrapped)
      else
        base
      end

    if map_size(options) > 0, do: Map.put(base, :options, options), else: base
  end

  defp parse_response(body, model_str, on_tokens) when is_map(body) do
    rx = body["eval_count"] || 0
    tx = body["prompt_eval_count"] || 0
    if on_tokens && (rx > 0 or tx > 0), do: on_tokens.(rx, tx)
    msg = body["message"] || %{}
    tool_calls = msg["tool_calls"]
    content = msg["content"] || ""
    thinking = msg["thinking"]

    if is_binary(thinking) and thinking != "" do
      Logger.debug("[LLM] thinking len=#{String.length(thinking)} #{model_str}: #{String.slice(thinking, 0, 200)}")
    end

    cond do
      is_list(tool_calls) and tool_calls != [] ->
        Logger.info("[LLM] call tool_calls=#{length(tool_calls)}")
        {:ok, {:tool_calls, normalize_tool_calls(tool_calls)}}

      true ->
        Logger.info("[LLM] call done chars=#{String.length(to_string(content))} #{model_str}")
        {:ok, to_string(content)}
    end
  end

  defp parse_response(body, _model_str, _on_tokens) do
    {:error, "Unexpected response: #{inspect(body, limit: 200)}"}
  end

  # ─── Tool call normalization ────────────────────────────────────────────────

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        "id" => call["id"] || generate_id(),
        "function" => %{
          "name" =>
            get_in(call, ["function", "name"]) || "",
          "arguments" =>
            decode_args(get_in(call, ["function", "arguments"]) || %{})
        }
      }
    end)
  end

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  # ─── Helpers ───────────────────────────────────────────────────────────────

  # ─── Ollama cloud: streaming with per-key fallback ─────────────────────────

  defp do_cloud_stream([], _model_name, _body, _reply_pid, model_str, _on_tokens) do
    Logger.error("[LLM] all cloud accounts exhausted #{model_str}")
    {:error, "all_keys_exhausted"}
  end

  defp do_cloud_stream([account | rest], model_name, body, reply_pid, model_str, on_tokens) do
    key = (account["apiKey"] || account["key"] || "") |> String.trim()
    headers = if key != "", do: [{"authorization", "Bearer #{key}"}], else: []

    case do_stream_request(@ollama_cloud_url, headers, body, reply_pid, model_str, on_tokens) do
      {:error, :quota_exhausted} ->
        Logger.warning("[LLM] account #{account["name"]} weekly quota exhausted, throttling 7d")
        mark_account_throttled(account, :timer.hours(24 * 7))
        do_cloud_stream(rest, model_name, body, reply_pid, model_str, on_tokens)

      {:error, :rate_limited} ->
        Logger.warning("[LLM] account #{account["name"]} rate-limited, throttling 1h")
        mark_account_throttled(account, :timer.hours(1))
        do_cloud_stream(rest, model_name, body, reply_pid, model_str, on_tokens)

      other ->
        other
    end
  end

  defp do_stream_request(url, headers, body, reply_pid, model_str, on_tokens) do
    text_key  = {__MODULE__, :text,  self()}
    calls_key = {__MODULE__, :calls, self()}
    buf_key   = {__MODULE__, :buf,   self()}
    err_key   = {__MODULE__, :err,   self()}

    Process.put(text_key,  "")
    Process.put(calls_key, [])
    Process.put(buf_key,   "")
    Process.delete(err_key)

    result =
      Req.post(url,
        json: body,
        headers: headers,
        receive_timeout: :infinity,
        retry: false,
        finch: Dmhai.Finch,
        into: fn {:data, data}, {req, resp} ->
          combined = Process.get(buf_key) <> data
          lines = String.split(combined, "\n")
          {complete, [leftover]} = Enum.split(lines, length(lines) - 1)
          Process.put(buf_key, leftover)

          halt? =
            Enum.reduce_while(complete, false, fn line, _ ->
              line = String.trim(line)
              if line == "" do
                {:cont, false}
              else
                case Jason.decode(line) do
                  {:ok, %{"message" => %{"content" => token}}}
                  when is_binary(token) and token != "" ->
                    Process.put(text_key, Process.get(text_key) <> token)
                    send(reply_pid, {:chunk, token})
                    {:cont, false}

                  {:ok, %{"message" => %{"thinking" => token}}}
                  when is_binary(token) and token != "" ->
                    Logger.debug("[LLM] thinking token len=#{String.length(token)}")
                    send(reply_pid, {:thinking, token})
                    {:cont, false}

                  {:ok, %{"message" => %{"tool_calls" => calls}}}
                  when is_list(calls) and calls != [] ->
                    Process.put(calls_key, calls)
                    {:cont, false}

                  {:ok, %{"error" => err}} ->
                    Logger.error("[LLM] model error: #{err}")
                    Process.put(err_key, err)
                    {:halt, true}

                  {:ok, decoded} ->
                    if decoded["done"] do
                      rx = decoded["eval_count"] || 0
                      tx = decoded["prompt_eval_count"] || 0
                      if on_tokens && (rx > 0 or tx > 0), do: on_tokens.(rx, tx)
                    end
                    Logger.debug("[LLM] unmatched line keys=#{inspect(Map.keys(decoded))}")
                    {:cont, false}

                  {:error, _} ->
                    {:cont, false}
                end
              end
            end)

          if halt?, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
        end
      )

    stream_err = Process.get(err_key)
    full_text  = Process.get(text_key)
    tool_calls = Process.get(calls_key)
    Process.delete(text_key)
    Process.delete(calls_key)
    Process.delete(buf_key)
    Process.delete(err_key)

    cond do
      stream_err != nil ->
        # Inline error in NDJSON — distinguish quota exhausted vs temporary rate-limit
        if String.contains?(to_string(stream_err), "weekly usage limit") do
          {:error, :quota_exhausted}
        else
          {:error, :rate_limited}
        end

      match?({:ok, %{status: s}} when s not in [200], result) ->
        {:ok, %{status: status}} = result
        Logger.error("[LLM] stream HTTP #{status} #{model_str}")
        if status == 429, do: {:error, :rate_limited}, else: {:error, "HTTP #{status}"}

      match?({:ok, _}, result) ->
        if tool_calls != [] do
          Logger.info("[LLM] stream tool_calls=#{length(tool_calls)}")
          {:ok, {:tool_calls, normalize_tool_calls(tool_calls)}}
        else
          Logger.info("[LLM] stream done chars=#{String.length(full_text)}")
          {:ok, full_text}
        end

      true ->
        {:error, reason} = result
        Logger.error("[LLM] stream failed #{model_str}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ─── Ollama cloud: non-streaming with per-key fallback ──────────────────────

  defp do_cloud_call([], _model_name, _body, model_str, _on_tokens) do
    Logger.error("[LLM] all cloud accounts exhausted #{model_str}")
    {:error, "all_keys_exhausted"}
  end

  defp do_cloud_call([account | rest], model_name, body, model_str, on_tokens) do
    key = (account["apiKey"] || account["key"] || "") |> String.trim()
    headers = if key != "", do: [{"authorization", "Bearer #{key}"}], else: []

    case do_call_request(@ollama_cloud_url, headers, body, model_str, on_tokens) do
      {:error, :quota_exhausted} ->
        Logger.warning("[LLM] account #{account["name"]} weekly quota exhausted, throttling 7d")
        mark_account_throttled(account, :timer.hours(24 * 7))
        do_cloud_call(rest, model_name, body, model_str, on_tokens)

      {:error, :rate_limited} ->
        Logger.warning("[LLM] account #{account["name"]} rate-limited, throttling 1h")
        mark_account_throttled(account, :timer.hours(1))
        do_cloud_call(rest, model_name, body, model_str, on_tokens)

      other ->
        other
    end
  end

  defp do_call_request(url, headers, body, model_str, on_tokens) do
    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: :infinity,
           retry: false,
           finch: Dmhai.Finch
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body, model_str, on_tokens)

      {:ok, %{status: 429, body: resp_body}} ->
        err_msg = get_in(resp_body, ["error"]) || ""
        Logger.warning("[LLM] call 429 #{model_str}: #{inspect(resp_body)}")
        if String.contains?(to_string(err_msg), "weekly usage limit") do
          {:error, :quota_exhausted}
        else
          {:error, :rate_limited}
        end

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[LLM] call HTTP #{status} #{model_str}: #{inspect(resp_body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("[LLM] call failed #{model_str}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Split accounts into {active, throttled} based on throttledUntil epoch-ms field.
  # Throttled accounts go to the back of the queue as last-resort fallback.
  defp partition_accounts(accounts) do
    now = System.os_time(:millisecond)
    Enum.split_with(accounts, fn acc ->
      throttled_until = acc["throttledUntil"]
      is_nil(throttled_until) or throttled_until <= now
    end)
  end

  # Persist throttledUntil on the matching account in admin_cloud_settings.
  defp mark_account_throttled(account, duration_ms) do
    name = account["name"] || account["apiKey"] || "unknown"
    failed_until = System.os_time(:millisecond) + duration_ms

    try do
      settings = load_settings()
      updated_accounts =
        Enum.map(settings["accounts"] || [], fn acc ->
          if (acc["name"] || acc["apiKey"]) == name,
            do: Map.put(acc, "throttledUntil", failed_until),
            else: acc
        end)

      save_settings(Map.put(settings, "accounts", updated_accounts))
      Logger.info("[LLM] account #{name} throttled until #{failed_until}")
    rescue
      e -> Logger.error("[LLM] mark_account_throttled failed: #{Exception.message(e)}")
    end
  end

  defp save_settings(settings) do
    query!(Repo, "UPDATE settings SET value=? WHERE key=?",
           [Jason.encode!(settings), "admin_cloud_settings"])
  end

  defp pick_pool_key(settings) do
    accounts = settings["accounts"] || []

    case accounts do
      [] -> ""
      list ->
        account = Enum.random(list)
        (account["apiKey"] || account["key"] || "") |> String.trim()
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp load_settings do
    try do
      result = query!(Repo, "SELECT value FROM settings WHERE key=?", ["admin_cloud_settings"])

      case result.rows do
        [[v] | _] -> Jason.decode!(v || "{}")
        _ -> %{}
      end
    rescue
      _ -> %{}
    end
  end
end
