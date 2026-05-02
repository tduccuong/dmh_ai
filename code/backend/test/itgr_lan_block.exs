# Tests for the LAN-destination Police gate that fires on master-side
# tool calls (web_fetch / connect_mcp). See specs/permissions.md
# §Police hook + lib/dmh_ai/permissions/lan_block.ex.
#
# DNS-dependent paths are exercised via literal IPs (which skip DNS
# entirely in `LanBlock.resolved_ips/1`). Real DNS lookups are not
# tested here — they're side-effectful and would tag this whole file
# as :network. The literal-IP path covers the membership check, the
# admin bypass, the per-tool gating, and the URL-arg extraction.

defmodule Itgr.LanBlock do
  use ExUnit.Case, async: true

  alias DmhAi.Permissions.LanBlock
  alias DmhAi.Agent.Police

  defp call(name, args) do
    %{
      "id"       => "call_#{:rand.uniform(1_000_000)}",
      "type"     => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  defp user_ctx(role \\ "user") do
    %{user_role: role, session_root: "/data/user_assets/u/S"}
  end

  # ─── Direct LanBlock.check/2 ───────────────────────────────────────────

  describe "LanBlock.check/2 — admin bypass" do
    test "admin can target any IP" do
      c = call("web_fetch", %{"url" => "http://192.168.1.1/path"})
      assert nil == LanBlock.check([c], user_ctx("admin"))
    end

    test "admin loopback also OK" do
      c = call("web_fetch", %{"url" => "http://127.0.0.1:11434/api/tags"})
      assert nil == LanBlock.check([c], user_ctx("admin"))
    end
  end

  describe "LanBlock.check/2 — literal IP rejection (non-admin)" do
    for {ip, label} <- [
          {"192.168.178.49", "RFC1918 192.168/16"},
          {"10.0.0.5",        "RFC1918 10/8"},
          {"172.16.0.1",      "RFC1918 172.16/12 lower bound"},
          {"172.31.255.254",  "RFC1918 172.16/12 upper bound"},
          {"127.0.0.1",       "loopback"},
          {"169.254.1.1",     "link-local"}
        ] do
      test "rejects #{label}" do
        c = call("web_fetch", %{"url" => "http://#{unquote(ip)}/x"})
        assert {tool, host, detail} = LanBlock.check([c], user_ctx())
        assert tool == "web_fetch"
        assert host == unquote(ip)
        assert is_binary(detail) and String.contains?(detail, "private")
      end
    end

    test "rejects connect_mcp with LAN url arg" do
      c = call("connect_mcp", %{"url" => "http://192.168.0.1:8080/mcp"})
      assert {tool, _, _} = LanBlock.check([c], user_ctx())
      assert tool == "connect_mcp"
    end
  end

  describe "LanBlock.check/2 — IPv6 literals (non-admin)" do
    test "rejects IPv6 loopback" do
      c = call("web_fetch", %{"url" => "http://[::1]:8080/x"})
      assert {"web_fetch", _, _} = LanBlock.check([c], user_ctx())
    end

    test "rejects IPv6 unique-local (fc00::/7)" do
      c = call("web_fetch", %{"url" => "http://[fc00::1]/x"})
      assert {"web_fetch", _, _} = LanBlock.check([c], user_ctx())
    end

    test "rejects IPv6 link-local (fe80::/10)" do
      c = call("web_fetch", %{"url" => "http://[fe80::1234]/x"})
      assert {"web_fetch", _, _} = LanBlock.check([c], user_ctx())
    end
  end

  describe "LanBlock.check/2 — public IPs pass" do
    for ip <- ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "11.0.0.1"] do
      test "public IPv4 #{ip} not blocked" do
        c = call("web_fetch", %{"url" => "http://#{unquote(ip)}/x"})
        assert nil == LanBlock.check([c], user_ctx())
      end
    end
  end

  describe "LanBlock.check/2 — non-gated tools" do
    test "run_script never gated by LanBlock (sandbox iptables handles it)" do
      c = call("run_script", %{"script" => "curl http://192.168.1.1"})
      assert nil == LanBlock.check([c], user_ctx())
    end

    test "fetch_task / read_file etc. not gated" do
      a = call("fetch_task", %{"task_num" => 1})
      b = call("read_file",  %{"path" => "data/x"})
      assert nil == LanBlock.check([a, b], user_ctx())
    end
  end

  describe "LanBlock.check/2 — malformed input" do
    test "missing url arg → no rejection (let tool surface its own error)" do
      c = call("web_fetch", %{})
      assert nil == LanBlock.check([c], user_ctx())
    end

    test "non-URL string → no rejection" do
      c = call("web_fetch", %{"url" => "not a url at all"})
      assert nil == LanBlock.check([c], user_ctx())
    end

    test "args as JSON string also decoded" do
      raw_call = %{
        "id"       => "x",
        "type"     => "function",
        "function" => %{
          "name"      => "web_fetch",
          "arguments" => ~s|{"url":"http://10.0.0.1/x"}|
        }
      }
      assert {"web_fetch", _, _} = LanBlock.check([raw_call], user_ctx())
    end
  end

  describe "LanBlock.check/2 — first-hit semantics" do
    test "scans the batch and returns the first match" do
      ok = call("web_fetch", %{"url" => "http://1.1.1.1/x"})
      bad = call("web_fetch", %{"url" => "http://192.168.1.1/y"})
      assert {"web_fetch", "192.168.1.1", _} = LanBlock.check([ok, bad], user_ctx())
    end
  end

  # ─── End-to-end through Police.check_tool_calls ─────────────────────────

  describe "Police.check_tool_calls integration" do
    test "non-admin LAN web_fetch → :rejected with lan_blocked: prefix" do
      c = call("web_fetch", %{"url" => "http://192.168.178.49:11434/api/tags"})
      assert {:rejected, reason} = Police.check_tool_calls([c], [], user_ctx())
      assert String.starts_with?(reason, "lan_blocked: web_fetch:")
    end

    test "admin LAN web_fetch → :ok" do
      c = call("web_fetch", %{"url" => "http://192.168.178.49:11434/api/tags"})
      assert :ok = Police.check_tool_calls([c], [], user_ctx("admin"))
    end

    test "rejection_msg/1 produces the human-readable lan_blocked text" do
      msg = Police.rejection_msg("lan_blocked: web_fetch: host 10.0.0.1 resolves to a private/loopback/link-local address")
      assert String.starts_with?(msg, "REJECTED (lan_blocked):")
      assert String.contains?(msg, "Local-network destinations")
      assert String.contains?(msg, "public URL")
    end

    test "path_violation takes precedence over lan_blocked when both apply" do
      # Read with absolute path outside session_root → path_violation.
      # (web_fetch isn't in the same call, but if a batch had both
      # types of issues, the path check fires first.)
      ctx = user_ctx() |> Map.put(:workspace_dir, "/data/user_workspaces/u/S")
                     |> Map.put(:data_dir,      "/data/user_assets/u/S/data")
      bad_path = call("read_file", %{"path" => "/etc/passwd"})
      bad_lan  = call("web_fetch", %{"url" => "http://10.0.0.1/x"})
      assert {:rejected, reason} = Police.check_tool_calls([bad_path, bad_lan], [], ctx)
      assert String.starts_with?(reason, "path_violation:")
    end
  end
end
