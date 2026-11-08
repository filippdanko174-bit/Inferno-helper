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
local function hook(name, f) if okEv and ev then ev[name] = function(...) pcall(f, ...) end end end
hook("onSendCommand", function(c) w("SEND CMD  " .. cut(c, 90)) end)
hook("onSendChat", function(c) w("SEND CHAT " .. cut(c, 90)) end)
hook("onServerMessage", function(col, t) w("RECV MSG  " .. cut(t, 90)) end)
hook("onShowDialog", function(id, st, title, b1, b2, t) w(string.format("RECV DLG  id=%s style=%s title=%s len=%d", tostring(id), tostring(st), cut(title, 30), #tostring(t))) end)
hook("onSendDialogResponse", function(id, b, l, inp) w(string.format("SEND DLGR id=%s btn=%s list=%s input=%s", tostring(id), tostring(b), tostring(l), cut(inp, 30))) end)
hook("onSetPlayerPos", function(p) w("RECV SETPOS") end)
hook("onSendClientJoin", function() w("SEND CLIENT JOIN") end)
hook("onConnectionRejected", function(r) w("CONNECTION REJECTED " .. tostring(r)) end)
hook("onSendPlayerSync", function() D.sync = (D.sync or 0) + 1 end)
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
