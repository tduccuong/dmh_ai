# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.DaemonClient do
  @moduledoc """
  Unix-socket client for the sandbox-side browser daemon
  (`code/sandbox/browser_daemon.py`).

  Protocol — newline-JSON, one connection per request:

      → {"id":"<corr>", "user_id":"<id>", "email":"<email>",
         "command":"navigate", "args":{"url":"https://..."}}\\n
      ← {"id":"<corr>", "ok":true,  "result":{...}}\\n
        {"id":"<corr>", "ok":false, "error":"...", "type":"<py-exc>"}\\n

  The socket path is bind-mounted from the sandbox container at
  `/data/run/dmh-browser/daemon.sock` (host-master side, see
  `dist/docker-compose.yml`).

  ## Lifecycle / availability

  The daemon self-terminates after `BROWSER_IDLE_SHUTDOWN_S` of no
  traffic to free Chromium memory on Pi-class hosts; the sandbox's
  `start.sh` supervisor relaunches it on the next request. So a
  `:enoent` / `:econnrefused` here is **expected** during that brief
  relaunch window — caller should retry once with a small backoff.

  ## v0 limitations (see arch_wiki/dmh_ai/architecture.md §Browser tools)

    - Single global lock inside the daemon serialises all turns.
    - One connection per call, no pooling. Open/close cost on a
      Unix socket is ~10 µs — negligible vs Playwright command
      latency (50 ms - 5 s).
    - No retry/backoff in this module beyond a single relaunch wait;
      higher-level retry policy lives in `Browser.Loop`.
  """

  require Logger

  @sock_path Application.compile_env(
               :dmh_ai,
               :browser_daemon_sock_path,
               "/data/run/dmh-browser/daemon.sock"
             )

  # Connection-establishment timeout. The socket file might not exist
  # yet (daemon restarting after idle shutdown) — short timeout so we
  # can retry quickly.
  @connect_timeout_ms 2_000

  # Per-call response timeout. Most browser commands return in
  # 50 ms - 5 s; navigate / wait_for_selector can legitimately take
  # 30 s on a slow page. Cap above the daemon's per-command default
  # (15 s) to leave room for the daemon's own internal timeout to
  # fire first with a clean error.
  @recv_timeout_ms 60_000

  # If the first connect fails (socket missing — daemon shutdown),
  # wait this long and retry once. Daemon takes ~1.5 s to relaunch
  # under start.sh's supervisor. One retry covers the relaunch
  # window without burning latency on a genuine outage.
  @relaunch_wait_ms 2_500

  @type call_result ::
          {:ok, map()}
          | {:error, :daemon_unreachable}
          | {:error, {:daemon_error, %{type: String.t(), message: String.t()}}}
          | {:error, term()}

  @doc """
  Send `command` with `args` to the daemon for `user_id`/`email`.

  Returns:

    - `{:ok, result_map}` on a successful daemon response.
    - `{:error, {:daemon_error, %{type, message}}}` when the daemon
      ran the command but it raised (Playwright timeout, missing
      selector, navigation error, etc.). The caller — typically the
      action loop — feeds this back to the model so it can correct.
    - `{:error, :daemon_unreachable}` after a failed retry. The
      sandbox is probably crashed; the action loop surfaces this
      to the user.
  """
  @spec call(String.t(), map(), String.t(), String.t() | nil) :: call_result
  def call(command, args, user_id, email)
      when is_binary(command) and is_map(args) and is_binary(user_id) do
    payload = %{
      id: corr_id(),
      command: command,
      args: args,
      user_id: user_id,
      email: email || ""
    }

    line = Jason.encode!(payload) <> "\n"

    case do_call(line) do
      {:ok, _} = ok ->
        ok

      {:error, :enoent} ->
        # Socket file missing — daemon is mid-restart. Wait briefly
        # and retry once.
        Process.sleep(@relaunch_wait_ms)
        case do_call(line) do
          {:ok, _} = ok ->
            ok
          _ ->
            Logger.warning("[Browser.DaemonClient] daemon unreachable after retry")
            {:error, :daemon_unreachable}
        end

      {:error, :econnrefused} ->
        Process.sleep(@relaunch_wait_ms)
        case do_call(line) do
          {:ok, _} = ok ->
            ok
          _ ->
            Logger.warning("[Browser.DaemonClient] daemon unreachable after retry")
            {:error, :daemon_unreachable}
        end

      {:error, _} = err ->
        err
    end
  end

  # ── private ──────────────────────────────────────────────────────────────────

  defp do_call(line) do
    opts = [:binary, active: false, packet: :line]

    case :gen_tcp.connect({:local, @sock_path}, 0, opts, @connect_timeout_ms) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_tcp.send(sock, line),
               {:ok, response_line} <- :gen_tcp.recv(sock, 0, @recv_timeout_ms),
               {:ok, decoded} <- Jason.decode(response_line) do
            interpret(decoded)
          else
            {:error, _} = err -> err
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, _} = err ->
        err
    end
  end

  defp interpret(%{"ok" => true, "result" => result}) when is_map(result), do: {:ok, result}

  defp interpret(%{"ok" => false, "error" => msg, "type" => type}),
    do: {:error, {:daemon_error, %{type: type, message: to_string(msg)}}}

  defp interpret(%{"ok" => false, "error" => msg}),
    do: {:error, {:daemon_error, %{type: "Unknown", message: to_string(msg)}}}

  defp interpret(other),
    do: {:error, {:malformed_response, other}}

  defp corr_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
