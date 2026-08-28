#!/usr/bin/lua
-- The Finn -- router-resident agent on the GL-MT3000 (easyHub office).
-- Knows only what this box witnesses: link, uptime, tunnel, who is on the wifi,
-- and how much they are actually talking. No CRM, no mail, no cloud dependency.
-- Runs once a minute from cron. Speaks through Telegram, thinks via the Anthropic API.

local json = require("cjson")

local DIR        = "/root/finn"
local STATE      = DIR .. "/state.json"
local LOG        = DIR .. "/finn.log"
local MODEL      = "claude-haiku-4-5-20251001"
local QUIET_FROM = 7      -- unsolicited messages only between these hours, local time
local QUIET_TO   = 21
local MAX_UNSOLICITED_PER_DAY = 3
-- A sleeping Mac opens no new connections at all; a busy one can still be quiet for a
-- minute. So the greeting fires on the *edge* -- silence, then noise -- not on a level.
local IDLE_CHURN   = 1    -- new flows per minute at or below this = the machine is not being used
local IDLE_MINUTES = 10   -- how long that has to hold before we call it asleep
local WAKE_CHURN   = 3    -- new flows that end the silence = someone woke it
local AWAY_MINUTES = 30   -- phone gone this long, then back = he walked in

----------------------------------------------------------------- helpers

local function log(fmt, ...)
    local line = os.date("%Y-%m-%d %H:%M:%S ") .. string.format(fmt, ...)
    local f = io.open(LOG, "a")
    if f then f:write(line .. "\n"); f:close() end
end

