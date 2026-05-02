# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

defmodule DmhAi.Permissions.LanBlock do
  @moduledoc """
  Police-side gate that rejects non-admin tool calls whose target URL
  resolves to a LAN address (RFC1918, loopback, link-local, IPv6
  unique-local). See specs/permissions.md §Police hook.

  Why this exists: a handful of tools issue HTTP from the **master**
  container, not the sandbox. The iptables fence we install on the
  sandbox container doesn't see master's traffic, so without this
  gate a user could ask the assistant to `web_fetch
  http://192.168.178.49:11434` and reach the host's LAN through the
  master process.

  How it works:
    1. Inspect every tool call in the batch.
    2. For tools listed in `@lan_gated_tools`, pull the URL from the
       known argument name and DNS-resolve the host.
    3. If any resolved IP is in a private range, reject the batch
       with a `[[ISSUE:lan_blocked:<tool>]]` marker.
    4. Admin (`ctx.user_role == "admin"`) is exempt — short-circuited
       before DNS even runs.

  Failure semantics:
    * DNS error (NXDOMAIN, timeout) is **not** a security failure —
      the tool runs and surfaces its own error. Returning a
      lan-blocked rejection on every typo would surprise the user.
    * URL parsing failure → same: don't intervene.
    * Host that is itself a literal IP → checked directly, no DNS.
  """

  # Tools that issue HTTP from the master container, with the name
  # of their "URL" argument. `connect_mcp` has both `url` (direct)
  # and `slug` (catalog lookup) — only the direct case is checkable
  # here; slug-resolved URLs are operator-curated and trusted at
  # this layer.
  @lan_gated_tools %{
    "web_fetch"   => "url",
    "connect_mcp" => "url"
  }

  @doc """
  Check a batch of tool calls. Returns `nil` if every call is OK or
  exempt; returns `{tool_name, host, reason}` describing the first
  hit when one is found, so Police can format a rejection that
  names the offending tool.
  """
  @spec check(list(), map()) :: nil | {String.t(), String.t(), String.t()}
  def check(calls, ctx) when is_list(calls) and is_map(ctx) do
    if admin?(ctx) do
      nil
    else
      Enum.find_value(calls, nil, fn call -> check_call(call) end)
    end
  end

  def check(_, _), do: nil

  defp admin?(ctx), do: Map.get(ctx, :user_role) == "admin"

  defp check_call(call) do
    name = get_in(call, ["function", "name"]) || ""

    case Map.get(@lan_gated_tools, name) do
      nil ->
        nil

      arg_key ->
        args =
          case get_in(call, ["function", "arguments"]) do
            s when is_binary(s) ->
              case Jason.decode(s) do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end

            m when is_map(m) ->
              m

            _ ->
              %{}
          end

        case Map.get(args, arg_key) do
          url when is_binary(url) and url != "" -> check_url(url, name)
          _ -> nil
        end
    end
  end

  defp check_url(url, tool_name) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        case resolved_ips(host) do
          {:ok, ips} ->
            if Enum.any?(ips, &private?/1) do
              {tool_name, host,
               "host #{host} resolves to a private/loopback/link-local address"}
            else
              nil
            end

          :unresolved ->
            nil
        end

      _ ->
        nil
    end
  end

  # Resolve a host to a list of IP strings. Accepts literal IPv4 / IPv6
  # without going through DNS. Errors return `:unresolved` — caller
  # treats that as "let the tool error out on its own".
  defp resolved_ips(host) do
    cond do
      literal_ipv4?(host) -> {:ok, [host]}
      literal_ipv6?(host) -> {:ok, [String.replace(host, ["[", "]"], "")]}
      true -> dns_lookup(host)
    end
  end

  defp dns_lookup(host) do
    case :inet.gethostbyname(String.to_charlist(host)) do
      {:ok, {:hostent, _name, _aliases, _af, _len, addrs}} ->
        ip_strs = Enum.map(addrs, &ip_to_string/1)
        {:ok, ip_strs}

      _ ->
        :unresolved
    end
  rescue
    _ -> :unresolved
  end

  defp ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp ip_to_string({_, _, _, _, _, _, _, _} = v6) do
    v6 |> :inet.ntoa() |> List.to_string()
  end

  defp ip_to_string(other), do: to_string(other)

  defp literal_ipv4?(s),
    do: Regex.match?(~r/^\d{1,3}(\.\d{1,3}){3}$/, s)

  defp literal_ipv6?(s),
    do: String.contains?(s, ":")

  # Private / loopback / link-local IP membership. Mirrors the iptables
  # rules in code/sandbox/start.sh + IPv6 ULA/link-local even though
  # IPv6 is disabled inside the sandbox — master's network stack still
  # has IPv6, so we check it here.
  defp private?(ip) when is_binary(ip) do
    cond do
      String.starts_with?(ip, "127.")    -> true
      String.starts_with?(ip, "10.")     -> true
      String.starts_with?(ip, "192.168.") -> true
      String.starts_with?(ip, "169.254.") -> true
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./, ip) -> true
      ip == "::1" -> true
      String.starts_with?(ip, "fe80:") or String.starts_with?(ip, "FE80:") -> true
      Regex.match?(~r/^[fF][cdCD]/, ip) -> true
      # IPv4-mapped IPv6 (::ffff:192.168.1.1 etc.). Re-extract the
      # IPv4 tail and recurse.
      Regex.run(~r/^::ffff:(\d{1,3}(\.\d{1,3}){3})$/i, ip) ->
        case Regex.run(~r/^::ffff:(\d{1,3}(\.\d{1,3}){3})$/i, ip) do
          [_, v4, _] -> private?(v4)
          _ -> false
        end

      true ->
        false
    end
  end

  defp private?(_), do: false
end
