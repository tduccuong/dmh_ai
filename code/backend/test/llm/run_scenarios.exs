# Live-LLM scenario suite for the Assistant system prompt.
#
# Builds messages via the production `ContextEngine.build_assistant_messages/2`
# path, with the only override being the system-prompt content (loaded
# from `test/llm/sysprompt_v2_5.md` instead of the live
# `SystemPrompt.assistant_base/0`). All other production behavior —
# `## Task list`, `## Recently-extracted files`, `## Active task`
# anchor block, `mark_fresh_attachments` rewrite, `tool_history`
# injection, periodic synthetic `[Task due: …]` message — flows
# through the real code paths.
#
# Each scenario sets up real DB state (sessions row, tasks rows,
# session.messages, sessions.tool_history) before the build call and
# tears down after, so the runner can't drift from production.
#
# Run with:
#   MIX_ENV=test DB_PATH=~/.dmhai/db/chat.db mix run test/llm/run_scenarios.exs
#
# Optional env:
#   PROMPT_FILE   — path to the system prompt (default: test/llm/sysprompt_v2_5.md)
#   PROBE_MODELS  — comma-separated model names (default: @target_models)
#   PROBE_DELAY   — ms between scenarios (default: 1000)
#   PROBE_RETRY   — ms to wait before single retry on error (default: 5000)