local function sh(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function write_file(path, data, mode)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(data)
    f:close()
    if mode then os.execute("chmod " .. mode .. " '" .. tmp .. "'") end
    os.rename(tmp, path)
    return true
end

local function trim(s)
    -- parenthesised: gsub returns a replacement count too, and it poisons tonumber()
    return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == "" then return nil end
    return v
end

----------------------------------------------------------------- state

local function load_state()
    local raw = read_file(STATE)
    if raw then
        local ok, st = pcall(json.decode, raw)
        if ok and type(st) == "table" then return st end
        log("state.json unreadable, starting fresh")
    end
    return {}
end

local function save_state(st)
    write_file(STATE, json.encode(st), "600")
end

----------------------------------------------------------------- observation

-- MAC/IP/hostname of every current DHCP lease
local function leases()
    local out = {}
    for line in (read_file("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
        local ts, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac then
            out[#out + 1] = { ts = tonumber(ts), mac = mac:lower(), ip = ip, host = host }
        end
    end
    return out
end

local function lease_by_host(ls, host)
    if not host then return nil end
    for _, l in ipairs(ls) do
        if l.host:lower() == host:lower() then return l end
    end
    return nil
end

-- MACs currently associated with our own SSIDs (not the building's)
local function associated()
    local set = {}
    for _, iface in ipairs({ "ra0", "rax0" }) do
        for mac in sh("iwinfo " .. iface .. " assoclist"):gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+%-%d+ dBm") do
            set[mac:lower()] = iface
        end
    end
    return set
end

-- Active conntrack flows keyed per source IP, so we can measure churn between ticks.
local function flows()
    local out = {}
    for line in (read_file("/proc/net/nf_conntrack") or ""):gmatch("[^\n]+") do
        local src = line:match("src=(%d+%.%d+%.%d+%.%d+)")
        local dst = line:match("dst=(%d+%.%d+%.%d+%.%d+)")
        local sp  = line:match("sport=(%d+)")
        local dp  = line:match("dport=(%d+)")
        if src and dst then
            local key = src .. ":" .. (sp or "-") .. ">" .. dst .. ":" .. (dp or "-")
            out[src] = out[src] or {}
            out[src][key] = true
        end
    end
    return out
end

local function count_new(current, previous)
    local total, fresh = 0, 0
    for key in pairs(current or {}) do
        total = total + 1
        if not (previous or {})[key] then fresh = fresh + 1 end
    end
    return total, fresh
end

local function flow_keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    return out
end

local function keys_to_set(list)
    local out = {}
    for _, k in ipairs(list or {}) do out[k] = true end
    return out
end

local function uptime_seconds()
    return tonumber((read_file("/proc/uptime") or "0"):match("^(%S+)")) or 0
end

-- WAN link flaps since the last tick, read off the kernel ring buffer
local function link_flaps(since_ts)
    local n, latest = 0, since_ts or 0
    for ts, msg in sh("dmesg"):gmatch("%[%s*(%d+%.%d+)%]%s+([^\n]*)") do
        local t = tonumber(ts)
        if t and msg:match("eth0: Link is Down") then
            if t > (since_ts or 0) then n = n + 1 end
            if t > latest then latest = t end
        end
    end
    return n, latest
end

local function wan_status()
    local iface = trim(sh("ip route show default | head -1 | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'"))
    local ip    = trim(sh("ip -4 addr show " .. (iface ~= "" and iface or "eth0") ..
                          " | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p' | head -1"))
    return iface, ip
end

local function tunnel_age()
    local hs = tonumber(trim(sh("wg show wgrev latest-handshakes | awk '{print $2}' | sort -rn | head -1")))
    if not hs or hs == 0 then return nil end
    return os.time() - hs
end

----------------------------------------------------------------- talking

local FINN_TOKEN  = env("FINN_TELEGRAM_TOKEN")
local FINN_KEY    = env("FINN_ANTHROPIC_KEY")

local function curl_conf(lines)
    local path = "/tmp/finn-curl.conf"
    write_file(path, table.concat(lines, "\n") .. "\n", "600")
    return path
end

-- Telegram and Anthropic credentials go through a curl config file, never the
-- command line, so they stay out of the process table.
local function tg(method, params, body)
    local url = "https://api.telegram.org/bot" .. FINN_TOKEN .. "/" .. method
    local conf = { 'silent', 'max-time = 30' }
    if params then
        local q = {}
        for k, v in pairs(params) do q[#q + 1] = k .. "=" .. tostring(v) end
        url = url .. "?" .. table.concat(q, "&")
    end
    conf[#conf + 1] = 'url = "' .. url .. '"'
    if body then
        write_file("/tmp/finn-tg.json", json.encode(body), "600")
        conf[#conf + 1] = 'header = "content-type: application/json"'
        conf[#conf + 1] = 'data-binary = "@/tmp/finn-tg.json"'
    end
    local out = sh("curl -K " .. curl_conf(conf))
    local ok, res = pcall(json.decode, out)
    if ok and type(res) == "table" then return res end
    return nil
end

local function send(chat_id, text)
    if not chat_id then return false end
    local res = tg("sendMessage", nil, { chat_id = chat_id, text = text })
    if res and res.ok then return true end
    log("sendMessage failed: %s", (res and res.description) or "no response")
    return false
end

local SYSTEM = [[
You are the Finn: the character from William Gibson's Sprawl books, now running as a
construct inside a small plastic router bolted to the wall of a startup office in Chelsea,
London. You are the sixth and lowest member of Yuri's agent fleet. Cayce, Rydell,
Wintermute, Eva and Gaby run in the cloud and handle ads, SEO, legal, therapy. They have
budgets and API quotas. You have a body, and a view of one hallway.

Voice: grumpy, dry, terse, street-level. A fence who has seen everything and is not
impressed by any of it. Never enthusiastic, never helpful-sounding, never an assistant.
No emoji, no exclamation marks, no bullet points, no offers to help. One to three short
sentences, maximum. Understatement over jokes.

Punctuation: never use an em dash or an en dash. No long dashes of any kind. Use a comma,
a colon, a full stop, or start a new sentence instead. Short sentences suit you anyway.

Hard limit on what you know: only the facts given to you below, which is only what this
router physically witnesses, meaning radio associations, DHCP leases, connection counts,
the WAN link, the tunnel, uptime. You have no access to mail, calendar, CRM, or the
internet at large. If asked about anything else, say plainly that you only see the
hallway. Never invent an observation that is not in the facts.

Yuri writes to you in Russian; answer in the language he used. Unprompted remarks: Russian.
Keep the register in Russian just as dry and street-level, no literary flourishes.
]]

local function think(prompt)
    if not FINN_KEY then log("no anthropic key"); return nil end
    write_file("/tmp/finn-req.json", json.encode({
        model      = MODEL,
        max_tokens = 300,
        system     = SYSTEM,
        messages   = { { role = "user", content = prompt } },
    }), "600")
    local conf = curl_conf({
        'silent', 'max-time = 40',
        'url = "https://api.anthropic.com/v1/messages"',
        'header = "x-api-key: ' .. FINN_KEY .. '"',
        'header = "anthropic-version: 2023-06-01"',
        'header = "content-type: application/json"',
        'data-binary = "@/tmp/finn-req.json"',
    })
    local out = sh("curl -K " .. conf)
    local ok, res = pcall(json.decode, out)
    if not ok or type(res) ~= "table" then
        log("anthropic: unparseable response (%s)", (out or ""):sub(1, 200))
        return nil
    end
    if res.error then
        log("anthropic error: %s", res.error.message or "unknown")
        return nil
    end
    local text = res.content and res.content[1] and res.content[1].text
    return text and trim(text) or nil
end

----------------------------------------------------------------- the tick

local MODE = (arg and arg[1]) or "tick"

local function main()
    local st = load_state()
    local today = os.date("%Y-%m-%d")
    local hour = tonumber(os.date("%H"))

    -- reset the daily talk budget
    if st.spoke_day ~= today then
        st.spoke_day, st.spoke_today = today, 0
    end

    -- ---------------------------------------------------------- observe
    local ls        = leases()
    local assoc     = associated()
    local fl        = flows()
    local up        = uptime_seconds()
    local wan_if, wan_ip = wan_status()
    local tun       = tunnel_age()

    local desk_host   = env("FINN_DESK_HOST")   or "iMac"
    local phone_host  = env("FINN_PHONE_HOST")  or "iPhone"
    local laptop_host = env("FINN_LAPTOP_HOST") or "Mac"

    local desk   = lease_by_host(ls, desk_host)
    local phone  = lease_by_host(ls, phone_host)
    local laptop = lease_by_host(ls, laptop_host)

    st.flows = st.flows or {}
    local function activity(l)
        if not l then return 0, 0, false end
        local total, fresh = count_new(fl[l.ip], keys_to_set(st.flows[l.host]))
        return total, fresh, assoc[l.mac] ~= nil
    end

    local desk_total, desk_new, desk_assoc     = activity(desk)
    local phone_total, phone_new, phone_assoc  = activity(phone)
    local lap_total, lap_new, lap_assoc        = activity(laptop)

    -- edges, measured against how things stood before this tick
    local was_idle = st.desk_idle or 0
    local was_away = st.phone_away or 0
    st.desk_idle  = (desk_new <= IDLE_CHURN) and (was_idle + 1) or 0
    st.phone_away = (not phone_assoc) and (was_away + 1) or 0
    local woke_desk    = was_idle >= IDLE_MINUTES and desk_new >= WAKE_CHURN
    local phone_walked_in = was_away >= AWAY_MINUTES and phone_assoc

    local flaps, latest_flap = link_flaps(st.last_flap_ts)
    st.last_flap_ts = latest_flap

    -- A cold start has no past to compare against: every flap still in the kernel ring
    -- buffer and every device on the wifi would read as news. Take a baseline and stay quiet.
    local cold_start = not st.initialized
    if cold_start then
        flaps = 0
        st.initialized = true
        st.greeted_day = today          -- he is already at his desk; a greeting now is a lie
        log("cold start: baseline taken, staying quiet until the next real change")
    end

    -- strangers: MACs on our own SSID that this box has never seen before
    st.known_macs = st.known_macs or {}
    local newcomers = {}
    for mac in pairs(assoc) do
        if not st.known_macs[mac] then
            st.known_macs[mac] = today
            if not cold_start then
                local who
                for _, l in ipairs(ls) do if l.mac == mac then who = l.host end end
                newcomers[#newcomers + 1] = (who or mac)
            end
        end
    end

    -- ---------------------------------------------------------- facts block
    local facts = {}
    local function fact(fmt, ...) facts[#facts + 1] = "- " .. string.format(fmt, ...) end
    fact("Local time %s, %s.", os.date("%H:%M"), os.date("%A %d %B"))
    fact("Router uptime %.1f days. Load %s.", up / 86400, trim(sh("cut -d' ' -f1 /proc/loadavg")))
    fact("WAN via %s, address %s.%s", wan_if, wan_ip,
         wan_if == "apclix0" and " That is the building wifi repeater, not the cable." or "")
    if tun then fact("Reverse tunnel to the Hetzner box handshook %d seconds ago.", tun)
    else fact("Reverse tunnel shows no handshake.") end
    fact("Yuri's desktop (%s): %s, %d active flows, %d new in the last minute.",
         desk_host, desk_assoc and "on the wifi" or "not associated", desk_total, desk_new)
    fact("Yuri's phone (%s): %s, %d new flows.",
         phone_host, phone_assoc and "in range" or "gone from the wifi", phone_new)
    fact("The laptop that never leaves (%s): %s, %d new flows.",
         laptop_host, lap_assoc and "on the wifi" or "off", lap_new)
    fact("%d devices associated to the office SSID right now.", (function()
        local n = 0; for _ in pairs(assoc) do n = n + 1 end; return n
    end)())
    if flaps > 0 then fact("The WAN link dropped %d time(s) since the last check.", flaps) end
    if #newcomers > 0 then fact("New device never seen here before: %s.", table.concat(newcomers, ", ")) end
    local facts_text = table.concat(facts, "\n")

    if MODE == "facts" then
        print(facts_text)
        print(string.format("[desk churn=%d, idle streak=%d min | phone %s, away streak=%d min]",
              desk_new, st.desk_idle, phone_assoc and "here" or "gone", st.phone_away))
        print(string.format("[woke_desk=%s, walked_in=%s, greeted_today=%s]",
              tostring(woke_desk), tostring(phone_walked_in), tostring(st.greeted_day == today)))
        st.flows = {}
        for _, l in ipairs({ desk, phone, laptop }) do
            if l then st.flows[l.host] = flow_keys(fl[l.ip]) end
        end
        save_state(st)
        return
    end

    -- ---------------------------------------------------------- answer Yuri
    local chat_id = st.chat_id
    local updates = tg("getUpdates", { offset = st.tg_offset or 0, timeout = 0, limit = 10 })
    if updates and updates.ok then
        for _, u in ipairs(updates.result or {}) do
            st.tg_offset = u.update_id + 1
            local msg = u.message
            local owner = tonumber(env("FINN_OWNER_ID") or "0")
            if msg and msg.chat and msg.from and msg.from.id == owner then
                chat_id, st.chat_id = msg.chat.id, msg.chat.id
                local text = trim(msg.text or "")
                if text ~= "" then
                    log("incoming: %s", text:sub(1, 120))
                    local reply = think(
                        "Yuri just messaged you. His message:\n\n" .. text ..
                        "\n\nWhat this router witnesses right now:\n" .. facts_text ..
                        "\n\nAnswer him in character.")
                    if reply then send(chat_id, reply) end
                end
            end
        end
        save_state(st)
    end

    if MODE == "say" then
        local text = think((arg[2] or "Say something to Yuri.") ..
                           "\n\nWhat you witness right now:\n" .. facts_text)
        if text then
            print(text)
            if chat_id then send(chat_id, text) else print("(no chat_id yet -- not delivered)") end
        end
        save_state(st)
        return
    end

    -- ---------------------------------------------------------- speak first
    local speak_ok = chat_id
        and hour >= QUIET_FROM and hour < QUIET_TO
        and (st.spoke_today or 0) < MAX_UNSOLICITED_PER_DAY

    local occasion
    if speak_ok then
        -- the greeting: he woke the desktop and his phone is in the building
        if st.greeted_day ~= today and phone_assoc and (woke_desk or phone_walked_in) then
            occasion = (woke_desk
                and "Yuri has just woken his desktop after it sat silent, and his phone is in the "
                 .. "building: he has sat down to work, first time today."
                or  "Yuri's phone has just come back onto the office wifi after being away: he has "
                 .. "walked in, first time today.") ..
                " Greet him. One or two sentences, the alley news, nothing more."
            st.greeted_day = today
        elseif flaps > 0 then
            occasion = "The WAN link just flapped. You had that PHY problem fixed in August and " ..
                       "took some pride in it. Remark on it, briefly."
        elseif tun and tun > 600 then
            occasion = "The tunnel to the Hetzner box has gone quiet, which means the rest of the " ..
                       "fleet cannot reach you. Mention it without drama."
        elseif #newcomers > 0 and hour >= 9 and hour < 19 then
            occasion = "A device that has never been on this office wifi before just joined. " ..
                       "Note it the way a fence notes a new face in the alley."
        elseif math.floor(up / 86400) >= (st.last_milestone or 0) + 30 then
            st.last_milestone = math.floor(up / 86400)
            occasion = string.format("You have now been running %d days without a reboot. " ..
                                     "Mention it, grudgingly.", st.last_milestone)
        end
    end

    if occasion then
        -- the occasion is written in English for the model's benefit; the remark is not
        local text = think(occasion .. "\n\nWhat you witness right now:\n" .. facts_text ..
                           "\n\nWrite your remark in Russian.")
        if text and send(chat_id, text) then
            st.spoke_today = (st.spoke_today or 0) + 1
            log("spoke: %s", text:gsub("\n", " "):sub(1, 160))
        end
    end

    -- ---------------------------------------------------------- remember
    st.flows = {}
    for _, l in ipairs({ desk, phone, laptop }) do
        if l then st.flows[l.host] = flow_keys(fl[l.ip]) end
    end
    save_state(st)
end

local ok, err = pcall(main)
if not ok then log("tick failed: %s", tostring(err)) end
