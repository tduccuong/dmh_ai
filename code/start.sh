#!/bin/sh
su-exec appuser python3 /app/server.py &
exec nginx -g 'daemon off;'
