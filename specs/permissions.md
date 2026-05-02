# Per-user permissions & sandbox isolation

## Goal

Two-layer enforcement that keeps the assistant agent of a non-admin user
contained to (a) its own per-user filesystem subtree and (b) public
internet only. The agent must not be able to touch another user's data
or reach machines on the host's local network — even via SSH, even via
shell-script obfuscation, even if the model is fully adversarial.

The two layers:

1. **OS-level fence in the sandbox container** — Linux user accounts +
   chmod 0700 + read-only bind mounts + iptables/ip6tables rules. The
   model can't read another user's files because the kernel rejects
   the syscall; can't ssh to `192.168.x.x` because the kernel drops
   the packet. No prompt rule, no tool filter, no Police check is
   load-bearing for these properties.

2. **Police permission gate for BE-side tools** — for tools that don't
   run inside the sandbox (`web_fetch`, `connect_mcp`, future
   `browse_authenticated`), Police checks the resolved target against
   the same policy: non-admin → reject RFC1918 destinations.

The grain is **resource-scoped**: a user's `role` controls what
filesystem subtree and network targets they can reach. There is no
per-tool feature matrix (no `{run_script: true, web_fetch: false}`).
Adding a new tool is a code change; gating which users can reach which
*resources* is a role/role-derived check.

## What's in / out

**In scope:**
- New top-level filesystem split: `user_assets/` (RO from sandbox) +
  `user_workspaces/` (RW from sandbox).
- Per-user Linux account inside the sandbox container, scoped by
  `users.unix_uid` (new column).
- `chmod 0700` on each user's `<email>/` subtree under both roots.
- iptables + ip6tables rules in the sandbox container that REJECT
  outbound traffic to RFC1918 / RFC4193 / loopback / link-local;
  IPv6 disabled at the sysctl level.
- `users.role` already exists (`admin` | `user`); this spec defines
  what each implies for sandbox exec and Police enforcement.
- Idempotent on-boot migration sweep that moves
  `user_assets/<email>/<session>/workspace/*` →
  `user_workspaces/<email>/<session>/*`.
- Police hook for non-sandbox tools: reject RFC1918 destinations for
  non-admin users.

