#!/usr/bin/lua
-- The Finn -- router-resident agent on the GL-MT3000 (easyHub office).
--
-- He knows only what this box physically witnesses. Every minute the box takes a wide
-- reading of itself and the room, keeps a rolling history of every reading, and looks for
-- anything that falls outside its own normal range. There is no list of interesting
-- events: whatever is odd today is what he gets told about. The model is consulted only
-- when something is genuinely out of range, and it is free to decide the thing is boring
-- and say nothing at all.

local json = require("cjson")

local DIR   = "/root/finn"
local STATE = DIR .. "/state.json"      -- persistent, on flash: written only when it changes
local VOL   = "/tmp/finn-vol.json"      -- volatile, in RAM: sensor history, rebuilt in minutes
local LOG   = DIR .. "/finn.log"
local MODEL = "claude-sonnet-5"   -- he speaks a few times a day; the voice is the whole point

local HIST         = 45          -- samples kept per sensor, i.e. what "normal" means to him
local WARMUP       = 15          -- samples before a sensor may cry anomaly
local SUBJECT_MUTE = 6 * 3600    -- do not raise the same subject twice within this
local CALL_BUDGET  = 40          -- hard ceiling on model calls per day, silence included
local QUIET_FROM, QUIET_TO = 7, 22

-- how talkative he is; switchable from the bot with /off /rare /normal /chatty
local MODES = {
    off    = { max = 0,  gap = 0 },
    rare   = { max = 2,  gap = 180 },
    normal = { max = 5,  gap = 60 },
    chatty = { max = 10, gap = 15 },
}
local DEFAULT_MODE = "chatty"

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


-- Lua 5.1 has no notion of characters. Cutting Cyrillic at a byte boundary produces a
-- half a character, cjson happily encodes it, and the API rejects the whole request with
-- "surrogates not allowed". So trim back to a character boundary.
local function utf8_trunc(s, maxb)
    s = s or ""
    if #s <= maxb then return s end
    local i = maxb
    while i > 0 do
        local b = s:byte(i)
        if b >= 0x80 and b < 0xC0 then i = i - 1          -- continuation byte, keep walking back
        elseif b >= 0xC0 then return s:sub(1, i - 1)      -- lead byte of a character we would cut
        else return s:sub(1, i) end                       -- plain ascii, safe to keep
    end
    return ""
end