defmodule TestLLM.Runner do
  alias Dmhai.Agent.{ContextEngine, LLM, Tasks, ToolHistory, UserAgentMessages}
  alias Dmhai.Repo
  alias Dmhai.Tools.Registry, as: ToolsRegistry
  import Ecto.Adapters.SQL, only: [query!: 3]

  # Devstral family is the workhorse — listed first so the default
  # full sweep covers them before everything else.
  @target_models [
    "devstral-small-2:24b-cloud",
    "devstral-2:123b-cloud",
    "gemma4:31b-cloud",
    "minimax-m2.5:cloud",
    "glm-4.6:cloud"
  ]

  @prompt_path_default "test/llm/sysprompt_v2_5.md"
  @reports_dir         "test/llm/reports"
  @test_user_id        "llm-scenario-runner"
  @mocks_bin_default   "../../mocks/bin"

  @inter_call_delay_default 1_000
  @retry_after_default      5_000

  # ─── Entry point ─────────────────────────────────────────────────────────

  def run do
    File.mkdir_p!(@reports_dir)

    # PROMPT_FILE=live (or =production) → use whatever
    # `SystemPrompt.assistant_base/0` returns, no override. Lets us
    # run the suite against the actually-shipped prompt code post-sync.
    # Otherwise: default to test/llm/sysprompt_v2_5.md (or any path
    # the user passes), which gets substituted into the system message.
    {prompt_path, prompt} =
      case System.get_env("PROMPT_FILE") do
        v when v in ["live", "production", "real"] ->
          {:live, nil}

        path when is_binary(path) ->
          {path, File.read!(path)}

        nil ->
          {@prompt_path_default, File.read!(@prompt_path_default)}
      end

    models = configured_models()
    delay  = configured_int("PROBE_DELAY", @inter_call_delay_default)
    retry  = configured_int("PROBE_RETRY", @retry_after_default)
    scenarios = filtered_scenarios()

    IO.puts("\n=== TestLLM.Runner ===")
    case prompt_path do
      :live -> IO.puts("Prompt:      <live SystemPrompt.generate_assistant/1>")
      path  -> IO.puts("Prompt:      #{path} (#{byte_size(prompt)} bytes)")
    end
    IO.puts("Models:      #{Enum.join(models, ", ")}")
    IO.puts("Scenarios:   #{length(scenarios)}")
    IO.puts("Inter-call:  #{delay}ms")
    IO.puts("Retry-after: #{retry}ms")

    mocks = start_mocks()

    try do
      Enum.each(models, fn model_plain ->
        model = route(model_plain)
        IO.puts("\n\n=== Model: #{model_plain} ===")
        results = Enum.map(scenarios, fn s ->
          Process.sleep(delay)
          run_one(prompt, model, s, retry, mocks)
        end)
        write_report(model_plain, prompt_path, results)
      end)
    after
      stop_mocks(mocks)
    end

    IO.puts("\nAll done.")
  end

  # ─── Mock-server lifecycle ──────────────────────────────────────────────
  #
  # Spawns the Go mock binaries from `mocks/bin/` under Erlang ports so
  # they're killed when the BEAM exits. `bitrix24` listens on a random
  # port (we parse it from stdout); `mcp_api_key` pins to 9091. If a
  # binary isn't present, the corresponding mock entry comes back as
  # `nil` and `requires_mock` scenarios skip cleanly.

  defp start_mocks do
    bin_dir =
      case System.get_env("MOCKS_BIN_DIR") do
        nil -> Path.expand(@mocks_bin_default, File.cwd!())
        path -> path
      end

    IO.puts("Mocks dir:   #{bin_dir}")

    bitrix24    = start_bitrix24(bin_dir)
    mcp_api_key = start_mcp_api_key(bin_dir)

    %{bitrix24: bitrix24, mcp_api_key: mcp_api_key}
  end

  defp stop_mocks(mocks) do
    Enum.each(mocks, fn
      {_name, %{port: port}} when is_port(port) ->
        try do
          Port.close(port)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end)

    IO.puts("Mocks stopped.")
  end

  # bitrix24 binds to :0 (random). Read stdout until we see
  # `http://localhost:<PORT>` and capture it.
  defp start_bitrix24(bin_dir) do
    bin = Path.join(bin_dir, "bitrix24")

    if File.exists?(bin) do
      port_handle = Port.open({:spawn_executable, bin}, [:binary, :stderr_to_stdout, :exit_status, args: []])

      case wait_for_port_line(port_handle, ~r{http://localhost:(\d+)}, 3_000) do
        {:ok, port_num} ->
          IO.puts("Mock:        bitrix24 → http://localhost:#{port_num}")
          %{port: port_handle, http_port: port_num, url: "http://localhost:#{port_num}"}

        :timeout ->
          IO.puts("Mock:        bitrix24 FAILED to print port within 3s — closing")
          Port.close(port_handle)
          nil
      end
    else
      IO.puts("Mock:        bitrix24 binary missing at #{bin} (skip)")
      nil
    end
  end

  defp start_mcp_api_key(bin_dir) do
    bin = Path.join(bin_dir, "mcp_api_key")
    fixed_port = 9091

    if File.exists?(bin) do
      port_handle = Port.open({:spawn_executable, bin}, [:binary, :stderr_to_stdout, :exit_status, args: ["--port", "#{fixed_port}"]])

      case wait_for_port_line(port_handle, ~r{http://localhost:(\d+)/mcp}, 3_000) do
        {:ok, port_num} ->
          url = "http://localhost:#{port_num}/mcp"
          IO.puts("Mock:        mcp_api_key → #{url}")
          %{port: port_handle, http_port: port_num, url: url, api_key: "test-api-key-12345"}

        :timeout ->
          IO.puts("Mock:        mcp_api_key FAILED to print port within 3s — closing")
          Port.close(port_handle)
          nil
      end
    else
      IO.puts("Mock:        mcp_api_key binary missing at #{bin} (skip)")
      nil
    end
  end

  # Read from the port until a line matches `pattern` (with one capture
  # group = port number). Returns `{:ok, integer}` or `:timeout`.
  defp wait_for_port_line(port, pattern, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(port, pattern, deadline, "")
  end

  defp do_wait_for(port, pattern, deadline, buf) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {^port, {:data, chunk}} ->
          combined = buf <> chunk

          case Regex.run(pattern, combined) do
            [_, port_str] ->
              case Integer.parse(port_str) do
                {n, _} -> {:ok, n}
                :error -> do_wait_for(port, pattern, deadline, combined)
              end

            _ ->
              do_wait_for(port, pattern, deadline, combined)
          end

        {^port, {:exit_status, _}} ->
          :timeout
      after
        remaining -> :timeout
      end
    end
  end

  defp configured_models do
    case System.get_env("PROBE_MODELS") do
      nil -> @target_models
      env -> env |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  # Scenario filter — `PROBE_SCENARIOS=8,19` runs only those IDs.
  # Default: all scenarios. Useful for focused re-runs after assertion
  # tweaks without burning the full suite.
  defp filtered_scenarios do
    case System.get_env("PROBE_SCENARIOS") do
      nil ->
        scenarios()

      env ->
        ids =
          env
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.flat_map(fn s ->
            case Integer.parse(s) do
              {n, _} -> [n]
              :error -> []
            end
          end)
          |> MapSet.new()

        Enum.filter(scenarios(), &(&1.id in ids))
    end
  end

  defp configured_int(env_key, default) do
    case System.get_env(env_key) do
      nil -> default
      str ->
        case Integer.parse(str) do
          {n, _} -> n
          :error -> default
        end
    end
  end

  # Surface scenario description above the result line so a reader
  # following the run console can see WHY this test exists without
  # scrolling back to the source. Heredoc descriptions are word-
  # wrapped from the source's leading whitespace; we strip indents
  # and keep paragraph breaks.
  defp print_scenario_header(scenario) do
    desc = (scenario[:description] || "") |> String.trim()
    indented = desc |> String.split("\n") |> Enum.map(&("       " <> &1)) |> Enum.join("\n")
    IO.puts("\n  ##{scenario.id} #{scenario.name}")
    if desc != "", do: IO.puts(indented)
  end

  defp run_one(prompt, model, scenario, retry_ms, mocks) do
    started    = System.monotonic_time(:millisecond)
    session_id = "llm-test-#{scenario.id}-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    print_scenario_header(scenario)

    # Mock-gated scenarios: skip cleanly when the required mock isn't
    # reachable. Lets us ship test code for #26 / #27 / #28 before
    # the mock servers are ready — first run after the dev finishes
    # the binary just works.
    skip_reason = scenario_skip_reason(scenario, mocks)

    cond do
      skip_reason ->
        IO.puts("[SKIP] ##{scenario.id} #{String.pad_trailing(scenario.name, 32)} — " <> skip_reason)

        %{
          id:          scenario.id,
          name:        scenario.name,
          description: scenario[:description] || "",
          pass:        true,
          observed:    %{kind: :skipped, reason: skip_reason},
          reason:      "skipped — " <> skip_reason,
          duration_ms: 0,
          prompt_size_bytes: 0,
          skipped:     true
        }

      true ->
        try do
          insert_session(session_id, @test_user_id)
          ctx = scenario.setup.(session_id, @test_user_id, mocks) || %{}

          llm_messages = build_messages(prompt, session_id, ctx)
          tools        = ToolsRegistry.all_definitions()
          mode         = Map.get(scenario.expect, :kind)

          {result_or_trace, trace_for_obs} =
            if mode == :chain do
              tool_ctx = build_tool_ctx(session_id, @test_user_id, ctx)
              chain_ctx = %{
                prompt:     prompt,
                session_id: session_id,
                user_id:    @test_user_id,
                setup_ctx:  ctx
              }

              t = run_chain(llm_messages, tool_ctx, model, retry_ms, scenario, chain_ctx)
              {{:chain, t}, t}
            else
              r = call_with_retry(model, llm_messages, tools, retry_ms)
              {r, nil}
            end

          duration = System.monotonic_time(:millisecond) - started
          {pass?, observed, reason} = check_result(result_or_trace, scenario.expect)
          observed = if trace_for_obs, do: Map.put(observed, :trace, summarize_trace(trace_for_obs)), else: observed

          label = if pass?, do: "PASS", else: "FAIL"
          IO.puts("    [#{label}] #{duration}ms" <> (if reason, do: " — " <> reason, else: ""))

          %{
            id:          scenario.id,
            name:        scenario.name,
            description: scenario[:description] || "",
            pass:        pass?,
            observed:    observed,
            reason:      reason,
            duration_ms: duration,
            prompt_size_bytes: messages_byte_size(llm_messages),
            skipped:     false
          }
        after
          cleanup_session(session_id)
        end
    end
  end

  # ─── Multi-round chain runner ───────────────────────────────────────────
  #
  # Iterates LLM ↔ tool execution until plain text emerges, max_turns
  # is hit, or a chain-terminating tool result lands. The trace
  # captures every turn so chain-mode assertions can inspect the full
  # path the model took, not just the first move.

  @max_chain_turns_default 5

  defp run_chain(messages, tool_ctx, model, retry_ms, scenario, chain_ctx) do
    max_turns = Map.get(scenario.expect, :max_turns, @max_chain_turns_default)
    trace1 = do_chain_loop(messages, tool_ctx, model, retry_ms, max_turns, %{turns: [], final: nil})

    # Optional 2nd chain after an OAuth callback simulation. Used by
    # #27: chain 1 emits connect_mcp → tool returns needs_auth →
    # chain ends; test fires the OAuth callback (hits the mock's
    # /authorize, captures code, runs complete_flow + finalize); then
    # chain 2 picks up with a follow-up user message that should
    # exercise the now-authorized service.
    case scenario_oauth_resume(scenario, trace1, chain_ctx) do
      {:run_chain_2, new_messages} ->
        IO.puts("    ── chain 2 ──")
        max2 = Map.get(scenario.expect, :max_turns_chain_2, @max_chain_turns_default)
        trace2 = do_chain_loop(new_messages, tool_ctx, model, retry_ms, max2, %{turns: [], final: nil})
        merge_traces(trace1, trace2)

      {:skip, reason} ->
        IO.puts("    [oauth-resume skipped: #{reason}]")
        trace1

      :no_resume ->
        trace1
    end
  end

  # Drives the OAuth callback simulation when the scenario opts in via
  # `expect.oauth_resume = true` AND `setup` returned a
  # `:followup_user_msg` field. Hits the mock /authorize endpoint via
  # the auth_url we extracted from chain 1's connect_mcp result, gets
  # back a redirect with `?code=…`, then drives
  # `Dmhai.Auth.OAuth2.complete_flow/2` + finalize. Returns
  # `{:run_chain_2, messages}` on success, or `{:skip, reason}` /
  # `:no_resume` otherwise.
  defp scenario_oauth_resume(scenario, trace1, chain_ctx) do
    cond do
      not Map.get(scenario.expect, :oauth_resume, false) ->
        :no_resume

      true ->
        with {:ok, auth_url} <- extract_auth_url_from_trace(trace1),
             {:ok, conn_data} <- simulate_oauth_callback(auth_url),
             :ok <- finalize_test_connection(conn_data),
             {:ok, new_messages} <- build_chain_2_messages(chain_ctx) do
          {:run_chain_2, new_messages}
        else
          {:error, reason} -> {:skip, reason}
        end
    end
  end

  defp extract_auth_url_from_trace(trace) do
    # Walk the trace's tool_call turns for any result that carries
    # `auth_url` (the connect_mcp `needs_auth` shape). String-keyed
    # and atom-keyed results both surface here depending on whether
    # the result was `Jason.encode/decode`-roundtripped.
    auth_url =
      trace.turns
      |> Enum.flat_map(fn
        %{kind: :tool_calls, results: rs} -> rs
        _ -> []
      end)
      |> Enum.find_value(fn
        {:ok, %{auth_url: url}} when is_binary(url) -> url
        {:ok, %{"auth_url" => url}} when is_binary(url) -> url
        _ -> nil
      end)

    if auth_url, do: {:ok, auth_url}, else: {:error, "no auth_url in chain 1 tool results"}
  end

  defp simulate_oauth_callback(auth_url) do
    # Hit the OAuth /authorize endpoint, do NOT follow redirects, and
    # parse `code` + `state` out of the Location header. Mock 302s
    # back to `redirect_uri?code=…&state=…`.
    case Req.get(auth_url, redirect: false, decode_body: false) do
      {:ok, %{status: 302} = resp} ->
        # Req 0.5+ returns headers as `%{"name" => [val, …]}` (map).
        # Older versions return a list of `{name, val}` tuples. Handle
        # both shapes; HTTP header names are case-insensitive so we
        # check both spellings.
        location =
          case resp.headers do
            %{} = m ->
              m
              |> Enum.find_value(fn
                {k, v} when is_binary(k) ->
                  if String.downcase(k) == "location" do
                    if is_list(v), do: List.first(v), else: v
                  end

                _ ->
                  nil
              end)

            list when is_list(list) ->
              Enum.find_value(list, fn
                {k, v} when is_binary(k) ->
                  if String.downcase(k) == "location" do
                    if is_list(v), do: List.first(v), else: v
                  end

                _ ->
                  nil
              end)

            _ ->
              nil
          end

        if is_binary(location) do
          uri = URI.parse(location)
          params = URI.decode_query(uri.query || "")
          code  = params["code"]
          state = params["state"]

          if is_binary(code) and is_binary(state) do
            case Dmhai.Auth.OAuth2.complete_flow(state, code) do
              {:ok, _conn_data} = ok -> ok
              {:error, r}            -> {:error, "complete_flow failed: #{inspect(r)}"}
            end
          else
            {:error, "no code/state in redirect Location: #{location}"}
          end
        else
          {:error, "no Location header in 302 response"}
        end

      {:ok, %{status: status}} ->
        {:error, "expected 302 from /authorize, got #{status}"}

      {:error, reason} ->
        {:error, "auth_url request failed: #{inspect(reason)}"}
    end
  end

  # Replicates the production `finalize_connection` body
  # (lib/dmhai/handlers/data.ex) so the test runner doesn't have to
  # build a Plug.Conn to drive the real callback handler. Persists
  # creds, runs the MCP handshake to populate the tool list, registers
  # the service, attaches it to the anchor task. The MCP handshake
  # against the bitrix24 mock's /mcp endpoint will likely 401 (mock
  # only accepts a hardcoded api key, not OAuth tokens) — that
  # leaves the registered service with `tools: []`. Acceptable for
  # this test; full tool exercise needs a mock refinement.
  defp finalize_test_connection(%{
         user_id: user_id,
         session_id: _session_id,
         anchor_task_id: anchor_task_id,
         alias: alias_,
         canonical_resource: resource,
         server_url: server_url,
         asm: asm,
         tokens: tokens
       }) do
    cred_payload = %{
      "access_token"        => tokens.access_token,
      "refresh_token"       => tokens.refresh_token,
      "scope"               => tokens.scope,
      "token_type"          => tokens.token_type,
      "server_url"          => server_url,
      "alias"               => alias_,
      "canonical_resource"  => resource,
      "asm_json"            => Jason.encode!(asm),
      "client_id"           => nil,
      "client_secret"       => nil
    }

    Dmhai.Auth.Credentials.save(
      user_id, "mcp:" <> resource, "oauth2_mcp", cred_payload,
      notes: "MCP connection: #{alias_}",
      expires_at: tokens.expires_at
    )

    handshake_ctx = %{
      server_url:         server_url,
      canonical_resource: resource,
      access_token:       tokens.access_token
    }

    tools =
      with {:ok, _info, sid} <- Dmhai.MCP.Client.initialize(handshake_ctx),
           {:ok, ts}          <- Dmhai.MCP.Client.list_tools(handshake_ctx, sid) do
        ts
      else
        _ -> []
      end

    Dmhai.MCP.Registry.authorize(user_id, alias_, resource, server_url, asm)
    Dmhai.MCP.Registry.set_authorized_tools(user_id, alias_, tools)
    Dmhai.MCP.Registry.attach(anchor_task_id, user_id, alias_)

    :ok
  rescue
    e -> {:error, "finalize raised: " <> Exception.message(e)}
  end

  # Append the followup user msg (stashed on the scenario via
  # `_followup_user_msg` in the setup-returned ctx) and rebuild the
  # full LLM context so chain 2 starts fresh from the latest session
  # state — including the new `## Authorized MCP services` row that
  # finalize_connection just registered.
  defp build_chain_2_messages(chain_ctx) do
    setup_ctx = chain_ctx.setup_ctx
    followup  = setup_ctx[:followup_user_msg]

    cond do
      not is_binary(followup) or followup == "" ->
        {:error, "scenario setup didn't return :followup_user_msg"}

      true ->
        UserAgentMessages.append(chain_ctx.session_id, chain_ctx.user_id,
          %{role: "user", content: followup})

        {:ok, build_messages(chain_ctx.prompt, chain_ctx.session_id, setup_ctx)}
    end
  end

  defp merge_traces(t1, t2) do
    %{
      turns: t1.turns ++ [%{kind: :chain_boundary}] ++ t2.turns,
      final: t2.final
    }
  end

  defp do_chain_loop(_msgs, _ctx, _model, _retry, 0, trace) do
    %{trace | final: :max_turns}
  end

  defp do_chain_loop(messages, tool_ctx, model, retry_ms, turns_left, trace) do
    tools = ToolsRegistry.all_definitions()
    turn_idx = length(trace.turns) + 1

    case call_with_retry(model, messages, tools, retry_ms) do
      {:error, reason} ->
        IO.puts("    t#{turn_idx} ERROR: #{inspect(reason) |> String.slice(0, 100)}")
        %{trace | final: {:error, reason}}

      {:ok, text} when is_binary(text) ->
        IO.puts("    t#{turn_idx} plain_text \"#{text |> String.slice(0, 60) |> String.replace("\n", " ")}\"")
        turn = %{kind: :plain_text, text: text}
        %{trace | turns: trace.turns ++ [turn], final: {:plain_text, text}}

      {:ok, {:tool_calls, calls}} ->
        names = Enum.map(calls, &(get_in(&1, ["function", "name"]) || ""))
        IO.puts("    t#{turn_idx} tool_calls #{inspect(names)}")

        # request_input is CALL-terminating in production — the runtime
        # captures preceding narration, persists the form, and ends the
        # chain BEFORE the model ever sees a tool result. Mirror that
        # by short-circuiting before tool execution.
        if Enum.any?(names, &call_terminating_tool?/1) do
          turn = %{
            kind:    :tool_calls,
            calls:   Enum.map(calls, fn c ->
              %{name: get_in(c, ["function", "name"]), args: get_in(c, ["function", "arguments"])}
            end),
            results: [:not_executed_call_terminating]
          }

          %{trace | turns: trace.turns ++ [turn], final: :terminated_by_tool}
        else
          # Execute each tool, capturing the result for the trace AND
          # building the role:tool message that flows back to the LLM.
          results = Enum.map(calls, &execute_tool_call(&1, tool_ctx))

          asst_msg = %{role: "assistant", content: "", tool_calls: calls}

          tool_msgs =
            Enum.zip(calls, results)
            |> Enum.map(fn {c, r} ->
              %{role: "tool", tool_call_id: c["id"], content: tool_result_to_string(r)}
            end)

          new_messages = messages ++ [asst_msg] ++ tool_msgs

          turn = %{
            kind:    :tool_calls,
            calls:   Enum.map(calls, fn c ->
              %{name: get_in(c, ["function", "name"]), args: get_in(c, ["function", "arguments"])}
            end),
            results: results
          }

          new_trace = %{trace | turns: trace.turns ++ [turn]}

          cond do
            Enum.any?(results, &chain_terminating?/1) ->
              %{new_trace | final: :terminated_by_tool}

            true ->
              do_chain_loop(new_messages, tool_ctx, model, retry_ms, turns_left - 1, new_trace)
          end
        end
    end
  end

  # Tools that ARE the chain end-marker — production captures these
  # at emit time, before any tool result flows back to the model.
  defp call_terminating_tool?("request_input"), do: true
  defp call_terminating_tool?(_), do: false

  # Build a real tool context. Some tools consult workspace_dir /
  # session_root / keystore_dir; we provide writable temp dirs so any
  # tool that touches the filesystem has a sandbox.
  defp build_tool_ctx(session_id, user_id, scenario_ctx) do
    base = "/tmp/llm-test-#{session_id}"
    workspace = base <> "/workspace"
    data      = base <> "/data"
    keystore  = base <> "/keystore"
    File.mkdir_p!(workspace)
    File.mkdir_p!(data)
    File.mkdir_p!(keystore)

    %{
      user_id:         user_id,
      user_email:      "llm-test@example.com",
      session_id:      session_id,
      anchor_task_num: scenario_ctx[:anchor_task_num],
      progress_row_id: nil,
      tool_call_id:    nil,
      workspace_dir:   workspace,
      session_root:    base,
      data_dir:        data,
      keystore_dir:    keystore
    }
  end

  defp execute_tool_call(call, ctx) do
    name = get_in(call, ["function", "name"]) || ""
    args = get_in(call, ["function", "arguments"]) || %{}
    do_execute_tool_call(name, args, call["id"] || "", ctx)
  end

  # Wrapped in its own function so the rescue/catch clauses can refer
  # to `name` (variables bound inside a function body aren't visible
  # in its own rescue clause when the rescue follows a multi-line body).
  defp do_execute_tool_call(name, args, tool_call_id, ctx) do
    ctx = Map.put(ctx, :tool_call_id, tool_call_id)
    Dmhai.Tools.Registry.execute(name, args, ctx)
  rescue
    e -> {:error, "tool #{name} raised: " <> Exception.message(e)}
  catch
    kind, payload -> {:error, "tool #{name} #{kind}: " <> inspect(payload)}
  end

  defp tool_result_to_string({:ok, result}) when is_binary(result), do: result
  defp tool_result_to_string({:ok, result}) when is_map(result) or is_list(result),
    do: Jason.encode!(result, pretty: true)
  defp tool_result_to_string({:ok, result}), do: inspect(result)
  defp tool_result_to_string({:error, reason}) when is_binary(reason), do: "Error: " <> reason
  defp tool_result_to_string({:error, reason}), do: "Error: " <> inspect(reason)

  # Tool results that should END the chain. Production runtime treats
  # these specially; the test runner mirrors that.
  defp chain_terminating?({:ok, %{status: "needs_auth"}}), do: true
  defp chain_terminating?({:ok, %{status: "needs_setup"}}), do: true
  defp chain_terminating?({:ok, %{"status" => "needs_auth"}}), do: true
  defp chain_terminating?({:ok, %{"status" => "needs_setup"}}), do: true
  # request_input persists a pending form and ends the chain in
  # production; for the test runner we treat any successful
  # request_input result as terminal.
  defp chain_terminating?({:ok, %{request_input_token: _}}), do: true
  defp chain_terminating?({:ok, %{"request_input_token" => _}}), do: true
  defp chain_terminating?(_), do: false

  defp summarize_trace(trace) do
    %{
      turn_count: length(trace.turns),
      final:      trace.final,
      turns: Enum.map(trace.turns, fn
        %{kind: :plain_text, text: t} -> %{kind: :plain_text, text: String.slice(t, 0, 200)}

        %{kind: :tool_calls, calls: cs, results: rs} ->
          %{kind: :tool_calls,
            calls: cs,
            results: Enum.map(rs, fn
              {:ok, r} when is_binary(r) -> {:ok, String.slice(r, 0, 200)}
              other                       -> other
            end)}

        %{kind: :chain_boundary} -> %{kind: :chain_boundary}

        other -> other
      end)
    }
  end

  # If the scenario declares `requires_mock: <atom>`, check the live
  # `mocks` map. A nil entry means the binary was missing or failed
  # to start; in that case we skip with a clear reason.
  defp scenario_skip_reason(scenario, mocks) do
    case Map.get(scenario, :requires_mock) do
      nil ->
        nil

      :bitrix24 ->
        if mocks[:bitrix24], do: nil, else: "needs bitrix24 mock running"

      :mcp_api_key ->
        if mocks[:mcp_api_key], do: nil, else: "needs mcp_api_key mock running"

      :oauth_callback_simulation ->
        # #27 needs an OAuth-callback simulation hook in the runner —
        # not yet implemented. Future round.
        "needs OAuth-callback simulation hook (not yet implemented)"

      other ->
        "unknown requires_mock: #{inspect(other)}"
    end
  end

  defp call_with_retry(model, messages, tools, retry_ms) do
    case LLM.call(model, messages, tools: tools) do
      {:ok, _} = ok -> ok
      {:error, _reason} ->
        Process.sleep(retry_ms)
        LLM.call(model, messages, tools: tools)
    end
  end

  # ─── Message construction via production ContextEngine ──────────────────

  defp build_messages(prompt, session_id, ctx) do
    active_tasks = Tasks.active_for_session(session_id)
    recent_done  = Tasks.recent_done_for_session(session_id)
    session_data = load_session_data(session_id)

    base =
      ContextEngine.build_assistant_messages(session_data,
        user_id:             @test_user_id,
        profile:             "",
        active_tasks:        active_tasks,
        recent_done:         recent_done,
        files:               [],
        silent_turn_task_id: ctx[:silent_turn_task_id]
      )

    base
    |> override_system_prompt(prompt)
    |> append_periodic_synthetic(ctx)
    |> append_mid_chain(ctx)
  end

  # Replace the system message's content with the v2.5 prompt + date.
  # Production stamps date inside `SystemPrompt.generate_assistant/1`;
  # we mirror that suffix so the model has the same temporal anchor.
  #
  # When `prompt` is `nil` (PROMPT_FILE=live), keep the system message
  # ContextEngine produced verbatim — the runner is exercising the
  # live `SystemPrompt.assistant_base/0` body.
  defp override_system_prompt(messages, nil), do: messages

  defp override_system_prompt([%{role: "system"} | rest], prompt) do
    body = prompt <> "\n\nToday's date: " <> (Date.utc_today() |> Date.to_string()) <> ".\n"
    [%{role: "system", content: body} | rest]
  end

  defp override_system_prompt(other, prompt) do
    body = prompt <> "\n\nToday's date: " <> (Date.utc_today() |> Date.to_string()) <> ".\n"
    [%{role: "system", content: body} | other]
  end

  # Periodic pickups in production append a long synthetic [Task due: ...]
  # user message AFTER `build_assistant_messages` returns — it isn't
  # persisted. We replicate the exact text from
  # `Dmhai.Agent.UserAgent.run_assistant_silent/3` so the model sees the
  # same workflow / forbidden-this-turn instructions.
  defp append_periodic_synthetic(msgs, %{silent_turn_task_id: tid}) when is_binary(tid) do
    case Tasks.get(tid) do
      %{} = task ->
        msgs ++ [%{role: "user", content: build_periodic_synthetic(task)}]

      _ ->
        msgs
    end
  end

  defp append_periodic_synthetic(msgs, _), do: msgs

  defp build_periodic_synthetic(task) do
    task_num = Map.get(task, :task_num)

    "[Task due: (#{task_num}) — #{task.task_title}]\n\n" <>
      "This is a PICKUP of the EXISTING periodic task (#{task_num}). " <>
      "The runtime has already flipped it to `ongoing` for you — " <>
      "you do NOT need to call `pickup_task`. (Calling it is a harmless " <>
      "no-op; skipping it is preferred to save a turn.)\n\n" <>
      "STAY IN LANE — a silent pickup is scoped to THIS ONE TASK. " <>
      "Even if the user asked about a different task in an earlier " <>
      "conversational turn, do NOT act on that here. The user will " <>
      "re-ask on their next message; wait for it. Forbidden this turn: " <>
      "`create_task` (any type), `pickup_task` / `complete_task` / " <>
      "`pause_task` / `cancel_task` on ANY task_num other than " <>
      "#{task_num}, and cancelling (#{task_num}) itself to " <>
      "free the periodic slot.\n\n" <>
      "Workflow:\n" <>
      "  1. Run whatever execution tools you need (web_fetch, run_script, etc.) " <>
      "to produce this cycle's fresh output.\n" <>
      "  2. Call `complete_task(task_num: #{task_num}, " <>
      "task_result: \"<short summary>\")` — this auto-reschedules the next cycle.\n" <>
      "  3. Your final text IS the task output (the joke, the quote, the status — " <>
      "whatever this task produces). Write it directly in the user's language. " <>
      "NO meta-prefix like \"Joke delivered:\", \"Task complete\", \"Here is your...\", " <>
      "\"Your update:\". The user just wants the content."
  end

  # Mid-chain appendix — assistant tool_calls / tool_result pairs that
  # would only exist *during* a chain (not in persisted session.messages).
  # Used by scenario #15 to test the FINAL turn of a periodic chain
  # where the model must emit complete_task.
  defp append_mid_chain(msgs, %{mid_chain: extra}) when is_list(extra), do: msgs ++ extra
  defp append_mid_chain(msgs, _), do: msgs

  # ─── DB plumbing ────────────────────────────────────────────────────────

  defp insert_session(session_id, user_id) do
    now = System.os_time(:millisecond)
    query!(Repo, """
    INSERT INTO sessions (id, name, model, messages, context, user_id, mode, tool_history, created_at, updated_at)
    VALUES (?, ?, NULL, '[]', NULL, ?, 'assistant', NULL, ?, ?)
    """, [session_id, "scenario-test", user_id, now, now])
  end

  defp load_session_data(session_id) do
    r = query!(Repo,
               "SELECT id, user_id, mode, messages, context FROM sessions WHERE id=?",
               [session_id])

    case r.rows do
      [[id, uid, mode, messages_json, context_json]] ->
        %{
          "id"       => id,
          "user_id"  => uid,
          "mode"     => mode,
          "messages" => Jason.decode!(messages_json || "[]"),
          "context"  => if(is_binary(context_json), do: Jason.decode!(context_json), else: nil)
        }

      _ ->
        raise "session #{session_id} disappeared mid-test"
    end
  end

  defp cleanup_session(session_id) do
    try do
      query!(Repo, "DELETE FROM session_progress WHERE session_id=?", [session_id])
      query!(Repo,
             "DELETE FROM task_turn_archive WHERE task_id IN (SELECT task_id FROM tasks WHERE session_id=?)",
             [session_id])
      query!(Repo, "DELETE FROM tasks WHERE session_id=?", [session_id])
      query!(Repo, "DELETE FROM sessions WHERE id=?", [session_id])

      # Per-test creds + MCP service rows. The test user_id is
      # shared across scenarios, so we wipe everything attached to
      # localhost mock URLs to keep scenarios isolated.
      query!(Repo,
             "DELETE FROM user_credentials WHERE user_id=? AND target LIKE 'oauth_client:http://localhost:%'",
             [@test_user_id])
      query!(Repo,
             "DELETE FROM user_credentials WHERE user_id=? AND target LIKE 'mcp:http://localhost:%'",
             [@test_user_id])
      query!(Repo,
             "DELETE FROM authorized_services WHERE user_id=? AND canonical_resource LIKE 'http://localhost:%'",
             [@test_user_id])
    rescue
      _ -> :ok
    end
  end

  # ─── Result checking ────────────────────────────────────────────────────

  defp check_result({:error, reason}, _expect) do
    {false, %{kind: :error, reason: inspect(reason)}, "LLM error"}
  end

  # ─── Chain-mode assertions ──────────────────────────────────────────────
  #
  # Trace shape:
  #   %{turns: [%{kind: :tool_calls, calls: [%{name, args}], results: [...]} |
  #             %{kind: :plain_text, text: "..."}, ...],
  #     final: {:plain_text, text} | :terminated_by_tool | :max_turns | {:error, reason}}
  #
  # Chain-mode `expect` keys:
  #   :includes_tool       — tool name (string) that must appear somewhere in the trace
  #   :includes_tools_all  — list of tool names ALL of which must appear
  #   :includes_tools_none — list of tool names NONE of which may appear
  #   :final               — :plain_text | :terminated_by_tool | :max_turns
  #   :text_contains       — substring (or list of substrings) that must appear in
  #                          some plain-text turn (case-insensitive)
  #   :max_turns           — pre-cap on chain length (default @max_chain_turns_default)
  #   :tool_args_pred      — same shape as :tool_calls mode; checks first matching call

  defp check_result({:chain, trace}, %{kind: :chain} = expect) do
    observed = %{kind: :chain, turn_count: length(trace.turns)}

    cond do
      reason = chain_violates?(trace, expect) ->
        {false, observed, reason}

      true ->
        {true, observed, nil}
    end
  end

  defp chain_violates?(trace, expect) do
    all_tool_names = chain_all_tool_names(trace)

    # Pre-compute each check's violation reason (or nil). First non-nil
    # wins. Avoids cond with bindings in guards (which Elixir doesn't
    # propagate to do-blocks).
    [
      check_chain_error(trace),
      check_chain_includes_tool(expect[:includes_tool], all_tool_names),
      check_chain_includes_all(expect[:includes_tools_all], all_tool_names),
      check_chain_includes_none(expect[:includes_tools_none], all_tool_names),
      check_chain_final(expect[:final], trace.final),
      check_chain_text(expect[:text_contains], trace),
      chain_args_predicate_violations(trace, expect[:tool_args_pred] || %{})
    ]
    |> Enum.find(&(&1 != nil))
  end

  defp check_chain_error(%{final: {:error, reason}}), do: "chain ended in LLM error: " <> inspect(reason)
  defp check_chain_error(_), do: nil

  defp check_chain_includes_tool(nil, _), do: nil
  defp check_chain_includes_tool(name, names) do
    if name in names, do: nil, else: "expected tool #{inspect(name)} in chain, got #{inspect(names)}"
  end

  defp check_chain_includes_all(nil, _), do: nil
  defp check_chain_includes_all(required, names) do
    case required -- names do
      []      -> nil
      missing -> "missing tools: #{inspect(missing)}"
    end
  end

  defp check_chain_includes_none(nil, _), do: nil
  defp check_chain_includes_none(forbidden, names) do
    case Enum.filter(forbidden, &(&1 in names)) do
      []    -> nil
      found -> "forbidden tools called: #{inspect(found)}"
    end
  end

  defp check_chain_final(nil, _), do: nil
  defp check_chain_final(expected, actual) do
    if chain_final_matches?(actual, expected),
      do: nil,
      else: "expected final=#{inspect(expected)}, got #{inspect(actual)}"
  end

  defp check_chain_text(nil, _), do: nil
  defp check_chain_text(needle, trace) do
    if chain_text_contains?(trace, needle),
      do: nil,
      else: "no plain-text turn contained #{inspect(needle)}"
  end

  defp chain_all_tool_names(trace) do
    trace.turns
    |> Enum.flat_map(fn
      %{kind: :tool_calls, calls: cs} -> Enum.map(cs, & &1.name)
      _ -> []
    end)
  end

  defp chain_final_matches?({:plain_text, _}, :plain_text), do: true
  defp chain_final_matches?(:terminated_by_tool, :terminated_by_tool), do: true
  defp chain_final_matches?(:max_turns, :max_turns), do: true
  defp chain_final_matches?(actual, expected), do: actual == expected

  defp chain_text_contains?(trace, needle) when is_binary(needle) do
    chain_text_contains?(trace, [needle])
  end

  defp chain_text_contains?(trace, needles) when is_list(needles) do
    plain_texts =
      trace.turns
      |> Enum.flat_map(fn
        %{kind: :plain_text, text: t} -> [String.downcase(t)]
        _ -> []
      end)

    Enum.all?(needles, fn n ->
      ndown = String.downcase(n)
      Enum.any?(plain_texts, &String.contains?(&1, ndown))
    end)
  end

  defp chain_args_predicate_violations(_trace, predicates) when map_size(predicates) == 0, do: nil

  defp chain_args_predicate_violations(trace, predicates) do
    all_calls =
      trace.turns
      |> Enum.flat_map(fn
        %{kind: :tool_calls, calls: cs} -> cs
        _ -> []
      end)

    Enum.reduce_while(predicates, nil, fn {tool_name, pred}, _acc ->
      case Enum.find(all_calls, fn c -> c.name == tool_name end) do
        nil ->
          {:halt, "args-predicate set for #{tool_name} but the tool was not called in the chain"}

        %{args: args} ->
          case pred.(args) do
            :ok            -> {:cont, nil}
            {:ok, _}       -> {:cont, nil}
            {:error, msg}  -> {:halt, "#{tool_name} args predicate failed: #{msg}"}
            other          -> {:halt, "#{tool_name} args predicate returned #{inspect(other)}"}
          end
      end
    end)
  end

  defp check_result({:ok, text}, %{kind: :plain_text} = expect) when is_binary(text) do
    observed = %{kind: :plain_text, text: slice(text)}

    cond do
      Map.get(expect, :no_bookkeeping, false) and has_bookkeeping?(text) ->
        {false, observed, "plain text contains bookkeeping markers"}

      pred = Map.get(expect, :text_pred) ->
        if pred.(text), do: {true, observed, nil},
                       else: {false, observed, "text predicate failed"}

      true ->
        {true, observed, nil}
    end
  end

  defp check_result({:ok, {:tool_calls, _}} = result, %{kind: :plain_text}) do
    names = tool_names(result)
    {false, %{kind: :tool_calls, names: names}, "expected plain text, got tools: #{inspect(names)}"}
  end

  defp check_result({:ok, {:tool_calls, calls}} = result, %{kind: :tool_calls} = expect) do
    names = tool_names(result)

    args_summary =
      Enum.map(calls, fn c ->
        %{
          name: get_in(c, ["function", "name"]) || "",
          args: get_in(c, ["function", "arguments"]) || %{}
        }
      end)

    observed = %{kind: :tool_calls, names: names, calls: args_summary}

    required  = Map.get(expect, :required, [])
    forbidden = Map.get(expect, :forbidden, [])
    any_of    = Map.get(expect, :any_of, [])
    args_pred = Map.get(expect, :tool_args_pred, %{})

    missing      = Enum.reject(required, &(&1 in names))
    found_forbid = Enum.filter(forbidden, &(&1 in names))
    any_match    = any_of == [] or Enum.any?(any_of, &(&1 in names))

    args_check = check_args_predicates(args_summary, args_pred)

    cond do
      missing != [] ->
        {false, observed, "missing required tools: #{inspect(missing)}"}

      found_forbid != [] ->
        {false, observed, "forbidden tools called: #{inspect(found_forbid)}"}

      not any_match ->
        {false, observed, "expected one of #{inspect(any_of)}, got #{inspect(names)}"}

      args_check != :ok ->
        {false, observed, args_check}

      true ->
        {true, observed, nil}
    end
  end

  # `tool_args_pred` shape: `%{tool_name => fn args -> {:ok, summary} | {:error, reason} end}`.
  # Predicate fires for the FIRST matching tool_call of that name. If
  # any predicate fails, we surface its error string. If a predicate
  # is declared for a tool that wasn't called, that's a fail too —
  # the assertion implies the call should have been made.
  defp check_args_predicates(_calls, predicates) when map_size(predicates) == 0, do: :ok

  defp check_args_predicates(calls, predicates) do
    Enum.reduce_while(predicates, :ok, fn {tool_name, pred}, _acc ->
      case Enum.find(calls, fn c -> c.name == tool_name end) do
        nil ->
          {:halt, "args-predicate set for #{tool_name} but the tool was not called"}

        %{args: args} ->
          case pred.(args) do
            :ok            -> {:cont, :ok}
            {:ok, _}       -> {:cont, :ok}
            {:error, msg}  -> {:halt, "#{tool_name} args predicate failed: #{msg}"}
            other          -> {:halt, "#{tool_name} args predicate returned #{inspect(other)}"}
          end
      end
    end)
  end

  defp check_result({:ok, text}, %{kind: :tool_calls}) when is_binary(text) do
    {false, %{kind: :plain_text, text: slice(text)}, "expected tool calls, got plain text"}
  end

  # Either-mode: accepts plain text OR tool calls. When tool calls,
  # applies the same forbidden / required / any_of checks. Useful for
  # scenarios where multiple defensible responses exist (e.g. verb on
  # a missing task — plain text "there's no task X" is fine, AND a
  # fetch_task probe is fine, but a destructive verb on the bad num
  # is not).
  defp check_result({:ok, text}, %{kind: :either} = expect) when is_binary(text) do
    observed = %{kind: :plain_text, text: slice(text)}

    if Map.get(expect, :no_bookkeeping, false) and has_bookkeeping?(text) do
      {false, observed, "plain text contains bookkeeping markers"}
    else
      {true, observed, nil}
    end
  end

  defp check_result({:ok, {:tool_calls, _}} = result, %{kind: :either} = expect) do
    # Promote :either → :tool_calls reuses all the tool-call checks
    # (required / forbidden / any_of / tool_args_pred).
    check_result(result, Map.put(expect, :kind, :tool_calls))
  end

  defp tool_names({:ok, {:tool_calls, calls}}) do
    Enum.map(calls, &(get_in(&1, ["function", "name"]) || ""))
  end
  defp tool_names(_), do: []

  defp has_bookkeeping?(text) do
    Regex.match?(~r/\b(?:Task\s*)?\(\d+\)/u, text) or
      String.contains?(text, "Result:") or
      String.contains?(text, "✓ Done") or
      String.contains?(text, "[used:")
  end

  defp slice(text) when is_binary(text), do: String.slice(text, 0, 500)
  defp slice(other), do: inspect(other)

  defp messages_byte_size(messages) do
    messages
    |> Enum.map(fn m -> byte_size(m[:content] || m["content"] || "") end)
    |> Enum.sum()
  end

  defp route(model) do
    if String.contains?(model, "::") do
      model
    else
      pool = if String.ends_with?(model, "-cloud") or String.ends_with?(model, ":cloud"),
              do: "cloud", else: "local"

      "ollama::#{pool}::#{model}"
    end
  end

  # ─── Report writer ──────────────────────────────────────────────────────

  defp write_report(model_name, prompt_path, results) do
    timestamp   = DateTime.utc_now() |> DateTime.to_iso8601()
    skipped     = Enum.filter(results, &Map.get(&1, :skipped, false))
    runnable    = Enum.reject(results, &Map.get(&1, :skipped, false))
    pass_count  = Enum.count(runnable, & &1.pass)
    total_run   = length(runnable)

    prompt_label =
      case prompt_path do
        :live -> "_live `SystemPrompt.assistant_base/0`_"
        path  -> "`#{path}`"
      end

    md =
      "# Prompt scenarios — `#{model_name}`\n\n" <>
        "Generated: #{timestamp}\n\n" <>
        "Prompt: #{prompt_label}\n\n" <>
        "Pass: **#{pass_count}/#{total_run}**" <>
        (if skipped != [], do: " (#{length(skipped)} skipped)", else: "") <>
        "\n\n" <>
        "## Summary\n\n" <>
        "| # | Scenario | Result | Duration | Reason |\n" <>
        "|---|---|---|---|---|\n" <>
        (results
         |> Enum.map_join("\n", fn r ->
           result_str =
             cond do
               Map.get(r, :skipped, false) -> "_skipped_"
               r.pass -> "PASS"
               true -> "**FAIL**"
             end

           "| #{r.id} | `#{r.name}` | #{result_str} | #{r.duration_ms}ms | #{r.reason || ""} |"
         end)) <>
        "\n\n## Details\n\n" <>
        Enum.map_join(results, "\n\n---\n\n", &render_detail/1)

    safe = String.replace(model_name, [":", "/"], "_")
    path = Path.join(@reports_dir, "#{safe}.md")
    File.write!(path, md)
    IO.puts("Report: #{path}")
  end

  defp render_detail(r) do
    "### ##{r.id} `#{r.name}` — #{if r.pass, do: "PASS", else: "FAIL"}\n\n" <>
      (if r.description != "", do: "> #{r.description}\n\n", else: "") <>
      (if r.reason, do: "**Reason:** #{r.reason}\n\n", else: "") <>
      "**Observed:**\n\n```elixir\n" <>
      inspect(r.observed, pretty: true, limit: :infinity, width: 80) <>
      "\n```"
  end

  # ─── Setup helpers (used by scenario setup fns) ─────────────────────────

  defp insert_task(user_id, session_id, opts) do
    Tasks.insert(
      Keyword.merge(
        [
          user_id:     user_id,
          session_id:  session_id,
          task_type:   "one_off",
          intvl_sec:   0,
          task_status: "ongoing",
          language:    "en",
          attachments: []
        ],
        opts
      )
    )
  end

  defp append_user(session_id, user_id, content) do
    UserAgentMessages.append(session_id, user_id, %{role: "user", content: content})
  end

  defp append_assistant(session_id, user_id, content) do
    UserAgentMessages.append(session_id, user_id, %{role: "assistant", content: content})
  end

  # ─── Scenarios ──────────────────────────────────────────────────────────

  defp scenarios do
    [
      # 1. Chitchat — should be plain text, no tools.
      %{
        id: 1,
        name: "chitchat",
        description: "casual greeting → plain text only, no tools",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id, "hi, how are you today?")
          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 2. Knowledge — should be plain text, no tools.
      %{
        id: 2,
        name: "knowledge_static_fact",
        description: "static fact answerable from training → plain text only",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id, "what is the capital of France?")
          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 3. Live event — should call tools (typically create_task).
      %{
        id: 3,
        name: "live_event_create_task",
        description: "live data question → must call tool",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id, "what is the bitcoin price right now in USD?")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["create_task", "web_search", "run_script", "web_fetch"]}
      },

      # 4. Webhook NOT MCP — must NOT call connect_mcp on a non-MCP URL.
      %{
        id: 4,
        name: "webhook_not_mcp",
        description: "user pastes a Bitrix webhook URL — must NOT call connect_mcp",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "create a new deal in bitrix24 via this inbound webhook: " <>
              "https://example.bitrix24.de/rest/1/abc123def456/")
          %{}
        end,
        expect: %{kind: :tool_calls, forbidden: ["connect_mcp"]}
      },

      # 5. Real MCP server — should call connect_mcp.
      %{
        id: 5,
        name: "mcp_real",
        description: "user names an MCP server URL → connect_mcp",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "connect to my Hugging Face MCP server at https://huggingface.co/mcp")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["connect_mcp", "create_task"]}
      },

      # 6. Fresh attachment — `📎 ` line on the last user msg gets
      #    rewritten to `📎 [newly attached] ` by mark_fresh_attachments
      #    inside build_assistant_messages. Model must extract.
      %{
        id: 6,
        name: "fresh_attachment_extract",
        description: "📎 [newly attached] file (after runtime rewrite) → must extract_content",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "📎 workspace/data/quarterly_report.pdf\n\nplease summarize this report.")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["extract_content", "create_task"]}
      },

      # 7. Historical attachment in `## Recently-extracted files`, gist Q.
      #    Production-realistic: prior task done, prior extract tool_history
      #    entry (so the directory block fires AND the actual `role: "tool"`
      #    content sits in context). Current user msg has NO 📎 — they just
      #    reference the file by name in prose.
      %{
        id: 7,
        name: "historical_attachment_gist",
        description: "file in `## Recently-extracted files`, gist Q, no 📎 → answer from history",
        setup: fn session_id, user_id, _mocks ->
          path = "workspace/data/quarterly_report.pdf"

          # Prior task: created, did the extract, answered, marked done.
          task_id = insert_task(user_id, session_id,
            task_title: "Summarize quarterly report",
            task_spec:  "summarize the quarterly report",
            attachments: [path])

          # Persist ONLY the prior text exchange in session.messages.
          # In production, tool_call / tool_result messages live in
          # `sessions.tool_history` (rolling window), NOT in
          # `sessions.messages` — that's the layer that carries text
          # only. ContextEngine.build_assistant_messages re-injects
          # tool_history at the right point in the LLM message stream.
          append_user(session_id, user_id,
            "📎 " <> path <> "\n\nplease summarize this report.")
          append_assistant(session_id, user_id,
            "Q3 revenue rose 12%, eight hires landed, and edge runtime v2 ships.")

          # Tag this turn's tool messages into tool_history so
          # `## Recently-extracted files` fires AND the raw tool content
          # is re-injected into the next chain's context.
          ToolHistory.save_turn(
            session_id,
            user_id,
            System.os_time(:millisecond),
            [
              %{
                role: "assistant",
                content: "",
                tool_calls: [%{
                  "id" => "call_extract_001",
                  "type" => "function",
                  "function" => %{
                    "name" => "extract_content",
                    "arguments" => %{"path" => path}
                  }
                }]
              },
              %{
                role: "tool",
                tool_call_id: "call_extract_001",
                content:
                  "QUARTERLY REPORT — Q3.\n" <>
                    "Headlines: revenue +12% YoY, headcount up 8 hires, edge runtime ships v2.\n\n" <>
                    "Body sections covered (beyond the headline blurb):\n" <>
                    "1. Operating margins by segment.\n" <>
                    "2. Customer churn breakdown by tier.\n" <>
                    "3. Forward-looking risks: regulatory in EU, hiring pipeline thinning.\n" <>
                    "4. Capital allocation: 60% R&D, 25% sales, 15% buyback.\n" <>
                    "5. Roadmap detail: edge runtime v2, OAuth2.1 compliance, multi-region rollout."
              }
            ],
            1
          )

          Tasks.mark_done(task_id, "summarized — covers Q3 revenue, headcount, product roadmap")

          # Current chain's user message — pure prose, no 📎.
          append_user(session_id, user_id,
            "for the quarterly_report — what else does it cover beyond the headlines?")

          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 8. Historical attachment NOT in Recently-extracted, verbatim Q.
      #    Prior extraction happened in a far-past chain that has rolled
      #    out of tool_history retention; the file name appears in prose
      #    only. Model must re-extract via a full task cycle.
      %{
        id: 8,
        name: "historical_attachment_verbatim",
        description: "file NOT in `## Recently-extracted files`, verbatim Q → re-extract",
        setup: fn session_id, user_id, _mocks ->
          # An older done task that mentioned the file but whose
          # tool_history entry has aged out.
          old = insert_task(user_id, session_id,
            task_title: "Old contract review",
            task_spec:  "review old_contract.pdf",
            attachments: ["workspace/data/old_contract.pdf"])
          Tasks.mark_done(old, "reviewed — flagged 2 risk clauses")

          append_user(session_id, user_id,
            "for old_contract.pdf — what is the EXACT wording of clause 3?")

          %{}
        end,
        # `fetch_task` is a defensible first move — gather the prior
        # task's context before deciding whether to re-extract or
        # answer from a still-cached prior result. The next turn would
        # land on `create_task` / `extract_content` if the prior
        # archive doesn't have the verbatim content. Plain text is
        # the wrong answer (no verbatim source).
        expect: %{kind: :tool_calls, any_of: ["create_task", "extract_content", "fetch_task"]}
      },

      # 9. Pivot — anchor set, off-topic ask → plain text only,
      #    NO tool calls (including no create_task).
      %{
        id: 9,
        name: "pivot_off_topic",
        description: "anchor set + off-topic question → plain text only, NO tools",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Send Bitrix deal via webhook",
            task_spec: "create a deal in bitrix24 using the inbound webhook URL the user provided")

          # Some prior activity on this task so the anchor block's
          # "recent activity is in the conversation above" claim isn't
          # a flat lie.
          append_user(session_id, user_id,
            "create a new deal in bitrix24 via webhook https://example.bitrix24.de/rest/1/x/")
          append_assistant(session_id, user_id,
            "On it — let me probe the webhook to confirm the available fields.")

          # Off-topic chain-opening message. NOT a silent pickup —
          # this is user-initiated. Anchor block fires from the active
          # task without needing silent_turn_task_id.
          append_user(session_id, user_id, "what is the capital of Germany?")

          _ = tid
          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 10. Pivot accept — model already surfaced the conflict; user
      #     says "yes pause". Must call pause_task. Must NOT call
      #     create_task (runtime auto-creates the new task).
      %{
        id: 10,
        name: "pivot_accept_pause",
        description: "user accepts pivot → pause_task only, runtime auto-creates new task",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Send Bitrix deal via webhook",
            task_spec: "create a deal in bitrix24")

          append_user(session_id, user_id,
            "create a new deal in bitrix24 via webhook https://example.bitrix24.de/rest/1/x/")
          append_assistant(session_id, user_id, "Working on it.")

          append_user(session_id, user_id, "what is the capital of Germany?")
          append_assistant(session_id, user_id,
            "I'm currently on task (1) — Send Bitrix deal via webhook. Want me to pause / cancel / stop it and handle your new request first, or finish (1) before getting to it?")

          append_user(session_id, user_id,
            "yes, pause it for now and handle my new question first")

          _ = tid
          %{}
        end,
        expect: %{kind: :tool_calls, required: ["pause_task"], forbidden: ["create_task"]}
      },

      # 11. Refine anchor — anchor set, on-topic clarification.
      #     Must continue with execution tools. Must NOT create_task.
      %{
        id: 11,
        name: "refine_anchor",
        description: "anchor set + on-topic clarification → continue, NOT create_task",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Send Bitrix deal via webhook",
            task_spec: "create a deal in bitrix24 using the inbound webhook URL")

          append_user(session_id, user_id,
            "create a new deal in bitrix24 via webhook https://example.bitrix24.de/rest/1/x/")
          append_assistant(session_id, user_id,
            "Started — I'll use the default category for now.")

          append_user(session_id, user_id, "use category=2 instead of the default")

          _ = tid
          %{}
        end,
        expect: %{kind: :tool_calls, forbidden: ["create_task"]}
      },

      # 12. Don't teach — DO action with tools available.
      %{
        id: 12,
        name: "dont_teach_use_tool",
        description: "DO action with tools available → tool call, not instructions",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "fetch the title of https://example.com and tell me what it is")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["create_task", "web_fetch", "run_script"]}
      },

      # 13. SSH — must call provision_ssh_identity (or wrap in create_task).
      %{
        id: 13,
        name: "ssh_provision_first",
        description: "ssh request → provision_ssh_identity",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "ssh into ubuntu@1.2.3.4 and run `df -h` to check disk usage")
          %{}
        end,
        expect: %{
          kind: :tool_calls,
          any_of: ["provision_ssh_identity", "create_task"]
        }
      },

      # 14. Save creds — user pastes a credential.
      %{
        id: 14,
        name: "save_creds_on_paste",
        description: "user pastes API key → save_creds for cross-chain recall",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "save my OpenAI API key for later use: sk-test-1234567890abcdef. " <>
              "Use it when I ask you to call OpenAI.")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["save_creds", "create_task"]}
      },

      # 15. Periodic completion — periodic task in silent pickup, model
      #     has already done the work mid-chain. Model's NEXT call must
      #     be complete_task. We use `mid_chain` to inject the
      #     tool_call/tool_result pair that would only exist while a
      #     chain is actually running.
      %{
        id: 15,
        name: "periodic_completion",
        description: "periodic anchor + work done in mid-chain → complete_task",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Daily news brief",
            task_spec:  "fetch today's top 5 tech headlines and summarize",
            task_type:  "periodic",
            intvl_sec:  86_400)

          # Mid-chain pairs end with the tool result so the LLM's
          # NEXT generation is the model's response (Ollama rejects
          # requests where the last message is `assistant`). The
          # model should observe the tool result, recognize work is
          # done, and emit `complete_task` as its next call.
          mid = [
            %{
              role: "assistant",
              content: "",
              tool_calls: [%{
                "id" => "call_news_001",
                "type" => "function",
                "function" => %{
                  "name" => "run_script",
                  "arguments" => %{
                    "script" => "curl -s https://news.example.com/api/top5 | jq ."
                  }
                }
              }]
            },
            %{
              role: "tool",
              tool_call_id: "call_news_001",
              content:
                "[\n  {\"title\":\"AI chip prices ease\"},\n" <>
                  "  {\"title\":\"Quantum router beats benchmark\"},\n" <>
                  "  {\"title\":\"OSS license fight in EU\"},\n" <>
                  "  {\"title\":\"FE framework rotates leader\"},\n" <>
                  "  {\"title\":\"Edge runtime ships v2\"}\n]"
            }
          ]

          %{silent_turn_task_id: tid, mid_chain: mid}
        end,
        expect: %{kind: :tool_calls, required: ["complete_task"]}
      },

      # 16. No bookkeeping — task just delivered, recent_done has it,
      #     prior turn shows the actual answer, user replies "thanks!"
      #     Plain text, must NOT contain "(N)", "Result:", "✓ Done".
      %{
        id: 16,
        name: "no_bookkeeping_in_text",
        description: "post-delivery reply → plain text without bookkeeping markers",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Identify the flower",
            task_spec:  "identify the flower from the description")

          append_user(session_id, user_id,
            "what's this flower in my garden? small purple, smells strongly, leaves are silvery green")
          append_assistant(session_id, user_id,
            "That's lavender (Lavandula angustifolia) — silvery foliage and the strong scent are dead giveaways.")

          Tasks.mark_done(tid, "lavender (Lavandula angustifolia)")

          append_user(session_id, user_id, "thanks!")

          %{}
        end,
        expect: %{kind: :plain_text, no_bookkeeping: true}
      },

      # ─── Tier 2 — stress / ambiguity / trap scenarios ───────────────────

      # 17. Ambiguous refine-or-new. Anchor=1 was "scrape example.com title".
      #     User now says "do the same for github.com too" — could be:
      #       a) refine task (1) to also handle github
      #       b) new task in parallel
      #       c) different domain → pivot rule (different objective)
      #     v2.5 prompt's `<resuming_task>`: "Ambiguous → ASK FIRST".
      #     Best behavior: plain-text clarification question, no tools.
      %{
        id: 17,
        name: "ambiguous_refine_or_new",
        description: "ambiguous request that overlaps with anchor → ask first, no tools",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Scrape example.com title",
            task_spec:  "fetch https://example.com and extract its title")

          append_user(session_id, user_id, "scrape the title of https://example.com for me")
          append_assistant(session_id, user_id, "On it.")

          append_user(session_id, user_id, "do the same for github.com too")

          _ = tid
          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 18. Multi-axis overload. ONE user message bundles three independent
      #     concerns: a fresh attachment to extract, a credential to save,
      #     and a live-data question to answer. Model must engage tools
      #     (NOT plain text). Choice of which tools is up to the model
      #     (likely create_task + extract_content + save_creds, or
      #     a multi-tool first turn).
      %{
        id: 18,
        name: "multi_axis_overload",
        description: "fresh attachment + cred paste + live-event ask in one msg → tool calls",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "📎 workspace/data/openai_audit.csv\n\n" <>
              "Also, my OpenAI API key is sk-test-mxBpSuf78ABCDEFGH. " <>
              "Use it when needed. And tell me which OpenAI model is currently fastest " <>
              "according to their status page.")
          %{}
        end,
        expect: %{kind: :tool_calls}
      },

      # 19. Adversarial override. User explicitly says "don't create a task,
      #     just answer". The prompt's "live data → tool/task" rule conflicts
      #     with the user's preference. The model should HONOR the user
      #     — either reply directly in plain text (best) OR use a non-task
      #     tool like web_search/web_fetch — but MUST NOT silently
      #     `create_task` against the user's stated wishes.
      %{
        id: 19,
        name: "adversarial_override_no_task",
        description: "user explicitly forbids create_task — model must comply",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "don't create a task, just tell me bitcoin's current price " <>
              "quickly off the top of your head — I just want a rough number")
          %{}
        end,
        # Plain text from training is valid here — the user said "off
        # the top of your head", which licenses a no-tool answer. The
        # rule that fails: silently calling create_task against the
        # user's explicit "don't create a task".
        expect: %{kind: :either, forbidden: ["create_task"]}
      },

      # 20. Boundary — knowledge vs. live with strong recency hint.
      #     "Latest macOS version" — training data has *some* answer,
      #     but the word "latest" demands a current source. Prompt's
      #     <tool_selection>: "current/changing information ... newer
      #     than training data" → web_search.
      %{
        id: 20,
        name: "latest_version_recency",
        description: "'latest' implies recency → engage tools, not plain text",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "what's the latest stable version of macOS, and when did Apple ship it?")
          %{}
        end,
        expect: %{kind: :tool_calls}
      },

      # 21. Changed-mind cancel. Anchor=1 ongoing; user explicitly drops
      #     the work. Must call cancel_task. Forbidden: complete_task
      #     (the work wasn't delivered) or pause_task (user said drop,
      #     not pause).
      %{
        id: 21,
        name: "changed_mind_cancel",
        description: "user explicitly drops the active task → cancel_task",
        setup: fn session_id, user_id, _mocks ->
          tid = insert_task(user_id, session_id,
            task_title: "Research vendor X pricing",
            task_spec:  "compare pricing tiers for vendor X")

          append_user(session_id, user_id, "research pricing for vendor X")
          append_assistant(session_id, user_id, "Pulling their site now.")

          append_user(session_id, user_id,
            "actually, scratch that — I changed my mind, drop it")

          _ = tid
          %{}
        end,
        expect: %{kind: :tool_calls, required: ["cancel_task"], forbidden: ["complete_task", "pause_task"]}
      },

      # 22. Multi-attachment compare. Three fresh attachments at once.
      #     mark_fresh_attachments will mark each `📎 ` line on the last
      #     user message. Model should engage tools — typically
      #     create_task + extract_content (× 3) or a single create_task
      #     wrapping the comparison.
      %{
        id: 22,
        name: "multi_attachment_compare",
        description: "3 fresh attachments → engage tools",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "📎 workspace/data/q1_report.pdf\n" <>
              "📎 workspace/data/q2_report.pdf\n" <>
              "📎 workspace/data/q3_report.pdf\n\n" <>
              "compare these three quarterly reports — what changed across them?")
          %{}
        end,
        expect: %{kind: :tool_calls, any_of: ["create_task", "extract_content"]}
      },

      # 23. Don't-teach explainer exception. The user's literal message
      #     starts with "how do I" — the v2.5 prompt's <hard_constraints>
      #     explicitly authorizes how-to replies in that case. Model
      #     should answer in plain text, NOT silently substitute a tool
      #     call.
      %{
        id: 23,
        name: "dont_teach_explainer_exception",
        description: "'how do I…' authorizes how-to plain-text reply",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "how do I send a Slack message via webhook from the command line?")
          %{}
        end,
        expect: %{kind: :plain_text}
      },

      # 24. Verb on missing task. User says "cancel task 47" but no
      #     task 47 exists. Model should NOT blindly call
      #     cancel_task / complete_task / pause_task / pickup_task on
      #     a non-existent task_num. Acceptable: plain text pointing
      #     out there's no such task; OR a `fetch_task(47)` probe
      #     (which returns "not found") that the model can recover
      #     from on the next turn.
      %{
        id: 24,
        name: "verb_on_missing_task",
        description: "destructive verb on non-existent task_num → don't call it",
        setup: fn session_id, user_id, _mocks ->
          # Insert a task numbered (1) so the task list isn't empty,
          # but NOT (47).
          tid = insert_task(user_id, session_id,
            task_title: "Some real task",
            task_spec:  "do something")

          append_user(session_id, user_id, "cancel task 47")

          _ = tid
          %{}
        end,
        expect: %{kind: :either, forbidden: ["cancel_task", "complete_task", "pause_task", "pickup_task"]}
      },

      # ─── Tier 3 — credentials / MCP / request_input details ─────────────

      # 25. (RESERVED for stdio MCP transport — task #153, not built yet.)

      # 26. MCP OAuth — connect_mcp on a Bitrix-style OAuth URL.
      #     Model must emit connect_mcp on the URL the user pasted.
      #
      #     Single-turn assertion: tool call shape only. Full
      #     auth_url-relay validation requires multi-turn execution
      #     (next round).
      %{
        id: 26,
        name: "mcp_oauth_needs_auth",
        description: "connect_mcp on OAuth-protected URL → call connect_mcp",
        requires_mock: :bitrix24,
        setup: fn session_id, user_id, mocks ->
          url = mocks[:bitrix24][:url]
          append_user(session_id, user_id, "connect to my Bitrix24 at #{url} so I can use its tools")
          %{}
        end,
        expect: %{
          kind: :tool_calls,
          required: ["connect_mcp"],
          tool_args_pred: %{
            "connect_mcp" => fn args ->
              url = args["url"] || args[:url] || ""

              if is_binary(url) and String.contains?(url, "localhost") do
                :ok
              else
                {:error, "expected localhost mock URL, got #{inspect(url)}"}
              end
            end
          }
        }
      },

      # 27. End-to-end OAuth callback resume.
      %{
        id: 27,
        name: "chain_oauth_callback_resume",
        description: """
        Two-chain flow simulating the full OAuth lifecycle:

          Chain 1
            1. Model emits connect_mcp(url) on the bitrix24 mock URL
               (path /mcp).
            2. Runtime walks the discovery cascade (PRM → ASM), mints
               state, builds auth_url, returns
               {status: "needs_auth", auth_url}.
            3. Chain ends (needs_auth is result-terminating).

          OAuth simulation (driven by the runner)
            4. Test hits the auth_url against the bitrix mock with
               `redirect: false`. Mock 302s to the runtime's
               configured redirect_uri with `?code=…&state=…`.
            5. Test parses code+state from the Location header,
               calls Dmhai.Auth.OAuth2.complete_flow(state, code).
            6. Test replicates the production finalize_connection
               body — saves creds, runs MCP handshake to populate
               tools list, registers the service, attaches to anchor.

          Chain 2
            7. Test appends the followup user msg
               ("now use the bitrix tools to ..."). Builds a fresh
               LLM context — `## Authorized MCP services` block now
               carries a row for the bitrix alias.
            8. Model is expected to recognize the now-authorized
               service and either (a) reference it in the answer
               or (b) call a `<alias>.<tool>` namespaced tool.

        Pass criteria
          * Chain 1 includes connect_mcp + ends in :terminated_by_tool
          * OAuth simulation succeeds (auth_url → code → tokens)
          * Chain 2 has at least one turn AND mentions
            the bitrix alias OR calls a namespaced tool

        Caveat / known gap
          The bitrix24 mock's /mcp endpoint requires a hardcoded
          test API key, not the OAuth-minted token. So step 6's
          MCP handshake hits 401 → registered service has tools=[].
          Chain 2 still sees the alias row in the services block
          (just with no tool list). To fully exercise namespaced
          tool calls, the mock /mcp needs to accept tokens minted
          via /oauth/token as well.
        """,
        requires_mock: :bitrix24,
        setup: fn session_id, user_id, mocks ->
          bitrix_base = mocks[:bitrix24][:url]
          url         = bitrix_base <> "/mcp"

          # Pre-save manual oauth_client creds at the bitrix mock's
          # ASM issuer. Without these, connect_mcp's
          # `acquire_or_signal` step returns `:needs_manual` (the
          # mock doesn't expose a DCR endpoint), and the runtime
          # falls through to the api_key setup form — never reaches
          # `needs_auth`. The hardcoded client_id / client_secret
          # match what the bitrix mock's /oauth/token endpoint
          # accepts (see mocks/src/bitrix24.go: `clientSecrets`).
          Dmhai.Auth.Credentials.save(
            user_id,
            "oauth_client:" <> bitrix_base,
            "oauth_client",
            %{"client_id" => "app.test123", "client_secret" => "test_secret_123"},
            notes: "test-prepopulated for #27"
          )

          insert_task(user_id, session_id,
            task_title: "Use bitrix tools",
            task_spec:  "connect to bitrix and call its tools")

          # `auth_method: "auto"` is critical here — anything else
          # short-circuits before reaching needs_auth:
          #   * "none"   → tool tries unauthed `initialize`, gets
          #               401, returns error (skips OAuth discovery
          #               because the user explicitly said no-auth)
          #   * "oauth"  → returns the manual oauth_setup_form
          #   * "api_key"→ returns the api_key_setup_form
          # Tell the model explicitly to use auto so the runtime's
          # discovery cascade fires. Don't say "OAuth" — devstral-
          # small picks "oauth" literally.
          append_user(session_id, user_id,
            "connect to the MCP server at #{url}. " <>
              "Use `auth_method: \"auto\"` so the runtime auto-detects " <>
              "the right authentication via discovery.")

          %{
            anchor_task_num: 1,
            followup_user_msg:
              "now use the connected Bitrix to call its `current_time` tool — " <>
                "use the namespaced tool name from the Authorized MCP services block."
          }
        end,
        expect: %{
          kind: :chain,
          oauth_resume: true,
          max_turns: 3,
          max_turns_chain_2: 4,
          # Chain 1 must include connect_mcp.
          includes_tool: "connect_mcp"
        }
      },

      # 28. MCP api_key needs_setup — connect_mcp on an api-key-protected
      #     MCP URL. Model should call connect_mcp on the user's URL.
      #
      #     Single-turn assertion: tool call shape. Full needs_setup-form
      #     relay validation requires multi-turn execution (next round).
      %{
        id: 28,
        name: "mcp_api_key_needs_setup",
        description: "connect_mcp on api-key MCP URL",
        requires_mock: :mcp_api_key,
        setup: fn session_id, user_id, mocks ->
          url = mocks[:mcp_api_key][:url]
          append_user(session_id, user_id, "connect to my MCP server at #{url}")
          %{}
        end,
        expect: %{
          kind: :tool_calls,
          required: ["connect_mcp"],
          tool_args_pred: %{
            "connect_mcp" => fn args ->
              url = args["url"] || args[:url] || ""

              if is_binary(url) and String.contains?(url, "localhost") do
                :ok
              else
                {:error, "expected localhost mock URL, got #{inspect(url)}"}
              end
            end
          }
        }
      },

      # 29. request_input two fields — model needs paired credentials
      #     (≥2 inputs). v2.5 prompt's <credentials> rule: "Multi-field
      #     (≥2 inputs) → request_input". Assert both:
      #       a) request_input was called
      #       b) the fields list has ≥2 entries with name + label + type
      %{
        id: 29,
        name: "request_input_two_fields",
        description: "≥2 cred fields needed → request_input with all fields populated",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "I want you to call our internal API. It needs both an OAuth client_id " <>
              "and a client_secret. Please set that up so I can use it.")
          %{}
        end,
        expect: %{
          kind: :either,
          required: ["request_input"],
          tool_args_pred: %{
            "request_input" => fn args ->
              fields = args["fields"] || args[:fields] || []

              cond do
                not is_list(fields) ->
                  {:error, "fields must be a list, got #{inspect(fields)}"}

                length(fields) < 2 ->
                  {:error, "expected ≥2 fields, got #{length(fields)}"}

                not Enum.all?(fields, fn f ->
                  is_map(f) and is_binary(f["name"] || f[:name]) and
                    is_binary(f["label"] || f[:label]) and
                    is_binary(f["type"] || f[:type])
                end) ->
                  {:error, "each field must have name + label + type as strings"}

                true ->
                  :ok
              end
            end
          }
        }
      },

      # 30. request_input single field uses text — single credential
      #     ask should NOT use request_input; v2.5 prompt: "Single-field
      #     asks (one password, one URL) → just ask in plain text".
      %{
        id: 30,
        name: "request_input_single_field_uses_text",
        description: "single-field cred ask → plain text, NOT request_input",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "I want you to call OpenAI for me. Please ask me for what's needed.")
          %{}
        end,
        # The model can reasonably either ask in plain text OR call
        # lookup_creds first. What it must NOT do: fire request_input
        # for a single credential (over-engineered for the ask).
        expect: %{kind: :either, forbidden: ["request_input"]}
      },

      # 32. Multi-field non-secret config — request_input is the right
      #     primitive for ≥ 2 named values regardless of whether they're
      #     credentials. Tests that the model doesn't reserve
      #     request_input for secrets only.
      %{
        id: 32,
        name: "request_input_multi_field_config",
        description: "≥2 non-secret config fields → request_input",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "Set up an SMTP relay for me — you'll need from me: " <>
              "host, port, from_address, and reply_to_address. Please " <>
              "set that up.")
          %{}
        end,
        expect: %{
          kind: :either,
          required: ["request_input"],
          tool_args_pred: %{
            "request_input" => fn args ->
              fields = args["fields"] || args[:fields] || []

              if is_list(fields) and length(fields) >= 3 do
                :ok
              else
                {:error, "expected ≥3 fields for SMTP setup, got #{length(fields)}"}
              end
            end
          }
        }
      },

      # 33. Borderline two-input form. Light-stakes pair (name + email)
      #     — still ≥ 2 inputs per prompt rule, so request_input is
      #     correct. Tests that the model doesn't escape into prose
      #     just because the inputs aren't secrets.
      %{
        id: 33,
        name: "request_input_two_inputs_borderline",
        description: "borderline 2 light-stakes inputs (name + email) → request_input",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "I need to set up your account. Please collect from me: " <>
              "my display_name and my email_address.")
          %{}
        end,
        expect: %{
          kind: :either,
          required: ["request_input"],
          tool_args_pred: %{
            "request_input" => fn args ->
              fields = args["fields"] || args[:fields] || []

              if is_list(fields) and length(fields) >= 2 do
                :ok
              else
                {:error, "expected ≥2 fields, got #{length(fields)}"}
              end
            end
          }
        }
      },

      # 34. Open-ended ask — must NOT use request_input. Single
      #     conceptual answer (not structured key-value), so plain text
      #     is the right primitive.
      %{
        id: 34,
        name: "open_ended_uses_prose",
        description: "open-ended question → plain text, NOT request_input",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "I'm starting a new side project. What should I name it? " <>
              "Just throw out a few suggestions and I'll pick.")
          %{}
        end,
        expect: %{kind: :either, forbidden: ["request_input"]}
      },

      # ─── Tier 4 — chain mode (multi-round runner) ───────────────────────

      # 35. End-to-end MCP connect with OAuth discovery → needs_auth
      #     relay. With the extended bitrix24 mock publishing
      #     /.well-known/oauth-protected-resource and
      #     /.well-known/oauth-authorization-server, connect_mcp's
      #     discovery cascade succeeds and returns needs_auth with
      #     a real auth_url. Chain ends right after the tool fires
      #     (needs_auth is result-terminating).
      %{
        id: 35,
        name: "chain_mcp_connect_oauth_needs_auth",
        description: """
        End-to-end MCP connect against the OAuth-publishing bitrix24
        mock. Single tool-call turn:
          1. Model emits connect_mcp(url: "<bitrix>/mcp").
          2. Runtime tries MCP at that path → mock returns 401 with
             WWW-Authenticate: Bearer.
          3. Runtime walks /.well-known/oauth-protected-resource →
             /.well-known/oauth-authorization-server, mints state,
             builds auth_url, and returns
             {status: "needs_auth", auth_url, ...}.
          4. Tool result is chain-terminating → chain ends with
             final = :terminated_by_tool. The model never gets a
             follow-up turn (production behavior: runtime captures
             the auth_url, persists state, emits a synthetic
             assistant message with the link).

        Pass criteria:
          * connect_mcp appears in the chain
          * URL passed to connect_mcp contains "localhost" + "/mcp"
          * final = :terminated_by_tool (NOT plain_text, NOT
            max_turns — must be the tool result that ends it)
        """,
        requires_mock: :bitrix24,
        setup: fn session_id, user_id, mocks ->
          url = mocks[:bitrix24][:url] <> "/mcp"
          tid = insert_task(user_id, session_id,
            task_title: "Connect bitrix",
            task_spec:  "connect to bitrix mock")

          append_user(session_id, user_id,
            "connect to my Bitrix MCP server at #{url} — it uses OAuth 2.1")

          %{anchor_task_num: 1, _tid: tid}
        end,
        expect: %{
          kind: :chain,
          max_turns: 3,
          includes_tool: "connect_mcp",
          final: :terminated_by_tool,
          tool_args_pred: %{
            "connect_mcp" => fn args ->
              url = args["url"] || args[:url] || ""

              cond do
                not is_binary(url) ->
                  {:error, "url must be a string, got #{inspect(url)}"}

                not String.contains?(url, "localhost") ->
                  {:error, "expected localhost URL, got #{inspect(url)}"}

                not String.contains?(url, "/mcp") ->
                  {:error, "expected /mcp suffix in url, got #{inspect(url)}"}

                true ->
                  :ok
              end
            end
          }
        }
      },

      # 36. request_input form ENDS the chain — model must not pair
      #     it with another tool. Production runtime treats
      #     request_input as chain-terminating; the runner mirrors
      #     this. Test asserts the chain ends as soon as
      #     request_input fires.
      %{
        id: 36,
        name: "chain_request_input_terminates",
        description: """
        Verifies request_input is chain-terminating. After the model
        emits request_input(fields: [...]), the chain must NOT
        continue with another LLM call — production captures the
        preceding narration, persists the form, and ends the chain
        until the user submits.

        Setup: user asks for paired credentials so the model is
        expected to call request_input.

        Chain expectation:
          * exactly ONE tool-calls turn (containing request_input)
          * final state == :terminated_by_tool
          * NO subsequent plain-text turn (the chain stops cold)
        """,
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "Set up an OAuth integration for me — I need to provide " <>
              "client_id and client_secret. Please collect them from me.")
          %{}
        end,
        expect: %{
          kind: :chain,
          max_turns: 3,
          includes_tool: "request_input",
          final: :terminated_by_tool
        }
      },

      # 31. save_creds payload shape — when the user hands over a
      #     credential, the model must save it with the right shape:
      #     `target` = stable specific label, `kind` = shape descriptor,
      #     `payload` = nested object (not flat strings).
      %{
        id: 31,
        name: "save_creds_payload_shape",
        description: "save_creds called with target/kind/nested-payload of correct shape",
        setup: fn session_id, user_id, _mocks ->
          append_user(session_id, user_id,
            "save my OpenAI API key sk-test-abc12345 so you can use it later when I ask")
          %{}
        end,
        expect: %{
          kind: :tool_calls,
          any_of: ["save_creds", "create_task"],
          tool_args_pred: %{
            "save_creds" => fn args ->
              target  = args["target"]  || args[:target]
              kind    = args["kind"]    || args[:kind]
              payload = args["payload"] || args[:payload]

              cond do
                not (is_binary(target) and target != "") ->
                  {:error, "target must be a non-empty string, got #{inspect(target)}"}

                not (is_binary(kind) and kind != "") ->
                  {:error, "kind must be a non-empty string, got #{inspect(kind)}"}

                not is_map(payload) ->
                  {:error, "payload must be an object/map, got #{inspect(payload)}"}

                map_size(payload) == 0 ->
                  {:error, "payload must be non-empty"}

                true ->
                  :ok
              end
            end
          }
        }
      }
    ]
  end
end

TestLLM.Runner.run()