**Out of scope:**
- Per-tool capability matrix (deferred until a real use case appears).
- Quotas (CPU, RAM, disk per user).
- Network egress rate limits.
- Allowlisted-domain network policy (granular per-domain ACLs).
- Per-user iptables rules (everyone non-admin gets the same set; admin
  gets the same too — sandbox isn't where admin should reach LAN).
- Per-session sub-bind-mounts (rejected — see "Decisions" §3).

## Filesystem layout

### Host

```
/data/user_assets/                                   ← bind RO  into sandbox
└── <email>/                                         chmod 0700, owned by dmh_ai-master-u
    ├── _keystore/                                   long-lived per-user secrets
    │   ├── ssh/                                     id_rsa, id_ed25519, …
    │   ├── tls/                                     future
    │   ├── gpg/                                     future
    │   └── (any new credential type)
    └── <session_id>/
        └── data/                                    user uploads in this session

/data/user_workspaces/                               ← bind RW  into sandbox
└── <email>/                                         chmod 0700, owned by dmh_ai-u<uid>
    └── <session_id>/                                model scratch in this session
```

`_keystore/` is a sibling of session directories and survives session
deletion. The subdirectory tree is open-ended: `provision_ssh_identity`
writes to `_keystore/ssh/` today; future tools (`provision_tls_*`,
`provision_gpg_*`, …) write to their own subdirs without spec change.
File-on-disk credentials live here; opaque-string credentials (OAuth
tokens, API keys with expiry) continue to use the `user_credentials`
table.

### Sandbox container

Two static bind mounts, set once in `docker-compose.yml`, never touched
at runtime:

```
/assets    ← :ro mount of /data/user_assets
/work      ← rw mount of /data/user_workspaces
```

A non-admin user's process inside the sandbox sees only paths under
`/assets/<their-email>/` (read) and `/work/<their-email>/` (write).
Other users' subtrees are unreadable: `chmod 0700` on `<email>/` plus
the per-user OS account makes lateral access EACCES.

Working directory for `run_script`: `/work/<email>/<session>/`. Paths
the model writes resolve via `DmhAi.Util.Path.resolve/2`, which already
distinguishes `data/` (under `/assets/<email>/<session>/data/`) from
`workspace/` (under `/work/<email>/<session>/`); the resolver's
`within?` check is generalised to allow either root.

## OS isolation

### Per-user Linux accounts in the sandbox

- `users.unix_uid INTEGER UNIQUE` — new column. Allocated sequentially
  from `10001` on first sandbox use for that user. Stored in the row;
  reused forever. The DB is the source of truth — sandbox container
  state (passwd entries) is reconstructed lazily from the DB.

- Username convention: `dmh_ai-u<uid>` (e.g. `dmh_ai-u10001`). Matches
  the `dmh_ai-*` naming used by container/service names.

- Master service identity inside the sandbox: `dmh_ai-master-u`
  (UID 10000, fixed). Owns `user_assets/<email>/` files (writes
  uploads, writes provisioned credentials).

### Master container changes

- Master runs as **root** (drops the existing `su-exec appuser`
  step in `code/start.sh`). Required so master can `chown` per-user
  directories on the host volumes during provisioning. The existing
  `appuser` (UID 1000) is retained in the image and used only as the
  ownership target for files master writes on behalf of itself
  (logs, DB, search engine settings); `chown` to per-user UIDs
  during provisioning needs root.

- This is not a meaningful security regression: master already
  bind-mounts `/var/run/docker.sock`, which is root-equivalent in
  practice (master can spawn arbitrarily-privileged containers,
  mount the host filesystem, etc.). The `su-exec appuser` was
  cosmetic given that surface.

### Sandbox container changes

- Container runs as **root** (replaces the current `sandbox` UID 1000
  user). Required so the sandbox can `useradd` per user at runtime
  and write the iptables rules at boot.

- Capabilities granted: `CAP_NET_ADMIN` (for iptables) and the
  default-allowed user-management caps (`CAP_SETUID`, `CAP_SETGID`,
  `CAP_DAC_OVERRIDE` for `useradd` to write `/etc/passwd`).

- Sandbox image's `start.sh` sets up iptables/ip6tables rules at
  startup (see §Network isolation), then `tail -f /dev/null` to keep
  the container alive. Master execs into it via existing
  `docker.sock` mount.

### Per-user account provisioning (master-driven)

Before the first `docker exec` for a given user:

1. **Allocate UID** (DB) — if `users.unix_uid IS NULL`, write the next
   integer ≥ 10001 (transactional select-max-then-insert, or sequence
   if SQLite supports it).
2. **Create OS user** (sandbox) — `docker exec sandbox useradd -u
   <uid> -M -s /bin/bash dmh_ai-u<uid>`. Idempotent: if the entry
   already exists in `/etc/passwd`, no-op.
3. **Initialise host directories** — master creates
   `/data/user_assets/<email>/` (chmod 0700, chown
   `dmh_ai-master-u`) and `/data/user_workspaces/<email>/` (chmod
   0700, chown `dmh_ai-u<uid>:dmh_ai-u<uid>`).

Steps 1+3 run in master Elixir code; step 2 is a `docker exec` call.
All three are idempotent and re-runnable — useful for crash recovery
(sandbox container restart loses `/etc/passwd` entries; master's
provisioning logic re-creates them lazily on next exec).

### Sandbox exec path (per command)

Master invokes:

```
docker exec \
  -u dmh_ai-u<uid> \
  -w /work/<email>/<session-id>/ \
  dmh_ai-assistant-sandbox \
  <cmd>
```

The `-u` flag drops privileges to the per-user OS account before
running the command. The kernel enforces all subsequent filesystem
and network checks against that UID. Admin users are the same code
path with `-u dmh_ai-master-u` (or root, see §Admin) and a permissive
`-w`.

## Network isolation

`docker-compose.yml`:

```yaml
sandbox:
  network_mode: bridge          # was: host
  cap_add:
    - NET_ADMIN
```

`start.sh` for the sandbox container sets at boot. The admin pass-
through MUST come before the REJECT rules — iptables is first-match,
so an earlier ACCEPT short-circuits the later drops:

```bash
# Disable IPv6 entirely — far simpler than maintaining a parallel
# ip6tables ruleset that has to keep up with IPv4-mapped addresses
# (::ffff:0:0/96), unique-local (fc00::/7), link-local (fe80::/10).
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

# Admin pass-through: any packet originated by the dmh_ai-master-u
# UID (admin's exec identity, fixed UID 10000) is accepted before the
# REJECT rules below see it. Per-user accounts (UID 10001+) fall
# through to the REJECT rules and get blocked.
iptables -A OUTPUT -m owner --uid-owner 10000 -j ACCEPT

# Drop outbound to anything that could be a host LAN address.
iptables -A OUTPUT -d 127.0.0.0/8     -j REJECT
iptables -A OUTPUT -d 10.0.0.0/8      -j REJECT
iptables -A OUTPUT -d 172.16.0.0/12   -j REJECT
iptables -A OUTPUT -d 192.168.0.0/16  -j REJECT
iptables -A OUTPUT -d 169.254.0.0/16  -j REJECT
```

Result: non-admin scripts (UID ≥ 10001) reach any public IPv4
address; anything routing to RFC1918 / loopback / link-local gets
EACCES from the kernel before the syscall completes — SSH to a LAN
box, curl to the host, port scans against `192.168.x.x` are all dead
at the kernel layer. **Admin scripts (UID 10000 = `dmh_ai-master-u`)
are exempt** — they pass through to anywhere, including the LAN, by
the owner-match ACCEPT rule above.

The exemption is keyed on Linux UID, not on any per-user matrix or
runtime check. The kernel decides; the rule is one line; it's
auditable in three seconds.

## Admin role

Admin is god — the role exists to do anything a user can plus the
ops-style work the platform itself sometimes needs. Three specific
relaxations versus a non-admin user:

- **Filesystem:** `docker exec -u dmh_ai-master-u -w /work` (no
  per-user prefix). Admin can read/write anywhere under `/work` and
  read everywhere under `/assets`. Useful for ops scripts that need
  to inspect or move files across users.

- **Sandbox network:** admin's exec identity is `dmh_ai-master-u`
  (UID 10000), which the sandbox iptables `--uid-owner 10000 -j
  ACCEPT` rule passes through before any REJECT rule fires. Admin's
  scripts can therefore reach LAN destinations — `ssh
  192.168.178.49`, `curl http://10.0.0.1`, etc. — directly from the
  sandbox.

- **Police:** for non-sandbox tools (`web_fetch`, `connect_mcp`,
  future `browse_authenticated`) admin bypasses the RFC1918-rejection
  rule.

The admin role is set by `users.role = 'admin'`. Existing rows with
`role = 'admin'` migrate automatically; this spec adds no new role
fields.

## Police hook for non-sandbox tools

Tools that issue HTTP from the master container (not the sandbox)
bypass the kernel-level fence. Police's per-call check covers them:

```
before tool call:
  if user.role != "admin"
    if tool ∈ {web_fetch, connect_mcp, browse_authenticated}
      resolved_ip = dns_lookup(tool_args.url)
      if resolved_ip ∈ RFC1918 ∪ {loopback, link-local}
        reject with [[ISSUE:lan_blocked:<tool>]]
```

The check happens after DNS resolution, not on the URL string —
otherwise a host like `internal.local` resolving to `192.168.1.5`
would slip past a textual block. This is the same posture as the
sandbox iptables rules; the two layers enforce the same policy
through different mechanisms.

## Migration

`DmhAi.Permissions.Migration.run/0` runs idempotently at the same boot
stage as `DmhAi.DB.Init.run/0` (immediately after — see
`application.ex` post-supervisor block). It:

1. **Adds `unix_uid` column** to `users` (idempotent ALTER TABLE).
2. **Sweeps existing per-session workspace dirs:**
   for each `user_assets/<email>/<session-id>/workspace/`:
     - `mkdir -p user_workspaces/<email>/<session-id>/`
     - `mv` contents
     - `rmdir` the empty source
3. **Re-applies host permissions** for existing `<email>/`
   directories (chmod 0700, chown to allocated UID once available).
4. Logs `[info] Permissions: migrated N session workspaces`.

No data loss. Re-running on a fully-migrated install is a no-op. New
installs hit nothing to migrate and skip silently.

## Files involved

```
NEW
  specs/permissions.md                                          (this doc)
  code/backend/lib/dmh_ai/permissions/migration.ex              (one-shot sweep)
  code/backend/lib/dmh_ai/permissions/sandbox_user.ex           (alloc UID + useradd)

MODIFIED
  code/backend/lib/dmh_ai/constants.ex                          (add @workspaces_dir; redirect session_workspace_dir/2)
  code/backend/lib/dmh_ai/util/path.ex                          (within? accepts data_dir OR workspace_dir)
  code/backend/lib/dmh_ai/db/init.ex                            (users.unix_uid migration)
  code/backend/lib/dmh_ai/application.ex                        (call Permissions.Migration.run/0)
  code/backend/lib/dmh_ai/agent/police.ex                       (RFC1918 block for web_fetch/connect_mcp)
  code/backend/lib/dmh_ai/tools/run_script.ex                   (use docker exec -u dmh_ai-u<uid>)
  code/backend/lib/dmh_ai/tools/extract_content.ex              (output paths under workspace_dir)
  code/sandbox/Dockerfile                                       (root user; iptables; sysctl IPv6 off)
  code/sandbox/start.sh                                         (NEW — current sandbox has no start script; this hosts iptables/sysctl)
  scripts/build.sh                                              (compose: bridge net + cap_add NET_ADMIN; new mounts)
  specs/architecture.md                                         (link to this doc)
```

## Decisions (recorded for history)

1. **One shared sandbox container, not per-user.** Per-user
   containers were considered (~30 MB idle each, real isolation) but
   rejected — too much memory + lifecycle cost for a self-hosted
   single-machine deployment. OS-level isolation inside one container
   is sufficient.

2. **Permission grain is resource-scoped, not feature-scoped.** No
   `{run_script: true, web_fetch: false, …}` per-user matrix. The
   role (`admin` | `user`) selects the exec path and the Police
   posture; everything else flows from there. Adding a granular cap
   map is deferred — we ship it when there's a concrete need.

3. **No per-session sub-bind-mounts.** Considered as a way to enforce
   RO-on-uploads at the mount layer (instead of file permissions),
   but rejected: dynamic mount lifecycle, `CAP_SYS_ADMIN`
   requirement, mount-table bloat. Two static top-level mounts
   (`user_assets:/assets:ro`, `user_workspaces:/work`) gives the
   same kernel-level RO with none of the cost.

4. **IPv6 disabled, not parallel-blocked.** Maintaining a parallel
   `ip6tables` ruleset across IPv4-mapped, unique-local, link-local
   ranges is more work than turning IPv6 off in the sandbox
   container. Public IPv4 covers the model's reachability needs.

5. **Admin gets a LAN pass-through, not the same fence as everyone
   else.** Earlier draft had iptables apply uniformly to all UIDs in
   the sandbox; revised to add an `--uid-owner 10000 -j ACCEPT` rule
   ahead of the REJECTs so admin's exec identity (`dmh_ai-master-u`)
   can reach the LAN through the assistant. Costs ~1 line of
   iptables; recovers a real workflow (admin asks the agent to
   ssh/curl to a homelab box). Non-admin UIDs still hit the REJECTs
   verbatim — the fence is intact for the security target.

6. **Email kept as the per-user filesystem namespace.** Could have
   switched to `users.id` hex; rejected because the existing layout
   uses email and the comment in `Constants` is explicit about
   readability. Not load-bearing for security — the chmod 0700
   fence works regardless of segment shape.

7. **Migration runs automatically on first boot of the new version.**
   Operator-run mix tasks were considered but rejected — auto
   migration keeps the upgrade path identical to every other
   `DB.Init` change in the project's history.