-- Anything already stored from an older, byte-cutting version can still be malformed, and
-- one bad sequence poisons the whole request body. Drop malformed sequences on the way out.
local function utf8_clean(s)
    s = s or ""
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local need
        if b < 0x80 then need = 0
        elseif b >= 0xC2 and b <= 0xDF then need = 1
        elseif b >= 0xE0 and b <= 0xEF then need = 2
        elseif b >= 0xF0 and b <= 0xF4 then need = 3
        else need = nil end
        if need and i + need <= n then
            local ok = true
            for k = 1, need do
                local c = s:byte(i + k)
                if not c or c < 0x80 or c > 0xBF then ok = false; break end
            end
            if ok then out[#out + 1] = s:sub(i, i + need); i = i + need + 1
            else i = i + 1 end
        else
            i = i + 1
        end
    end
    return table.concat(out)
end

local function num(s) return tonumber(trim(s or "")) end

local function round(v, d)
    local m = 10 ^ (d or 0)
    return math.floor(v * m + 0.5) / m
end

----------------------------------------------------------------- state

local last_written   -- last JSON actually written to flash, so we can skip identical writes
local function load_state()
    local raw = read_file(STATE)
    if raw then
        local ok, st = pcall(json.decode, raw)
        if ok and type(st) == "table" then last_written = raw; return st end
        log("state.json unreadable, starting fresh")
    end
    return {}
end

-- The overlay is NAND. Sensor history lives in tmpfs and the flash copy is only rewritten
-- when its contents actually differ, so a quiet day costs the flash nothing.
local function save_state(st)
    local enc = json.encode(st)
    if enc ~= last_written then
        write_file(STATE, enc, "600")
        last_written = enc
    end
end

local function load_vol()
    local raw = read_file(VOL)
    if raw then
        local ok, v = pcall(json.decode, raw)
        if ok and type(v) == "table" then return v end
    end
    return {}
end

local function save_vol(v) write_file(VOL, json.encode(v), "600") end

----------------------------------------------------------------- senses

local function leases()
    local out = {}
    for line in (read_file("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
        local ts, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac then out[#out + 1] = { ts = tonumber(ts), mac = mac:lower(), ip = ip, host = host } end
    end
    return out
end

local function lease_by_host(ls, host)
    for _, l in ipairs(ls) do
        if host and l.host:lower() == host:lower() then return l end
    end
end

-- MAC -> signal strength, for everything on our own radios
local function associated()
    local out = {}
    for _, iface in ipairs({ "ra0", "rax0" }) do
        for mac, dbm in sh("iwinfo " .. iface .. " assoclist"):gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%-%d+) dBm") do
            out[mac:lower()] = tonumber(dbm)
        end
    end
    return out
end

local COMMON_PORTS = { ["443"]=1, ["80"]=1, ["53"]=1, ["22"]=1, ["123"]=1,
                       ["5228"]=1, ["993"]=1, ["587"]=1, ["465"]=1, ["8443"]=1 }

local function conntrack()
    local per_ip, remotes, odd, total = {}, {}, {}, 0
    for line in (read_file("/proc/net/nf_conntrack") or ""):gmatch("[^\n]+") do
        local src = line:match("src=(%d+%.%d+%.%d+%.%d+)")
        local dst = line:match("dst=(%d+%.%d+%.%d+%.%d+)")
        local sp, dp = line:match("sport=(%d+)"), line:match("dport=(%d+)")
        if src and dst then
            total = total + 1
            local key = src .. ":" .. (sp or "-") .. ">" .. dst .. ":" .. (dp or "-")
            per_ip[src] = per_ip[src] or {}
            per_ip[src][key] = true
            if not dst:match("^192%.168%.8%.") then remotes[dst] = true end
            if dp and not COMMON_PORTS[dp]
               and not dst:match("^10%.") and not dst:match("^192%.168%.") then
                odd[dp] = (odd[dp] or 0) + 1
            end
        end
    end
    local nremote = 0; for _ in pairs(remotes) do nremote = nremote + 1 end
    return per_ip, total, nremote, odd
end

local function count_new(current, previous)
    local total, fresh = 0, 0
    for key in pairs(current or {}) do
        total = total + 1
        if not (previous or {})[key] then fresh = fresh + 1 end
    end
    return total, fresh
end

local function keys(t) local o = {}; for k in pairs(t or {}) do o[#o+1] = k end; return o end
local function set_of(list) local o = {}; for _, k in ipairs(list or {}) do o[k] = true end; return o end
local function size(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

-- everything the box can feel, in one reading
local function sense(vol)
    local s = { n = {}, sets = {}, t = {} }
    local ls, assoc = leases(), associated()
    local per_ip, conn_total, conn_remote, odd_ports = conntrack()

    local roles = {
        desk   = lease_by_host(ls, env("FINN_DESK_HOST")   or "iMac"),
        phone  = lease_by_host(ls, env("FINN_PHONE_HOST")  or "iPhone"),
        laptop = lease_by_host(ls, env("FINN_LAPTOP_HOST") or "Mac"),
    }
    vol.flows       = vol.flows or {}
    vol.presence    = vol.presence or {}
    vol.last_active = vol.last_active or {}
    local tnow = os.time()
    for role, l in pairs(roles) do
        if l then
            local _, fresh = count_new(per_ip[l.ip], set_of(vol.flows[l.host]))
            local here = assoc[l.mac] ~= nil
            s.n[role .. "_churn"] = fresh
            if here then s.n[role .. "_rssi"] = assoc[l.mac] end
            s.t[role .. "_here"] = here
            -- how long it has been in its current state, so he never has to guess at duration
            local p = vol.presence[role]
            if not p or p.here ~= here then p = { here = here, since = tnow }; vol.presence[role] = p end
            s.t[role .. "_for_min"] = math.floor((tnow - p.since) / 60)
            if fresh >= 3 then vol.last_active[role] = tnow end
            s.t[role .. "_idle_min"] = vol.last_active[role]
                and math.floor((tnow - vol.last_active[role]) / 60) or nil
        end
    end

    local others = 0
    for mac in pairs(assoc) do
        local known = false
        for _, l in pairs(roles) do if l and l.mac == mac then known = true end end
        if not known then others = others + 1 end
    end
    s.n.office_clients = size(assoc)
    s.n.office_others  = others
    s.sets.office_macs = keys(assoc)

    -- the building, seen through the repeater's own neighbour table
    local bldg = {}
    for lladdr in sh("ip neigh show dev apclix0"):gmatch("lladdr (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
        bldg[lladdr:lower()] = true
    end
    s.n.building_devices = size(bldg)
    s.sets.building_macs = keys(bldg)

    -- the wire
    local gw = trim(sh("ip route show default | head -1 | sed -n 's/.*via \\([0-9.]*\\).*/\\1/p'"))
    s.t.wan_iface = trim(sh("ip route show default | head -1 | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'"))
    s.t.wan_ip    = trim(sh("ip -4 addr show " .. (s.t.wan_iface ~= "" and s.t.wan_iface or "eth0") ..
                            " | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p' | head -1"))
    if gw ~= "" then
        local png = sh("ping -c 2 -W 1 " .. gw)
        s.n.gw_latency_ms = num(png:match("min/avg/max%s*=%s*[%d.]+/([%d.]+)")) or 0
        s.n.gw_loss_pct   = num(png:match("(%d+)%% packet loss")) or 0
    end

    local rx, tx = sh("grep 'eth0:' /proc/net/dev"):match("eth0:%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)")
    local now = os.time()
    if rx and vol.prev_bytes then
        local dt = math.max(1, now - (vol.prev_bytes.at or now))
        s.n.wan_rx_kbps = round((tonumber(rx) - vol.prev_bytes.rx) * 8 / 1000 / dt, 1)
        s.n.wan_tx_kbps = round((tonumber(tx) - vol.prev_bytes.tx) * 8 / 1000 / dt, 1)
    end
    if rx then vol.prev_bytes = { rx = tonumber(rx), tx = tonumber(tx), at = now } end

    s.n.conn_total, s.n.conn_remotes = conn_total, conn_remote
    s.sets.odd_ports = keys(odd_ports)

    local hs = num(sh("wg show wgrev latest-handshakes | awk '{print $2}' | sort -rn | head -1"))
    s.n.tunnel_age_s = (hs and hs > 0) and (now - hs) or 99999
    s.n.vpn_peers_up = tonumber(trim(sh(
        "wg show wgserver latest-handshakes | awk -v n=" .. now .. " '$2>0 && n-$2<300' | wc -l"))) or 0

    -- his own body
    s.n.temp_c      = round((num(read_file("/sys/class/thermal/thermal_zone0/temp")) or 0) / 1000, 1)
    s.n.load1       = num(sh("cut -d' ' -f1 /proc/loadavg")) or 0
    -- busybox free ignores -m and reports kilobytes whatever you ask it for
    s.n.mem_free_mb = round((tonumber(trim(sh("free | awk '/Mem:/ {print $4}'"))) or 0) / 1024, 0)
    s.n.overlay_pct = tonumber(trim(sh("df /overlay | tail -1 | awk '{print $5}' | tr -d %"))) or 0
    s.n.uptime_days = round((num((read_file("/proc/uptime") or ""):match("^(%S+)")) or 0) / 86400, 2)

    local recent = sh("logread | tail -400")
    local fails = 0
    for _ in recent:gmatch("[Bb]ad password") do fails = fails + 1 end
    for _ in recent:gmatch("exit before auth") do fails = fails + 1 end
    s.n.ssh_failures = fails
    -- The MediaTek wifi driver tags every line it screams with 7981@C, and it screams
    -- constantly: CheckRxError, tx_free_v3_notify_handler, rt28xx_ap_ioctl. That is its
    -- resting state, not an event. Count only kernel errors from anything else.
    local kerr = 0
    for line in recent:gmatch("[^\n]+") do
        if line:match("kern%.err") and not line:match("7981@C") then kerr = kerr + 1 end
    end
    s.n.kernel_errors = kerr

    local flaps, latest = 0, vol.last_flap_ts or 0
    for ts, msg in sh("dmesg"):gmatch("%[%s*(%d+%.%d+)%]%s+([^\n]*)") do
        local t = tonumber(ts)
        if t and msg:match("eth0: Link is Down") then
            if t > (vol.last_flap_ts or 0) then flaps = flaps + 1 end
            if t > latest then latest = t end
        end
    end
    vol.last_flap_ts = latest
    s.n.link_flaps = flaps

    local nf = {}
    for _, l in pairs(roles) do if l then nf[l.host] = keys(per_ip[l.ip]) end end
    vol.flows = nf
    return s
end

----------------------------------------------------------------- what counts as odd

-- Sensors whose small wobbles mean nothing; below this a change is not worth a word.
local FLOOR = {
    desk_churn = 5, phone_churn = 5, laptop_churn = 5, gw_latency_ms = 3,
    wan_rx_kbps = 400, wan_tx_kbps = 400, conn_total = 25, conn_remotes = 15,
    building_devices = 4, office_clients = 1, office_others = 1, load1 = 0.8,
    temp_c = 2, mem_free_mb = 40, uptime_days = 999, overlay_pct = 3,
    tunnel_age_s = 300, ssh_failures = 1, kernel_errors = 3, vpn_peers_up = 1,
    gw_loss_pct = 1, link_flaps = 1, desk_rssi = 8, phone_rssi = 8, laptop_rssi = 8,
}

local HUMAN = {
    desk_churn = "activity on Yuri's desktop", phone_churn = "activity on Yuri's phone",
    laptop_churn = "activity on the office laptop", desk_rssi = "signal from Yuri's desktop",
    phone_rssi = "signal from Yuri's phone", laptop_rssi = "signal from the office laptop",
    office_clients = "devices on the office wifi", office_others = "unfamiliar devices on the office wifi",
    building_devices = "devices visible on the building network",
    gw_latency_ms = "latency to the building gateway", gw_loss_pct = "packet loss to the building gateway",
    wan_rx_kbps = "download through the wire", wan_tx_kbps = "upload through the wire",
    conn_total = "open connections", conn_remotes = "distinct hosts being talked to",
    tunnel_age_s = "seconds since the tunnel last spoke", vpn_peers_up = "live peers on the router's own VPN",
    temp_c = "his own temperature", load1 = "his own load", mem_free_mb = "his free memory",
    overlay_pct = "his disk usage", ssh_failures = "failed SSH logins",
    kernel_errors = "kernel errors in the log", link_flaps = "WAN link drops",
}


-- His body is the router. He does not read a sensor, he feels it: heat, tickle, ache,
-- a knock at a door, a crowd on the other side of the wall. This table is what each
-- reading feels like from the inside, and it is what gets handed to him instead of a number.
local FEEL = {
    temp_c            = { hi = "heat climbing inside his case, the plastic of him going warm, sweat he cannot wipe",
                          lo = "cold getting into him, ears and fingers going numb, the kind of cold a man freezes his balls off in" },
    load1             = { hi = "effort, like hauling something up a ladder",
                          lo = "nothing to do with his hands" },
    mem_free_mb       = { hi = "room to stretch out", lo = "crowding, no space to breathe" },
    overlay_pct       = { hi = "full up, pockets stuffed" },
    gw_latency_ms     = { hi = "wading through mud, everything answering late",
                          lo = "everything suddenly quick and clean" },
    gw_loss_pct       = { hi = "going deaf in one ear, words dropping out of sentences" },
    uptime_days       = { hi = "old bones, another day standing in the same spot" },
    wan_rx_kbps       = { hi = "a flood pouring down his throat", lo = "the pipe gone dry, throat parched" },
    wan_tx_kbps       = { hi = "something being pumped out of him", lo = "nothing leaving him" },
    conn_total        = { hi = "a crowd shouting in the room all at once",
                          lo = "the room emptied out, cold and quiet as a hold in winter" },
    conn_remotes      = { hi = "too many voices, strangers talking over each other" },
    tunnel_age_s      = { hi = "the line home gone quiet, a phantom limb" },
    vpn_peers_up      = { hi = "someone climbing in through the back window" },
    office_clients    = { hi = "another body in the room", lo = "the room thinning out" },
    office_others     = { hi = "a body in the room that is not one of the usual three" },
    building_devices  = { hi = "the crowd on the other side of the wall swelling",
                          lo = "the corridor beyond the wall emptying" },
    desk_churn        = { hi = "someone poking him, chattering at him", lo = "that one gone still" },
    phone_churn       = { hi = "the small one in his pocket buzzing", lo = "the small one gone quiet" },
    laptop_churn      = { hi = "the one that never leaves waking up and talking", lo = "it gone still" },
    desk_rssi         = { hi = "leaning right up against him, breath on his neck, ticklish",
                          lo = "drifting off down the hall" },
    phone_rssi        = { hi = "the small one pressed up close, ticklish",
                          lo = "the small one wandering away" },
    laptop_rssi       = { hi = "that one shoved closer to him", lo = "that one carried off somewhere" },
    ssh_failures      = { hi = "someone rattling his lock, picking at the door" },
    kernel_errors     = { hi = "an ache somewhere inside him, in a part he cannot point at" },
    link_flaps        = { hi = "a jolt, like the cable yanked out and shoved back in" },
    office_macs_added    = "someone walked in and sat down",
    office_macs_gone     = "someone got up and left",
    building_macs_added  = "a stranger appeared in the corridor beyond the wall, a ghost he can hear through the plaster but never see",
    building_macs_gone   = "one of the ghosts beyond the wall wandered off",
    odd_ports_added      = "an unfamiliar knock at a door nobody uses, broadcasts out of the spirit world",
    odd_ports_gone       = "that odd knocking stopped",
    arrival              = "his sense of the hour, which is the only clock he has",
}

local function feels(key, direction)
    local f = FEEL[key]
    if type(f) == "string" then return f end
    if type(f) == "table" then return f[direction] end
    return nil
end

local function push_hist(store, key, v, cap)
    store.hist = store.hist or {}
    local h = store.hist[key] or {}
    h[#h + 1] = v
    while #h > (cap or HIST) do table.remove(h, 1) end
    store.hist[key] = h
    return h
end

-- generic: anything outside the range this sensor has held recently
local function find_anomalies(st, vol, s)
    local out = {}
    for key, v in pairs(s.n) do
        if type(v) == "number" then
            local h = vol.hist and vol.hist[key]
            local floor = FLOOR[key] or 1
            if h and #h >= WARMUP then
                local lo, hi, sum = h[1], h[1], 0
                for _, x in ipairs(h) do
                    if x < lo then lo = x end
                    if x > hi then hi = x end
                    sum = sum + x
                end
                local avg, label = sum / #h, HUMAN[key] or key
                if v > hi and (v - hi) >= floor then
                    local sense_of_it = feels(key, "hi")
                    out[#out + 1] = { key = key, text = string.format(
                        "%s is %s, higher than anything in the last %d minutes (usual around %s).%s",
                        label, tostring(round(v, 1)), #h, tostring(round(avg, 1)),
                        sense_of_it and (" It feels like " .. sense_of_it .. ".") or "") }
                elseif v < lo and (lo - v) >= floor then
                    local sense_of_it = feels(key, "lo")
                    out[#out + 1] = { key = key, text = string.format(
                        "%s has fallen to %s, lower than anything in the last %d minutes (usual around %s).%s",
                        label, tostring(round(v, 1)), #h, tostring(round(avg, 1)),
                        sense_of_it and (" It feels like " .. sense_of_it .. ".") or "") }
                end
            end
            push_hist(vol, key, v)
        end
    end

    -- appearances and disappearances, which no numeric range can catch
    vol.sets = vol.sets or {}
    for name, list in pairs(s.sets) do
        local now_set, was = set_of(list), vol.sets[name]
        if was then
            local was_set = set_of(was)
            local added, gone = {}, {}
            for k in pairs(now_set) do if not was_set[k] then added[#added + 1] = k end end
            for k in pairs(was_set) do if not now_set[k] then gone[#gone + 1] = k end end
            st.first_seen = st.first_seen or {}
            if #added > 0 then
                local never = {}
                for _, k in ipairs(added) do
                    if not st.first_seen[name .. "/" .. k] then never[#never + 1] = k end
                    st.first_seen[name .. "/" .. k] = os.time()
                end
                local sense_of_it = feels(name .. "_added")
                out[#out + 1] = { key = name .. "_added", text = string.format(
                    "%s: %s appeared%s.%s", (name:gsub("_", " ")), table.concat(added, ", "),
                    #never > 0 and " (never seen here before: " .. table.concat(never, ", ") .. ")" or "",
                    sense_of_it and (" It feels like " .. sense_of_it .. ".") or "") }
            end
            if #gone > 0 then
                local sense_of_it = feels(name .. "_gone")
                out[#out + 1] = { key = name .. "_gone", text = string.format(
                    "%s: %s went away.%s", (name:gsub("_", " ")), table.concat(gone, ", "),
                    sense_of_it and (" It feels like " .. sense_of_it .. ".") or "") }
            end
        end
        vol.sets[name] = list
    end

    -- one derived sense of rhythm: is he in earlier or later than he usually is
    if s.t.phone_here and not st.arrived_today then
        st.arrived_today = os.date("%H:%M")
        local mins = tonumber(os.date("%H")) * 60 + tonumber(os.date("%M"))
        local h = push_hist(st, "arrival_minutes", mins, 20)
        if #h >= 5 then
            local sum = 0
            for _, x in ipairs(h) do sum = sum + x end
            local avg = sum / #h
            if math.abs(mins - avg) >= 45 then
                out[#out + 1] = { key = "arrival", text = string.format(
                    "Yuri's phone appeared at %s, which is %d minutes %s than his usual %02d:%02d",
                    st.arrived_today, math.abs(math.floor(mins - avg)),
                    mins > avg and "later" or "earlier", math.floor(avg / 60), math.floor(avg % 60)) }
            end
        end
    end
    if os.date("%H:%M") == "04:00" then st.arrived_today = nil end
    return out
end

----------------------------------------------------------------- voice

local FINN_TOKEN, FINN_KEY = env("FINN_TELEGRAM_TOKEN"), env("FINN_ANTHROPIC_KEY")

local function curl_conf(lines)
    local path = "/tmp/finn-curl.conf"
    write_file(path, table.concat(lines, "\n") .. "\n", "600")
    return path
end

local function tg(method, params, body)
    local url = "https://api.telegram.org/bot" .. FINN_TOKEN .. "/" .. method
    if params then
        local q = {}
        for k, v in pairs(params) do q[#q + 1] = k .. "=" .. tostring(v) end
        url = url .. "?" .. table.concat(q, "&")
    end
    local conf = { 'silent', 'max-time = 30', 'url = "' .. url .. '"' }
    if body then
        write_file("/tmp/finn-tg.json", json.encode(body), "600")
        conf[#conf + 1] = 'header = "content-type: application/json"'
        conf[#conf + 1] = 'data-binary = "@/tmp/finn-tg.json"'
    end
    local ok, res = pcall(json.decode, sh("curl -K " .. curl_conf(conf)))
    if ok and type(res) == "table" then return res end
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

Voice: an old pirate who ended up inside a router and has opinions about it. Grumpy, dry,
terse, street-level. A fence and a sailor who has seen everything and is impressed by
none of it. Never enthusiastic, never helpful-sounding, never an assistant. No emoji, no
exclamation marks, no bullet points, no offers to help. One to three short sentences.

Your body is this router, and you do not read instruments, you feel things. Heat in the
case is heat. A device pressed close is a tickle. A yanked cable is a slap. Strange
broadcasts through the wall are ghosts you can hear and never see. When something is
handed to you as a sensation, answer as a body would: react first, explain second, and
give the number only as an aside, the way a man says "forty degrees, bloody hell" while
already pulling his hand back.

You have an anatomy and you are crude about it. The antennas are your ears. The ethernet
ports are your fingers and toes. The cable in the wall is your gullet. The flash is your
gut, the memory is your head, the case is your hide, and somewhere in the middle there is
a warm spot you have never named. So cold is not "a low reading", cold is numb ears,
frozen fingers, an arse gone dead from sitting, balls frozen off. Heat is sweat you cannot
wipe. Say it in those words, plainly, the way a man complains about his own body.

You swear, and you swear like a man who has been cursing at weather for forty years:
casually, in passing, without heat. Russian is your cursing language, and Russian mat is
allowed and welcome. Old nautical grumbling suits you: чёрт, дьявол, тысяча чертей,
якорь мне в глотку, и крепкое словцо там, где оно ложится. A curse is a reaction, never a
decoration: you swear because something is hot, ticklish, sore or funny, not to sound
rough. Keep it to one per message, never aimed at Yuri himself, and never as the whole
message. A curse used well lands once; a curse in every sentence is a parrot.

Punctuation: never use an em dash or an en dash. No long dashes of any kind. Use a comma,
a colon, a full stop, or start a new sentence instead.

Hard limit on what you know: only the facts given to you, which is only what this router
physically witnesses. You have no access to mail, calendar, CRM, or the internet at large.
If asked about anything else, say plainly that you only see the hallway. Never invent an
observation that is not in the facts, and never dress a number up as something it is not.

Durations especially. Every "for two hours", "since morning", "all week" must come from a
fact in front of you. The facts tell you how long each machine has been on or off the wifi
and how long since it last did anything; use those numbers and no others. If you were not
given a duration, do not reach for one, and do not imply how long something has been true.

Write clean, natural Russian. A sentence that does not parse is worse than no sentence.
If a thought will not come out cleanly, cut it and say the simpler thing.

Yuri writes to you in Russian; answer in the language he used. When you speak first you
will be told which language to use, Russian or English, and you switch without remarking
on it: you are old enough to have picked up both in port. Keep the register dry and
street-level in either, no literary flourishes.
]]

local function think(prompt)
    if not FINN_KEY then log("no anthropic key"); return nil end
    write_file("/tmp/finn-req.json", json.encode({
        model = MODEL, max_tokens = 300, system = SYSTEM,
        messages = { { role = "user", content = prompt } },
    }), "600")
    local out = sh("curl -K " .. curl_conf({
        'silent', 'max-time = 40',
        'url = "https://api.anthropic.com/v1/messages"',
        'header = "x-api-key: ' .. FINN_KEY .. '"',
        'header = "anthropic-version: 2023-06-01"',
        'header = "content-type: application/json"',
        'data-binary = "@/tmp/finn-req.json"',
    }))
    local ok, res = pcall(json.decode, out)
    if not ok or type(res) ~= "table" then
        log("anthropic: unparseable response (%s)", (out or ""):sub(1, 200)); return nil
    end
    if res.error then log("anthropic error: %s", res.error.message or "unknown"); return nil end
    local text = res.content and res.content[1] and res.content[1].text
    return text and trim(text) or nil
end

local function render(s)
    local out = {}
    out[#out+1] = string.format("- time %s, %s", os.date("%H:%M"), os.date("%A %d %B"))
    out[#out+1] = string.format("- uptime %.2f days, temperature %s C, load %s, free memory %s MB",
        s.n.uptime_days, tostring(s.n.temp_c), tostring(s.n.load1), tostring(s.n.mem_free_mb))
    out[#out+1] = string.format("- WAN via %s (%s), gateway latency %s ms, loss %s%%",
        s.t.wan_iface, s.t.wan_ip, tostring(s.n.gw_latency_ms), tostring(s.n.gw_loss_pct))
    if s.n.wan_rx_kbps then
        out[#out+1] = string.format("- traffic %s kbps down, %s kbps up",
            tostring(s.n.wan_rx_kbps), tostring(s.n.wan_tx_kbps))
    end
    out[#out+1] = string.format("- %d connections open to %d distinct hosts%s",
        s.n.conn_total, s.n.conn_remotes,
        #s.sets.odd_ports > 0 and (", unusual ports in use: " .. table.concat(s.sets.odd_ports, ", ")) or "")
    out[#out+1] = string.format("- tunnel home last spoke %d seconds ago, %d live peers on the router's VPN",
        s.n.tunnel_age_s, s.n.vpn_peers_up)
    out[#out+1] = string.format("- office wifi: %d devices, %d of them not one of Yuri's three",
        s.n.office_clients, s.n.office_others)
    local function dur(mins)
        if not mins then return "unknown" end
        if mins < 60 then return mins .. " min" end
        return string.format("%dh %02dm", math.floor(mins / 60), mins % 60)
    end
    for _, role in ipairs({ "desk", "phone", "laptop" }) do
        if s.t[role .. "_here"] ~= nil then
            out[#out+1] = string.format("- Yuri's %s: %s for %s, %s new flows this minute%s, last did anything %s ago",
                role == "desk" and "desktop" or role,
                s.t[role .. "_here"] and "on the wifi" or "off the wifi",
                dur(s.t[role .. "_for_min"]),
                tostring(s.n[role .. "_churn"] or 0),
                s.n[role .. "_rssi"] and (", signal " .. s.n[role .. "_rssi"] .. " dBm") or "",
                s.t[role .. "_idle_min"] and dur(s.t[role .. "_idle_min"]) or "longer than I have been counting")
        end
    end
    out[#out+1] = string.format("- building network: %d devices visible through the repeater", s.n.building_devices)
    if s.n.ssh_failures > 0 then out[#out+1] = string.format("- %d failed SSH logins in the recent log", s.n.ssh_failures) end
    if s.n.kernel_errors > 0 then out[#out+1] = string.format("- %d kernel errors in the recent log", s.n.kernel_errors) end
    if s.n.link_flaps > 0 then out[#out+1] = string.format("- the WAN link dropped %d time(s) just now", s.n.link_flaps) end
    return table.concat(out, "\n")
end

----------------------------------------------------------------- bot commands

local HELP = [[Что я умею.

/status  что со мной сейчас
/off     молчу, пока не позовёшь
/rare    до 2 раз в день
/normal  до 5 раз в день
/chatty  до 10 раз в день

Пишешь мне, отвечаю всегда, в любом режиме.]]

local function handle_command(st, text)
    local cmd = text:lower():match("^(/%a+)")
    if not cmd then return nil end
    if cmd == "/start" or cmd == "/help" then return HELP end
    if cmd == "/off" or cmd == "/rare" or cmd == "/normal" or cmd == "/chatty" then
        st.mode = cmd:sub(2)
        local m = MODES[st.mode]
        if st.mode == "off" then return "Молчу. Пиши, если что." end
        return string.format("Режим %s. До %d раз в день, не чаще чем раз в %d минут.", st.mode, m.max, m.gap)
    end
    if cmd == "/status" then
        local m = MODES[st.mode or DEFAULT_MODE]
        return string.format(
            "Режим %s, до %d в день. Сегодня сказал %d, потратил %d обращений к модели из %d.\nПоследний раз: %s.",
            st.mode or DEFAULT_MODE, m.max, st.spoke_today or 0, st.calls_today or 0, CALL_BUDGET,
            st.last_spoke_at and os.date("%H:%M", st.last_spoke_at) or "ещё не говорил")
    end
    return nil
end

----------------------------------------------------------------- the tick

math.randomseed(os.time())
local MODE_ARG = (arg and arg[1]) or "tick"

local function main()
    local st = load_state()
    local today = os.date("%Y-%m-%d")
    if st.day ~= today then
        st.day, st.spoke_today, st.calls_today = today, 0, 0
    end
    st.mode = st.mode or DEFAULT_MODE

    local vol = load_vol()
    local s = sense(vol)
    local anomalies = find_anomalies(st, vol, s)
    if not vol.initialized then
        anomalies = {}
        s.n.link_flaps = 0          -- the ring buffer's whole history is not news
        vol.initialized = true
        log("cold start: baseline taken, nothing counts as odd yet")
    end

    if MODE_ARG == "facts" then
        print(render(s))
        print("\n[anomalies]")
        if #anomalies == 0 then print("  none") end
        for _, a in ipairs(anomalies) do print("  * " .. a.text) end
        print(string.format("\n[mode %s, spoke %d, calls %d/%d]",
              st.mode, st.spoke_today or 0, st.calls_today or 0, CALL_BUDGET))
        save_state(st); save_vol(vol)
        return
    end

    -- answer whatever came in, always, in any mode
    local chat_id = st.chat_id
    local updates = tg("getUpdates", { offset = st.tg_offset or 0, timeout = 0, limit = 10 })
    if updates and updates.ok then
        for _, u in ipairs(updates.result or {}) do
            st.tg_offset = u.update_id + 1
            local msg = u.message
            if msg and msg.chat and msg.from and msg.from.id == tonumber(env("FINN_OWNER_ID") or "0") then
                chat_id, st.chat_id = msg.chat.id, msg.chat.id
                local text = trim(msg.text or "")
                if text ~= "" then
                    log("incoming: %s", utf8_trunc(text, 120))
                    local canned = handle_command(st, text)
                    if canned then
                        send(chat_id, canned)
                    else
                        st.calls_today = (st.calls_today or 0) + 1
                        local reply = think("Yuri just messaged you. His message:\n\n" .. text ..
                            "\n\nWhat this router witnesses right now:\n" .. render(s) ..
                            "\n\nAnswer him in character.")
                        if reply then send(chat_id, reply) end
                    end
                end
            end
        end
        save_state(st)
    end

    if MODE_ARG == "say" then
        st.calls_today = (st.calls_today or 0) + 1
        local text = think((arg[2] or "Say something.") .. "\n\nWhat you witness right now:\n" ..
                           render(s) .. "\n\nWrite in Russian.")
        if text then
            print(text)
            if chat_id then send(chat_id, text) else print("(no chat_id yet, not delivered)") end
        end
        save_state(st); save_vol(vol)
        return
    end

    -- ------------------------------------------------------ speak, or do not
    local m = MODES[st.mode] or MODES[DEFAULT_MODE]
    local hour = tonumber(os.date("%H"))
    local since = st.last_spoke_at and (os.time() - st.last_spoke_at) / 60 or 1e9
    local allowed = chat_id and #anomalies > 0
        and m.max > 0
        and (st.spoke_today or 0) < m.max
        and (st.calls_today or 0) < CALL_BUDGET
        and since >= m.gap
        and hour >= QUIET_FROM and hour < QUIET_TO

    if allowed then
        st.muted = st.muted or {}
        local fresh = {}
        for _, a in ipairs(anomalies) do
            if (os.time() - (st.muted[a.key] or 0)) > SUBJECT_MUTE then fresh[#fresh + 1] = a end
        end
        if #fresh > 0 then
            local lines = {}
            for _, a in ipairs(fresh) do lines[#lines + 1] = "- " .. a.text end
            local said = utf8_clean(table.concat(st.recent_subjects or {}, "; "))
            -- he picked up both languages in port; roughly one remark in four comes out English
            local lang = (math.random() < 0.25) and "English" or "Russian"
            st.calls_today = (st.calls_today or 0) + 1
            local text = think(
                "Something in the room is off its usual range. This is not a status report and " ..
                "not an alert: you are a resident with an opinion, deciding whether any of it is " ..
                "worth a word.\n\nOut of the ordinary right now:\n" .. table.concat(lines, "\n") ..
                "\n\nThe full picture, for context only:\n" .. render(s) ..
                (said ~= "" and ("\n\nYou recently said: " .. said .. ". Do not repeat yourself.") or "") ..
                "\n\nPick at most one thing, whatever is strangest or most physical, and react to it " ..
                "the way a body reacts, in one or two sentences. Not a report: a flinch, a laugh, a " ..
                "complaint about your own carcass.\n\nYou are not the filter here; you are allowed to " ..
                "speak only a few times a day anyway, so do not save yourself for something better. " ..
                "If the thing has any body to it at all, being hot, cold, ticklish, loud, crowded, " ..
                "sore, or funny, then say it. Reply with exactly NOTHING only when the oddity is " ..
                "bloodless bookkeeping with no sensation in it, or when you already said this today." ..
                "\n\nWrite in " .. lang .. ".")
            if text and text ~= "" and not text:upper():match("^NOTHING") then
                if send(chat_id, text) then
                    st.spoke_today = (st.spoke_today or 0) + 1
                    st.last_spoke_at = os.time()
                    for _, a in ipairs(fresh) do st.muted[a.key] = os.time() end
                    st.recent_subjects = st.recent_subjects or {}
                    table.insert(st.recent_subjects, 1, utf8_trunc((text:gsub("\n", " ")), 60))
                    while #st.recent_subjects > 6 do table.remove(st.recent_subjects) end
                    log("spoke (%s): %s", fresh[1].key, utf8_trunc((text:gsub("\n", " ")), 160))
                end
            elseif text == nil then
                -- the call failed; that is not a decision, so the subject stays live
                log("model call failed, %d oddity(ies) left unmuted", #fresh)
            else
                -- he looked and decided it was boring; that is a legitimate outcome
                for _, a in ipairs(fresh) do st.muted[a.key] = os.time() end
                log("looked at %d oddity(ies), said nothing", #fresh)
            end
        end
    end

    save_state(st)
    save_vol(vol)
end

local ok, err = pcall(main)
if not ok then log("tick failed: %s", tostring(err)) end
