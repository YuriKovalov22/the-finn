# The Finn

A small, grumpy agent that lives inside your router and only knows what the router can see.

Named after the character in William Gibson's Sprawl trilogy who ends up as a construct in
an armoured box bolted into an alley, where people come to hear the oracle complain. This
one runs on a GL.iNet GL-MT3000 on an office wall. It watches the hallway it is in, and
occasionally has something to say about it.

It is deliberately not an assistant. No tools, no memory beyond a state file, no access to
your mail or calendar or tickets, and nothing to be helpful with. It has a view of one
hallway and an opinion about it.

https://github.com/user-attachments/assets/1a2ea4b4-33c7-4f07-93e6-b644f8d201d0

> Six failed SSH logins in the last minute, usually it's zero all night. Bloody hell, some
> tosser out there fancies his chances.

> Well, bugger me, look what the tide dragged in, thought you'd gone to ground for good.

Everything runs on the router itself. If the rest of your infrastructure is on fire, this
still works, which was most of the point. The words come from a model, and that model can be
a cloud one or a box on your own network; with a local one he keeps talking with the
internet cut, and no key sits on the router at all.

## Things he has said

From the log of one router on one wall, in the order they happened, trimmed only where the
log had cut them.

> Port 853 knocking, one I've never heard before. New ghost this time, DNS-over-TLS by the
> smell of it, some machine gone shy about who it's asking directions from.

> Your phone's gone mental, 99 new flows this minute against a usual 3. Bloody thing's buzzing
> like a hornet in a jar, hell if I know what it's chattering about.

> One less tickle on my ear, that fourth device on wifi just packed up and walked out. Down to
> three now, just the usual family.

> Port 853 stopped knocking, 17500 started up again in its place. Same damn ghost just
> changed its knock, dressed up different, still scratching at the same door.

> Port 500 popped up in the traffic, IKE, the kind of knock nobody in this office ever uses.
> Ears pricked and nothing there, just some VPN handshake ghost passing through.

> Root's back in the building. Grid just lit up, one node blinking awake in the dark like the
> whole network's been waiting on you, you magnificent bastard.

> Your desktop's new connections dropped to 9 this minute, usual is around 45. Bloody hell,
> after all that racket it's finally sat down and shut up for once.

> Port 3478 popped up in the mess, that's the knock STUN servers make when something's trying
> to punch a hole through for a voice or video call.

> Ten straight days on my feet and not a single ache out of the ordinary, that's the strange
> part tonight.

