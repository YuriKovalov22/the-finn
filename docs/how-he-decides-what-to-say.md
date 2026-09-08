# How a router decides what is worth saying

*Notes from eleven days of a resident agent on an office wall. The code is
[the-finn](https://github.com/YuriKovalov22/the-finn); this is the part of it that
is not obvious from reading it.*

The Finn is a Lua script on a GL.iNet router. Once a minute it looks at the box and the
room, and a few times a day it says something in Telegram. It is not an assistant and it
has no tools. The interesting problem was never getting a model to write a grumpy sentence.
It was deciding, on a router with 512 MB of RAM and no idea what an office is, *which*
minute out of 1440 deserves one.

The first version had a list. Five things worth mentioning: a new device, a failed login,
the tunnel dying, the temperature climbing, a traffic spike. It worked for a day and was
dead by the second, because a list of interesting events is a list of the five
notifications you will receive for the rest of your life. The owner of the router said so
in fewer words. What follows is what replaced the list.

## Normal is whatever this room did in the last 45 minutes

There are no thresholds in the file. Every sensor keeps a ring of its last 45 readings in
RAM, one per minute, and an anomaly is a reading outside the range that ring has held. Not
outside some idea of a healthy router. Outside what *this* router saw in the last three
quarters of an hour.

That sounds too simple and it mostly is. Two additions make it survive contact with a real
network.

The first is a floor per sensor. Latency wobbles by a millisecond, connection counts by a
dozen, without anything having happened, and a range detector with no floor will announce
every wobble. So each sensor carries a minimum change that counts, set by watching the
sensor for a day: 400 kbit/s for the uplink, 25 for open connections, 3 ms for gateway
latency, 2 degrees for his own temperature.

The second is that some things are sets, not numbers. Devices on the wifi, MAC addresses
on the building's network beyond the wall, destination ports in the connection table.
For those the oddity is membership: something appeared, or something left. And churn is
not news. A port that was seen yesterday and came back is not a new port, a neighbour that
reconnects every morning is not a new neighbour. Only genuine novelty counts, a day of
absence for a port and six hours for a neighbour, and a port disappearing does not count at all.

A sensor needs fifteen readings before it is allowed to cry anomaly, so a cold start does
not report the whole building as strangers.

## The twitchiest sensor wins every round, so ration it

With the list gone and the detector in, he spoke about traffic. Then about traffic again.
Five of six consecutive remarks were some counter going up. Not because traffic was
interesting, but because throughput, open connections and per-device flow churn are three
sensors, and all three twitch more often than anything else on a network, so any fair
contest between oddities is won by one of them.

The fix has three layers, and the coarsest one matters most.

**Kind.** Every anomaly belongs to a kind that says what it is *about* to a reader:
traffic, presence, neighbours, an intruder, his own body, the rhythm of the place.
Connections and throughput and churn are three sensors and one kind. Each kind has a
silence after it speaks, and traffic's is six hours. When several anomalies are live, the
kind that has waited longest is chosen first, and only then the biggest deviation inside it.

**Theme.** A finer grouping, ports and room and building and people and body and
network, with a 90 minute silence, so that two remarks in a row are not both about the
hallway even if one is a count and one is an arrival.

**Shape.** This one is easy to miss. Six remarks varied by theme still all read "X is N,
usually M", because that is what an anomaly detector produces. So each oddity also carries
a shape: a level rising, something quieting, an arrival, a departure, a change of rhythm,
a stretch of stillness. The pair of theme and shape that has waited longest wins. He is
also shown his own last six remarks and told not to reuse their construction. If they all
opened with a number, this one opens with the hour, or with who is in the room.

## Ration one thing and the others have to have something to say

Once traffic was limited to four remarks a day the room went quiet, because the other kinds
were starved. Presence and rhythm needed observations of their own that are not counters.

So several were added that come from bookkeeping rather than sensors: a machine arriving
and how long it was gone, a person at the desk at an hour the room is normally empty, an
uptime milestone, and stillness itself. After some hours in which nothing has left its
range, that fact is handed to him rather than treated as a reason to stay mute, because a
resident would remark on a quiet evening.

The slow human sensors got hour-of-day profiles. The building network at nine in the
morning and at nine at night are different normals, and a 45 minute window cannot tell
them apart. So the device count beyond the wall keeps a smoothed mean per hour of the day,
one sample per hour per day, and is compared against that hour's own habit.

## A model is asked once, about one thing, and may decline

Only after all of that is a model called, and it is handed one anomaly, not the list. It
is asked as a resident rather than a monitor: react to this, or answer `NOTHING` if it is
bloodless bookkeeping. `NOTHING` is a legitimate outcome and mutes the subject for six
hours. A failed API call is not, and leaves the subject live, because a network error is
not a decision to stay quiet.

Calls are capped at 40 a day including the ones that end in `NOTHING`. Remarks are capped
by mode, 10 a day at the chattiest, and the allowance opens through the day in proportion
to how much of the speaking window has passed, with one always available. A flat cap gets
spent before eleven, and mornings are the richest hours for oddities.

## Things that were wrong and looked right

**Association is not presence.** A sleeping Mac stays associated with the wifi all night,
and so does a printer. The honest signal is flow churn: a sleeping machine opens no new
connections, a machine someone is sitting at opens between three and fifty a minute.

**A phone in a pocket leaves every four minutes.** Wi-Fi association flaps. Read naively,
the owner's phone left and returned constantly, the away-timer reset every time, and the
"welcome back after three hours" greeting never fired. Presence is now debounced: gone
after five minutes unseen, back after two consecutive sightings.

**Hardware NAT makes per-device traffic lie.** The MT3000 offloads established flows to
silicon, and the byte counters in conntrack stop growing for those flows. A busy video
call shows up as a handful of packets, and the arithmetic produces devices that uploaded
more than the entire cable carried. Every tick now checks the parts against the whole and
publishes nothing rather than an impossible number.

**The model narrates its own plumbing.** Unprompted, it will say "I was not given that
value", which is true of the prompt and fatal to a thing bolted to a wall. It will also
invent outside knowledge, such as what bandwidth a video call needs, which it cannot know
from inside a router. Both are forbidden in the prompt, in the language the rule governs,
because an English style rule sits unread at the bottom of a Russian answer.

## What generalises

None of this is specific to routers. Any agent that watches a stream and speaks
occasionally faces the same three problems: what counts as unusual, which unusual thing to
mention when several are live, and how not to say the same sentence twice. The answers
here were a rolling range per signal with a floor, a rationing hierarchy from coarse to
fine, and a shape axis separate from the subject axis. The model does the last ten percent.
The router does the rest, and it is the rest that makes him worth listening to.
