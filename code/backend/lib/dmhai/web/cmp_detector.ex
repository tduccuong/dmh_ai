# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.CmpDetector do
  @moduledoc """
  Detect "content is hidden" fingerprints in an HTML response body.

  Two failure modes we want to catch:

  1. **GDPR/CMP consent walls** — the real article is hidden client-side
     behind a consent dialog (OneTrust, Sourcepoint, Didomi, etc.).

  2. **Bot-challenge pages** — the real article is not served at all; the
     body is a CAPTCHA / JS challenge from Datadome, Cloudflare Turnstile,
     Akamai Bot Manager, PerimeterX, etc.

  Both are "chrome instead of content" from our perspective, and both
  benefit from the same fallback strategy (AMP variants, archive mirrors).

  Returns `{:cmp, vendor_atom}` on detection, else `:clean`.
  """

  # Order matters: more specific / more common vendors first.
  # Each entry is {vendor, [regex patterns]}; any match flags the CMP.
  @signatures [
    # ── Bot-challenge pages ────────────────────────────────────────────────
    # Detected FIRST because they typically produce short bodies that could
    # otherwise slip past a CMP check with :clean.

    # Datadome — the 774-byte captcha page we observed on Reuters with
    # bare UA. Signature: geo.captcha-delivery.com + the obfuscated config.
    {:datadome, [
      ~r/captcha-delivery\.com/i,
      ~r/geo\.captcha-delivery/i,
      ~r|<p id="cmsg">Please enable JS|i
    ]},

    # Cloudflare interstitial (UAM / managed challenge / Turnstile)
    {:cloudflare_challenge, [
      ~r/cdn-cgi\/challenge-platform/i,
      ~r/cf-challenge/i,
      ~r/Just a moment\.\.\./,
      ~r/challenges\.cloudflare\.com/i
    ]},

    # Akamai Bot Manager
    {:akamai_bot, [
      ~r/_abck=/,
      ~r/ak_bmsc=/,
      ~r/bm_sz=/
    ]},

    # PerimeterX / HUMAN
    {:perimeterx, [
      ~r/px-captcha/i,
      ~r/_pxhd/,
      ~r/captcha\.px-cdn\.net/i
    ]},

    # hCaptcha / reCAPTCHA landing
    {:captcha_landing, [
      ~r/hcaptcha\.com\/1\/api\.js/i,
      ~r/www\.google\.com\/recaptcha\/api\.js.*size=invisible/i
    ]},

    # ── GDPR/CMP consent walls ─────────────────────────────────────────────

    # OneTrust — very common (BBC, Reuters, many EU news)
    {:onetrust, [
      ~r/onetrust[-_]consent[-_]sdk/i,
      ~r/cdn\.cookielaw\.org/i,
      ~r/OptanonConsent/,
      ~r/otSDKStub\.js/,
      # Attribute form seen on Reuters etc.
      ~r/data-onetrust-script-id\s*=/i,
      ~r/ONETRUST_SCRIPT_ID/
    ]},

    # Sourcepoint
    {:sourcepoint, [
      ~r/_sp_v1_/,
      ~r/sourcepoint\.com/i,
      ~r/cmp\.sp-prod\.net/i,
      ~r/cmp-sp\.trustarc\.com/i,
      ~r/_sp_queue_/
    ]},

    # Quantcast Choice
    {:quantcast, [
      ~r/quantcast\.mgr\.consensu\.org/i,
      ~r/quantcast\/choice/i,
      ~r/QCCMP/,
      ~r/__qc__/
    ]},

    # Cookiebot
    {:cookiebot, [
      ~r/consent\.cookiebot\.com/i,
      ~r/data-cbid=/i,
      ~r/CookieConsentDialog/
    ]},

    # Didomi
    {:didomi, [
      ~r/didomi\.io/i,
      ~r/didomi-notice/i,
      ~r/window\.didomiConfig/i
    ]},

    # Usercentrics
    {:usercentrics, [
      ~r/usercentrics\./i,
      ~r/UC_UI/,
      ~r/app\.usercentrics\.eu/i
    ]},

    # TrustArc (formerly TRUSTe)
    {:trustarc, [
      ~r/consent\.trustarc\.com/i,
      ~r/trustarc[-_]notice/i
    ]},

    # Google Funding Choices / Google CMP
    {:google_cmp, [
      ~r/fundingchoicesmessages\.google\.com/i,
      ~r/googlefc[-_]cnr/i
    ]},

    # InMobi / PubMatic / LiveRamp CMPs
    {:inmobi, [~r/cmp\.inmobi\.com/i, ~r/choice\.consensu\.org/i]},

    # Raw TCF v2 API (generic — catches many custom CMPs implementing IAB TCF).
    # Kept last because it's broad: only matches if body has NO article content
    # but DOES have __tcfapi, a strong signal of a consent-only landing.
    {:tcf_v2, [
      ~r/window\.__tcfapi\s*=\s*function/,
      ~r/__tcfapiLocator/
    ]},

    # Generic cookie-banner classes/IDs that often wrap the whole page
    {:generic_banner, [
      ~r/class="[^"]*cookie-consent-overlay[^"]*"/i,
      ~r/id="gdpr-consent"/i,
      ~r/class="[^"]*cookie-wall[^"]*"/i
    ]}
  ]

  @doc """
  Return `{:cmp, vendor}` if a CMP fingerprint is detected in `body`,
  otherwise `:clean`. Accepts any binary; non-binary input returns `:clean`.
  """
  @spec detect(binary() | any()) :: {:cmp, atom()} | :clean
  def detect(body) when is_binary(body) do
    Enum.find_value(@signatures, :clean, fn {vendor, patterns} ->
      if Enum.any?(patterns, fn pat -> Regex.match?(pat, body) end) do
        {:cmp, vendor}
      else
        nil
      end
    end)
  end

  def detect(_), do: :clean

  @doc "Vendor atoms this detector can report. Useful for exhaustive tests."
  def known_vendors,
    do: [
      # bot challenges
      :datadome, :cloudflare_challenge, :akamai_bot, :perimeterx, :captcha_landing,
      # CMPs
      :onetrust, :sourcepoint, :quantcast, :cookiebot, :didomi,
      :usercentrics, :trustarc, :google_cmp, :inmobi, :tcf_v2, :generic_banner
    ]

  @doc "Whether a vendor is a bot-challenge (vs a GDPR/CMP consent wall)."
  @spec bot_challenge?(atom()) :: boolean()
  def bot_challenge?(vendor) when vendor in [:datadome, :cloudflare_challenge,
                                             :akamai_bot, :perimeterx, :captcha_landing],
    do: true
  def bot_challenge?(_), do: false
end
