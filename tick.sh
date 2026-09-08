#!/bin/sh
# One Finn tick. Runs every minute from cron; also the entry point for manual use:
#   /root/finn/tick.sh facts        what the box sees right now
#   /root/finn/tick.sh say "..."    make him speak on a given occasion
#   /root/finn/tick.sh said         everything he has said, in full
#   /root/finn/tick.sh think "..."  ask the brain a question, print the answer, post nothing
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

# keep the logs from ever filling the overlay
for f in finn.log said.log; do
    if [ -f "$DIR/$f" ] && [ "$(wc -c < "$DIR/$f")" -gt 262144 ]; then
        tail -c 131072 "$DIR/$f" > "$DIR/$f.new" && mv "$DIR/$f.new" "$DIR/$f"
    fi
done

/usr/bin/lua "$DIR/finn.lua" "$@"
