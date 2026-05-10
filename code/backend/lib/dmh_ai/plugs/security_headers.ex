# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Plugs.SecurityHeaders do
  @moduledoc """
  Browser security headers.

    * **CSP** — primary XSS defense. `script-src` is locked to `'self'`
      + the KaTeX CDN; the FE has been refactored to remove ALL inline
      `<script>` blocks and `onclick="…"` attributes so we can do this
      safely. `style-src` keeps `'unsafe-inline'` because the FE's
      `style="…"` attributes are scattered across the markup; a CSS-
      injection attack has a much smaller blast radius than script
      injection (UI redress, not arbitrary code execution).
    * **HSTS** — emitted only on HTTPS responses. On plain HTTP it's
      explicitly forbidden by the spec (and harmful: the browser
      remembers max-age and refuses HTTP for that period afterwards
      even if HTTPS is broken).
    * **Permissions-Policy** — disables sensitive browser APIs the
      chat UI doesn't use. Reduces attack surface if XSS slips
      through despite CSP.
    * **`x-frame-options`** — kept for older browsers that don't
      honor CSP `frame-ancestors`. Modern browsers ignore it when
      both are present and use the CSP value.
    * **`x-content-type-options`** — sniffing defense.
    * **`referrer-policy`** — leak-prevention.

  Dropped: `x-xss-protection`. Modern browsers ignore it; older
  Safari versions had bugs that made it exploitable. Current OWASP
  guidance is to OMIT.
  """
  import Plug.Conn

  @csp [
    "default-src 'self'",
    "script-src 'self' https://cdn.jsdelivr.net",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdn.jsdelivr.net",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data: blob:",
    "media-src 'self' blob:",
    "connect-src 'self'",
    "worker-src 'self' blob:",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "base-uri 'self'",
    "object-src 'none'"
  ]
  |> Enum.join("; ")

  @permissions_policy [
    "geolocation=()",
    "camera=()",
    "microphone=()",
    "payment=()",
    "usb=()",
    "magnetometer=()",
    "gyroscope=()",
    "accelerometer=()"
  ]
  |> Enum.join(", ")

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("permissions-policy", @permissions_policy)
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> maybe_put_hsts()
  end

  defp maybe_put_hsts(%Plug.Conn{scheme: :https} = conn) do
    put_resp_header(conn, "strict-transport-security", "max-age=31536000; includeSubDomains")
  end

  defp maybe_put_hsts(conn), do: conn
end
