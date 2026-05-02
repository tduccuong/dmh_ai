#!/bin/sh
# Assistant sandbox container entrypoint. See specs/permissions.md.
#
# Sets up the network fence on container start:
#   1. Disable IPv6 entirely (simpler than maintaining a parallel
#      ip6tables ruleset).
#   2. ACCEPT outbound from UID 10000 (dmh_ai-master-u, admin) BEFORE
#      the REJECT rules — first match wins, so admin's exec'd
#      commands reach the LAN. Per-user UIDs (10001+) fall through.
#   3. REJECT outbound to RFC1918 / loopback / link-local for the
#      remaining UIDs.
#
# Then `tail -f /dev/null` to keep the container alive. Per-user OS
# accounts are added lazily by master via `docker exec sandbox useradd
# -u <uid> dmh_ai-u<uid>` — see DmhAi.Permissions.SandboxUser.

set -e

# --- IPv6 off ----------------------------------------------------------------
# Best effort: containers may have these as sysctls already locked at
# the Docker daemon level. If a sysctl is read-only the line errors;
# we don't want to block container start for that — fall through.
sysctl -w net.ipv6.conf.all.disable_ipv6=1     2>/dev/null || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1      2>/dev/null || true

# --- iptables fence ----------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
    # Admin pass-through. UID 10000 = dmh_ai-master-u. First-match-
    # wins ordering: this ACCEPT must come before the REJECTs below.
    iptables -A OUTPUT -m owner --uid-owner 10000 -j ACCEPT 2>/dev/null || \
        echo "[sandbox start.sh] WARN: failed to add admin ACCEPT rule (CAP_NET_ADMIN missing?)"

    # LAN-wide REJECTs — apply to every other UID (10001+).
    iptables -A OUTPUT -d 127.0.0.0/8     -j REJECT 2>/dev/null || true
    iptables -A OUTPUT -d 10.0.0.0/8      -j REJECT 2>/dev/null || true
    iptables -A OUTPUT -d 172.16.0.0/12   -j REJECT 2>/dev/null || true
    iptables -A OUTPUT -d 192.168.0.0/16  -j REJECT 2>/dev/null || true
    iptables -A OUTPUT -d 169.254.0.0/16  -j REJECT 2>/dev/null || true
else
    echo "[sandbox start.sh] WARN: iptables not present — LAN fence not applied"
fi

# --- Stay alive --------------------------------------------------------------
exec tail -f /dev/null
