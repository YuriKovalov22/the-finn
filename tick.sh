#!/bin/sh
# One Finn tick. Runs every minute from cron; also the entry point for manual use:
#   /root/finn/tick.sh facts        what the box sees right now
#   /root/finn/tick.sh say "..."    make him speak on a given occasion
#   /root/finn/tick.sh said         everything he has said, in full
#   /root/finn/tick.sh think "..."  ask the brain a question, print the answer, post nothing
#   /root/finn/tick.sh self [dry]   look inward now: remark, theory, face ("dry": print, change nothing)
#   /root/finn/tick.sh inner        the inward senses as he is handed them, no model call
#   /root/finn/tick.sh theory       his current theory of himself and its revisions
#   /root/finn/tick.sh face <mood>  put an expression on the lamps by hand
#   /root/finn/tick.sh gong [wav]   ring the bowl now, whatever the voice mode says
DIR=/root/finn
LOCK=/tmp/finn.lock

# Ringing the bowl: an alarm come due, /alarm test, or a hand on the rope. Deliberately
# not a remark. It rings whatever /voice is set to, it takes no lock so a tick in flight
# cannot swallow it, and it is shell rather than lua so it still rings with the brain
# unreachable or the lua broken.
if [ "$1" = "gong" ]; then
    set -a
    . "$DIR/env"
    set +a
    WAV="${2:-${FINN_ALARM_WAV:-/root/bell/gong.wav}}"
    [ -f "$WAV" ] || { echo "$(date '+%Y-%m-%d %H:%M:%S') gong: no $WAV" >> "$DIR/finn.log"; exit 1; }
    ls /dev/snd/pcmC*p >/dev/null 2>&1 || { echo "$(date '+%Y-%m-%d %H:%M:%S') gong: no speaker" >> "$DIR/finn.log"; exit 1; }
    amixer -c 0 sset FinnVol "${FINN_GONG_VOLUME:-${FINN_VOLUME:-55}}%" >/dev/null 2>&1
    # he may be halfway through saying something: the card plays one thing at a time,
    # so a collision is a failed aplay, not a queue. Keep trying for half a minute.
    n=0
    while [ "$n" -lt 10 ]; do
        if aplay -D finnvol -q "$WAV" 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') gong" >> "$DIR/finn.log"
            exit 0
        fi
        n=$((n + 1))
        sleep 3
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') gong: speaker busy, gave up after 30s" >> "$DIR/finn.log"
    exit 1
fi

# Is an alarm due this minute? The times are set from the chat with /alarm and written
# one per line: HH:MM, a tab, the weekday digits with Monday as 1. Checked here, above
# the lock, because cron already runs this file every minute and a clock that waits its
# turn behind a model call is not a clock.
if [ -z "$1" ] && [ -s "$DIR/alarms" ]; then
    NOW=$(date +%H:%M)
    TODAY=$(date +%u)
    STAMP="$(date +%F) $NOW"
    if [ "$(cat /tmp/finn-alarm 2>/dev/null)" != "$STAMP" ]; then
        while IFS="	" read -r AT DAYS; do
            [ "$AT" = "$NOW" ] || continue
            case "$DAYS" in *"$TODAY"*) ;; *) continue ;; esac
            # a tick started by hand in the same minute must not ring it a second time
            echo "$STAMP" > /tmp/finn-alarm
            "$0" gong &
            break
        done < "$DIR/alarms"
    fi
fi

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
