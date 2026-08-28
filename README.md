# The Finn

A small, grumpy agent that lives inside an office router and only knows what the router
can actually see.

Named after the character in William Gibson's Sprawl trilogy who ends up as a construct
in an armoured box bolted into an alley, where people come to hear the oracle complain.
This one runs on a GL.iNet GL-MT3000 on an office wall. It watches the hallway it is in,
and occasionally has something to say about it.

It is deliberately not an assistant. It has no tools, no memory beyond a state file, no
access to mail or calendars or tickets, and nothing to be helpful with. It has a view of
one hallway and an opinion about it.

## What it observes

Everything comes from the router itself, with no cloud collector in the middle:

| Signal | Source |
|---|---|
| who is on the wifi | `iwinfo <iface> assoclist` |
| who they are | `/tmp/dhcp.leases` (hostname, so Apple MAC rotation does not break it) |
| whether a machine is actually in use | per-device flow churn in `/proc/net/nf_conntrack` |
| WAN health, link flaps | `/proc/uptime`, `dmesg` |
| whether the tunnel home is alive | `wg show <iface> latest-handshakes` |

The activity signal is worth a note. Association is useless as presence: a sleeping Mac
stays associated all night, and so does a printer. New conntrack flows per minute are a
much better proxy. A sleeping machine opens none; a machine someone is sitting at opens
between three and fifty. So "he woke his desktop" is detected as an *edge*: ten quiet
minutes, then flows again.

## What it does with that

- **Greets you once a day**, when you actually wake your machine or walk back into range.
- **Remarks, rarely**, on things it genuinely witnesses: a link flap, a tunnel that has
  gone quiet, a device that has never been on this network before, an uptime milestone.
  Capped at three unprompted messages a day, inside waking hours only.
- **Answers when written to**, in character, from the same facts and nothing else.

Everything runs on the router. If the rest of your infrastructure is on fire, this still
works, which was most of the point.

## Requirements

- An OpenWrt-based router with `lua`, `cjson`, `curl` with TLS, and a few MB of overlay.
  Tested on a GL-MT3000 (GL.iNet firmware, OpenWrt 21.02, 512 MB RAM).
- A Telegram bot token, from [@BotFather](https://t.me/botfather).
- An Anthropic API key. Use a dedicated key with a low spend limit: it sits in plaintext
  on a device that other people share a network with. One Haiku call per message costs
  approximately nothing, and the design makes very few of them.

## Install

```sh
ssh root@your-router 'mkdir -p /root/finn && chmod 700 /root/finn'
ssh root@your-router 'cat > /root/finn/finn.lua' < finn.lua
ssh root@your-router 'cat > /root/finn/tick.sh'  < tick.sh
ssh root@your-router 'chmod +x /root/finn/finn.lua /root/finn/tick.sh'

# secrets over stdin, so they never reach the process table or your shell history
cp env.example env && $EDITOR env
ssh root@your-router 'cat > /root/finn/env && chmod 600 /root/finn/env' < env

ssh root@your-router '(crontab -l 2>/dev/null; echo "* * * * * /root/finn/tick.sh >/dev/null 2>&1") | crontab -'
ssh root@your-router '/etc/init.d/cron enable && /etc/init.d/cron start'
```

Then message the bot once. Telegram will not let a bot open a conversation, so the first
`/start` is what teaches it where to write; it picks the chat id up from there and stores it.

Note: dropbear has no `sftp-server`, so `scp` fails. Pipe through `ssh cat`, as above.

## Use

```sh
/root/finn/tick.sh          # one tick, as cron runs it
/root/finn/tick.sh facts    # print what the box sees right now, send nothing
/root/finn/tick.sh say "..." # make it speak on a given occasion
```

State lives in `/root/finn/state.json`, events in `/root/finn/finn.log` (a quiet tick
writes nothing). The first run takes a baseline and stays silent, so a cold start does not
report every device in the building as a new face.

## Tuning

At the top of `finn.lua`:

| Constant | Meaning |
|---|---|
| `IDLE_CHURN` / `IDLE_MINUTES` | how still a machine must be before it counts as asleep |
| `WAKE_CHURN` | flows that end the silence and mean someone woke it |
| `AWAY_MINUTES` | phone gone this long, then back, means you walked in |
| `QUIET_FROM` / `QUIET_TO` | hours in which it may speak unprompted |
| `MAX_UNSOLICITED_PER_DAY` | the hard cap on it talking first |

The character is a single prompt near the bottom of the file. Rewrite it and you have a
different resident.

## A note on privacy

This watches a network, which means it watches the people on it. It is written for a
router you own, in a room you occupy. Keep it that way. It reports on the owner's own
devices and on anonymous counts, never on individuals it has not been told about, and it
sends messages to exactly one Telegram id.
