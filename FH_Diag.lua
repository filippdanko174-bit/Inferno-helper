-- FH_Diag: диагностика крашей SA-MP/MoonLoader. Положите ОТДЕЛЬНЫМ скриптом (лучше без других скриптов).
-- Пишет FH_Diag.log рядом (папка moonloader) с записью на диск после КАЖДОЙ строки:
-- последняя строка перед крашем показывает, что делала игра. Текст только латиницей (работает на ПК и Android).
pcall(function() script_name("FH_Diag") script_author("ByFilipp") end)

local LOG = getWorkingDirectory() .. "/FH_Diag.log"
local PREV = getWorkingDirectory() .. "/FH_Diag.prev.log"
local MARK = getWorkingDirectory() .. "/FH_Diag.run"
local T0 = os.clock()
local fh
local D = { frames = 0, hooks = {}, last = "start" }

local function w(s)
    s = string.format("[%8.2f] %s", os.clock() - T0, tostring(s))
    pcall(function()
        if not fh then fh = io.open(LOG, "ab") end
        if fh then fh:write(s, "\r\n") fh:flush() end
    end)
    D.last = s
end
local function chat(s) pcall(sampAddChatMessage, "{66CCFF}[Diag] {FFFFFF}" .. s, -1) end
local function safe(f, ...) local ok, a, b, c = pcall(f, ...) if ok then return a, b, c end return "ERR:" .. tostring(a) end

-- предыдущий запуск закончился крашем, если маркер остался
local crashed = false
do
    local f = io.open(MARK, "rb")
    if f then f:close() crashed = true end
    local src = io.open(LOG, "rb")
    if src then
        local data = src:read("*a") src:close()
        local dst = io.open(PREV, "wb")
        if dst then dst:write(data) dst:close() end
        os.remove(LOG)
    end
    local m = io.open(MARK, "wb") if m then m:write("1") m:close() end
end

w("FH_Diag started, previous run crashed=" .. tostring(crashed))
w("lua=" .. tostring(_VERSION) .. " jit=" .. tostring(jit and jit.version or "no") .. " os=" .. tostring(jit and jit.os or "?"))
w("moonloader=" .. tostring(safe(function() return getMoonloaderVersion() end)))
w("samp available=" .. tostring(safe(isSampAvailable)) .. " sampfuncs=" .. tostring(safe(isSampfuncsLoaded)))

