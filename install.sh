#!/usr/bin/env bash
# Install the Finn onto an OpenWrt router over ssh.
#
#   ./install.sh root@192.168.8.1
#
# Reads ./env (copy env.example first and fill it in), copies the agent, installs the
# cron entry and starts cron. Safe to re-run: it overwrites the code and leaves state alone.
set -euo pipefail

ROUTER="${1:-}"
if [ -z "$ROUTER" ]; then
    echo "usage: $0 user@router-address" >&2
    exit 1
fi
cd "$(dirname "$0")"

if [ ! -f env ]; then
    echo "no ./env file. Copy env.example to env and fill it in first." >&2
    exit 1
fi

for required in FINN_TELEGRAM_TOKEN FINN_OWNER_ID; do
    if ! grep -q "^${required}=." env; then
        echo "env is missing $required" >&2
        exit 1
    fi
done
if ! grep -qE "^FINN_(ANTHROPIC|OPENAI)_KEY=." env; then
    echo "env needs FINN_ANTHROPIC_KEY or FINN_OPENAI_KEY" >&2
    exit 1
fi

say() { printf '\n== %s\n' "$1"; }

say "checking the router"
# dropbear has no sftp-server, so everything goes through ssh + cat rather than scp
ssh "$ROUTER" 'command -v lua >/dev/null || { echo "lua is missing: opkg install lua"; exit 1; }
               lua -e "require(\"cjson\")" 2>/dev/null || { echo "lua-cjson is missing: opkg install lua-cjson"; exit 1; }
               command -v curl >/dev/null || { echo "curl is missing: opkg install curl"; exit 1; }
               echo "lua, cjson and curl are present"'

say "copying the agent"
ssh "$ROUTER" 'mkdir -p /root/finn && chmod 700 /root/finn'
ssh "$ROUTER" 'cat > /root/finn/finn.lua' < finn.lua
ssh "$ROUTER" 'cat > /root/finn/tick.sh'  < tick.sh
ssh "$ROUTER" 'cat > /root/finn/env && chmod 600 /root/finn/env' < env
ssh "$ROUTER" 'chmod +x /root/finn/finn.lua /root/finn/tick.sh'

say "installing the minute tick"
ssh "$ROUTER" '(crontab -l 2>/dev/null | grep -v "finn/tick.sh"; \
                echo "* * * * * /root/finn/tick.sh >/dev/null 2>&1") | crontab -
               /etc/init.d/cron enable >/dev/null 2>&1 || true
               /etc/init.d/cron start  >/dev/null 2>&1 || true
               crontab -l | grep finn'

say "what he can see right now"
ssh "$ROUTER" '/root/finn/tick.sh facts'

cat <<'DONE'

Installed. One thing left, and it has to be you: open Telegram, find the bot you created,
and press Start. Telegram does not let a bot speak first, so that message is what tells him
where to write. He picks the chat up on his next tick, within a minute.

Then talk to him. /help lists what he understands.
DONE
