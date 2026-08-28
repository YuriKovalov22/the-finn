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

## How it decides to speak

There is no list of interesting events. Every minute the box takes a wide reading of
itself and the room, keeps a rolling history of every reading in RAM, and looks for
anything that has fallen outside its own recent range. Whatever is unusual *today* is
what it gets told about, so it is not the same five notifications forever.

Two kinds of oddity are detected generically:

- **numeric**, when a sensor leaves the band it has held for the last 45 minutes, by more
  than a per-sensor floor that keeps ordinary wobble out;
- **membership**, when anything appears in or disappears from a set: a device, a MAC on
  the building network, an unusual destination port.

Every sensor is also wired to a sensation. It is not handed "temperature 63, was 45", it is
handed "heat climbing inside his case, the plastic of you going warm"; a device drawing
closer is a tickle, a yanked cable is a slap, unfamiliar broadcasts through the wall are
ghosts it can hear and never see. It has an anatomy to complain about: the antennas are its
ears, the ports its fingers and toes, the flash its gut. So it reacts first and gives the
number as an aside, the way a person says "forty degrees, bloody hell" while already pulling
their hand back.

Only then is the model asked, and it is asked as a resident, not a monitoring system: pick
one thing, react to it as a body would, and if it is bloodless bookkeeping with no sensation
in it, reply `NOTHING`. A subject it has raised is muted for six hours so it cannot harp on
one thing, and a failed API call is not treated as a decision to stay quiet.

## What it can feel

| Sense | Source |
|---|---|
| who is on the office wifi, and how strong their signal is | `iwinfo assoclist` |
| who they are | `/tmp/dhcp.leases`, by hostname, so Apple MAC rotation does not break it |
| whether a machine is in use or asleep | per-device flow churn in `/proc/net/nf_conntrack` |
| how many devices the building has, and which are new | neighbour table on the repeater interface |
| what the network is talking to, and on what ports | conntrack, with common ports filtered out |
| link health, latency and loss to the upstream gateway | `dmesg`, `ping` |
| throughput both ways | `/proc/net/dev` deltas |
| whether the tunnel home is alive, and who is on its VPN | `wg show` |
| its own temperature, load, memory, disk, uptime | `/sys`, `/proc` |
| failed SSH logins and real kernel errors | `logread`, with the wifi driver's constant screaming filtered out |
| how long each machine has been on or off the wifi, and how long since it last did anything | tracked between ticks |
| whether you arrived earlier or later than usual | rolling history of first phone appearance |

Association is useless as presence, which is worth knowing before you build something like
this: a sleeping Mac stays associated all night, and so does a printer. Flow churn is the
honest signal. A sleeping machine opens no new connections; a machine someone is sitting at
opens between three and fifty a minute.

## Talking to it

It answers anything you write, always, in any mode. It also takes commands:

Unprompted remarks come out in Russian or English by coin toss, an even split; it answers
you in whichever language you wrote in.

| Command | Effect |
|---|---|
| `/status` | mode, what it has said today, model calls spent |
| `/off` | speaks only when spoken to |
| `/rare` | at most 2 unprompted a day, 3 hours apart |
| `/normal` | at most 5 a day, an hour apart |
| `/chatty` | at most 10 a day, 15 minutes apart |

Commands are handled locally and cost nothing.

Everything runs on the router. If the rest of your infrastructure is on fire, this still
works, which was most of the point.

## Cost and wear

The minute tick is pure local work: no API call unless an anomaly was found, and a hard
ceiling of 40 model calls a day including the ones that end in `NOTHING`. On a small model
that is cents a month.

The flash is treated as the scarce resource it is on these boxes. Sensor history lives in
tmpfs, the persistent state file is a few hundred bytes and is only rewritten when its
contents actually change, and the log is truncated at 256 KB. Total footprint on the
overlay is well under a megabyte.

A note on durations, learned the hard way. Give a model a snapshot with no sense of time and
it will invent one: ours produced "nobody has been here for about two hours" from facts that
said nothing of the kind. Any fact you would not want fabricated has to be measured and
handed over explicitly, and the prompt has to forbid reaching for the rest.

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
