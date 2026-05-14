FROM alpine:3
RUN apk add --no-cache \
      bash curl wget python3 py3-pip jq git \
      nodejs npm make gcc g++ musl-dev \
      ca-certificates tzdata \
      openssh-client sshpass expect \
      shadow iptables

# Trust-on-first-use SSH host-key handling. Default is interactive
# yes/no on first connect, which fails in sandbox scripts where stdin
# isn't a TTY (sshpass exits with code 6, raw ssh blocks). `accept-new`
# auto-accepts a host's key the FIRST time it's seen and remembers it;
# subsequent connections verify against the remembered key and refuse
# with a loud error if it changed (MITM caught). LogLevel ERROR keeps
# the "Permanently added ... to known_hosts" notice out of the script
# output the model parses.
RUN mkdir -p /etc/ssh && printf 'StrictHostKeyChecking accept-new\nLogLevel ERROR\n' >> /etc/ssh/ssh_config

RUN pip3 install --no-cache-dir requests httpx --break-system-packages 2>/dev/null || \
    pip3 install --no-cache-dir requests httpx

# Deliverable lib set: the model is taught (system prompt
# `<sandbox_capabilities>`) that these are present so it can produce
# PDFs / XLSX / DOCX / images / charts / Markdown / YAML on first
# try without pip-install. PyPI is unreachable from non-admin uids
# because of the LAN-fence in start.sh, so a missing lib means the
# model either fakes a malformed file or thrashes through five
# install attempts that all RST. Pillow / matplotlib / openpyxl /
# markdown / pyyaml come from Alpine packages (PyPI wheels are
# manylinux-only and don't run on musl); fpdf2 and python-docx are
# pure-Python and install fine via pip.
RUN apk add --no-cache \
      py3-pillow py3-matplotlib py3-openpyxl py3-markdown py3-yaml && \
    (pip3 install --no-cache-dir --break-system-packages fpdf2 python-docx 2>/dev/null || \
     pip3 install --no-cache-dir fpdf2 python-docx)

# Master service identity inside the sandbox — used by docker exec -u
# for admin-side operations and matched by the iptables --uid-owner
# pass-through for admin LAN access. UID 10000 reserved by spec
# (specs/permissions.md §Per-user account provisioning).
RUN adduser -D -u 10000 dmh_ai-master-u

# start.sh sets sysctl + iptables on container start, then waits.
# Container runs as root (no USER directive) so the script can
# manage namespaces and the user database.
COPY start.sh /sandbox-start.sh
RUN chmod +x /sandbox-start.sh

WORKDIR /
CMD ["/sandbox-start.sh"]
