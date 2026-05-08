# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Tools.BrowserNavigate do
  @moduledoc """
  Drives a real Chromium browser inside the sandbox to carry out
  authenticated, multi-step tasks on the user's behalf — *"go to
  shop-apotheke.com, find ibuprofen 400mg, add it to the cart"* style.

  ## Implementation (v0 — #215, #219, #220)

  Three pieces:

    - **Consent gate** in this module — `users.browser_consent_at`
      must be set AND `users.browser_consent_text_hash` must equal
      `DmhAi.Browser.ConsentText.hash/0`. Misses emit a
      `kind: "browser_consent_required"` `session_progress` row and
      return `{:ok, %{status: "needs_consent"}}`.

    - **Sandbox Playwright daemon**
      (`code/sandbox/browser_daemon.py`) — one Chromium per
      deployment, BrowserContext-per-user, Unix-socket IPC.

    - **Action loop** (`DmhAi.Browser.Loop`) — observe→ask→act with
      `browserAgentModel`, capped by `browserMaxTurnsPerTask` and
      `browserMaxRuntimeMs`.

  ## Consent gate

  Before any real browser work can run, `users.browser_consent_at` must
  be set AND `users.browser_consent_text_hash` must equal the current
  `DmhAi.Browser.ConsentText.hash/0`.

  Misses (NULL watermark, hash mismatch from a meaningful text update,
  or revocation) cause the tool to:

    1. Append a `kind: \"browser_consent_required\"` `session_progress`
       row carrying the canonical consent text + the current hash.
       The FE renders that row as a modal-style card with "I
       understand and accept" / "Cancel" buttons.

    2. Return `{:ok, %{status: \"needs_consent\", reason: <human
       string>}}` to the model. The model sees an honest tool result
       and can relay it to the user in plain text — no error from
       the runtime's perspective.

  After the user accepts via `POST /auth/me/browser-consent`, the
  next `browser_navigate` invocation passes the gate and dispatches to
  `Browser.Loop.run/4`.
  """

  @behaviour DmhAi.Tools.Behaviour

  alias DmhAi.Repo
  alias DmhAi.Browser.ConsentText
  alias DmhAi.Agent.SessionProgress
  import Ecto.Adapters.SQL, only: [query!: 3]
  require Logger

  @impl true
  def name, do: "browser_navigate"

  @impl true
  def description do
    """
    Drive a real Chromium browser to complete a multi-step task on a website using the user's own login. Use for things like \"check current price of X on shop-apotheke.com\" or \"find the latest order in my account on Y\". Authentication, captchas, and 2FA are handed back to the user via an embedded browser view; payment confirmation is always done by the user, not by you.
    """
  end

  @impl true
  def definition do
    %{
      name: name(),
      description: description(),
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "Starting URL. Must be https://. Will be opened in the headless browser; from there the agent navigates as needed."
          },
          goal: %{
            type: "string",
            description: "Plain-English description of what to accomplish on the site. Be specific — include product names, sizes, account-section names, the user's stated preferences. Stop short of any payment / final-submit step; a separate confirmation flow handles that."
          },
          constraints: %{
            type: "string",
            description: "Optional: hard guardrails the agent must obey (\"do not switch to a different brand\", \"only use the saved address\", etc.). Plain English."
          }
        },
        required: ["url", "goal"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    user_id = ctx[:user_id] || ctx["user_id"]

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, "browser_navigate called without user_id in context"}

      not valid_url?(args["url"]) ->
        {:error, "browser_navigate: `url` must be an https:// URL"}

      not (is_binary(args["goal"]) and args["goal"] != "") ->
        {:error, "browser_navigate: `goal` is required"}

      true ->
        case consent_state(user_id) do
          :consented ->
            DmhAi.Browser.Loop.run(
              args["url"],
              args["goal"],
              args["constraints"],
              ctx
            )

          reason ->
            emit_consent_progress_row(ctx)
            {:ok, %{status: "needs_consent", reason: human_reason(reason)}}
        end
    end
  end

  # ── consent lookup ────────────────────────────────────────────────────────

  @doc """
  Public helper — returns one of:

    * `:consented` — accepted, hash matches the current canonical text.
    * `:never_accepted` — never POSTed to /auth/me/browser-consent.
    * `:hash_mismatch` — accepted previously, but the canonical text
      has changed since.
    * `:user_not_found` — defensive; treated as never-accepted.
  """
  @spec consent_state(String.t()) :: :consented | :never_accepted | :hash_mismatch | :user_not_found
  def consent_state(user_id) when is_binary(user_id) do
    case query!(Repo,
           "SELECT browser_consent_at, browser_consent_text_hash FROM users WHERE id=?",
           [user_id]
         ) do
      %{rows: [[ts, hash]]} ->
        cond do
          is_nil(ts) -> :never_accepted
          hash != ConsentText.hash() -> :hash_mismatch
          true -> :consented
        end

      _ ->
        :user_not_found
    end
  rescue
    _ -> :never_accepted
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp valid_url?(url) when is_binary(url), do: String.starts_with?(url, "https://")
  defp valid_url?(_), do: false

  defp human_reason(:never_accepted),
    do:
      "Browser tools are disabled for this user. The user must read and accept the terms — a consent prompt has been added to the chat. Once accepted, ask the user to retry."

  defp human_reason(:hash_mismatch),
    do:
      "The browser-tools terms have changed since the user last accepted. A new consent prompt has been added to the chat — once accepted, ask the user to retry."

  defp human_reason(_),
    do: "Browser tools are not enabled for this user."

  # Marker label only — the full canonical text is multi-paragraph
  # and would render as a one-line slice in the regular progress-row
  # UI. The FE detects this kind, opens a modal, and pulls the
  # canonical text + hash from `GET /auth/me/browser-consent` so the
  # text shown to the user and the hash POSTed on accept come from
  # the same fresh server fetch (no race with consent_text.ex edits
  # landing between row-emission and modal-open).
  @progress_marker "Browser tools require your consent — review and accept the terms."

  @doc "Marker label used on the consent progress row. Public for tests."
  def progress_marker, do: @progress_marker

  defp emit_consent_progress_row(ctx) do
    progress_ctx = %{
      session_id: Map.get(ctx, :session_id) || Map.get(ctx, "session_id"),
      user_id:    Map.get(ctx, :user_id) || Map.get(ctx, "user_id"),
      task_id:    Map.get(ctx, :task_id) || Map.get(ctx, "task_id")
    }

    if is_binary(progress_ctx.session_id) and is_binary(progress_ctx.user_id) do
      _ =
        SessionProgress.append(
          progress_ctx,
          "browser_consent_required",
          @progress_marker
        )
    end

    :ok
  end
end
