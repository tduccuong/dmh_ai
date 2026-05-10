# Browser tool v0 (#215 / #219) requires Chromium + Playwright. The
# upstream Playwright team ships a working browser-bundle image for
# Linux, so we base on it and add our shell-script tooling on top
# rather than fight Chromium-on-musl issues with Alpine.
#
# Base image: Microsoft's official Playwright-for-Python image,
# Ubuntu 22.04 LTS (jammy) underneath. Ships Chromium, Firefox, and
# WebKit pre-installed; we only use Chromium. Pinning a fixed minor
# version because Playwright's API/binary contract changes between
# versions and we can't redeploy the daemon without a rebuild.
FROM mcr.microsoft.com/playwright/python:v1.49.0-jammy

# Disable interactive apt prompts (tzdata, locales).
ENV DEBIAN_FRONTEND=noninteractive

# Run-script tooling. Most of this comes pre-installed in the
# Playwright base image; the explicit apt-get is a guard against
# upstream image trimming. Notable additions over the old Alpine
# image: passwd (was `shadow` on Alpine — provides useradd/userdel),
# iptables (LAN-fence in start.sh), openssh-client / sshpass /
# expect (model often SSHs into remote boxes from inside the sandbox).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl wget jq git \
      build-essential \
      ca-certificates tzdata \
      openssh-client sshpass expect \
      passwd iptables \
      python3-pip \
      socat netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Trust-on-first-use SSH host-key handling. Default is interactive
# yes/no on first connect, which fails in sandbox scripts where stdin
# isn't a TTY (sshpass exits with code 6, raw ssh blocks). `accept-new`
# auto-accepts a host's key the FIRST time it's seen and remembers it;
# subsequent connections verify against the remembered key and refuse
# with a loud error if it changed (MITM caught). LogLevel ERROR keeps
# the "Permanently added ... to known_hosts" notice out of the script
# output the model parses.
RUN mkdir -p /etc/ssh && printf 'StrictHostKeyChecking accept-new\nLogLevel ERROR\n' >> /etc/ssh/ssh_config

# Common Python HTTP libraries the model uses in run_script,
# plus the Playwright Python client. The base image ships
# Chromium/Firefox/WebKit binaries and the `playwright` CLI but
# does NOT install the Python module on the system Python (its
# build step uses a venv that's then removed). Pin the Python
# client to the same minor version as the base image's bundled
# browsers to avoid client/binary protocol mismatches.
# `--break-system-packages` is required on Debian's PEP 668 setup;
# the sandbox is a single-purpose container, OS-Python conflicts
# don't matter here.
RUN pip3 install --no-cache-dir --break-system-packages \
      requests httpx \
      "playwright==1.49.0" \
      fpdf2 openpyxl python-docx Pillow matplotlib markdown pyyaml

# Common deliverable libs preinstalled above:
#   fpdf2          — PDF generation
#   openpyxl       — .xlsx read/write
#   python-docx    — .docx generation
#   Pillow         — image processing (resize/crop/convert/draw)
#   matplotlib     — chart rendering to PNG/SVG
#   markdown       — markdown → HTML
#   pyyaml         — YAML read/write
# The model is taught (system prompt) that these are available
# without pip-install. Anything outside this list will fail because
# the per-user (non-admin) iptables fence in start.sh REJECTs all
# LAN/loopback/RFC1918 egress for uid 10001+, so PyPI is unreachable
# from a model-authored install attempt.

# Master service identity inside the sandbox — used by docker exec -u
# for admin-side operations and matched by the iptables --uid-owner
# pass-through for admin LAN access. UID 10000 reserved by spec
# (isolation.md §Per-user account provisioning).
RUN useradd -m -u 10000 -s /bin/bash dmh_ai-master-u

# Browser daemon (Phase 2 of #215). One Playwright process holding
# one Chromium for the whole deployment, BrowserContext-per-user.
# Bound to /var/run/dmh-browser/daemon.sock — start.sh creates the
# directory at boot.
COPY browser_daemon.py /sandbox-browser-daemon.py
RUN chmod +x /sandbox-browser-daemon.py

# Container entrypoint: iptables fence → spawn browser daemon under
# a supervisor loop → block on tail.
COPY start.sh /sandbox-start.sh
RUN chmod +x /sandbox-start.sh

WORKDIR /
CMD ["/sandbox-start.sh"]
