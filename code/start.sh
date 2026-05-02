#!/bin/sh
# Master container entrypoint. Runs as root.
#
# Why root: master needs to chown per-user host directories during
# provisioning (see DmhAi.Permissions.SandboxUser), which requires
# CAP_CHOWN — granted by default to root, not to UID 1000.
#
# This is not a meaningful security regression vs. the previous
# `su-exec appuser` drop: master already mounts /var/run/docker.sock,
# which is root-equivalent (master can spawn arbitrarily-privileged
# containers, mount the host filesystem, etc.). The drop was cosmetic
# given that surface. See specs/permissions.md §Master container
# changes.
#
# The `docker` CLI inside this container talks to the host daemon via
# /var/run/docker.sock. Because we're root, no group-membership dance
# is needed — root bypasses the socket's group ACL. The legacy
# DOCKER_GID block has been removed.

exec /app/bin/dmh_ai start
