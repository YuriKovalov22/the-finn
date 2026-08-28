#!/bin/sh
# One Finn tick. Runs every minute from cron; also the entry point for manual use:
#   /root/finn/tick.sh facts        what the box sees right now
#   /root/finn/tick.sh say "..."    make him speak on a given occasion
DIR=/root/finn
LOCK=/tmp/finn.lock

# a tick never takes minutes; anything older than that is a corpse
if [ -d "$LOCK" ] && [ -n "$(find /tmp -maxdepth 1 -name finn.lock -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

set -a
. "$DIR/env"
set +a

# keep the log from ever filling the overlay
if [ -f "$DIR/finn.log" ] && [ "$(wc -c < "$DIR/finn.log")" -gt 262144 ]; then
    tail -c 131072 "$DIR/finn.log" > "$DIR/finn.log.new" && mv "$DIR/finn.log.new" "$DIR/finn.log"
fi

/usr/bin/lua "$DIR/finn.lua" "$@"
