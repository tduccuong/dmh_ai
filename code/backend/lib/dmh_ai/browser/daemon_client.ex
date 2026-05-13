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
  Send `command` with `args` to the daemon. `ctx` is a map carrying:

    - `:user_id`    (required) — selects the user's BrowserContext.
    - `:session_id` (required) — selects the SessionContext (Page).
    - `:email`      (optional) — used for storage_state path on first
      BrowserContext creation; ignored otherwise.
    - `:viewport`   (optional) — `%{w, h, is_mobile}` to set on the
      session's Page. Omitted → daemon's FALLBACK_VIEWPORT applies on
      first creation; existing Pages keep their viewport.

  Returns:

    - `{:ok, result_map}` on a successful daemon response.
    - `{:error, {:daemon_error, %{type, message}}}` when the daemon
      ran the command but it raised (Playwright timeout, navigation
      error, etc.).
    - `{:error, :daemon_unreachable}` after a failed retry.
  """
  @type ctx :: %{
          required(:user_id) => String.t(),
          required(:session_id) => String.t(),
          optional(:email) => String.t() | nil,
          optional(:viewport) => map() | nil
        }

  @spec call(String.t(), map(), ctx()) :: call_result
  def call(command, args, ctx)
      when is_binary(command) and is_map(args) and is_map(ctx) do
    # Test hook: `Application.put_env(:dmh_ai, :__daemon_client_stub__, fn cmd, args, ctx -> ... end)`.
    if stub = Application.get_env(:dmh_ai, :__daemon_client_stub__) do
      stub.(command, args, ctx)
    else
      real_call(command, args, ctx)
    end
  end

  defp real_call(command, args, ctx) do
    payload = %{
      id: corr_id(),
      command: command,
      args: args,
      user_id: ctx.user_id,
      session_id: ctx.session_id,
      email: Map.get(ctx, :email) || "",
      viewport: Map.get(ctx, :viewport)
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

  # Max single-response size accepted from the daemon. Transport-layer
  # cap. The largest payload is a `screenshot` response: a viewport-
  # sized JPEG (q=80), base64-encoded. At desktop viewport on
  # graphics-heavy commerce pages a JPEG can reach ~300 KB; mobile
  # viewports compress proportionally smaller. 4 MiB covers every
  # realistic case with margin while still catching a runaway
  # response.
  @max_response_bytes 4 * 1024 * 1024

  defp do_call(line) do
    # Raw read-until-EOF. The daemon does one-shot reply-then-close per
    # connection (see browser_daemon.py `handle/2`), so reading until
    # the socket closes is the bulletproof shape: no packet_size cap
    # to tune, no MTU-boundary fragmentation, just "the daemon's full
    # response, however long". Prior `packet: :line` mode silently
    # truncated multi-KB responses at TCP-frame boundaries on
    # AF_UNIX, producing partial JSON that broke Jason.decode.
    opts = [
      :binary,
      active: false,
      packet: :raw
    ]

    case :gen_tcp.connect({:local, @sock_path}, 0, opts, @connect_timeout_ms) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_tcp.send(sock, line),
               {:ok, response} <- recv_until_eof(sock, []),
               {:ok, decoded} <- Jason.decode(String.trim(response)) do
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

  defp recv_until_eof(sock, acc) do
    case :gen_tcp.recv(sock, 0, @recv_timeout_ms) do
      {:ok, chunk} ->
        if IO.iodata_length(acc) + byte_size(chunk) > @max_response_bytes do
          {:error, :response_too_large}
        else
          recv_until_eof(sock, [acc, chunk])
        end

      {:error, :closed} ->
        {:ok, IO.iodata_to_binary(acc)}

      {:error, _} = err ->
        err
    end
  end

  # In-band soft errors: the daemon's indexed and selector verbs return
  # a successful result envelope whose body is `{"error": <type>, "reason": <msg>}`
  # when the verb's preconditions couldn't be met (stale nonce, selector
  # matched nothing) — see `browser_daemon.py` `_cmd_indexed` /
  # `_cmd_selector`. Translate them up to a uniform `{:error,
  # {:daemon_error, ...}}` so callers (`Browser.Loop`, R10 tests, future
  # tools) can pattern-match on `%{type: "stale_index"}` etc. without
  # caring whether the daemon raised or returned-with-error.
  defp interpret(%{"ok" => true, "result" => %{"error" => err_type} = result})
       when is_binary(err_type) do
    msg = result["reason"] || result["message"] || err_type
    {:error, {:daemon_error, %{type: err_type, message: to_string(msg)}}}
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
