#!/bin/sh
su-exec appuser /app/bin/dmhai start &
exec nginx -g 'daemon off;'