-- какие библиотеки подгружены (главное: imgui и mimgui одновременно = частая причина краша)
local interesting = { "imgui", "mimgui", "samp.events", "lib.samp.events", "effil", "requests", "ffi", "encoding", "vkeys", "memory", "ssl.https", "lfs", "fa-icons", "fAwesome5" }
local function libs()
    local names = {}
    for _, n in ipairs(interesting) do if package.loaded[n] then names[#names + 1] = n end end
    return table.concat(names, ", ")
end
w("loaded libs: " .. libs())
if package.loaded["imgui"] and package.loaded["mimgui"] then w("WARNING: imgui AND mimgui both loaded - known crash source") end

local function scripts()
    local ok, list = pcall(function() return script.list() end)
    if not ok or type(list) ~= "table" then return end
    for _, s in ipairs(list) do
        pcall(function() w("script: " .. tostring(s.name) .. " v" .. tostring(s.version) .. " " .. tostring(s.path)) end)
    end
end
scripts()

-- сканируем исходники других скриптов: какие хуки/библиотеки они используют
local PATTERNS = {
    { "onServerMessage", "hook:onServerMessage" }, { "onShowDialog", "hook:onShowDialog" }, { "onSendCommand", "hook:onSendCommand" },
    { "onSendChat", "hook:onSendChat" }, { "onSendDialogResponse", "hook:onSendDialogResponse" }, { "onSendRpc", "hook:onSendRpc" },
    { "onReceiveRpc", "hook:onReceiveRpc" }, { "onSendPacket", "hook:onSendPacket" }, { "onReceivePacket", "hook:onReceivePacket" },
    { "require%s*%(?%s*['\"]imgui['\"]", "lib:imgui(old)" }, { "require%s*%(?%s*['\"]mimgui['\"]", "lib:mimgui" },
    { "ffi%.cast", "ffi.cast" }, { "memory%.", "memory" }, { "writeMemory", "writeMemory" }, { "callFunction", "callFunction" }, { "sampSendChat", "sampSendChat" },
    { "setWindowPosition", "winapi" }, { "ffi%.C%.", "ffi.C" },
}
local SCAN = {}   -- имя -> { path, flags = {...} }
local function scanScripts()
    local ok, list = pcall(function() return script.list() end)
    if not ok or type(list) ~= "table" then return end
    for _, sc in ipairs(list) do
        pcall(function()
            local name, path = tostring(sc.name), tostring(sc.path)
            if name == "FH_Diag" then return end
            local f = io.open(path, "rb")
            if not f then SCAN[name] = { path = path, flags = {}, nosrc = true } return end
            local src = f:read(3000000) or "" f:close()
            local fl = {}
            for _, p in ipairs(PATTERNS) do if src:find(p[1]) then fl[#fl + 1] = p[2] end end
            SCAN[name] = { path = path, flags = fl, obj = sc }
        end)
    end
end
local function has(name, flag) local e = SCAN[name] for _, x in ipairs(e and e.flags or {}) do if x == flag then return true end end end
local function whoHas(flag) local r = {} for n in pairs(SCAN) do if has(n, flag) then r[#r + 1] = n end end table.sort(r) return r end
scanScripts()
for n, e in pairs(SCAN) do w("scan " .. n .. ": " .. table.concat(e.flags, " ")) end

-- хуки SAMP: логируем всё, что приходит и уходит (кратко)
local okEv, ev = pcall(require, "samp.events")
if not okEv then okEv, ev = pcall(require, "lib.samp.events") end
local function cut(s, n) s = tostring(s):gsub("[%c]", " ") return #s > n and s:sub(1, n) .. "..." or s end
local HOOKS = {}
local function hook(name, f)   -- несколько обработчиков на одно событие; ни один не ломает игру
    if not (okEv and ev) then return end
    if not HOOKS[name] then
        HOOKS[name] = {}
        ev[name] = function(...) for _, h in ipairs(HOOKS[name]) do pcall(h, ...) end end
    end
    table.insert(HOOKS[name], f)
end
hook("onSendCommand", function(c) w("SEND CMD  " .. cut(c, 90)) end)
hook("onSendChat", function(c) w("SEND CHAT " .. cut(c, 90)) end)
hook("onServerMessage", function(col, t) w("RECV MSG  " .. cut(t, 90)) end)
hook("onShowDialog", function(id, st, title, b1, b2, t) w(string.format("RECV DLG  id=%s style=%s title=%s len=%d", tostring(id), tostring(st), cut(title, 30), #tostring(t))) end)
hook("onSendDialogResponse", function(id, b, l, inp) w(string.format("SEND DLGR id=%s btn=%s list=%s input=%s", tostring(id), tostring(b), tostring(l), cut(inp, 30))) end)
hook("onSetPlayerPos", function(p) w("RECV SETPOS") end)
hook("onSendClientJoin", function() w("SEND CLIENT JOIN") end)
hook("onConnectionRejected", function(r) w("CONNECTION REJECTED " .. tostring(r)) end)
hook("onSendPlayerSync", function() D.sync = (D.sync or 0) + 1 end)

-- счётчики событий за окно (пишутся в строку RATE раз в 5 с) и ключевые игровые события
D.cnt = {}
local function bump(k, n) D.cnt[k] = (D.cnt[k] or 0) + (n or 1) end
hook("onServerMessage", function() bump("msg") end)
hook("onShowDialog", function() bump("dlg") end)
hook("onSendCommand", function() bump("cmdOut") end)
hook("onPlayerStreamIn", function() bump("streamInPlayers") end)
hook("onPlayerStreamOut", function() bump("streamOutPlayers") end)
hook("onVehicleStreamIn", function() bump("streamInVeh") end)
hook("onCreateObject", function() bump("createObj") end)
hook("onDestroyObject", function() bump("destroyObj") end)
hook("onCreate3DText", function() bump("text3d") end)
hook("onTextDrawSetString", function() bump("tdString") end)
hook("onShowTextDraw", function() bump("tdShow") end)
hook("onSetPlayerAttachedObject", function() bump("attach") end)
hook("onSetPlayerPos", function(p) bump("setpos") w("EVT SETPOS to " .. string.format("%.0f,%.0f,%.0f", p.x or 0, p.y or 0, p.z or 0)) end)
hook("onSetInterior", function(i) w("EVT INTERIOR " .. tostring(i)) end)
hook("onTogglePlayerSpectating", function(on) w("EVT SPECTATE " .. tostring(on)) end)
hook("onSetSpawnInfo", function() w("EVT SPAWNINFO") end)
hook("onRequestSpawnResponse", function() w("EVT SPAWN RESPONSE") end)
hook("onSendEnterVehicle", function(id) w("EVT ENTER VEH " .. tostring(id)) end)
hook("onSendExitVehicle", function(id) w("EVT EXIT VEH " .. tostring(id)) end)
hook("onSetWeather", function(x) w("EVT WEATHER " .. tostring(x)) end)
hook("onSetPlayerSkin", function(i, sk) w("EVT SKIN " .. tostring(sk)) end)
hook("onSetVehicleParamsEx", function() bump("vehParams") end)
hook("onSendGiveDamage", function() bump("dmgOut") end)
hook("onResetPlayerWeapons", function() w("EVT RESETWEAPONS") end)
hook("onSendRequestClass", function() w("EVT REQUEST CLASS") end)
w("hooks installed: " .. tostring(okEv))

-- минимальное окно mimgui (команда /dtest imgui) - проверяет, падает ли сама отрисовка
local imgui, win, frameFn
do
    local ok, m = pcall(require, "mimgui")
    if ok and type(m) == "table" then
        imgui = m
        win = imgui.new.bool(false)
        pcall(function()
            imgui.OnFrame(function() return win[0] end, function()
                D.frames = D.frames + 1
                if D.frames % 120 == 1 then w("imgui frame " .. D.frames) end
                imgui.SetNextWindowSize(imgui.ImVec2(300, 120), imgui.Cond.FirstUseEver)
                if imgui.Begin("FH_Diag##d", win) then imgui.Text("diag window, frames: " .. D.frames) end
                imgui.End()
            end)
        end)
        w("mimgui: OnFrame registered")
    else
        w("mimgui: not available (" .. tostring(m):match("^[^\n]*") .. ")")
    end
end

local function snapshot()
    local gs = safe(sampGetGamestate)
    local _, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    w(string.format("snapshot: gamestate=%s myid=%s ping=%s", tostring(gs), tostring(id), tostring(safe(function() return sampGetPlayerPing(id) end))))
end


----------------------------------------------------------------------
-- АВТО-ВЫВОД: анализ лога прошлого запуска + moonloader.log + скан чужих скриптов
----------------------------------------------------------------------
local function readLines(p, tailN)
    local f = io.open(p, "rb")
    if not f then return {} end
    local out = {}
    for l in f:lines() do out[#out + 1] = (l:gsub("\r$", "")) if tailN and #out > tailN then table.remove(out, 1) end end
    f:close()
    return out
end
local function analyze()
    local V = { causes = {}, notes = {} }
    local function add(code, score, text, who) V.causes[#V.causes + 1] = { code = code, score = score, text = text, who = who } end
    local prev = readLines(PREV)
    if #prev == 0 then return V, "no previous log" end
    local ml = readLines(getWorkingDirectory() .. "/moonloader.log", 400)

    -- 1) Lua-ошибки перед крашем (из moonloader.log)
    for i = #ml, math.max(1, #ml - 60), -1 do
        local l = ml[i]
        local sc = l:match("%(error%)%s*([%w_%.%-]+):") or l:match("%[ML%]%s*%(error%)%s*([%w_%.%-]+)")
        if sc and sc ~= "FH_Diag" then add("LUA_ERROR", 90, "Lua error in script " .. sc .. ": " .. l:sub(1, 120), { sc }) break end
    end
    for i = #ml, math.max(1, #ml - 60), -1 do
        if ml[i]:lower():find("exception", 1, true) or ml[i]:lower():find("access violation", 1, true) then add("EXCEPTION_IN_MLOG", 70, "moonloader.log: " .. ml[i]:sub(1, 120)) break end
    end

    -- 2) конфликт imgui + mimgui
    for _, l in ipairs(prev) do if l:find("imgui AND mimgui", 1, true) then add("IMGUI_CONFLICT", 85, "old imgui and mimgui loaded together (known crash source)", whoHas("lib:imgui(old)")) break end end
    local old, new = whoHas("lib:imgui(old)"), whoHas("lib:mimgui")
    if #old > 0 and #new > 0 then add("IMGUI_CONFLICT", 80, "scripts use old imgui (" .. table.concat(old, ",") .. ") and mimgui (" .. table.concat(new, ",") .. ")", old) end

    -- 3) что было последним событием
    local last, lastTs, hbs = nil, 0, 0
    for _, l in ipairs(prev) do
        local ts = tonumber(l:match("^%[%s*([%d%.]+)%]")) or 0
        if ts > 0 then lastTs = ts end
        if l:find("] hb ", 1, true) then hbs = hbs + 1 end
        if l:find("] SEND ", 1, true) or l:find("] RECV ", 1, true) or l:find("] TEST ", 1, true) or l:find("imgui frame", 1, true) then last = l end
    end
    V.notes[#V.notes + 1] = string.format("prev run lived %.0f sec, last event: %s", lastTs, last and last:sub(1, 90) or "none")
    local joined = false
    for _, l in ipairs(prev) do if l:find("connected (gamestate 3)", 1, true) then joined = true end end
    if not joined then
        add("CRASH_BEFORE_JOIN", 75, "crash happened before reaching the server (loading or connecting); suspects: scripts loaded at start", nil)
    end
    if last then
        if last:find("TEST send %d begin") and not last:find("returned") then add("CRASH_IN_SENDCHAT", 95, "game died INSIDE sampSendChat (client/sampfuncs/server-side message)", nil)
        elseif last:find("RECV DLG", 1, true) then add("CRASH_ON_DIALOG", 80, "crash right after a server dialog was shown", whoHas("hook:onShowDialog"))
        elseif last:find("RECV MSG", 1, true) then add("CRASH_ON_CHAT_MSG", 70, "crash right after a chat message was received; message handlers: ", whoHas("hook:onServerMessage"))
        elseif last:find("SEND CMD", 1, true) or last:find("SEND CHAT", 1, true) then add("CRASH_ON_COMMAND", 75, "crash right after a command/chat was sent; handlers: ", whoHas("hook:onSendCommand"))
        elseif last:find("imgui frame", 1, true) or last:find("TEST imgui", 1, true) then add("CRASH_IN_IMGUI", 90, "crash while drawing imgui windows", (#old > 0 and old) or new)
        elseif last:find("SEND DLGR", 1, true) then add("CRASH_ON_DIALOG_RESPONSE", 70, "crash right after a dialog response was sent", whoHas("hook:onSendDialogResponse")) end
    end

    -- 5) данные чёрного ящика
    local function num(line, key) return tonumber((line or ""):match(key .. "=(%-?[%d%.]+)")) end
    local lastSnap, lastRate, snaps = nil, nil, {}
    for _, l in ipairs(prev) do
        if l:find("] SNAP ", 1, true) then lastSnap = l snaps[#snaps + 1] = l end
        if l:find("] RATE/5s ", 1, true) then lastRate = l end
    end
    if lastSnap then
        V.notes[#V.notes + 1] = "last snapshot: " .. lastSnap:gsub("^%[%s*[%d%.]+%]%s*", ""):sub(1, 140)
        local mem = num(lastSnap, "mem")
        if mem and mem > 700000 then add("LUA_MEMORY_HUGE", 80, string.format("Lua memory %.0f MB before crash (a script leaks memory)", mem / 1024), nil) end
        if #snaps >= 4 then
            local m1, m2 = num(snaps[1], "mem"), mem
            if m1 and m2 and m2 > m1 * 3 and m2 > 200000 then add("LUA_MEMORY_GROWTH", 65, string.format("Lua memory grew %.0f MB -> %.0f MB (leak)", m1 / 1024, m2 / 1024), nil) end
        end
        local objs = num(lastSnap, "objs") if objs and objs > 3000 then add("MANY_OBJECTS", 55, "very many streamed objects: " .. objs .. " (draw/streaming overload)", nil) end
        local ch = num(lastSnap, "chars") if ch and ch > 200 then add("MANY_PEDS", 40, "many peds/players around: " .. ch, nil) end
        if lastSnap:find("spectating", 1, true) then add("CRASH_WHILE_SPECTATING", 60, "crash while spectating (/re): streaming of the watched player's area", nil) end
    end
    if lastRate then
        local msg = num(lastRate, "msg")
        if msg and msg > 150 then add("CHAT_FLOOD", 70, "server flooded chat: " .. msg .. " messages in 5 sec before crash; message handlers: ", whoHas("hook:onServerMessage")) end
        local fps = num(lastRate, "fps")
        if fps and fps < 10 then add("LOW_FPS", 45, "fps dropped to " .. fps .. " before crash (overload)", nil) end
        local sin = (num(lastRate, "streamInPlayers") or 0) + (num(lastRate, "streamInVeh") or 0) + (num(lastRate, "createObj") or 0)
        if sin > 200 then add("STREAM_BURST", 60, "burst of stream-in/object creation (" .. sin .. " in 5 sec) right before crash", nil) end
    end
    -- события в последние 4 секунды лога
    local tail = {}
    for _, l in ipairs(prev) do
        local ts = tonumber(l:match("^%[%s*([%d%.]+)%]")) or 0
        if ts >= lastTs - 4 then tail[#tail + 1] = l end
    end
    local function tailHas(pat) for _, l in ipairs(tail) do if l:find(pat, 1, true) then return l end end end
    if tailHas("EVT SETPOS") then add("CRASH_AFTER_TELEPORT", 65, "crash within 4 sec after a server teleport: " .. tailHas("EVT SETPOS"):sub(12, 70), nil) end
    if tailHas("EVT INTERIOR") then add("CRASH_AFTER_INTERIOR", 65, "crash within 4 sec after interior change", nil) end
    if tailHas("EVT SPECTATE") then add("CRASH_AFTER_SPECTATE", 65, "crash within 4 sec after spectate toggle", nil) end
    if tailHas("EVT SPAWN") or tailHas("EVT REQUEST CLASS") then add("CRASH_AROUND_SPAWN", 60, "crash right around spawn/class selection", nil) end
    if tailHas("EVT ENTER VEH") or tailHas("EVT EXIT VEH") then add("CRASH_ON_VEHICLE", 55, "crash right after entering/leaving a vehicle", nil) end
    if tailHas("EVT SKIN") or tailHas("EVT WEATHER") then add("CRASH_ON_SKIN_WEATHER", 40, "crash right after skin/weather change", nil) end
    if tailHas("SCRIPTS loaded") or tailHas("SCRIPTS gone") then add("SCRIPT_RELOAD", 70, "a script was loaded/unloaded right before crash: " .. (tailHas("SCRIPTS loaded") or tailHas("SCRIPTS gone")):sub(12, 70), nil) end
    if tailHas("STALL") then add("FREEZE_BEFORE_CRASH", 60, "game froze before crashing (script loop or heavy load)", nil) end
    local ml2 = tailHas("MLOG ") if ml2 then add("MLOG_NEAR_CRASH", 70, "moonloader.log line near crash: " .. ml2:sub(12, 130), nil) end
    -- кто может быть причиной по частоте обработки (много хуков на одно событие)
    local hookers = whoHas("hook:onServerMessage")
    if #hookers >= 4 then V.notes[#V.notes + 1] = #hookers .. " scripts hook chat messages: " .. table.concat(hookers, ",") end
    -- 4) тихий обрыв: пульс шёл, событий нет - подозрение на скрипты с памятью/ffi
    if joined and #V.causes == 0 then
        local suspects = {}
        for _, f in ipairs({ "writeMemory", "ffi.cast", "callFunction", "ffi.C", "memory" }) do for _, n in ipairs(whoHas(f)) do suspects[#suspects + 1] = n .. "(" .. f .. ")" end end
        add("SILENT_CRASH", 50, "game died with no recent events; scripts touching memory/ffi: " .. (#suspects > 0 and table.concat(suspects, ", ") or "none found"), nil)
    end
    table.sort(V.causes, function(a, b) return a.score > b.score end)
    return V
end
local function verdictText(V, err)
    if err then return err end
    local out = { "=== FH_Diag verdict ===" }
    for _, n in ipairs(V.notes) do out[#out + 1] = n end
    if #V.causes == 0 then out[#out + 1] = "no clear cause found; run /dbisect start" end
    for i, c in ipairs(V.causes) do
        out[#out + 1] = string.format("%d) [%s %d%%] %s %s", i, c.code, c.score, c.text, c.who and #c.who > 0 and ("-> " .. table.concat(c.who, ", ")) or "")
    end
    return table.concat(out, "\n")
end
local function showVerdict()
    local V, err = analyze()
    local text = verdictText(V, err)
    local f = io.open(getWorkingDirectory() .. "/FH_Diag_verdict.txt", "wb")
    if f then f:write((text:gsub("\n", "\r\n"))) f:close() end
    w(text)
    for line in text:gmatch("[^\n]+") do chat(line:sub(1, 120)) end
end

----------------------------------------------------------------------
-- АВТО-ПОИСК ВИНОВНИКА (bisect): каждый запуск отключаем половину подозреваемых скриптов
----------------------------------------------------------------------
local STATE = getWorkingDirectory() .. "/FH_Diag.bisect"
local function bisectLoad()
    local st = { active = false, suspects = {}, disabled = {}, round = 0 }
    for _, l in ipairs(readLines(STATE)) do
        local k, v = l:match("^(%w+)=(.*)$")
        if k == "active" then st.active = (v == "1")
        elseif k == "round" then st.round = tonumber(v) or 0
        elseif k == "suspects" or k == "disabled" then st[k] = {} for n in v:gmatch("[^,]+") do st[k][#st[k] + 1] = n end end
    end
    return st
end
local function bisectSave(st)
    local f = io.open(STATE, "wb")
    if f then f:write("active=", st.active and "1" or "0", "\r\nround=", st.round, "\r\nsuspects=", table.concat(st.suspects, ","), "\r\ndisabled=", table.concat(st.disabled, ","), "\r\n") f:close() end
end
local function unloadList(list)
    for _, n in ipairs(list) do
        local e = SCAN[n]
        if e and e.obj then pcall(function() e.obj:unload() end) w("bisect: unloaded " .. n) end
    end
end
local function bisectStep(st, crashedPrev)
    -- итог прошлого раунда: упало -> виновник среди НЕОТКЛЮЧЁННЫХ; не упало -> среди отключённых
    if st.round > 0 then
        local keep = {}
        local dis = {} for _, n in ipairs(st.disabled) do dis[n] = true end
        for _, n in ipairs(st.suspects) do if (crashedPrev and not dis[n]) or (not crashedPrev and dis[n]) then keep[#keep + 1] = n end end
        if #keep > 0 then st.suspects = keep end
        w("bisect round " .. st.round .. " result: crashed=" .. tostring(crashedPrev) .. " suspects now: " .. table.concat(st.suspects, ","))
    end
    if #st.suspects <= 1 then
        st.active = false bisectSave(st)
        return "BISECT RESULT: culprit is most likely '" .. tostring(st.suspects[1]) .. "'"
    end
    st.round = st.round + 1
    st.disabled = {}
    for i = 1, math.floor(#st.suspects / 2) do st.disabled[i] = st.suspects[i] end
    bisectSave(st)
    return "bisect round " .. st.round .. ": disabling " .. table.concat(st.disabled, ",") .. " - play until crash or run /dok if it survived"
end


----------------------------------------------------------------------
-- ЧЁРНЫЙ ЯЩИК: срез состояния игры каждые 5 с (только безопасные вызовы API, без чтения сырой памяти)
----------------------------------------------------------------------
local function cnt(f) local ok, t = pcall(f) return ok and type(t) == "table" and #t or -1 end
local function blackbox()
    local p = {}
    p[#p + 1] = "mem=" .. math.floor(collectgarbage("count")) .. "KB"
    local ok1, x, y, z = pcall(getCharCoordinates, PLAYER_PED)
    if ok1 then p[#p + 1] = string.format("pos=%.0f,%.0f,%.0f", x, y, z) end
    local ok2, int = pcall(getActiveInterior) if ok2 then p[#p + 1] = "int=" .. tostring(int) end
    local ok3, hp = pcall(getCharHealth, PLAYER_PED) if ok3 then p[#p + 1] = "hp=" .. tostring(hp) end
    local ok4, car = pcall(isCharInAnyCar, PLAYER_PED)
    if ok4 and car then
        local ok5, veh = pcall(storeCarCharIsInNoSave, PLAYER_PED)
        if ok5 then local ok6, mdl = pcall(getCarModel, veh) p[#p + 1] = "veh=" .. tostring(ok6 and mdl or "?") end
    else p[#p + 1] = "veh=0" end
    p[#p + 1] = "chars=" .. cnt(getAllChars) .. " cars=" .. cnt(getAllVehicles) .. " objs=" .. cnt(getAllObjects)
    local okd, did = pcall(sampGetCurrentDialogId) if okd then p[#p + 1] = "dlgid=" .. tostring(did) end
    local oks, spec = pcall(sampIsPlayerSpectating) if oks and spec then p[#p + 1] = "spectating" end
    w("SNAP " .. table.concat(p, " "))
end
local function monitorThread()
    local lastBeat, mlSize = os.clock(), 0
    local loaded = {}
    do local okL, list = pcall(function() return script.list() end) if okL and list then for _, sc in ipairs(list) do loaded[tostring(sc.name)] = true end end end
    local tick = 0
    while true do
        local t0 = os.clock()
        wait(1)   -- ~1 кадр игры
        local dt = os.clock() - t0
        D.fpsN = (D.fpsN or 0) + 1
        if dt > 1.5 then w(string.format("STALL main loop frame took %.1f sec (game freeze)", dt)) end
        if os.clock() - lastBeat >= 5 then
            local el = os.clock() - lastBeat
            lastBeat = os.clock()
            tick = tick + 1
            local parts = { string.format("fps=%.0f", (D.fpsN or 0) / el) }
            D.fpsN = 0
            for k, v in pairs(D.cnt) do parts[#parts + 1] = k .. "=" .. v end
            table.sort(parts)
            w("RATE/5s " .. table.concat(parts, " "))
            D.cnt = {}
            blackbox()
            -- новые строки moonloader.log (ошибки других скриптов в реальном времени)
            pcall(function()
                local f = io.open(getWorkingDirectory() .. "/moonloader.log", "rb")
                if f then
                    local size = f:seek("end")
                    if mlSize > 0 and size > mlSize then
                        f:seek("set", mlSize)
                        local chunk = f:read(size - mlSize) or ""
                        for line in chunk:gmatch("[^\r\n]+") do
                            local low = line:lower()
                            if low:find("error", 1, true) or low:find("warn", 1, true) or low:find("crash", 1, true) or low:find("exception", 1, true) or low:find("terminat", 1, true) or low:find("unload", 1, true) then
                                w("MLOG " .. line:sub(1, 150))
                            end
                        end
                    end
                    mlSize = size
                    f:close()
                end
            end)
            -- скрипты загружались/выгружались
            if tick % 2 == 0 then
                pcall(function()
                    local cur = {}
                    for _, sc in ipairs(script.list()) do cur[tostring(sc.name)] = true end
                    for n in pairs(cur) do if not loaded[n] then w("SCRIPTS loaded: " .. n) end end
                    for n in pairs(loaded) do if not cur[n] then w("SCRIPTS gone: " .. n) end end
                    loaded = cur
                end)
            end
        end
    end
end

-- сценарии: /dtest otb | chat | dlg | imgui | all
local function scenario(name)
    if name == "chat" or name == "otb" then
        for i = 1, 3 do
            w("TEST send " .. i .. " begin")
            local ok, err = pcall(sampSendChat, "/aad [Diag] test " .. i)
            w("TEST send " .. i .. " returned ok=" .. tostring(ok) .. " " .. tostring(err or ""))
            wait(1100)
        end
    elseif name == "dlg" then
        w("TEST dialog show")
        pcall(sampShowDialog, 4999, "Diag", "line 1\nline 2", "OK", "Cancel", 2)
        wait(2500)
        w("TEST dialog polled has=" .. tostring(safe(sampHasDialogRespond, 4999)))
    elseif name == "imgui" then
        if not win then w("TEST imgui: mimgui missing") return end
        w("TEST imgui: open window")
        win[0] = true
        wait(5000)
        w("TEST imgui: frames=" .. D.frames .. ", closing")
        win[0] = false
    elseif name == "all" then
        scenario("chat") scenario("dlg") scenario("imgui")
    else
        chat("usage: /dtest chat | dlg | imgui | all")
        return
    end
    w("TEST " .. name .. " finished OK")
    chat("test " .. name .. " finished without crash")
end

function main()
    while not isSampAvailable() do wait(100) end
    w("samp available")
    while safe(sampGetGamestate) ~= 3 do wait(500) end
    w("connected (gamestate 3)")
    wait(1500)
    sampRegisterChatCommand("dtest", function(a) lua_thread.create(function() scenario((a or ""):match("%S+") or "") end) end)
    sampRegisterChatCommand("dreport", function()
        local f = io.open(getWorkingDirectory() .. "/FH_Diag_report.txt", "wb")
        if f then
            f:write("crashed_last_run=", tostring(crashed), "\r\nlibs=", libs(), "\r\nlast=", D.last, "\r\n")
            f:close()
        end
        chat("report written, see FH_Diag.log / FH_Diag.prev.log")
    end)
    chat("FH_Diag active. /dwhy - verdict, /dbisect start|stop, /dok, /dtest chat|dlg|imgui|all")
    if crashed then chat("{FF6666}Previous run ended with a CRASH. Analysing...") end
    snapshot()
    if crashed then showVerdict() end
    local st = bisectLoad()
    if st.active then
        local msg = bisectStep(st, crashed)
        chat(msg) w(msg)
        unloadList(st.disabled)
    end
    sampRegisterChatCommand("dwhy", function() showVerdict() end)
    sampRegisterChatCommand("dbisect", function(a)
        a = (a or ""):match("%S+") or ""
        if a == "start" then
            local s2 = { active = true, suspects = {}, disabled = {}, round = 0 }
            for n in pairs(SCAN) do s2.suspects[#s2.suspects + 1] = n end
            table.sort(s2.suspects)
            if #s2.suspects < 2 then chat("need at least 2 other scripts to bisect") return end
            bisectSave(s2)
            chat("bisect armed over " .. #s2.suspects .. " scripts. Restart the game (reload scripts) and play until crash; after each crash restart again.")
        elseif a == "stop" then os.remove(STATE) chat("bisect stopped")
        else chat("usage: /dbisect start | stop") end
    end)
    sampRegisterChatCommand("dok", function() -- "в этом раунде не упало"
        local s3 = bisectLoad()
        if s3.active then os.remove(MARK) chat("round marked as survived: restart the game for the next round") w("bisect: user marked survived") end
    end)
    lua_thread.create(function() local ok, e = pcall(monitorThread) if not ok then w('monitor died: ' .. tostring(e)) end end)
    local n = 0
    while true do   -- heartbeat: по нему видно, сколько игра прожила до краша
        wait(1000)
        n = n + 1
        if n % 5 == 0 then w("hb " .. n .. " frames=" .. D.frames .. " sync=" .. tostring(D.sync or 0)) end
        if n % 30 == 0 then snapshot() end
        if n == 600 then local s4 = bisectLoad() if s4.active then os.remove(MARK) w("bisect: survived 10 min, marked OK") chat("survived 10 min - restart the game for the next bisect round") end end
    end
end

function onScriptTerminate(s, quit)
    if s == thisScript() then
        w("script terminating normally, quit=" .. tostring(quit))
        os.remove(MARK)   -- нормальный выход: маркер краша снимаем
    end
end
