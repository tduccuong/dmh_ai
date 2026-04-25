FROM alpine:3
RUN apk add --no-cache \
      bash curl wget python3 py3-pip jq git \
      nodejs npm make gcc g++ musl-dev \
      ca-certificates tzdata \
      openssh-client sshpass expect

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
RUN adduser -D -u 1000 sandbox
WORKDIR /data
CMD ["tail", "-f", "/dev/null"]