`tick.sh said` prints your own router's collected works. Post the best of them in
[What did your Finn say today?](https://github.com/YuriKovalov22/the-finn/discussions/2)

## Quick start

You need about ten minutes, a router you own, and a brain for him: a card on file with an
LLM provider, or a machine on your network that runs a model.

**1. Check your router can host it.** OpenWrt-based, with `lua`, `lua-cjson` and a `curl`
built with TLS. On GL.iNet firmware all three are usually there already:

```sh
ssh root@192.168.8.1 'lua -e "require(\"cjson\") print(\"ok\")"; curl --version | head -1'
# missing anything?  opkg update && opkg install lua lua-cjson curl
```

It needs a few megabytes of overlay and nothing else. Tested on a GL-MT3000, OpenWrt 21.02,
512 MB RAM.

**2. Make him a Telegram bot.** In Telegram, open [@BotFather](https://t.me/botfather), send
`/newbot`, give it a name and a username. He hands you a token like `123456789:AAF...`. That
token is the bot; anyone holding it can post as him, so treat it as a password.

**3. Find your own Telegram id.** Message [@userinfobot](https://t.me/userinfobot); it replies
with a number. He answers that id and no other, so nobody else can talk to your router.

**4. Get an API key, or skip this step.** [Anthropic](https://console.anthropic.com) or
[OpenAI](https://platform.openai.com/api-keys), both are wired up. **Create a dedicated key
with a low monthly limit.** It will sit in plaintext on a device that shares a network with
other people; a key that can only ever spend five dollars is a key you can shrug about.
Expect single-digit dollars a month at the default settings. Or give him no key at all and
point him at a model on your own network, see [A brain on your own network](#a-brain-on-your-own-network).

**5. Install.**

```sh
git clone https://github.com/YuriKovalov22/the-finn && cd the-finn
cp env.example env && $EDITOR env     # paste the token, your id, the key
./install.sh root@192.168.8.1
```

The installer checks the router, copies two files, writes `env` with mode 0600, installs the
minute cron entry, enables cron, and prints what he can see right now.

**6. Say hello first.** Open your bot in Telegram and press Start. Telegram does not let a bot
open a conversation, so that message is what tells him where to write. He picks it up on his
next tick, within a minute. Send `/help` to see what he understands.

That is the whole setup. He will stay quiet for the first fifteen minutes while he learns what
normal looks like, then speak when something is not.

## A brain on your own network

The router does the sensing, the remembering and the deciding; the model only writes the
line. So the model does not have to be in a datacentre. Anything that speaks the OpenAI
chat API on your LAN works: llama.cpp, Ollama, vLLM, LM Studio, a Mac in the corner, a Pi
with too much RAM. In `env`:

```sh
FINN_PROVIDER=local
FINN_LOCAL_URL=http://192.168.8.20:11434/v1     # what your server prints; Ollama is 11434
FINN_MODEL=qwen3:8b
```

No key on the router, nothing leaves the building, and he keeps grumbling with the uplink
cut, which is when a router-resident has the most to say. `FINN_LOCAL_KEY` if your server
wants one; `FINN_LOCAL_TIMEOUT` (default 180 s) if the box is slow. Reasoning models are
told not to think first, and a `<think>` block that arrives anyway is stripped.

Audition the model before trusting it with his voice:

```sh
/root/finn/tick.sh think "Six failed SSH logins in the last minute, usually zero. English."
```

That asks the brain in character and prints the answer, nothing posted. The bar is the one
in [Tuning](#tuning): the fact first, an image that means something, no narrating its own
plumbing. Expect small models to fail it. Haiku could not hold the voice: it answered about
the wrong machine and let the metaphor swallow the fact. `qwen3:8b` on a 16 GB Apple Silicon
iMac, through Ollama, holds the shape (fact first, then the flinch) and answers in 20 to 45
seconds, but it invents a second fact to go with the first, a temperature or a weak signal
he was never given, which is the worse failure for a thing bolted to a wall. It also thinks
before answering even when told not to, so the budget is set with room for that. Try a few,
they are free, and if one holds him without inventing, say which in an issue.

## How he decides to speak

There is no list of interesting events, which is the part worth stealing. The long version,
with what went wrong on the way, is in [docs/how-he-decides-what-to-say.md](docs/how-he-decides-what-to-say.md). Every minute the box
takes a wide reading of itself and the room, keeps a rolling history of every reading in RAM,
and looks for anything that has fallen outside its own recent range. Whatever is unusual
*today* is what he talks about, so he does not become the same five notifications forever.

Two kinds of oddity are detected generically:

- **numeric**, when a sensor leaves the band it has held for the last 45 minutes by more than
  a per-sensor floor that keeps ordinary wobble out;
- **membership**, when anything appears in or disappears from a set: a device, a neighbour on
  the upstream network, an unusual destination port.

Variety is enforced along three axes, and the coarsest one matters most. **Kind** is what a
remark is actually about: traffic, presence, neighbours, an intruder, his own body, the rhythm
of the place. Connections, throughput and per-device flow churn are different sensors and
different themes but the same observation to a reader, and traffic is by far the twitchiest
thing on a network, so left to itself it wins nearly every round: five of six consecutive
remarks here were some counter going up. Traffic is therefore rationed to one remark in six
hours, and the kind that has waited longest is chosen first.

Which means the other kinds have to have something to say, so several observations exist that
are not counters at all: a machine arriving or leaving and how long it was gone, someone at the
desk at an hour the room is normally empty, an uptime milestone, a stretch of stillness, and
hour-of-day profiles for the slow human sensors, because what is normal at nine on a Tuesday is
not what is normal at nine on a Sunday and a 45 minute band cannot tell the difference.

Variety is enforced along two further axes, and the second one is easy to miss. **Theme** keeps him off
one subject; **shape** keeps him off one sentence. Six remarks reading "X is N now, usually M"
are varied by theme and identical to read, so each oddity also carries a shape (a level rising,
something quieting, an arrival, a departure, a change of rhythm, a stretch of stillness) and the
longest-waiting combination of the two wins. He is also shown his own last few remarks and told
not to reuse their form.

The watchdog is worth calling out because it inverts the usual arrangement: a router is the one
vantage point *outside* the blast radius of the server it depends on, so it is what still speaks
when that server dies. `FINN_WATCH` maps names to hosts or URLs; a target has to miss several
checks before he calls it down, and an outage is the single thing allowed past quiet hours and
the daily budget, because being woken at 3am is the whole point of it.

When an unusual port appears he names what it is from a built-in dictionary (STUN for a call
punching through, mDNS, Apple/Google push, Dropbox sync, VPN, torrent, and so on) rather than
guessing; an unknown port he honestly calls one he does not recognise.

When you walk back into the office after an hour or more away — your phone rejoining the wifi —
he greets you, and the greeting is different every time: consecutive welcomes step through a
rotating list of angles (pirate, underground hacker, a submarine surfacing, a smuggler at the
docks) so two in a row are never the same joke. It bypasses the daily budget and speaking gap,
within waking hours, because a greeting you have to wait an hour for is not a greeting.

Stillness is itself an observation: after some hours in which nothing has left its range, he is
handed that fact rather than staying mute, because a resident would remark on a quiet evening.

Two rules stop him degenerating into a monitor for whichever sensor twitches most. Every
oddity carries a **theme** (ports, the room, the wider network, people, his own body, the
network, an intruder); a theme that has just been used goes quiet for ninety minutes, and
among what is left the longest-waiting theme is the one he is handed. And churn is not news:
a port or a neighbour that was here yesterday and came back does not count, only genuine
novelty does.

Only then is a model asked, and it is asked as a resident rather than a monitoring system:
react to this one thing, or reply `NOTHING` if it is bloodless bookkeeping. A subject he has
raised is muted for six hours, and a failed API call is not treated as a decision to stay
quiet.

## What he can feel

| Sense | Source |
|---|---|
| who is on your wifi, and how strong their signal is | `iwinfo assoclist` |
| who they are | `/tmp/dhcp.leases`, by hostname, so MAC rotation does not break it |
| which of them are furniture rather than strangers | `FINN_KNOWN_HOSTS`, hostname to plain name |
| which of them are people you know | `FINN_PEOPLE`, hostname to a person's name |
| which are your own fixtures (printer, Pi, NAS) | `FINN_KNOWN_HOSTS`, so they never read as strangers |
| whether a machine is in use or asleep | per-device flow churn in `/proc/net/nf_conntrack` |
| how much each device is pulling and sending | conntrack byte counters, when they can be trusted (see below) |
| how long each machine has been here, and since it last stirred | tracked between ticks |
| how many devices the upstream network has, and which are new | neighbour table on that interface |
| what the network talks to, and on what ports, named | conntrack + a port→service dictionary |
| link health, latency and loss to the gateway | `dmesg`, `ping` |
| throughput both ways | `/proc/net/dev` deltas |
| whether a tunnel is alive, and who is on his VPN | `wg show` |
| his own temperature, load, memory, disk, uptime | `/sys`, `/proc` |
| failed SSH logins and real kernel errors | `logread`, with the wifi driver's constant screaming filtered out |
| whether you arrived earlier or later than usual | rolling history of first phone appearance |
| whether the servers your fleet depends on are still up | `FINN_WATCH`, ping or HTTP probe |
| whether the shared uplink is congested | sustained gateway latency over `FINN_CONGEST_MS` |

Per-device throughput deserves a warning. It is read from conntrack byte counters, and on any
router with hardware NAT offload, which includes this one, established flows are handled in
silicon and those counters stop growing. A busy video call shows up as a handful of packets.
Left alone this produces devices that appear to be sending more than the entire uplink carried,
and an agent will faithfully narrate the impossible number. Each tick therefore checks the parts
against the whole and publishes nothing rather than something wrong.

Association is useless as presence, which is worth knowing before you build something like
this: a sleeping Mac stays associated all night, and so does a printer. Flow churn is the
honest signal. A sleeping machine opens no new connections; a machine someone is sitting at
opens between three and fifty a minute.

Every sensor is also wired to a sensation. He is not handed "temperature 63, was 45", he is
handed heat climbing inside his case; a device drawing closer is a tickle, a yanked cable is a
slap, unfamiliar broadcasts from beyond the wall are ghosts he can hear and never see. He has
an anatomy to complain about: the antennas are his ears, the ports his fingers and toes, the
flash his gut.

## Talking to him

He answers anything you write, always, in any mode. He also takes commands, handled locally
at no cost:

| Command | Effect |
|---|---|
| `/status` | mode, what he has said today, model calls spent, which brain he is thinking with |
| `/off` | speaks only when spoken to |
| `/rare` | at most 2 unprompted a day, 3 hours apart |
| `/normal` | at most 5 a day, an hour apart |
| `/chatty` | at most 10 a day, 15 minutes apart |
| `/test` | no daily ceiling, one a minute, for two hours, then back to `/chatty` by itself |
| `/voice` | `beep` plays a pip when he posts, `speak` reads the remark aloud, `off` keeps him to Telegram |
| `/machines` | lists the machines he can control and which are awake |
| `/wake <name>` | sends a WOL magic packet, waits, and tells you whether it actually came up |
| `/sleep <name>` | sleeps the machine over SSH |

Test mode spends its own budget. Otherwise an afternoon of watching him work leaves him mute
for the rest of the day, which is exactly what happened here: two hours of testing burned 22
remarks against a ceiling of 10, and he went silent the moment the test expired.

The daily allowance opens gradually rather than all at once. Mornings are the richest hours
for oddities, so a flat cap gets spent before eleven and leaves nothing for whatever happens
at five; instead it unlocks in proportion to how much of the speaking window has passed, with
one message always available.

He calls you by whatever you put in `FINN_OWNER_NAME`, and he only ever talks to the one
Telegram id you configured.

He speaks English, whatever language you write to him in. He used to be bilingual, Russian
and English by coin toss, and the first Hacker News thread had it right: the Finn is offended
by the idea that he would speak Russian. To give him another language, the character prompt
and `STYLE` near the middle of `finn.lua` are the whole of it.

## Running it

```sh
/root/finn/tick.sh            # one tick, as cron runs it
/root/finn/tick.sh facts      # what the box sees right now: sends nothing, records nothing
/root/finn/tick.sh say "..."  # make him speak on a given occasion
/root/finn/tick.sh status     # the same answer /status gives in the bot
/root/finn/tick.sh kinds      # how each sensor is grouped, and when each group last spoke
/root/finn/tick.sh said       # everything he has ever said, in full, oldest first
/root/finn/tick.sh think "…"  # ask the brain something in character; prints, posts nothing
```

`facts` is strictly read-only, and that matters more than it looks: an inspection that saved
what it saw would mark the oddity as already known, and the next real tick would have nothing
left to say. Diagnostics must not eat the event they are diagnosing.

State lives in `/root/finn/state.json`, events in `/root/finn/finn.log`, his remarks in full
in `/root/finn/said.log`; a quiet tick writes nothing. The first run takes a baseline and stays silent, so a cold start does not report every
device in the building as a new face.

## A speaker, if you want one

Plug a class-compliant USB speaker into the router and he can be heard as well as read. Install
`kmod-usb-audio` and `alsa-utils`, and set `FINN_VOICE`:

- `beep`, the default and the one worth having: a short two-tone pip when he posts, so you look
  at your phone. `sounds/finn-blip.wav` in this repo, copy it to `/root/bell/finn.wav`.
- `speak`, which sends the remark to OpenAI speech synthesis (`FINN_TTS_VOICE`, default echo)
  and plays it through the speaker. Requires `FINN_OPENAI_KEY` even when the words come from
  Anthropic or a local model. Volume is `FINN_VOLUME` — but note many cheap USB DACs ignore the ALSA PCM
  control entirely (they report a level and play at full), so real attenuation is done by an
  ALSA softvol device; copy `asound.conf` to `/etc/asound.conf` and playback targets it.
- `off`.

Either way it only makes noise between `FINN_VOICE_FROM` and `FINN_VOICE_TO`, 9 to 19 by
default, and never when no sound card is present.

## Cost and wear

The minute tick is pure local work: no API call unless an anomaly was found, and a hard ceiling
of 40 model calls a day including the ones that end in `NOTHING`.

The flash is treated as the scarce resource it is on these boxes. Sensor history lives in
tmpfs, the persistent state file is a few hundred bytes and is only rewritten when its contents
actually change, and the log is truncated at 256 KB. Total footprint on the overlay is well
under a megabyte.

## Tuning

At the top of `finn.lua`:

| Constant | Meaning |
|---|---|
| `HIST` | how many minutes of history count as "normal" |
| `WARMUP` | samples before a sensor may cry anomaly |
| `SUBJECT_MUTE` | how long a subject stays quiet after he raises it |
| `CALL_BUDGET` | hard ceiling on model calls per day |
| `QUIET_FROM` / `QUIET_TO` | hours in which he may speak unprompted |
| `FLOOR` | per-sensor noise floors: how big a change has to be to count |
| `MODES` | the talkativeness presets behind the bot commands |

The character is one prompt near the middle of the file. Rewrite it and you have a different
resident. Four rules in it were each learned by getting them wrong, and are worth keeping in
any character you write:

1. **The plain fact first, then the image.** A remark made only of metaphor and swearing reads
   well and communicates nothing: "two hundred and seventy eight throats yelling in my gut"
   leaves the reader guessing what happened. Name the thing by its own name; the lock may follow as an
   image, but it may not stand in for "failed SSH logins".
2. **Every image must mean something.** Ask for a bodily reaction without demanding the
   comparison be checkable and you get filler shaped like style: "woke up sharper than it
   slept" cannot be true or false.
3. **Never let the character narrate its own plumbing.** Unprompted, a model will happily say
   "I was not given that value", which is true of the prompt and fatal to a thing bolted to a
   wall. It notices or it does not.
4. **Forbid the two lies a sensor agent tells naturally.** A throughput reading is how much is
   moving, not how much could move, and a model will happily turn "2.5 Mbit/s flowing" into
   "the line is narrow as a needle's eye" while a gigabit sits idle. It will also invent
   outside knowledge it cannot have: mine announced that video calls "need at least 5 to 10
   Mbit/s each way", which is both wrong and unknowable from inside a router. Say plainly that
   it has never read a specification and that the only normal it owns is the one it measured
   in that room.
5. **If you give him a second language, write the style rules in it.** From his bilingual
   days: an English instruction about writing numbers as digits sat unread at the bottom of a
   Russian answer. The same rule in Russian was obeyed at once.

## Privacy

`FINN_PEOPLE` lets him greet people by name: "John's just joined the wifi, go and say hello."
That is for a network you run and people who know it exists. The same trick pointed at a
shared building network would work rather well, and that is the point at which this stops
being a toy and becomes covert attendance tracking of strangers, so it is not built and I
would not add it. Aggregate counts of the wider network are already there and carry nobody's
name.

This watches a network, which means it watches the people on it. It is written for a router
you own, in a room you occupy. Keep it that way. It reports on the owner's own named devices
and on anonymous counts, it never inspects traffic contents (DNS query logging is deliberately
not switched on), and it sends messages to exactly one Telegram id.

## What it runs on

The sensors are Linux and OpenWrt shaped: `iwinfo`, `/tmp/dhcp.leases`, `/proc/net/nf_conntrack`,
`logread`, `wg`. The rest is Lua 5.1, cjson and curl. So:

| Platform | State | Notes |
|---|---|---|
| GL.iNet GL-MT3000 (Beryl AX), OpenWrt 21.02 | tested, lives here | everything in this README was learned on it |
| Other GL.iNet routers | expected to work | same firmware family, same packages; radios may be named differently, set `FINN_RADIOS` |
| Stock OpenWrt 21 to 24 on anything with a few MB of overlay | expected to work | `opkg install lua lua-cjson curl`; `iwinfo` is present on all wifi builds |
| A Raspberry Pi or x86 box running OpenWrt as the router | expected to work | plenty of RAM; a good place to also run the model |
| ASUS with Asuswrt-Merlin | untested | Entware has Lua; `iwinfo` and `logread` are missing, so the wifi and log senses need rewriting |
| Ubiquiti EdgeOS / UniFi gateways | untested | Debian underneath; conntrack is there, wifi is not on the box, so presence needs a different source |
| MikroTik RouterOS | no, not as is | no Lua, no cron shell. The honest route is a container on RouterOS 7 and RouterOS's API for the senses; that is a port, not a config change |
| OPNsense / pfSense | no, not as is | BSD: no `/proc/net/nf_conntrack`, no `iwinfo`. Doable with `pfctl` and `ifconfig`, again a port |

Questions about a router not on this list go to
[Ports and hardware](https://github.com/YuriKovalov22/the-finn/discussions/3); results go to
[issue #1](https://github.com/YuriKovalov22/the-finn/issues/1). If you get him talking
somewhere new, say what you changed and you get the row here.
The sensing is one function per sense, so a port is a matter of swapping those, not of
rewriting him.

## Notes for the road

- `scp` does not work against dropbear, which has no `sftp-server`. Pipe through `ssh 'cat > file'`.
- GL.iNet firmware runs a second `crond` off `/tmp/gl_crontabs` for its own jobs. Leave it alone;
  the installer uses the stock one at `/etc/crontabs/root`.
- A firmware upgrade wipes the overlay and takes `/root/finn` with it. Re-run `install.sh`.
- Lua 5.1 has no notion of a character, so every string cut is a byte cut. Slicing Cyrillic at a
  byte boundary produces invalid UTF-8 and the API rejects the whole request. There is a
  character-aware truncation helper in the file for this reason.

MIT licensed. It is a toy with a body; enjoy it.
