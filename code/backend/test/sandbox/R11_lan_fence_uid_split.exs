# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# Sandbox runtime tier — R11.
#
# Pin the LAN fence contract the system prompt + run_script tool
# description rely on. `start.sh` installs an iptables OUTPUT chain
# that REJECTs traffic to RFC1918 / loopback / link-local for every
# uid EXCEPT the master service identity (uid 10000):
#
#   ACCEPT  --uid-owner 10000
#   REJECT  -d 127.0.0.0/8 / 10.0.0.0/8 / 172.16.0.0/12 / 192.168.0.0/16 / 169.254.0.0/16
#
# Public internet is NOT in the REJECT set — so non-admin scripts
# CAN reach external APIs / PyPI / Alpine mirrors. The prompts frame
# preinstalled libs as a turn-economy hint, not a capability fence.
#
# The harness probes both sides of the boundary against a listener
# we run ON the sandbox's loopback (`127.0.0.1:19999`) so the
# assertion is fully self-contained — no external internet
# dependency, no flake risk on offline CI.

Code.require_file("sandbox_case.exs", __DIR__)

defmodule DmhAi.Sandbox.R11LanFenceUidSplit do
  use DmhAi.Test.SandboxCase

  alias DmhAi.Permissions.SandboxUser
  alias DmhAi.Repo
  import Ecto.Adapters.SQL, only: [query!: 3]

  @listener_port "19999"
  @docker_timeout_ms 5_000

  setup do
    sandbox = Application.fetch_env!(:dmh_ai, :sandbox_container_name)
    start_listener(sandbox)
    on_exit(fn -> stop_listener(sandbox) end)
    {:ok, %{sandbox_name: sandbox}}
  end

  test "admin (uid 10000) reaches the sandbox loopback listener; non-admin (uid ≥10001) is REJECTed",
       %{sandbox_name: sandbox} do
    rand    = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    user_id = "u_lan_#{rand}"
    email   = "lan_#{rand}@dmhai.test"
    now     = System.system_time(:millisecond)

    query!(Repo,
      "INSERT INTO users (id, email, password_hash, role, org_id, org_role, created_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [user_id, email, "FAKE-HASH-FOR-TEST-ONLY", "user",
       DmhAi.Constants.default_org_id(), "member", now])

    {:ok, non_admin_uid} = SandboxUser.ensure_provisioned(%{id: user_id, email: email})
    assert non_admin_uid >= 10001

    # Admin path — uid 10000 is whitelisted in OUTPUT, packet reaches
    # the listener, listener responds 200.
    {admin_code, admin_curl_exit} = curl_in_sandbox(sandbox, 10_000)

    assert admin_code == "200",
           """
           Admin (uid 10000) failed to reach the sandbox-local listener
           at http://127.0.0.1:#{@listener_port}/ — expected HTTP 200,
           got code=#{inspect(admin_code)} exit=#{admin_curl_exit}.
           Either the listener never bound or the admin ACCEPT rule
           is missing / out of order.
           """

    # Non-admin path — uid #{non_admin_uid} is NOT whitelisted, the
    # 127.0.0.0/8 REJECT rule fires, curl sees ICMP-unreachable
    # (treated as "Connection refused"), exits non-zero, http_code is "000".
    {nonadmin_code, nonadmin_curl_exit} = curl_in_sandbox(sandbox, non_admin_uid)

    refute nonadmin_code == "200",
           """
           LAN fence breach: non-admin uid #{non_admin_uid} reached
           http://127.0.0.1:#{@listener_port}/ (HTTP #{nonadmin_code}).
           The iptables REJECT for 127.0.0.0/8 must apply to every
           uid other than 10000. The system prompt + tool description
           both rely on this contract — a regression here makes them
           teach a falsehood to the model.
           """

    assert nonadmin_curl_exit != 0,
           "curl from non-admin uid must exit non-zero when LAN destination is REJECTed; got exit=0"
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp start_listener(sandbox) do
    # Listener runs as admin uid 10000 because the iptables OUTPUT
    # chain whitelists ONLY uid 10000 — root (uid 0) is fenced like
    # any non-admin. A root-owned listener could BIND fine but its
    # response packets to 127.0.0.1 would hit the LAN REJECT rule,
    # so the admin client would see a hung connection instead of
    # 200. Running the listener as 10000 lets admin↔listener traffic
    # flow both directions; non-admin → listener still hits REJECT
    # at the client's OUTPUT, which is what R11 wants to verify.
    SandboxUser.docker(
      ["exec", "-d", "-u", "10000", sandbox, "sh", "-c",
       "python3 -m http.server #{@listener_port} --bind 127.0.0.1 >/dev/null 2>&1"],
      @docker_timeout_ms
    )

    wait_for_listener(sandbox, 20)
  end

  defp stop_listener(sandbox) do
    SandboxUser.docker(
      ["exec", sandbox, "sh", "-c",
       "pkill -f 'http.server #{@listener_port}' >/dev/null 2>&1; true"],
      @docker_timeout_ms
    )
  end

  defp wait_for_listener(_sandbox, 0), do: flunk("listener never bound on :#{@listener_port}")

  defp wait_for_listener(sandbox, attempts_left) do
    # Probe as admin (uid 10000) — root traffic to 127.0.0.1 is
    # fenced, so a root probe would falsely report "never bound".
    {code, _exit} = curl_in_sandbox(sandbox, 10_000)

    if code == "200" do
      :ok
    else
      Process.sleep(100)
      wait_for_listener(sandbox, attempts_left - 1)
    end
  end

  # Returns `{http_code_string, curl_exit_int}`. `as_uid` is the
  # docker-exec uid; the iptables fence treats every uid other than
  # 10000 the same way.
  defp curl_in_sandbox(sandbox, as_uid) do
    exec_args = ["exec", "-u", Integer.to_string(as_uid), sandbox]

    args =
      exec_args ++
        ["sh", "-c",
         "curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:#{@listener_port}/; echo \",$?\""]

    case SandboxUser.docker(args, @docker_timeout_ms) do
      {:ok, output, _docker_exit} ->
        # Output shape: "<code>,<curl_exit>\n"
        [code, exit_str] =
          output
          |> String.trim()
          |> String.split(",", parts: 2)

        {code, String.to_integer(exit_str)}

      other ->
        flunk("docker exec curl failed: #{inspect(other)}")
    end
  end
end
