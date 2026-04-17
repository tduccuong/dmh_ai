# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule Dmhai.Web.ConsentSeeder do
  @moduledoc """
  Pre-seed lightweight "consent dismissed" cookies that many vanilla
  cookie banners respect. Does NOT attempt to impersonate TCF IAB
  consent strings — those are vendor-specific, expire, and faking them
  is fragile / ethically dubious. This just quiets the simple banners
  (CookieConsent.js, basic "OK got it" popups) so we don't get the
  chrome overlay in the response body.

  For heavy CMPs (OneTrust, Sourcepoint, Quantcast, etc.) this won't
  help — detection-then-fallback is the route for those.
  """

  @doc """
  Return a single `Cookie:` header value — a semicolon-separated list of
  benign "dismissed" hints. Safe to send on every request.
  """
  @spec cookie_header() :: String.t()
  def cookie_header do
    Enum.join(cookies(), "; ")
  end

  @doc "Raw list of `name=value` cookie strings."
  @spec cookies() :: [String.t()]
  def cookies do
    [
      # CookieConsent.js (osano / vanilla)
      "cookieconsent_status=dismiss",
      "cookieconsent=dismiss",
      "cookie_consent=true",

      # Generic "accepted" flags used by homemade banners
      "gdpr_consent=yes",
      "gdpr_accepted=1",
      "cookies_accepted=1",
      "cookies_agreed=1",
      "eu_cookie_consent=1",

      # OneTrust — users who land post-accept have this set; some sites
      # check for its *presence*, not validity.
      "OptanonAlertBoxClosed=" <> iso_today(),

      # Meta/OG consent-free variants seen on lightweight sites
      "accept-cookies=1",
      "consent=accepted"
    ]
  end

  @doc "Request headers to include with a fetch: UA + consent cookies."
  @spec request_headers(String.t()) :: [{String.t(), String.t()}]
  def request_headers(user_agent) do
    [
      {"user-agent", user_agent},
      {"cookie", cookie_header()},
      # Hinting DNT + GPC signals legitimate browser use and some sites
      # respect them by not showing a banner.
      {"dnt", "1"},
      {"sec-gpc", "1"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end

  defp iso_today do
    # "YYYY-MM-DDTHH:MM:SS.sssZ" minus the ms (good enough for banners
    # that just parse the date portion).
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
