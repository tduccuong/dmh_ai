# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Util.Redact do
  @moduledoc """
  Best-effort redaction of secrets in strings before they hit
  operator-visible logs or user-visible UI.

  Applied at:

    - `DmhAi.Agent.LogTrace` — every entry written to
      `/data/system_logs/llm_trace.log`. The trace log is operator-
      facing, but the file is local and may be tarred up for
      support; redacting on write means a leaked log doesn't leak
      live access tokens.

    - `DmhAi.Tools.RunScript.script_preview/1` — the one-line
      preview shown in the FE while a `run_script` tool call is
      running (e.g. `run_script (3s) → curl …`). The preview is
      taken from the script's first non-empty line; without
      redaction, a `TOKEN="ya29.…"` assignment shows the raw token
      to anyone glancing at the screen.

  ### Not redacted

  Strings sent to the LLM (the assistant's tool_history, the
  conversation messages, tool results returned via `Tools.Registry`)
  are NOT redacted — the model needs the live token to actually use
  the credential. Redaction is for log/display copies only.

  ### Patterns

  Ordered most-specific first (so prefixed token formats win over
  the generic `TOKEN=…` shell-assignment match):

    1. Google OAuth access tokens (`ya29.<base64url>`)
    2. Google OAuth refresh tokens (`1//<base64url>`)
    3. GitHub PATs / OAuth tokens (`gh[ousp]_<base62>`)
    4. AWS access key IDs (`A[KS]IA<upper-alphanum>`)
    5. JSON Web Tokens (three base64url segments separated by `.`)
    6. `Authorization: Bearer <token>` headers
    7. Common shell / config secret-name assignments — `TOKEN=`,
       `API_KEY=`, `SECRET=`, `PASSWORD=`, `ACCESS_KEY=`,
       `SESSION_KEY=`, `REFRESH_TOKEN=`, `CLIENT_SECRET=`,
       `PRIVATE_KEY=`. Case-insensitive, supports `_`/`-`
       variants and `=` or `:` separator.

  Unknown / custom token formats fall through unredacted. This
  module is best-effort — operators handling sensitive
  credentials should still avoid sharing trace logs verbatim.
  """

  @patterns [
    {~r/ya29\.[A-Za-z0-9_\-]{20,}/, "ya29.<redacted>"},
    {~r/\b1\/\/[A-Za-z0-9_\-]{20,}/, "1//<redacted>"},
    {~r/\bgh[ousp]_[A-Za-z0-9]{30,}\b/, "<redacted-github-token>"},
    {~r/\bA[KS]IA[A-Z0-9]{16,}\b/, "<redacted-aws-key>"},
    {~r/\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b/, "<redacted-jwt>"},
    {~r/(Bearer\s+)[A-Za-z0-9._\-+\/=]{20,}/, "\\1<redacted>"},
    # The optional `['"]?` between the key name and the `:`/`=`
    # separator catches the JSON form (`"client_secret": "…"`) in
    # addition to the shell form (`CLIENT_SECRET="…"`).
    {~r/((?i:TOKEN|API[_-]?KEY|SECRET|PASSWORD|ACCESS[_-]?KEY|SESSION[_-]?KEY|REFRESH[_-]?TOKEN|CLIENT[_-]?SECRET|PRIVATE[_-]?KEY)['"]?\s*[:=]\s*['"]?)[^'"\s,;]{16,}(['"]?)/,
     "\\1<redacted>\\2"}
  ]

  @doc """
  Redact all secret patterns from a string. Non-binary input is
  returned untouched (so callers can pipe through without an `is_binary`
  guard at every site).
  """
  def call(s) when is_binary(s) do
    Enum.reduce(@patterns, s, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def call(other), do: other
end
