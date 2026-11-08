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
    chat("FH_Diag active. Commands: /dtest chat|dlg|imgui|all, /dreport")
    if crashed then
        chat("{FF6666}Previous run ended with a CRASH. Last lines are in FH_Diag.prev.log")
        local f = io.open(PREV, "rb")
        if f then
            local lines = {}
            for l in f:lines() do lines[#lines + 1] = l end
            f:close()
            for i = math.max(1, #lines - 6), #lines do chat(cut(lines[i]:gsub("\r", ""), 110)) end
        end
    end
    snapshot()
    local n = 0
    while true do   -- heartbeat: по нему видно, сколько игра прожила до краша
        wait(1000)
        n = n + 1
        if n % 5 == 0 then w("hb " .. n .. " frames=" .. D.frames .. " sync=" .. tostring(D.sync or 0)) end
        if n % 30 == 0 then snapshot() end
    end
end

function onScriptTerminate(s, quit)
    if s == thisScript() then
        w("script terminating normally, quit=" .. tostring(quit))
        os.remove(MARK)   -- нормальный выход: маркер краша снимаем
    end
end
