# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Browser.ConsentText do
  @moduledoc """
  Single source of truth for the browser-tools consent text the user
  must accept before any `browser_navigate` invocation can proceed.

  The text is treated as a versioned artifact: changing it produces a
  new sha256 hash and forces every user to re-accept. This is the
  whole reason `users.browser_consent_text_hash` is stored alongside
  `users.browser_consent_at` — operators get an audit trail of which
  version each user agreed to, and meaningful text changes (new risk
  category, etc.) re-prompt automatically without manual cohort
  invalidation.

  Trivial wording tweaks (typo fixes, punctuation, whitespace) WILL
  also re-prompt by the strict-hash rule. That's a feature, not a
  bug — there's only one canonical text and it's whatever this module
  emits today. If you want to refine wording without re-prompting,
  don't change this file.
  """

  @text """
  DMH-AI Browser Tools — please read

  These tools let DMH-AI use a real Chromium browser on your behalf — searching, filling forms, navigating websites — using your own logins and your own accounts.

  - Terms of Service. Many websites' Terms of Service prohibit automated access, even by personal-use tools like this one. The site may detect automation and respond with captchas, rate-limits, or in extreme cases account suspension. The risk is yours.

  - DMH-AI never circumvents security gates. Captchas, 2FA codes, and login walls are handed back to you via an embedded browser view inside the chat. DMH-AI does not use captcha-solving services or fingerprint-spoofing.

  - Payments always require your explicit approval. Browser tools assemble the cart and stop at the "ready to confirm" page. You confirm in chat before any money moves.

  - Stored credentials and personal notes saved via save_creds or /memo may be used to log in to sites or fill in forms. Both stay encrypted at rest on your machine.

  Clicking "I understand and accept" confirms you've read this and accept the trade-off. You can revoke this in Settings → Browser tools at any time.
  """

  @hash :crypto.hash(:sha256, @text) |> Base.encode16(case: :lower)

  @doc "Canonical consent text shown to the user."
  @spec text() :: String.t()
  def text, do: @text

  @doc """
  Hex-encoded sha256 of `text/0`. Stored on accept; used at the
  consent-check site to detect text drift and re-prompt.
  """
  @spec hash() :: String.t()
  def hash, do: @hash
end
