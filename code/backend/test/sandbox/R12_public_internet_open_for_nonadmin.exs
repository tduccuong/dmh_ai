# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R12.
#
# Positive counterpart to R11. The iptables fence in `start.sh`
# REJECTs LAN / loopback / link-local for non-admin uids, but
# public-internet egress is NOT in the REJECT set — non-admin scripts
# CAN reach external APIs / PyPI / Alpine mirrors. The system prompt
# and `run_script` description rely on this asymmetry to frame the
# preinstalled deliverable libs as a turn-economy hint, not a hard
# capability fence.
#
# Without this test, a future "tighten the fence" change that DROPs
# public egress for non-admin would pass CI but silently break the
# model's outbound-API workflows AND make the prompt teach a
# falsehood. R12 pins the open half of the contract using a stable
# public endpoint (Cloudflare 1.1.1.1) so it doesn't depend on
# resolver state.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R12PublicInternetOpenForNonAdmin do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Tools.RunScript
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  test "non-admin (uid ≥10001) reaches a public internet endpoint" do
    rand    = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    user_id = "u_pub_#{rand}"
    email   = "pub_#{rand}@dmhai.test"
    session = "S_pub_#{rand}"
    now     = System.system_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "FAKE-HASH-FOR-TEST-ONLY", "user",
       DmhAi.Constants.default_org_id(), "member", now])

    ctx = %{
      user_id:    user_id,
      user_email: email,
      user_role:  "user",
      session_id: session
    }

    File.mkdir_p!(Constants.session_workspace_dir(email, session))

    # 1.1.1.1 (Cloudflare DNS-over-HTTPS) is a stable public anycast
    # endpoint that responds to HTTPS GET / with a small page. If
    # the runner host genuinely has no internet, the assertion
    # message tells the operator to check connectivity rather than
    # treat the failure as a fence regression.
    script = """
    curl -s -m 5 -o /dev/null -w "%{http_code}" https://1.1.1.1/ 2>&1
    echo ""
    echo "EXIT=$?"
    """

    assert {:ok, output} = RunScript.execute(%{"script" => script}, ctx)
    out = to_string(output)

    cond do
      String.contains?(out, "Could not resolve") ->
        flunk("""
        Runner host has no internet access (DNS resolution failed).
        R12 verifies the LAN-only fence does NOT block public egress
        for non-admin uids — the test requires the runner to itself
        be online. Output: #{out}
        """)

      # Successful HTTPS response (2xx/3xx). 1.1.1.1's root currently
      # serves 301; accept any 2xx/3xx as "fence let the packet
      # through".
      String.match?(out, ~r/^(2\d\d|3\d\d)\b/m) ->
        :ok

      true ->
        flunk("""
        Non-admin script could not reach https://1.1.1.1/ — the
        iptables OUTPUT chain is REJECTing public traffic for
        uids ≥ 10001, which contradicts both the system prompt's
        `<sandbox_capabilities>` block and the `run_script` tool
        description. Either the fence was tightened without
        updating the prompts, or the runner host is offline.
        Output: #{inspect(out)}
        """)
    end
  end
end
