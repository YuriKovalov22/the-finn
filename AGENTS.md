# Setting the Finn up on someone's router

Instructions for an agent doing this on a person's behalf. The human has to do two things
themselves; everything else is yours. Do them in this order and stop at the first failure.

## What you cannot do for them

1. **Create the Telegram bot.** Only they can talk to @BotFather. Ask them to send `/newbot`,
   pick a name and username, and paste back the token (`123456789:AAF...`). It is a credential:
   do not print it back, do not commit it, write it only to `env` with mode 0600.
2. **Press Start on the bot.** Telegram forbids a bot from opening a conversation. Until they
   press Start, the Finn has nowhere to write, and no amount of configuration fixes it. Ask for
   this explicitly after installing, and verify with
   `grep -o '"chat_id":[0-9]*' /root/finn/state.json` on the router.

You also need their numeric Telegram id (@userinfobot tells them) and an API key. Push for a
dedicated key with a low spend limit rather than their main one: this key lands in plaintext on
a router.

## Check the router first

```sh
ssh "$ROUTER" 'lua -e "require(\"cjson\")" && command -v curl && df -h /overlay'
```

OpenWrt, `lua`, `lua-cjson`, `curl` with TLS, a few MB of overlay. Missing pieces:
`opkg update && opkg install lua lua-cjson curl`. Confirm outbound TLS actually works from the
box before blaming anything else later:

```sh
ssh "$ROUTER" 'curl -s -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/v1/models \
  -H "x-api-key: bogus" -H "anthropic-version: 2023-06-01"'   # 401 means the path is fine
```

## Fill in env correctly

`cp env.example env`, then get these right, because they are the ones people get wrong:

- `FINN_DESK_HOST`, `FINN_PHONE_HOST`, `FINN_LAPTOP_HOST` are **DHCP hostnames**, from
  `cat /tmp/dhcp.leases` on the router. Not MAC addresses: Apple devices rotate their MAC and
  the binding breaks silently.
- `FINN_WAN_IFACE` and `FINN_RADIOS` from `ip link` and `iwinfo`. Defaults suit a GL-MT3000.
- `FINN_UPSTREAM_IFACE`, `FINN_TUNNEL_IFACE`, `FINN_VPN_IFACE` are optional. Leave them empty
  unless the router really has them; the sensors disappear cleanly when unset.

Then `./install.sh user@router`, which validates env, copies the code, installs the cron entry,
starts cron and prints a first reading.

## Verify, in this order

```sh
ssh "$ROUTER" '/root/finn/tick.sh facts'          # sensors read, and it records nothing
ssh "$ROUTER" 'tail -5 /root/finn/finn.log'       # errors show up here and only here
ssh "$ROUTER" 'grep -o "\"chat_id\":[0-9]*" /root/finn/state.json'   # after they press Start
```

He is silent for the first ~15 minutes by design, building a baseline. Silence is not a fault.
`tick.sh say "..."` forces one message if the person wants proof it works.

## Things that will waste your time if you do not know them

- `scp` fails against dropbear (no `sftp-server`). Pipe: `ssh "$ROUTER" 'cat > /path' < file`.
- Do not delete `state.json` to "reset" him: it holds the Telegram chat id, and losing it means
  the person has to press Start again. Delete `/tmp/finn-vol.json` instead; that is the volatile
  history and it rebuilds in fifteen minutes.
- Do not run `tick.sh` by bypassing its lock while cron is also running: two ticks racing each
  other produce nonsense throughput figures.
- `tick.sh facts` is read-only on purpose. Keep it that way. An inspection that records what it
  saw marks the oddity as already known and the next real tick has nothing left to report.
- On GL.iNet firmware there is a second `crond` on `/tmp/gl_crontabs` for the vendor's own jobs.
  Use the stock one at `/etc/crontabs/root` and leave the vendor's alone.

## If you are asked to change his voice

The character is one prompt inside `finn.lua`. Keep four rules or you will regress work that was
already done: the plain fact comes before any image; every image must be checkable or it is cut;
he never refers to how he knows things; and a style rule must be written in the language it
governs, or it will be ignored in the other one.
