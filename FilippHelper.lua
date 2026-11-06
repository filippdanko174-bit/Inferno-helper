-- FilippHelper (FH) -- ïîìîùíèê àäìèíèñòðàòîðà SA-MP äëÿ MoonLoader. Àâòîð: ByFilipp.
-- Ôàéë íà ÏÊ äîëæåí áûòü â êîäèðîâêå Windows-1251 (cp1251).
local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

-- @ENC-BEGIN (íà ÏÊ ôàéë óæå â cp1251, ïåðåêîäèðîâêà íå íóæíà)
local encOk, encoding = pcall(require, 'encoding')
local enc8
if encOk and encoding then
    encoding.default = 'CP1251'
    enc8 = encoding.UTF8
end
local GUI_ENCODING_OK = enc8 ~= nil                                     -- äëÿ îêíà mimgui íóæíà ïåðåêîäèðîâêà â UTF-8
local function toUi(s) if enc8 then return enc8:encode(s) end return s end    -- cp1251 -> UTF-8
local function fromUi(s) if enc8 then return enc8:decode(s) end return s end  -- UTF-8 -> cp1251
local function toGame(s) return s end     -- ñòðîêà ñêðèïòà -> èãðà
local function fromGame(s) return s end   -- èãðà -> ñòðîêà ñêðèïòà
-- @ENC-END

local VERSION = "1.1"
local UPDATE_FILE = "FilippHelper.lua"   -- êàêîé ôàéë ñêà÷èâàòü ñ GitHub ïðè îáíîâëåíèè
local MAX_CHAT_LEN = 128   -- áåçîïàñíàÿ äëèíà ñòðîêè äëÿ sampSendChat
local SEND_GAP = 1100      -- ïàóçà ìåæäó ñîîáùåíèÿìè (àíòèôëóä ñåðâåðà)
local MAX_REPORTS = 15

local watchedId = nil   -- ID èãðîêà èç /re
local reports = {}            -- ïîñëåäíèå ðåïîðòû, íîâûå â íà÷àëå

----------------------------------------------------------------------
-- ÂÑÏÎÌÎÃÀÒÅËÜÍÛÅ ÔÓÍÊÖÈÈ
----------------------------------------------------------------------
-- @LOWER-BEGIN
local LOWER_MAP = {}
for b = 192, 223 do LOWER_MAP[string.char(b)] = string.char(b + 32) end
LOWER_MAP[string.char(168)] = string.char(184) -- ¨ -> ¸
local function lower1251(s)
    return (s:lower():gsub("[\192-\223\168]", LOWER_MAP))
end
-- @LOWER-END

local function trim(s) return s:match("^%s*(.-)%s*$") end

-- Ïðè÷èíà íàêàçàíèÿ: åñëè ñåðâåð ïîêàçûâàåò ñïèñîê ïðè÷èí, âûáèðàåì ïîäõîäÿùóþ ïî íàøåìó òåêñòó
local PUN = { pending = nil }
function PUN.note(raw)
    local kind, reason = tostring(raw or ""):match("^/(%a+)%s+%S+%s+(.+)$")
    if kind == "mute" or kind == "jail" or kind == "warn" or kind == "ban" then
        PUN.pending = { reason = reason, t = os.clock() }
    end
end

local function safeSend(text)
    PUN.note(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" then return end
    if #text > MAX_CHAT_LEN then text = text:sub(1, MAX_CHAT_LEN) end
    local ok, err = pcall(sampSendChat, text)
    if not ok then print("[FH] sampSendChat error: " .. tostring(err)) end
end

-- Îòïðàâêà ñïèñêà ñòðîê îäíèì ïîòîêîì ñ ïàóçàìè
local function sendSeq(lines, gap, onDone, startDelay)
    return lua_thread.create(function()
        local ok, err = pcall(function()
            if startDelay then wait(startDelay) end
            local n = #lines
            for i = 1, n do
                safeSend(lines[i])
                if i < n or onDone then wait(gap or SEND_GAP) end
            end
        end)
        if not ok then print("[FH] sendSeq error: " .. tostring(err)) end
        if onDone then pcall(onDone) end
    end)
end

local function fmsg(text)
    sampAddChatMessage("{66CCFF}[FH] {FFFFFF}" .. text, -1)
end

----------------------------------------------------------------------
-- ÁÈÍÄÅÐ: ñâîè êîìàíäû, ñîçäàþòñÿ ïðÿìî â èãðå (/binder -- ñïðàâêà)
----------------------------------------------------------------------
local BIND_MAX, BIND_LINES = 50, 20
local binds = {}          -- binds[èìÿ] = { delay = ìñ, lines = { ... } }
local bindFile
local bindBuiltin, bindReg = {}, nil
local bindRunning = false
-- èìåíà, êîòîðûå áèíä çàíèìàòü íå äîëæåí (ñåðâåðíûå/÷àñòûå êîìàíäû)
local BIND_RESERVED = {}
for n in ("a o aad pm re rep report me do b s w g c pay mp setstat ban kick jail mute warn q quit save rcon login register"):gmatch("%S+") do BIND_RESERVED[n] = true end

local function bmsg(text)
    sampAddChatMessage("{66CCFF}[Binder] {FFFFFF}" .. text, -1)
end

local function bindPath()
    if not bindFile then
        local dir = getWorkingDirectory() .. "/config"
        pcall(createDirectory, dir)
        bindFile = dir .. "/FilippHelper_binds.txt"
    end
    return bindFile
end

local function sortedBindNames()
    local names = {}
    for n in pairs(binds) do names[#names + 1] = n end
    table.sort(names)
    return names
end

local function saveBinds()
    local ok = pcall(function()
        local f = assert(io.open(bindPath(), "wb"))
        for _, n in ipairs(sortedBindNames()) do
            f:write("[", n, "]\r\n", "#delay ", tostring(binds[n].delay), "\r\n")
            for _, l in ipairs(binds[n].lines) do f:write("> ", l, "\r\n") end
        end
        f:close()
    end)
    if not ok then bmsg("Íå óäàëîñü ñîõðàíèòü áèíäåð â ôàéë!") end
end

local function runBind(name, arg)
    local b = binds[name]
    if not b then return end
    arg = arg or ""
    local param = (arg ~= "") and arg or (watchedId or "")
    local lines = {}
    for i, l in ipairs(b.lines) do
        lines[i] = l:gsub("{id}", function() return param end):gsub("{arg}", function() return arg end)
    end
    if bindRunning then bmsg("Äîæäèòåñü îêîí÷àíèÿ ïðåäûäóùåãî áèíäà.") return end
    bindRunning = true
    sendSeq(lines, b.delay, function() bindRunning = false end)
end

local function registerBind(name)
    bindReg(name, function(arg) runBind(name, arg) end)
end

local function loadBindsUnsafe()
    local f = io.open(bindPath(), "rb")
    if not f then return end
    local cur, count = nil, 0
    for line in f:lines() do
        line = line:gsub("\r$", "")
        local n = line:match("^%[([%w_]+)%]$")
        if n then
            if not bindBuiltin[n] and not binds[n] and #n <= 20 and count < BIND_MAX then
                count = count + 1
                binds[n] = { delay = SEND_GAP, lines = {} }
                cur = binds[n]
                registerBind(n)
            else cur = nil end
        elseif cur then
            local d = line:match("^#delay (%d+)$")
            if d then cur.delay = math.min(10000, math.max(300, tonumber(d) or SEND_GAP))
            elseif line:sub(1, 2) == "> " and #cur.lines < BIND_LINES then cur.lines[#cur.lines + 1] = line:sub(3) end
        end
    end
    f:close()
end

local function loadBinds()
    local ok, err = pcall(loadBindsUnsafe)
    if not ok then print("[FH] binder load error: " .. tostring(err)) end
end

local function bindHelp()
    sampShowDialog(4109, "FH | Áèíäåð",
        "{66CCFF}[ ÑÂÎÉ ÁÈÍÄÅÐ ]\n\n{33CC33}/fbind {FFFFFF}- îòäåëüíîå îêíî áèíäåðà (ñîçäàíèå è ïðàâêà áåç êîìàíä).\n\n" ..
        "{FFFFFF}Ñîçäà¸ò ñâîè êîìàíäû: íàáðàëè {FFFF00}/èìÿ{FFFFFF} -- îòïðàâèëèñü âñå ñòðîêè áèíäà ïî î÷åðåäè.\n\n" ..
        "{66CCFF}/bnd add èìÿ òåêñò {FFFFFF}- ñîçäàòü áèíä / äîáàâèòü ñòðîêó.\n" ..
        "{FFFFFF}  Íåñêîëüêî ñòðîê ñðàçó ðàçäåëÿéòå {FFFF00};;{FFFFFF}, íàïðèìåð:\n" ..
        "{FFFF00}  /bnd add hi /aad Ïðèâåò! ;; /aad Êàê äåëà?\n" ..
        "{66CCFF}/bnd rm èìÿ N {FFFFFF}- óäàëèòü ñòðîêó N.\n" ..
        "{66CCFF}/bnd del èìÿ {FFFFFF}- óäàëèòü áèíä öåëèêîì.\n" ..
        "{66CCFF}/bnd delay èìÿ ìñ {FFFFFF}- ïàóçà ìåæäó ñòðîêàìè (300-10000, ïî óìîë÷àíèþ 1100).\n" ..
        "{66CCFF}/bnd show èìÿ {FFFFFF}- ïîêàçàòü ñòðîêè áèíäà.\n" ..
        "{66CCFF}/bnd list {FFFFFF}- ñïèñîê âñåõ áèíäîâ.\n\n" ..
        "{9933FF}Ïîäñòàíîâêè â òåêñòå: {FFFF00}{id}{FFFFFF} - ID èç êîìàíäû (/èìÿ 12) èëè ID èç /re,\n" ..
        "{FFFF00}{arg}{FFFFFF} - âñ¸, ÷òî íàïèñàíî ïîñëå êîìàíäû.\n" ..
        "{9933FF}Èìÿ: ëàòèíèöà, öèôðû è _ (äî 20 ñèìâîëîâ). Ëèìèò: " .. BIND_MAX .. " áèíäîâ ïî " .. BIND_LINES .. " ñòðîê.",
        "Çàêðûòü", "", 0)
end

local function bindAdd(name, text)
    if not name:match("^[%w_]+$") or #name > 20 then return false, "Èìÿ: ëàòèíèöà, öèôðû è _ (äî 20 ñèìâîëîâ)." end
    name = name:lower()
    if bindBuiltin[name] or BIND_RESERVED[name] then return false, "Èìÿ /" .. name .. " çàíÿòî êîìàíäîé õåëïåðà." end
    local b = binds[name]
    if not b then
        if #sortedBindNames() >= BIND_MAX then return false, "Äîñòèãíóò ëèìèò áèíäîâ: " .. BIND_MAX end
        b = { delay = SEND_GAP, lines = {} }
    end
    local added = 0
    for piece in (text .. ";;"):gmatch("(.-);;") do
        piece = trim(piece)
        if piece ~= "" then
            if #b.lines >= BIND_LINES then break end
            b.lines[#b.lines + 1] = piece
            added = added + 1
        end
    end
    if added == 0 then return false, "Íè÷åãî íå äîáàâëåíî (ïóñòîé òåêñò èëè ëèìèò ñòðîê " .. BIND_LINES .. ")." end
    if not binds[name] then binds[name] = b registerBind(name) end
    saveBinds()
    return true, string.format("Áèíä /%s: äîáàâëåíî ñòðîê %d (âñåãî %d).", name, added, #b.lines), name
end

local function bindDelete(name)
    binds[name] = nil
    pcall(sampUnregisterChatCommand, name)
    saveBinds()
end

----------------------------------------------------------------------
-- ÎÒÄÅËÜÍÎÅ ÎÊÍÎ ÁÈÍÄÅÐÀ: /fbind (íà äèàëîãàõ SA-MP, ðàáîòàåò áåç imgui)
----------------------------------------------------------------------
local D_MAIN, D_NAME, D_ADD, D_BIND, D_LINES, D_DELAY, D_CONF, D_SHOW = 4110, 4111, 4112, 4113, 4114, 4115, 4116, 4117
local ui = { open = nil, names = {}, sel = nil }
local uiHandlers = {}

local function uiShow(id, title, text, b1, b2, style)
    sampShowDialog(id, title, text, b1, b2, style)
    ui.open = id
end

local function uiMain()
    ui.names = sortedBindNames()
    local t = { "{33CC33}[+] Ñîçäàòü íîâûé áèíä" }
    for _, n in ipairs(ui.names) do
        t[#t + 1] = string.format("{FFFFFF}/%s {A9A9A9}- ñòðîê: %d, ïàóçà %d ìñ", n, #binds[n].lines, binds[n].delay)
    end
    uiShow(D_MAIN, "FH | Áèíäåð", table.concat(t, "\n"), "Âûáðàòü", "Çàêðûòü", 2)
end

local function uiBind()
    if not binds[ui.sel] then return uiMain() end
    uiShow(D_BIND, "Áèíä /" .. ui.sel,
        "Çàïóñòèòü\nÏîêàçàòü ñòðîêè\nÄîáàâèòü ñòðîêè\nÓäàëèòü ñòðîêó\nÈçìåíèòü ïàóçó\n{FF3333}Óäàëèòü áèíä\nÍàçàä",
        "Âûáðàòü", "Çàêðûòü", 2)
end

local function uiAddPrompt()
    uiShow(D_ADD, "Áèíä /" .. ui.sel .. " | Äîáàâèòü ñòðîêè",
        "Ââåäèòå òåêñò ñòðîêè (êîìàíäà èëè ñîîáùåíèå).\nÍåñêîëüêî ñòðîê ñðàçó ðàçäåëÿéòå {FFFF00};;\n{A9A9A9}Ïîäñòàíîâêè: {id} - ID, {arg} - òåêñò ïîñëå êîìàíäû.",
        "Äîáàâèòü", "Íàçàä", 1)
end

uiHandlers[D_MAIN] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NAME, "Íîâûé áèíä", "Ââåäèòå èìÿ êîìàíäû (ëàòèíèöà, öèôðû, _):", "Äàëåå", "Íàçàä", 1)
    else
        ui.sel = ui.names[list]
        uiBind()
    end
end

uiHandlers[D_NAME] = function(button, _, input)
    if button == 0 then return uiMain() end
    local name = trim(input):lower()
    if not name:match("^[%w_]+$") or #name > 20 then
        bmsg("Èìÿ: ëàòèíèöà, öèôðû è _ (äî 20 ñèìâîëîâ).")
        return uiShow(D_NAME, "Íîâûé áèíä", "{FF3333}Íåâåðíîå èìÿ!\n{FFFFFF}Ëàòèíèöà, öèôðû, _ (äî 20 ñèìâîëîâ):", "Äàëåå", "Íàçàä", 1)
    end
    if bindBuiltin[name] or BIND_RESERVED[name] then
        bmsg("Èìÿ /" .. name .. " çàíÿòî êîìàíäîé õåëïåðà.")
        return uiShow(D_NAME, "Íîâûé áèíä", "{FF3333}Èìÿ çàíÿòî êîìàíäîé õåëïåðà!\n{FFFFFF}Ââåäèòå äðóãîå:", "Äàëåå", "Íàçàä", 1)
    end
    ui.sel = name
    uiAddPrompt()
end

uiHandlers[D_ADD] = function(button, _, input)
    if button == 0 then return binds[ui.sel] and uiBind() or uiMain() end
    local ok, msg, name = bindAdd(ui.sel, input)
    bmsg(msg)
    if ok then ui.sel = name uiBind() else uiAddPrompt() end
end

uiHandlers[D_BIND] = function(button, list)
    if button == 0 then return end
    local b = binds[ui.sel]
    if not b then return uiMain() end
    if list == 0 then
        runBind(ui.sel, "")
    elseif list == 1 then
        local t = {}
        for i, l in ipairs(b.lines) do t[i] = string.format("{FFFF00}%d. {FFFFFF}%s", i, l) end
        uiShow(D_SHOW, "Áèíä /" .. ui.sel .. " | Ñòðîêè", table.concat(t, "\n"), "Íàçàä", "", 0)
    elseif list == 2 then uiAddPrompt()
    elseif list == 3 then
        local t = {}
        for i, l in ipairs(b.lines) do t[i] = i .. ". " .. l end
        uiShow(D_LINES, "Áèíä /" .. ui.sel .. " | Êàêóþ ñòðîêó óäàëèòü?", table.concat(t, "\n"), "Óäàëèòü", "Íàçàä", 2)
    elseif list == 4 then
        uiShow(D_DELAY, "Áèíä /" .. ui.sel .. " | Ïàóçà",
            string.format("Ïàóçà ìåæäó ñòðîêàìè â ìñ (300-10000).\nÑåé÷àñ: %d", b.delay), "Ãîòîâî", "Íàçàä", 1)
    elseif list == 5 then
        uiShow(D_CONF, "Óäàëåíèå áèíäà", "Óäàëèòü áèíä /" .. ui.sel .. " öåëèêîì?", "Äà", "Íåò", 0)
    else uiMain() end
end

uiHandlers[D_SHOW] = function() uiBind() end

uiHandlers[D_LINES] = function(button, list)
    local b = binds[ui.sel]
    if button == 1 and b and b.lines[list + 1] then
        table.remove(b.lines, list + 1)
        if #b.lines == 0 then
            bindDelete(ui.sel)
            bmsg("Ñòðîê íå îñòàëîñü, áèíä óäàë¸í.")
            return uiMain()
        end
        saveBinds()
        bmsg("Ñòðîêà óäàëåíà.")
    end
    uiBind()
end

uiHandlers[D_DELAY] = function(button, _, input)
    local ms = tonumber(trim(input))
    if button == 1 and binds[ui.sel] then
        if ms and ms >= 300 and ms <= 10000 then
            binds[ui.sel].delay = math.floor(ms)
            saveBinds()
            bmsg(string.format("Ïàóçà áèíäà /%s: %d ìñ.", ui.sel, ms))
        else bmsg("Íóæíî ÷èñëî îò 300 äî 10000.") end
    end
    uiBind()
end

uiHandlers[D_CONF] = function(button)
    if button == 1 and binds[ui.sel] then
        bindDelete(ui.sel)
        bmsg("Áèíä /" .. ui.sel .. " óäàë¸í.")
        return uiMain()
    end
    uiBind()
end

-- âûçûâàåòñÿ èç ãëàâíîãî öèêëà
local function uiTick()
    local id = ui.open
    if id and sampHasDialogRespond(id) then
        ui.open = nil
        local button, list, input = sampGetDialogResponse(id)
        input = fromGame(input or "")
        local h = uiHandlers[id]
        local ok, err = true, nil
        if h then ok, err = pcall(h, button, list, input or "") end
        if not ok then print("[FH] binder UI error: " .. tostring(err)) end
    end
end

local function setupBinder(builtin, reg)
    bindBuiltin, bindReg = builtin, reg
    builtin.bnd, builtin.binder, builtin.fbind = true, true, true
    loadBinds()

    reg("binder", bindHelp)
    reg("fbind", uiMain)
    reg("bnd", function(param)
        local sub, rest = (param or ""):match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local name, text = rest:match("^(%S+)%s+(.+)$")
            if not name then bmsg("Èñïîëüçîâàíèå: /bnd add èìÿ òåêñò") return end
            local _, msg = bindAdd(name, text)
            bmsg(msg)
        elseif sub == "del" then
            local name = trim(rest):lower()
            if not binds[name] then bmsg("Áèíä íå íàéäåí: " .. name) return end
            binds[name] = nil
            pcall(sampUnregisterChatCommand, name)
            saveBinds()
            bmsg("Áèíä /" .. name .. " óäàë¸í.")
        elseif sub == "rm" then
            local name, n = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            local b = name and binds[name]
            n = tonumber(n)
            if not b or not b.lines[n] then bmsg("Èñïîëüçîâàíèå: /bnd rm èìÿ N (íîìåð ñòðîêè èç /bnd show)") return end
            table.remove(b.lines, n)
            if #b.lines == 0 then
                binds[name] = nil
                pcall(sampUnregisterChatCommand, name)
                bmsg("Ñòðîê íå îñòàëîñü, áèíä /" .. name .. " óäàë¸í.")
            else bmsg("Ñòðîêà " .. n .. " óäàëåíà.") end
            saveBinds()
        elseif sub == "delay" then
            local name, ms = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            ms = tonumber(ms)
            if not name or not binds[name] or not ms or ms < 300 or ms > 10000 then
                bmsg("Èñïîëüçîâàíèå: /bnd delay èìÿ ìñ (300-10000)") return
            end
            binds[name].delay = ms
            saveBinds()
            bmsg(string.format("Ïàóçà áèíäà /%s: %d ìñ.", name, ms))
        elseif sub == "show" then
            local name = trim(rest):lower()
            local b = binds[name]
            if not b then bmsg("Áèíä íå íàéäåí: " .. name) return end
            bmsg(string.format("/%s (ïàóçà %d ìñ):", name, b.delay))
            for i, l in ipairs(b.lines) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, l), -1) end
        elseif sub == "list" then
            local names = sortedBindNames()
            if #names == 0 then bmsg("Áèíäîâ ïîêà íåò. Ñïðàâêà: /binder") return end
            bmsg("Âàøè áèíäû: /" .. table.concat(names, ", /"))
        else
            bindHelp()
        end
    end)
end


----------------------------------------------------------------------
-- ÍÀÑÒÐÎÉÊÈ, ØÀÁËÎÍÛ ÎÒÂÅÒÎÂ, ÀÂÒÎ-/mp
----------------------------------------------------------------------
local LITE_DEFAULT = false   -- íà ÏÊ ïî óìîë÷àíèþ ïîëíûé ñòèëü
local cfg = {
    automp = true,                  -- ïîñëå àíîíñà ÌÏ ââîäèòü /mp è íàæèìàòü 1-þ ñòðîêó
    accent = { 0.26, 0.62, 0.96 },  -- öâåò àêöåíòà îêíà
    bg = { 0.07, 0.08, 0.10 },      -- öâåò ôîíà îêíà
    alpha = 0.97,                   -- ïðîçðà÷íîñòü ôîíà
    glass = true,                   -- ñòèëü Liquid Glass (ñòåêëî)
    tagmode = 2,                    -- ìåòêà íàä èãðîêîì: 0 - imgui, 1 - render (çàïàñíîé)
    autoupd = true,                 -- ïðîâåðÿòü îáíîâëåíèÿ ïðè çàïóñêå
    reptoast = true,                -- îâàëüíîå óâåäîìëåíèå î ðåïîðòå
    intro = true,                   -- àíèìàöèÿ îòêðûòèÿ îêíà (òîëüêî ïðè ïåðâîì çàïóñêå)
    introDone = false,              -- àíèìàöèÿ óæå ïîêàçàíà
    lite = LITE_DEFAULT,            -- ë¸ãêèé ðåæèì: áåç áëèêîâ è ïðîçðà÷íîñòè (ìåíüøå ëàãîâ)
    aiUrl = "https://api.openai.com/v1/chat/completions",
    aiKey = "",
    aiModel = "gpt-4o-mini",
    aiPrompt = "Òû ïîìîùíèê àäìèíèñòðàòîðà SA-MP ñåðâåðà. Îòâåòü èãðîêó íà ðåïîðò âåæëèâî è ïî äåëó îäíèì êîðîòêèì ñîîáùåíèåì (äî 100 ñèìâîëîâ), áåç markdown. Åñëè äàííûõ ìàëî - ïîïðîñè óòî÷íèòü ID íàðóøèòåëÿ. Íå âûäóìûâàé ïðàâèëà è íå îáåùàé íàêàçàíèé.",
}

local function configDir()
    local dir = getWorkingDirectory() .. "/config"
    pcall(createDirectory, dir)
    return dir
end

local function clamp01(v, default)
    v = tonumber(v)
    if not v then return default end
    return math.max(0, math.min(1, v))
end

local function saveCfg()
    pcall(function()
        local f = assert(io.open(configDir() .. "/FilippHelper_settings.txt", "wb"))
        f:write("automp=", cfg.automp and "1" or "0", "\r\n")
        f:write(string.format("accent=%.3f,%.3f,%.3f\r\n", cfg.accent[1], cfg.accent[2], cfg.accent[3]))
        f:write(string.format("bg=%.3f,%.3f,%.3f\r\n", cfg.bg[1], cfg.bg[2], cfg.bg[3]))
        f:write(string.format("alpha=%.3f\r\n", cfg.alpha))
        f:write("glass=", cfg.glass and "1" or "0", "\r\n", "lite=", cfg.lite and "1" or "0", "\r\n", "tagmode=", tostring(cfg.tagmode), "\r\n", "intro=", cfg.intro and "1" or "0", "\r\n", "reptoast=", cfg.reptoast and "1" or "0", "\r\n", "introdone=", cfg.introDone and "1" or "0", "\r\n", "autoupd=", cfg.autoupd and "1" or "0", "\r\n")
        f:write("aiurl=", cfg.aiUrl, "\r\n", "aikey=", cfg.aiKey, "\r\n", "aimodel=", cfg.aiModel, "\r\n")
        f:write("aiprompt=", (cfg.aiPrompt:gsub("[\r\n]+", " ")), "\r\n")
        f:close()
    end)
end

local function loadCfg()
    local ok, err = pcall(function()
        local f = io.open(configDir() .. "/FilippHelper_settings.txt", "rb")
        if not f then return end
        for line in f:lines() do
            line = line:gsub("\r$", "")
            local k, v = line:match("^(%w+)=(.+)$")
            if k == "automp" then cfg.automp = (v == "1")
            elseif k == "glass" then cfg.glass = (v == "1")
            elseif k == "lite" then cfg.lite = (v == "1")
            elseif k == "tagmode" then cfg.tagmode = (tonumber(v) == 1) and 1 or 0
            elseif k == "intro" then cfg.intro = (v == "1")
            elseif k == "reptoast" then cfg.reptoast = (v == "1")
            elseif k == "introdone" then cfg.introDone = (v == "1")
            elseif k == "autoupd" then cfg.autoupd = (v == "1")
            elseif k == "aiurl" then cfg.aiUrl = v
            elseif k == "aikey" then cfg.aiKey = v
            elseif k == "aimodel" then cfg.aiModel = v
            elseif k == "aiprompt" then cfg.aiPrompt = v
            elseif k == "alpha" then cfg.alpha = math.max(0.5, clamp01(v, cfg.alpha))
            elseif k == "accent" or k == "bg" then
                local r, g, b = v:match("^([%d%.]+),([%d%.]+),([%d%.]+)$")
                if r then cfg[k] = { clamp01(r, cfg[k][1]), clamp01(g, cfg[k][2]), clamp01(b, cfg[k][3]) } end
            end
        end
        f:close()
    end)
    if not ok then print("[FH] settings load error: " .. tostring(err)) end
end

-- Øàáëîíû îòâåòîâ íà ðåïîðòû
local templates = {}
local TPL_MAX, TPL_LEN = 30, 120
local DEFAULT_TEMPLATES = {
    "Çäðàâñòâóéòå! Âàøà æàëîáà ïðèíÿòà, ðàçáèðàåìñÿ.",
    "Ïåðåäàíî íà ðàññìîòðåíèå ñòàðøåé àäìèíèñòðàöèè.",
    "Óòî÷íèòå, ïîæàëóéñòà: ID íàðóøèòåëÿ è ÷òî ïðîèçîøëî.",
    "Íàðóøåíèé íå îáíàðóæåíî.",
    "Èãðîê íàêàçàí, ñïàñèáî çà îáðàùåíèå!",
    "Ñ òàêèì âîïðîñîì îáðàòèòåñü íà ôîðóì ïðîåêòà.",
    "Ïðèÿòíîé èãðû íà íàøåì ñåðâåðå!",
}

local function saveTemplates()
    pcall(function()
        local f = assert(io.open(configDir() .. "/FilippHelper_templates.txt", "wb"))
        for _, t in ipairs(templates) do f:write("> ", t, "\r\n") end
        f:close()
    end)
end

local function loadTemplates()
    local ok, err = pcall(function()
        local f = io.open(configDir() .. "/FilippHelper_templates.txt", "rb")
        if f then
            for line in f:lines() do
                line = line:gsub("\r$", "")
                if line:sub(1, 2) == "> " and #templates < TPL_MAX then templates[#templates + 1] = line:sub(3, TPL_LEN + 2) end
            end
            f:close()
        end
    end)
    if not ok then print("[FH] templates load error: " .. tostring(err)) end
    if #templates == 0 then
        for i, t in ipairs(DEFAULT_TEMPLATES) do templates[i] = t end
    end
end

local function tplAdd(text)
    text = trim((text or ""):gsub("%c", " "))
    if text == "" then return false, "Ïóñòîé øàáëîí." end
    if #templates >= TPL_MAX then return false, "Ëèìèò øàáëîíîâ: " .. TPL_MAX end
    templates[#templates + 1] = text:sub(1, TPL_LEN)
    saveTemplates()
    return true, "Øàáëîí äîáàâëåí (âñåãî " .. #templates .. ")."
end

-- Àâòî-/mp: ââåñòè /mp è íàæàòü ïåðâóþ ñòðîêó îòêðûâøåãîñÿ ñïèñêà
local autoMp = { armed = false, t0 = 0 }
local function armAutoMp(force)
    if not force and not cfg.automp then return end
    autoMp.armed, autoMp.t0 = true, os.clock()
    safeSend("/mp")
end

----------------------------------------------------------------------
-- ÑÏÈÑÎÊ ÐÅÏÎÐÒÎÂ ÈÇ /define
-- /rpl (èëè êíîïêà â /fh) øë¸ò /define, ïåðåõâàòûâàåò äèàëîã ñî ñïèñêîì,
-- ðàçáèðàåò åãî è çàìåíÿåò èì ñïèñîê ðåïîðòîâ. Ñàì äèàëîã íå ïîêàçûâàåòñÿ.
-- Ñûðîé òåêñò äèàëîãà ñîõðàíÿåòñÿ â config/FilippHelper_define.txt.
----------------------------------------------------------------------
local DEF = { waiting = false, t0 = 0, user = nil, token = 0 }

local function defineParse(text)
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("{%x%x%x%x%x%x}", ""):gsub("[\t\r]", " ")
        local name, id, body = line:match("([A-Za-z][A-Za-z0-9_%.]*)%[(%d+)%]%s*[:%-%)]*%s*(.*)")
        if not name then name, id, body = line:match("([A-Za-z][A-Za-z0-9_%.]*)%s*%((%d+)%)%s*[:%-]*%s*(.*)") end
        if name and #list < MAX_REPORTS then list[#list + 1] = { name = name, id = id, text = trim(body or "") } end
    end
    return list
end

-- âûçûâàåòñÿ èç onShowDialog; ours - äèàëîã âûçâàí íàøèì çàïðîñîì (åãî ïðÿ÷åì)
function DEF.onDialog(id, title, text, ours)
    DEF.waiting = false
    pcall(function()
        local f = io.open(configDir() .. "/FilippHelper_define.txt", "wb")
        if f then f:write(tostring(title or ""), "\n", tostring(text or "")) f:close() end
    end)
    local list = defineParse(fromGame(tostring(text or "")))
    if #list == 0 then
        fmsg("Íå óäàëîñü ðàçîáðàòü /define. Ôîðìàò çàïèñàí â config/FilippHelper_define.txt - ïðèøëèòå ýòîò ôàéë ðàçðàáîò÷èêó.")
    else
        for i = #reports, 1, -1 do reports[i] = nil end
        for _, r in ipairs(list) do reports[#reports + 1] = r end
        fmsg("Ñïèñîê ðåïîðòîâ îáíîâë¸í èç /define: " .. #list .. ".")
    end
    if ours then
        lua_thread.create(function() wait(100) pcall(sampSendDialogResponse, id, 0, -1, "") end)
        return false
    end
end

function DEF.refresh()
    if DEF.waiting then return end
    DEF.waiting, DEF.t0 = true, os.clock()
    DEF.token = DEF.token + 1
    local my = DEF.token
    safeSend("/define")
    lua_thread.create(function()
        wait(5000)
        if DEF.waiting and DEF.token == my then
            DEF.waiting = false
            fmsg("/define íå îòâåòèë (íåò äîñòóïà èëè äðóãîé ôîðìàò).")
        end
    end)
end

-- ïîäáèðàåò ïóíêò ñïèñêà ïðè÷èí îò ñåðâåðà ïî ñëîâàì èç íàøåé ïðè÷èíû
function PUN.handle(id, style, text)
    local p = PUN.pending
    if not p then return false end
    if os.clock() - p.t > 12 then PUN.pending = nil return false end
    if style == 1 then
        local reasonG = toGame(p.reason)
        PUN.pending = nil
        lua_thread.create(function() wait(150) pcall(sampSendDialogResponse, id, 1, 0, reasonG) end)
        return false
    end
    if style ~= 2 and style ~= 4 then return false end
    local words = {}
    for w in lower1251(p.reason):gmatch("[^%s%.,!%?%-%(%)%[%]:;\"']+") do
        if #w >= 6 then words[#words + 1] = w end
    end
    if #words == 0 then return false end
    local best, bestScore, idx = nil, 0, -1
    local body = fromGame(tostring(text or "")):gsub("{%x%x%x%x%x%x}", "")
    local i = 0
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local low = lower1251(line)
        local score = 0
        for _, w in ipairs(words) do if low:find(w, 1, true) then score = score + 1 end end
        if score > bestScore then best, bestScore, idx = line, score, i end
        i = i + 1
    end
    if not best then return false end
    PUN.pending = nil
    lua_thread.create(function() wait(150) pcall(sampSendDialogResponse, id, 1, idx, "") end)
    fmsg("Ïðè÷èíà âûáðàíà: " .. trim(best))
    return true
end

function ev.onShowDialog(id, style, title, b1, b2, text)
    if PUN.pending and PUN.handle(id, style, text) then return false end
    local ours = DEF.waiting and os.clock() - DEF.t0 < 6
    if ours or (DEF.user and os.clock() - DEF.user < 3) then
        DEF.user = nil
        local okD, res = pcall(DEF.onDialog, id, title, text, ours)
        if okD and res == false then return false end
    end
    if not autoMp.armed then return end
    if os.clock() - autoMp.t0 > 6 then autoMp.armed = false return end
    if style ~= 2 and style ~= 4 and style ~= 5 then return end   -- òîëüêî ñïèñêè
    autoMp.armed = false
    lua_thread.create(function()
        wait(150)
        pcall(sampSendDialogResponse, id, 1, 0, "")
    end)
    return false
end

loadCfg()
loadTemplates()

----------------------------------------------------------------------
-- ÐÅÏÎÐÒÛ: æóðíàë ïîñëåäíèõ îáðàùåíèé è áûñòðûé îòâåò
----------------------------------------------------------------------
local D_MENU, D_RLIST, D_RREPLY, D_GWSTART = 4120, 4121, 4122, 4123

local function replyTo(id, text)
    text = trim(text or "")
    if text == "" then return false end
    safeSend(string.format("/pm %s %s", id, text))
    return true
end

----------------------------------------------------------------------
-- ÈÈ-ÏÎÄÑÊÀÇÊÀ ÎÒÂÅÒÀ ÍÀ ÐÅÏÎÐÒ (ëþáîé ñåðâèñ ñ OpenAI-ñîâìåñòèìûì API)
-- Íóæíû áèáëèîòåêè effil è requests. Êëþ÷ õðàíèòñÿ òîëüêî â config/FilippHelper_settings.txt.
----------------------------------------------------------------------
local AI = { busy = false, status = "", result = nil }

function AI.ready() return trim(cfg.aiKey or "") ~= "" and trim(cfg.aiUrl or "") ~= "" end

local function aiClean(text)
    text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    return trim(text)
end

-- ìèíè-JSON íà ñëó÷àé, åñëè â çàãðóç÷èêå íåò encodeJson/decodeJson
local function u8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local JSON_ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

function AI.jsonEncode(v)
    local t = type(v)
    if t == "string" then
        return '"' .. (v:gsub('[%c"\\]', function(c) return JSON_ESC[c] or string.format("\\u%04x", c:byte()) end)) .. '"'
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "table" then
        local out = {}
        if #v > 0 then
            for i = 1, #v do out[i] = AI.jsonEncode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, x in pairs(v) do out[#out + 1] = AI.jsonEncode(tostring(k)) .. ":" .. AI.jsonEncode(x) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end

function AI.jsonDecode(s)
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
    local val
    local function str()
        local out, i = {}, pos + 1
        while true do
            local j = s:find('["\\]', i)
            if not j then error("bad json string") end
            out[#out + 1] = s:sub(i, j - 1)
            if s:sub(j, j) == '"' then pos = j + 1 return table.concat(out) end
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local cp = tonumber(s:sub(j + 2, j + 5), 16) or error("bad json escape")
                i = j + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
                    local lo = tonumber(s:sub(i + 2, i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00) i = i + 6 end
                end
                out[#out + 1] = u8char(cp)
            else
                out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[e] or e
                i = j + 2
            end
        end
    end
    function val()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local o = {}
            pos = pos + 1 ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return o end
            while true do
                ws()
                local k = str() ws()
                if s:sub(pos, pos) ~= ":" then error("bad json object") end
                pos = pos + 1
                o[k] = val() ws()
                local d = s:sub(pos, pos) pos = pos + 1
                if d == "}" then return o elseif d ~= "," then error("bad json object") end
            end
        elseif c == "[" then
            local a = {}
            pos = pos + 1 ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return a end
            while true do
                a[#a + 1] = val() ws()
                local d = s:sub(pos, pos) pos = pos + 1
                if d == "]" then return a elseif d ~= "," then error("bad json array") end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil end
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not num or num == "" then error("bad json value") end
        pos = pos + #num
        return tonumber(num)
    end
    return val()
end

-- îòïðàâêà POST-çàïðîñà; âûçûâàåòñÿ èç ïîòîêà lua_thread. Âîçâðàùàåò êîä, òåêñò èëè nil, îøèáêà.
-- Ïåðåáèðàåì ñïîñîáû: effil+requests (áåç ïîäâèñàíèé) -> requests -> ssl.https -> curl.
function AI.http(url, key, body, method)
    method = method or "POST"
    body = body or ""
    local function mkHeaders()
        local h = {}
        if method ~= "GET" then h["Content-Type"] = "application/json" end
        if key ~= "" then h["Authorization"] = "Bearer " .. key end
        return h
    end
    local okE, effil = pcall(require, "effil")
    if okE and type(effil) == "table" and pcall(require, "requests") then
        local runner = effil.thread(function(u, k, payload, m)
            local requests = require "requests"
            local h = {}
            if m ~= "GET" then h["Content-Type"] = "application/json" end
            if k ~= "" then h["Authorization"] = "Bearer " .. k end
            local opts = { headers = h }
            if payload ~= "" then opts.data = payload end
            local okR, res = pcall(requests.request, m, u, opts)
            if not okR then return 0, tostring(res) end
            return res.status_code or 0, res.text or ""
        end)
        local h = runner(url, key, body, method)
        local t0 = os.clock()
        while true do
            local st = h:status()
            if st == "completed" then break end
            if st == "failed" or st == "canceled" then return nil, "çàïðîñ íå âûïîëíåí" end
            if os.clock() - t0 > 40 then pcall(function() h:cancel() end) return nil, "òàéìàóò îòâåòà (40 ñ)" end
            wait(100)
        end
        return h:get()
    end
    local okR, requests = pcall(require, "requests")
    if okR and type(requests) == "table" and requests.request then
        local opts = { headers = mkHeaders() }
        if body ~= "" then opts.data = body end
        local ok, res = pcall(requests.request, method, url, opts)
        if ok and type(res) == "table" then return res.status_code or 0, res.text or "" end
    end
    local okS, https = pcall(require, "ssl.https")
    local okL, ltn12 = pcall(require, "ltn12")
    if okS and okL and type(https) == "table" and https.request then
        local chunks = {}
        local headers = mkHeaders()
        local req = { url = url, method = method, headers = headers, sink = ltn12.sink.table(chunks) }
        if body ~= "" then
            headers["Content-Length"] = tostring(#body)
            req.source = ltn12.source.string(body)
        end
        local ok, r1, code = pcall(https.request, req)
        if ok and r1 then return tonumber(code) or 0, table.concat(chunks) end
    end
    if io.popen and not url:find('[%c"\\%s]') and not key:find('[%c"\\%s]') then
        local tmp = configDir() .. "/fh_ai_req.json"
        local cmd
        if method == "GET" then
            cmd = string.format('curl -s -L -m 40 -w "\\n%%{http_code}" "%s"', url)
        else
            local f = io.open(tmp, "wb")
            if f then
                f:write(body) f:close()
                cmd = string.format(
                    'curl -s -L -m 40 -w "\\n%%{http_code}" -X POST "%s" -H "Content-Type: application/json" -H "Authorization: Bearer %s" --data-binary @"%s"',
                    url, key, tmp)
            end
        end
        if cmd then
            local okP, p = pcall(io.popen, cmd)
            if okP and p then
                local out = p:read("*a") or "" p:close()
                pcall(os.remove, tmp)
                local text, code = out:match("^(.*)\n(%d+)%s*$")
                if code then return tonumber(code), text end
            end
            pcall(os.remove, tmp)
        end
    end
    return nil, "íåò ñïîñîáà îòïðàâèòü çàïðîñ (íóæíû effil+requests, ssl.https èëè curl). Êîìàíäà /aidiag ïîêàæåò, ÷òî åñòü"
end

-- çàïðîñ â îòäåëüíîì ïîòîêå; cb(ok, òåêñò_èëè_îøèáêà) âûçûâàåòñÿ èç ýòîãî ïîòîêà
function AI.ask(system, user, cb)
    if AI.busy then cb(false, "ïðåäûäóùèé çàïðîñ åù¸ èä¸ò") return end
    if not AI.ready() then cb(false, "íå çàïîëíåíû àäðåñ API è êëþ÷ (/fh - Íàñòðîéêè èëè /aiset)") return end
    AI.busy = true
    lua_thread.create(function()
        local ok, a, b = pcall(function()
            local enc, dec = encodeJson or AI.jsonEncode, decodeJson or AI.jsonDecode
            local body = enc({
                model = toUi(cfg.aiModel), temperature = 0.3, max_tokens = 220,
                messages = {
                    { role = "system", content = toUi(system) },
                    { role = "user", content = toUi(user) },
                },
            })
            local url = trim(cfg.aiUrl):gsub("/+$", "")
            if url:match("/v1$") then url = url .. "/chat/completions" end   -- àäðåñ âèäà .../v1 äîïîëíÿåì ñàìè
            local code, text = AI.http(url, trim(cfg.aiKey), body)
            if not code then return false, text end
            if code == 0 then return false, "íåò ñâÿçè: " .. tostring(text):sub(1, 80) end
            local okJ, data = pcall(dec, text)
            if not okJ or type(data) ~= "table" then return false, "îòâåò íå JSON (êîä " .. tostring(code) .. ")" end
            if type(data.error) == "table" and data.error.message then return false, "API: " .. tostring(data.error.message):sub(1, 100) end
            local msg = data.choices and data.choices[1] and data.choices[1].message
            local content = msg and msg.content
            if type(content) ~= "string" or content == "" then return false, "ïóñòîé îòâåò (êîä " .. tostring(code) .. ")" end
            return true, aiClean(fromUi(content))
        end)
        AI.busy = false
        if not ok then a, b = false, tostring(a) end
        pcall(cb, a, b)
    end)
end

-- /aidiag: ÷òî äîñòóïíî â çàãðóç÷èêå äëÿ çàïðîñîâ ê API
function AI.diag()
    local names = { "effil", "requests", "ssl.https", "ltn12", "socket", "copas", "cjson", "dkjson", "lib.requests" }
    local have, miss = {}, {}
    for _, n in ipairs(names) do
        if pcall(require, n) then have[#have + 1] = n else miss[#miss + 1] = n end
    end
    fmsg("Åñòü: " .. (#have > 0 and table.concat(have, ", ") or "íè÷åãî"))
    fmsg("Íåò: " .. table.concat(miss, ", "))
    fmsg("encodeJson: " .. (encodeJson and "äà" or "íåò (ìèíè-JSON)") .. ", io.popen: " .. (io.popen and "äà" or "íåò"))
end

function AI.suggest(r, cb)
    AI.status = "ÈÈ äóìàåò..."
    AI.ask(cfg.aiPrompt, "Ðåïîðò îò èãðîêà " .. r.name .. ": " .. r.text, function(ok, text)
        AI.status = ok and "Îòâåò ãîòîâ, ïðîâåðüòå è îòïðàâüòå." or ("Îøèáêà: " .. tostring(text))
        if ok then AI.result = { id = r.id, text = text } end
        cb(ok, text)
    end)
end

function AI.test()
    AI.status = "Ïðîâåðÿþ ñâÿçü..."
    AI.ask(cfg.aiPrompt, "Ïðèâåò! Îòâåòü îäíèì êîðîòêèì ïðåäëîæåíèåì.", function(ok, text)
        AI.status = ok and ("Ðàáîòàåò: " .. text) or ("Îøèáêà: " .. tostring(text))
    end)
end

-- /ai [ID]: ïîäñêàçêà ïî ðåïîðòó, òåêñò ïîïàäàåò â ñòðîêó ââîäà êàê /rr ID òåêñò
function AI.cmdAsk(p)
    local id = (p or ""):match("^(%d+)")
    local r
    for _, x in ipairs(reports) do
        if not id or x.id == id then r = x break end
    end
    if not r then fmsg("Ðåïîðò íå íàéäåí. Ñïèñîê: /reports") return end
    fmsg("Ñïðàøèâàþ ÈÈ ïðî ðåïîðò îò " .. r.name .. "...")
    AI.suggest(r, function(ok, text)
        fmsg("ÈÈ: " .. tostring(text))
        if ok then
            sampSetChatInputText("/rr " .. r.id .. " " .. text)
            sampSetChatInputEnabled(true)
        end
    end)
end

local AI_FIELDS = { url = "aiUrl", key = "aiKey", model = "aiModel", prompt = "aiPrompt" }
function AI.cmdSet(p)
    local k, v = (p or ""):match("^(%S+)%s*(.*)$")
    local f = k and AI_FIELDS[lower1251(k)]
    v = trim(v or "")
    if not f or v == "" then
        fmsg("/aiset url|key|model|prompt çíà÷åíèå. Ñåé÷àñ: êëþ÷ " .. (trim(cfg.aiKey) ~= "" and "çàäàí" or "íå çàäàí") ..
            ", ìîäåëü " .. cfg.aiModel .. ". Ïðîâåðêà: /ai ID")
        return
    end
    cfg[f] = v:gsub("[\r\n]+", " ")
    saveCfg()
    fmsg("ÈÈ: " .. k .. " ñîõðàíåíî.")
end

----------------------------------------------------------------------
-- ÏÐÎÂÅÐÊÀ ÎÁÍÎÂËÅÍÈÉ ÏÎ GITHUB
-- Â ðåïîçèòîðèè ëåæèò version.txt: 1-ÿ ñòðîêà - âåðñèÿ, 2-ÿ - ÷òî íîâîãî.
----------------------------------------------------------------------
local UPD = {
    base = "https://raw.githubusercontent.com/filippdanko174-bit/inferno-helper/main/",
    file = UPDATE_FILE,
    latest = nil, notes = "", checked = false, busy = false, status = "",
}

local function verParts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

local function verNewer(a, b)   -- a íîâåå b?
    local x, y = verParts(a), verParts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- silent: íå ïèñàòü «ó âàñ ïîñëåäíÿÿ âåðñèÿ»
function UPD.check(silent)
    if UPD.busy then return end
    UPD.busy = true
    UPD.status = "Ïðîâåðÿþ îáíîâëåíèÿ..."
    lua_thread.create(function()
        local ok, code, text = pcall(AI.http, UPD.base .. "version.txt", "", "", "GET")
        UPD.busy = false
        if not ok or not code or code ~= 200 or type(text) ~= "string" then
            UPD.status = "Íå óäàëîñü ïðîâåðèòü îáíîâëåíèÿ."
            if not silent then fmsg("Íå óäàëîñü ïðîâåðèòü îáíîâëåíèÿ (" .. tostring(ok and (code or text) or code) .. ").") end
            return
        end
        local ver, notes = text:match("^%s*([%d%.]+)[^\n]*\n?(.*)$")
        if not ver then UPD.status = "Íå óäàëîñü ðàçîáðàòü version.txt." return end
        UPD.checked, UPD.latest, UPD.notes = true, ver, trim(fromUi((notes or ""):gsub("[\r\n]+", " ")))
        if verNewer(ver, VERSION) then
            UPD.status = "Äîñòóïíà âåðñèÿ " .. ver
            fmsg("{FFD700}Äîñòóïíî îáíîâëåíèå {FFFFFF}v" .. ver .. " {A9A9A9}(ó âàñ v" .. VERSION .. ")")
            if UPD.notes ~= "" then fmsg("{A9A9A9}×òî íîâîãî: {FFFFFF}" .. UPD.notes) end
            fmsg("{A9A9A9}Óñòàíîâèòü: {FFFF00}/fhupd install {A9A9A9}èëè êíîïêà â /fh íà «Ãëàâíîé»")
        else
            UPD.latest = nil
            UPD.status = "Ó âàñ ïîñëåäíÿÿ âåðñèÿ (v" .. VERSION .. ")."
            if not silent then fmsg(UPD.status) end
        end
    end)
end

function UPD.install()
    if UPD.busy then return end
    if not UPD.latest then fmsg("Ñíà÷àëà ïðîâåðüòå îáíîâëåíèÿ: /fhupd") return end
    UPD.busy = true
    UPD.status = "Ñêà÷èâàþ îáíîâëåíèå..."
    fmsg("Ñêà÷èâàþ v" .. UPD.latest .. "...")
    lua_thread.create(function()
        local ok, err = pcall(function()
            local code, text = AI.http(UPD.base .. UPD.file, "", "", "GET")
            if code ~= 200 or type(text) ~= "string" then error("îøèáêà çàãðóçêè (" .. tostring(code) .. ")") end
            if #text < 20000 or not text:find("FilippHelper", 1, true) then error("ôàéë ïîâðåæä¸í èëè íåïîëíûé") end
            local chunk, cerr = (loadstring or load)(text)
            if not chunk then error("ôàéë íå êîìïèëèðóåòñÿ: " .. tostring(cerr)) end
            local path = thisScript().path
            local old = io.open(path, "rb")
            if old then
                local bak = io.open(path .. ".bak", "wb")
                if bak then bak:write(old:read("*a")) bak:close() end
                old:close()
            end
            local f = assert(io.open(path, "wb"))
            f:write(text) f:close()
        end)
        UPD.busy = false
        if ok then
            UPD.status = "Îáíîâëåíî äî v" .. tostring(UPD.latest) .. ", ïåðåçàãðóçêà..."
            fmsg("{66FF66}Îáíîâëåíî äî v" .. tostring(UPD.latest) .. ". Ïåðåçàãðóæàþ ñêðèïò...")
            wait(800)
            pcall(function() thisScript():reload() end)
        else
            UPD.status = "Îøèáêà îáíîâëåíèÿ: " .. tostring(err)
            fmsg("{FF6666}Îáíîâëåíèå íå óäàëîñü: " .. tostring(err))
        end
    end)
end

function UPD.cmd(p)
    p = trim(p or "")
    if p == "install" then UPD.install() else UPD.check(false) end
end

local function uiReports()
    if #reports == 0 then
        fmsg("Ðåïîðòîâ ïîêà íåò.")
        return
    end
    local t = {}
    for i, r in ipairs(reports) do
        t[i] = string.format("{FFFF00}[%s] {FFFFFF}%s: {A9A9A9}%s", r.id, r.name, r.text)
    end
    uiShow(D_RLIST, "FH | Ïîñëåäíèå ðåïîðòû", table.concat(t, "\n"), "Îòâåòèòü", "Çàêðûòü", 2)
end

local D_RTPL = 4147
local function findReport(id)
    for _, r in ipairs(reports) do if r.id == id then return r end end
end

local function uiTemplatesFor(r)
    local t = { "{33CC33}Íàïèñàòü ñâîé îòâåò" }
    for _, x in ipairs(templates) do t[#t + 1] = "{FFFFFF}" .. x end
    uiShow(D_RTPL, "Îòâåò: " .. r.name .. "[" .. r.id .. "]", table.concat(t, "\n"), "Îòïðàâèòü", "Íàçàä", 2)
end

uiHandlers[D_RLIST] = function(button, list)
    if button == 0 then return end
    local r = reports[list + 1]
    if not r then return uiReports() end
    ui.replyId = r.id
    uiTemplatesFor(r)
end

uiHandlers[D_RTPL] = function(button, list)
    local r = ui.replyId and findReport(ui.replyId)
    if button == 0 or not r then return uiReports() end
    if list == 0 then
        uiShow(D_RREPLY, "Îòâåò èãðîêó " .. r.name .. "[" .. r.id .. "]",
            "Æàëîáà: " .. r.text .. "\n\nÂâåäèòå îòâåò (óéä¸ò ÷åðåç /pm):", "Îòïðàâèòü", "Íàçàä", 1)
    elseif templates[list] then
        replyTo(r.id, templates[list])
    end
end

uiHandlers[D_RREPLY] = function(button, _, input)
    if button == 1 and ui.replyId and replyTo(ui.replyId, input) then return end
    uiReports()
end

----------------------------------------------------------------------
-- ÐÀÇÄÀ×À ÏÐÈÇÎÂ
----------------------------------------------------------------------
local gw = { active = false, last = false, word = "", prize = "", stat = nil, amount = nil, t0 = 0 }
local GW_TAG = "[Ðàçäà÷à]"
local GW_IGNORE_NAMES = { Admin = true, Utka_News = true }

-- {íîìåð ñòàòû íà ñåðâåðå, íàçâàíèÿ ïðèçà...}
local PRIZE_TYPES = {
    { 7,  "bank", "áàíê", "äåíüãè", "money", "ðóá" },
    { 1,  "lvl", "ëâë", "óðîâåíü", "level" },
    { 3,  "mat", "ìàò" },
    { 6,  "exp", "îïûò" },
    { 2,  "çàêîí" },
    { 5,  "sim", "ñèì", "íîìåð" },
    { 12, "box", "áîêñ" },
    { 13, "kung", "êóíã" },
    { 14, "kick", "êèê" },
}

-- "áàíê 500.000" -> 7, "500000"; "#9 15" -> 9, "15"; íå ðàñïîçíàíî -> nil
local function parsePrize(spec)
    local low = lower1251(spec)
    local word, rest = low:match("^(%S+)%s*(.*)$")
    if not word then return nil end
    local stat
    local raw = word:match("^#(%d+)$")
    if raw then stat = tonumber(raw)
    else
        for _, t in ipairs(PRIZE_TYPES) do
            for k = 2, #t do
                if word:find(t[k], 1, true) == 1 then stat = t[1] break end
            end
            if stat then break end
        end
    end
    local num = rest:match("^%d[%d%.,]*%d") or rest:match("^%d+")
    if not stat or not num then return nil end
    return stat, (num:gsub("[%.,]", ""))
end

local function gwFinish(name, id)
    gw.active = false
    local isLast = gw.last
    gw.last = false
    local sec = math.max(1, math.floor(os.clock() - gw.t0 + 0.5))
    local lines = { string.format("/aad %s Ïîáåäèòåëü - %s! Âðåìÿ: %d ñåê.", GW_TAG, name, sec) }
    if gw.stat then
        lines[#lines + 1] = string.format("/pm %s Ïîçäðàâëÿþ, âû ïåðâûé! Ïðèç ñåé÷àñ áóäåò âûäàí.", id)
        lines[#lines + 1] = string.format("/setstat %s %d %s", id, gw.stat, gw.amount)
        lines[#lines + 1] = string.format("/pm %s Ïðèç âûäàí, ïðèÿòíîé èãðû!", id)
    else
        fmsg(string.format("{FFFF00}Âûäàéòå ïðèç âðó÷íóþ: %s [%s] -> %s", name, id, gw.prize))
        lines[#lines + 1] = string.format("/pm %s Ïîçäðàâëÿþ, âû ïåðâûé! Ïðèç âûäàì â áëèæàéøåå âðåìÿ.", id)
    end
    if isLast then lines[#lines + 1] = "/aad " .. GW_TAG .. " Ðàçäà÷à çàâåðøåíà, ñïàñèáî âñåì çà ó÷àñòèå!" end
    sendSeq(lines, SEND_GAP, nil, SEND_GAP)
end

local function gwParse(param)
    local word, prize = (param or ""):match("^(.-)%s*|%s*(.+)$")
    if not word then return nil end
    word, prize = trim(word), trim(prize)
    if word == "" or prize == "" then return nil end
    return word, prize
end

local function gwStart(param, isLast)
    local word, prize = gwParse(param)
    if not word then
        fmsg("Èñïîëüçîâàíèå: /" .. (isLast and "gwlast" or "gw") .. " ñëîâî | ïðèç   (íàïðèìåð: /gw êîòèê | áàíê 500000)")
        return
    end
    gw.word, gw.prize, gw.last = lower1251(word), prize, isLast
    gw.stat, gw.amount = parsePrize(prize)
    gw.t0 = os.clock()
    gw.active = true
    local head = isLast and "ÔÈÍÀË! " or ""
    sendSeq({
        string.format("/aad %s %sÏðèç: %s", GW_TAG, head, prize),
        string.format("/aad %s Êòî ïåðâûì îòïðàâèò â /rep ñëîâî «%s» - òîò ïîáåäèë!", GW_TAG, word),
    }, SEND_GAP)
    if gw.stat then
        fmsg(string.format("Ðàçäà÷à çàïóùåíà. Ñëîâî: {FFFF00}%s{FFFFFF}. Ïðèç âûäàñòñÿ ñàì (ñòàòà %d, êîë-âî %s).", word, gw.stat, gw.amount))
    else
        fmsg(string.format("Ðàçäà÷à çàïóùåíà. Ñëîâî: {FFFF00}%s{FFFFFF}. Òèï ïðèçà íå ðàñïîçíàí - âûäàâàòü ïðèä¸òñÿ âðó÷íóþ.", word))
    end
end

uiHandlers[D_GWSTART] = function(button, _, input)
    if button == 1 then gwStart(input, false) end
end

----------------------------------------------------------------------
-- ÇÀÍßÒÜ ÇÀÄÀ×Ó: "z ..." íåñêîëüêî ðàç â /a
----------------------------------------------------------------------
local D_Z = 4148
local CLAIM_COUNT = 3
-- {êëþ÷, òåêñò ïîñëå "z "}
local CLAIMS = {
    { "ao", "aad otbor" }, { "oo", "o otbor" }, { "am", "aad mp" }, { "ar", "aad razdacha" },
    { "sp", "spawn" }, { "on", "o nabor" },
}

local function claim(text, count)
    text = trim(text or "")
    if text == "" then return end
    count = math.max(1, math.min(5, tonumber(count) or CLAIM_COUNT))
    local lines = {}
    for i = 1, count do lines[i] = "/a z " .. text end
    sendSeq(lines, SEND_GAP)
end

local function uiClaims()
    local t = {}
    for i, c in ipairs(CLAIMS) do t[i] = string.format("{FFFF00}z %s {A9A9A9}(/z %s)", c[2], c[1]) end
    uiShow(D_Z, "FH | Çàíÿòü", table.concat(t, "\n"), "Çàíÿòü", "Çàêðûòü", 2)
end

uiHandlers[D_Z] = function(button, list)
    if button == 0 then return end
    local c = CLAIMS[list + 1]
    if c then claim(c[2]) end
end

----------------------------------------------------------------------
-- ÌÅÐÎÏÐÈßÒÈß: ãîòîâûå àíîíñû â /aad
----------------------------------------------------------------------
local D_EV, D_FR, D_FRACT, D_NOTES, D_NOTE, D_NOTEADD = 4140, 4141, 4142, 4144, 4145, 4146
local D_EVPRIZE = 4149

-- {êëþ÷, íàçâàíèå, ñòðîêè àíîíñà}. {id} ïîäñòàâëÿåòñÿ äëÿ èíòåðàêòèâíûõ ÌÏ.
local EVENTS = {
    { "svet", "Ñâåòîôîð", "Áåæèì ê ôèíèøó íà «Çåë¸íûé» è çàìèðàåì íà «Êðàñíûé».", "Êòî äâèíóëñÿ íà êðàñíûé - âûëåòàåò. Ïîáåæäàåò ïåðâûé íà ôèíèøå." },
    { "poliv", "Ïîëèâàëêà", "Íóæíî óäåðæàòüñÿ íà êðûøå, ïîêà âàñ ïîëèâàþò èç ÁÒÐ.", "Îðóæèå è òîë÷êè çàïðåùåíû. Ïîáåæäàåò ïîñëåäíèé îñòàâøèéñÿ." },
    { "derbi", "Äåðáè", "Ñàäèìñÿ â ìàøèíû è òàðàíèòåñü íà àðåíå.", "Ïîáåæäàåò òîò, ÷üÿ ìàøèíà îñòàëàñü íà õîäó ïîñëåäíåé." },
    { "pryat", "Ïðÿòêè", "Ïðÿ÷üòåñü îò âåäóùåãî ãäå óãîäíî íà ëîêàöèè.", "Ïî êîìàíäå ìîæíî ïîëüçîâàòüñÿ ìàñêàìè è àíèìàöèÿìè." },
    { "parkur", "Ïàðêóð", "Êòî áûñòðåå âñåõ äîáåð¸òñÿ äî âåðøèíû ïàðêóð-çîíû?", "Áåç îðóæèÿ, ïîìåõ äðóãèì è áàãîâ." },
    { "rulet", "Ðóññêàÿ ðóëåòêà", "Âñòà¸ì â ñòðîé è ïî î÷åðåäè ïûòàåì óäà÷ó.", "Ñòðîé íå íàðóøàòü, îðóæèå è àíèìàöèè íå èñïîëüçîâàòü." },
    { "kovsh", "Ãîíêè îò Êîâøà", "Èãðîêè íà êâàäðîöèêëàõ óâîðà÷èâàþòñÿ îò Ãåëèêà ñ êîâøîì.", "Áàãè, ðåìîíò ìàøèí è ñòîðîííèé ñîôò çàïðåùåíû. Âûæèâàåò ïîñëåäíèé." },
    { "myaso", "Ìÿñîðóáêà", "Áåãàåì ïî ëîêàöèè è óõîäèì îò áåíçîïèëû âåäóùåãî.", "Áåç îðóæèÿ, áðîíè è ìàñîê. Ïîáåæäàåò ïîñëåäíèé âûæèâøèé." },
    { "dogon", "Äîãîíÿëêè", "Âåäóùèé ãîíèòñÿ çà èãðîêàìè.", "Êîãî óäàðèëè êóëàêîì - òîò âûáûë. Àíèìàöèè è áàãè çàïðåùåíû." },
    { "car", "Öàðü ãîðû", "Çàáåðèòåñü íà âåðøèíó ãîðû èç îáúåêòîâ è äåðæèòåñü.", "Òîëüêî êóëàêè, áåç îðóæèÿ è ìàñîê. Ïîáåæäàåò òîò, êòî îñòàëñÿ íàâåðõó." },
    { "parash", "Ïðûæêè ñ ïàðàøþòîì", "Âñå ïîëó÷àþò ïàðàøþòû è ïðèçåìëÿþòñÿ íà ìåòêó âåäóùåãî.", "Ïðîìàçàë èëè ðàçáèëñÿ - âûáûë. Âàæíà òî÷íîñòü." },
    { "digl", "Êîðîëü Äèãëà", "Êàæäîìó âûäà¸òñÿ Deagle.", "Íóæíî óáðàòü âñåõ ñîïåðíèêîâ. Ïîáåæäàåò ïîñëåäíèé æèâîé." },
    { "sultan", "Óâåðíèñü îò Ñóëòàíà", "Èãðîêè â ñòðîþ, âåäóùèé åäåò íà ìàøèíå.", "Êîãî çàäåëè - òîò âûáûë. Íóæíî âîâðåìÿ ïîäïðûãíóòü." },
    { "paint", "Ïåéíòáîë", "Êàæäûé ñàì çà ñåáÿ, ñ÷èòàþòñÿ óáèéñòâà.", "Ïîáåæäàåò òîò, ó êîãî â êîíöå áîëüøå ôðàãìåíòîâ." },
    { "krug", "Êðóã Ñìåðòè", "Èãðîêè âñòàþò êðóãîì, âåäóùèé âûäà¸ò Deagle ñ îäíèì ïàòðîíîì.", "Çàäà÷à - âûñòðåëèòü â îïïîíåíòà." },
    { "infern", "Äîãîíè Èíôåðíóñ", "Íàéäèòå íà êàðòå ×¨ÐÍÛÉ INFERNUS âåäóùåãî è ïåðåäàéòå åìó 1 ðóáëü: /pay {id} 1.", "×èòû è ïîìåõè çàïðåùåíû. Ïîáåæäàåò ïåðâûé, êòî ïåðåäàë." },
}

local function eventByKey(key)
    key = lower1251(key or "")
    for i, e in ipairs(EVENTS) do if e[1] == key then return e, i end end
end

local function announceEvent(e, arg)
    arg = trim(arg or "")
    local needId = false
    for k = 3, #e do if e[k]:find("{id}", 1, true) then needId = true end end
    local id, prize = nil, arg
    if needId then
        local a, b = arg:match("^(%d+)%s*(.*)$")
        if a then id, prize = a, b else id, prize = watchedId, arg end
        if not id then fmsg("Íóæåí ID âåäóùåãî: /ev " .. e[1] .. " ID [ïðèç]") return end
    end
    prize = trim(prize or "")
    local lines = {
        string.format("/aad [ÌÏ] Âíèìàíèå, èãðîêè! Ñêîðî ñòàðòóåò ìåðîïðèÿòèå «%s».", e[2]),
    }
    for k = 3, #e do
        lines[#lines + 1] = "/aad [ÌÏ] " .. e[k]:gsub("{id}", id or "")
    end
    if prize ~= "" then lines[#lines + 1] = "/aad [ÌÏ] Ïðèç ïîáåäèòåëþ: " .. prize .. "." end
    lines[#lines + 1] = "/aad [ÌÏ] Ó÷àñòèå ñâîáîäíîå äëÿ âñåõ. Æäèòå îòêðûòèÿ òåëåïîðòà."
    lines[#lines + 1] = "/aad [ÌÏ] Íàðóøèòåëè ïðàâèë ÌÏ áóäóò óäàëåíû áåç ïðàâà íà ïðèç."
    sendSeq(lines, SEND_GAP, cfg.automp and function() armAutoMp() end or nil)
end

local function uiEvents()
    local t = {}
    for i, e in ipairs(EVENTS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(/ev %s)", e[2], e[1]) end
    uiShow(D_EV, "FH | Ìåðîïðèÿòèÿ", table.concat(t, "\n"), "Îáúÿâèòü", "Çàêðûòü", 2)
end

uiHandlers[D_EV] = function(button, list)
    if button == 0 then return end
    local e = EVENTS[list + 1]
    if not e then return end
    ui.evPick = e
    uiShow(D_EVPRIZE, "FH | Ïðèç äëÿ ÌÏ «" .. e[2] .. "»",
        "{FFFFFF}Ââåäèòå ïðèç (ìîæíî îñòàâèòü ïóñòûì).\n" ..
        (e[1] == "infern" and "{FFCC00}Äëÿ ýòîãî ÌÏ: ID âåäóùåãî, çàòåì ïðèç. Ïðèìåð: 55 5êê\n" or "{A9A9A9}Ïðèìåð: 5êê"),
        "Îáúÿâèòü", "Íàçàä", 1)
end

uiHandlers[D_EVPRIZE] = function(button, _, input)
    local e = ui.evPick
    ui.evPick = nil
    if button == 0 or not e then return uiEvents() end
    announceEvent(e, input or "")
end

----------------------------------------------------------------------
-- ÔÐÀÊÖÈÈ: íàáîðû, îòáîðû íà ëèäåðà, âðåìåííûå ëèäåðêè
----------------------------------------------------------------------
-- {êëþ÷, íàçâàíèå, id äëÿ /templeader, òèï}
local FRACTIONS = {
    { "rus", "Ðóññêàÿ ìàôèÿ", 14, "mafia" }, { "jap", "ßïîíñêàÿ ìàôèÿ", 6, "mafia" }, { "ita", "Èòàëüÿíñêàÿ ìàôèÿ", 5, "mafia" },
    { "fun", "Ïîõîðîííîå áþðî", 23, "mafia" }, { "out", "Outlaws MC", 28, "mafia" },
    { "rif", "Rifa Gang", 18, "gang" }, { "bal", "Ballas Gang", 12, "gang" }, { "azt", "Aztec Gang", 17, "gang" },
    { "gro", "Grove Street", 15, "gang" }, { "vag", "LS Vagos", 13, "gang" },
    { "arm", "Àðìèÿ ËÑ", 3, "gov" }, { "hos", "Áîëüíèöà ËÑ", 4, "gov" }, { "mer", "Ìýðèÿ", 7, "gov" },
    { "rad", "Ðàäèîöåíòð", 16, "gov" }, { "swt", "S.W.A.T", 25, "gov" }, { "gov", "Ïðàâèòåëüñòâî", 26, "gov" },
    { "lsp", "LSPD", 1, "gov" }, { "fbi", "FBI", 2, "gov" }, { "rcp", "RCPD", 27, "gov" }, { "sud", "Âåðõîâíûé ñóä", 29, "gov" },
}
local RULES_BY_KIND = { mafia = "ïðàâèë áèçâàðîâ", gang = "ïðàâèë êàïòîâ", gov = "îáùèõ ïðàâèë ëèäåðîâ" }

local function fractionByKey(key)
    key = lower1251(key or "")
    for _, f in ipairs(FRACTIONS) do if f[1] == key then return f end end
end

local function recruit(f)
    sendSeq({
        "/o [Íàáîð] Âíèìàíèå! Îòêðûò íàáîð â «" .. f[2] .. "».",
        "/o [Íàáîð] Ïîäàéòå çàÿâêó ÷åðåç /rep +.",
    }, 2500)
end

local function tryoutAad(f)
    sendSeq({
        "/aad [Îòáîð] Âíèìàíèå! Ïðîõîäèò îòáîð íà ïîñò ëèäåðà: " .. f[2] .. ".",
        "/aad [Îòáîð] Òðåáîâàíèÿ: âîçðàñò 13+, ñâÿçü ÂÊ, çíàíèå " .. RULES_BY_KIND[f[4]] .. ".",
        "/aad [Îòáîð] Æäèòå îòêðûòèÿ òåëåïîðòà.",
    }, SEND_GAP, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tryoutO(f)
    sendSeq({
        "/o [Îòáîð] Èä¸ò îòáîð íà ïîñò ëèäåðà: " .. f[2] .. ".",
        "/o [Îòáîð] Íóæíî: 13+, ñâÿçü ÂÊ, çíàíèå " .. RULES_BY_KIND[f[4]] .. ".",
        "/o [Îòáîð] Æåëàþùèå - ïèøèòå /gomp.",
    }, 2500, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tempLeader(f) safeSend("/templeader " .. f[3]) end

local function uiFractions()
    local t = {}
    for i, f in ipairs(FRACTIONS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(%s)", f[2], f[1]) end
    uiShow(D_FR, "FH | Ôðàêöèè", table.concat(t, "\n"), "Âûáðàòü", "Çàêðûòü", 2)
end

uiHandlers[D_FR] = function(button, list)
    if button == 0 then return end
    local f = FRACTIONS[list + 1]
    if not f then return uiFractions() end
    ui.fr = list + 1
    uiShow(D_FRACT, f[2],
        "Íàáîð (â îáùèé ÷àò /o)\nÎòáîð íà ëèäåðà (/aad)\nÎòáîð íà ëèäåðà (îáùèé ÷àò /o)\nÂçÿòü âðåìåííóþ ëèäåðêó ñåáå\nÍàçàä",
        "Âûáðàòü", "Çàêðûòü", 2)
end

uiHandlers[D_FRACT] = function(button, list)
    if button == 0 then return end
    local f = FRACTIONS[ui.fr or 0]
    if not f then return uiFractions() end
    if list == 0 then recruit(f)
    elseif list == 1 then tryoutAad(f)
    elseif list == 2 then tryoutO(f)
    elseif list == 3 then tempLeader(f)
    else uiFractions() end
end

----------------------------------------------------------------------
-- ØÏÀÐÃÀËÊÈ: ñâîè çàìåòêè (ïðàâèëà, îòâåòû), õðàíÿòñÿ â ôàéëå
----------------------------------------------------------------------
local notes = {}   -- { {title=, lines={}}, ... }
local NOTE_MAX, NOTE_LINES = 40, 30
local notesFile

local function notesPath()
    if not notesFile then
        local dir = getWorkingDirectory() .. "/config"
        pcall(createDirectory, dir)
        notesFile = dir .. "/FilippHelper_notes.txt"
    end
    return notesFile
end

local function saveNotes()
    local ok = pcall(function()
        local f = assert(io.open(notesPath(), "wb"))
        for _, n in ipairs(notes) do
            f:write("[", n.title, "]\r\n")
            for _, l in ipairs(n.lines) do f:write("> ", l, "\r\n") end
        end
        f:close()
    end)
    if not ok then fmsg("Íå óäàëîñü ñîõðàíèòü çàìåòêè â ôàéë!") end
end

local function loadNotes()
    local ok, err = pcall(function()
        local f = io.open(notesPath(), "rb")
        if not f then return end
        local cur
        for line in f:lines() do
            line = line:gsub("\r$", "")
            local t = line:match("^%[(.+)%]$")
            if t then
                if #notes < NOTE_MAX then cur = { title = t:sub(1, 40), lines = {} } notes[#notes + 1] = cur else cur = nil end
            elseif cur and line:sub(1, 2) == "> " and #cur.lines < NOTE_LINES then
                cur.lines[#cur.lines + 1] = line:sub(3)
            end
        end
        f:close()
    end)
    if not ok then print("[FH] notes load error: " .. tostring(err)) end
end

local function findNote(title)
    title = lower1251(trim(title or ""))
    for i, n in ipairs(notes) do if lower1251(n.title) == title then return n, i end end
end

local function noteAdd(title, text)
    title = trim(title:gsub("[%[%]]", ""))
    if title == "" or #title > 40 then return false, "Íàçâàíèå: äî 40 ñèìâîëîâ." end
    local n = findNote(title)
    if not n then
        if #notes >= NOTE_MAX then return false, "Ëèìèò çàìåòîê: " .. NOTE_MAX end
        n = { title = title, lines = {} }
        notes[#notes + 1] = n
    end
    local added = 0
    for piece in (text .. ";;"):gmatch("(.-);;") do
        piece = trim(piece)
        if piece ~= "" and #n.lines < NOTE_LINES then n.lines[#n.lines + 1] = piece added = added + 1 end
    end
    if added == 0 then
        if #n.lines == 0 then table.remove(notes) end
        return false, "Ïóñòîé òåêñò, íè÷åãî íå äîáàâëåíî."
    end
    saveNotes()
    return true, string.format("Çàìåòêà «%s»: äîáàâëåíî ñòðîê %d (âñåãî %d).", n.title, added, #n.lines)
end

local function uiNotes()
    local t = { "{33CC33}[+] Íîâàÿ çàìåòêà" }
    for _, n in ipairs(notes) do t[#t + 1] = string.format("{FFFFFF}%s {A9A9A9}- ñòðîê: %d", n.title, #n.lines) end
    uiShow(D_NOTES, "FH | Øïàðãàëêè", table.concat(t, "\n"), "Îòêðûòü", "Çàêðûòü", 2)
end

uiHandlers[D_NOTES] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NOTEADD, "Íîâàÿ çàìåòêà",
            "Ôîðìàò: íàçâàíèå | òåêñò\nÍåñêîëüêî ñòðîê ðàçäåëÿéòå {FFFF00};;\n{A9A9A9}Ïðèìåð: Íîðìû | Áóäíè - 1 ÷àñ ;; Âûõîäíûå - 1.5 ÷àñà",
            "Ñîõðàíèòü", "Íàçàä", 1)
    else
        local n = notes[list]
        if not n then return uiNotes() end
        ui.note = list
        uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "Íàçàä", "Óäàëèòü", 0)
    end
end

uiHandlers[D_NOTEADD] = function(button, _, input)
    if button == 0 then return uiNotes() end
    local title, text = input:match("^(.-)%s*|%s*(.+)$")
    if not title then fmsg("Ôîðìàò: íàçâàíèå | òåêñò") return uiNotes() end
    local _, msg = noteAdd(title, text)
    fmsg(msg)
    uiNotes()
end

uiHandlers[D_NOTE] = function(button)
    if button == 0 and ui.note and notes[ui.note] then
        fmsg("Çàìåòêà «" .. notes[ui.note].title .. "» óäàëåíà.")
        table.remove(notes, ui.note)
        saveNotes()
    end
    uiNotes()
end

----------------------------------------------------------------------
-- ÊÎÌÀÍÄÛ-ÑÎÊÐÀÙÅÍÈß, ÎÏÐÎÑ, ÒÀÉÌÅÐ ÐÅÑÏÀÂÍÀ
----------------------------------------------------------------------
-- {êîðîòêîå èìÿ, ïîëíàÿ êîìàíäà, ðåæèì}
-- args - íóæíû ïàðàìåòðû; idin - âñòàâèòü "/cmd ID " â ñòðîêó ââîäà; idopt - ID èç àðãóìåíòà èëè èç /re;
-- optargs - ïàðàìåòðû íåîáÿçàòåëüíû; none - áåç ïàðàìåòðîâ
local ALIASES = {
    { "jj", "jail", "idin" }, { "mut", "mute", "idin" }, { "ww", "warn", "idin" }, { "bb", "ban", "args" },
    { "uw", "unwarn", "args" }, { "uj", "unjail", "args" }, { "unm", "unmute", "args" }, { "ub", "unban", "args" },
    { "ib", "iban", "args" }, { "ip", "pgetip", "args" }, { "bip", "banip", "args" },
    { "ofl", "offleader", "args" }, { "mkl", "makeleader", "args" },
    { "fuel", "fuelcars", "none" }, { "fc", "fuelcars", "none" }, { "spc", "spawncars", "none" }, { "gh", "ghetto", "none" }, { "gzc", "gzcolor", "args" },
    { "wh", "warehouse", "optargs" }, { "gs", "getstats", "idopt" }, { "inv", "checkinv", "idopt" },
    { "bp", "setbizprod", "args" },
}

local function regAlias(reg, a)
    local short, full, mode = a[1], a[2], a[3]
    reg(short, function(p)
        if mode == "none" then safeSend("/" .. full) return end
        if mode == "optargs" then safeSend(p == "" and ("/" .. full) or ("/" .. full .. " " .. p)) return end
        if mode == "idin" or mode == "idopt" then
            local id = p:match("^(%d+)") or watchedId
            if not id then fmsg("Óêàæèòå ID: /" .. short .. " ID") return end
            if mode == "idin" then
                sampSetChatInputText(string.format("/%s %s ", full, id)) sampSetChatInputEnabled(true)
            else safeSend(string.format("/%s %s", full, id)) end
            return
        end
        if p == "" then fmsg("Óêàæèòå ïàðàìåòðû: /" .. short .. " ...") return end
        safeSend("/" .. full .. " " .. p)
    end)
end

local function cmdAr(id)
    if not id then fmsg("Èñïîëüçîâàíèå: /ar ID") return end
    local text
    local name = "ID " .. id
    for _, r in ipairs(reports) do
        if r.id == id then text = r.text name = r.name .. "[" .. id .. "]" break end
    end
    sendSeq({
        string.format("/pm %s Çäðàâñòâóéòå, âàøà æàëîáà ïðèíÿòà, ïåðåäàþ å¸ àäìèíèñòðàöèè.", id),
        "/a Êîëëåãè, îòâå÷àåì íà ðåïîðò!",
        string.format("/a %s | Æàëîáà: %s", name, text or "òåêñò íå íàéäåí, ñìîòðèòå /report"),
    }, SEND_GAP)
end

----------------------------------------------------------------------
-- ÎÁÚßÂËÅÍÈß, ÏÀÌßÒÊÈ È ÏÐÎÂÅÐÊÈ
----------------------------------------------------------------------
local D_RULES = 4150

local D_CHK, D_CHKRES = 4151, 4152
local ROLES = {
    { "io", "ÈÎ", "È.Î. Îñíîâàòåëÿ" }, { "zo", "ÇÎ", "Çàìåñòèòåëü Îñíîâàòåëÿ" }, { "po", "ÏÎ", "Ïîìîùíèê Îñíîâàòåëÿ" },
    { "ks", "ÊÑ", "Êóðàòîð ñåðâåðà" }, { "zks", "ÇÊÑ", "Çàìåñòèòåëü Êóðàòîðà ñåðâåðà" },
    { "ga", "ÃÀ", "Ãëàâíûé àäìèíèñòðàòîð" }, { "zga", "ÇÃÀ", "Çàìåñòèòåëü Ãëàâíîãî àäìèíèñòðàòîðà" },
    { "gsg", "ÃÑ ãîññ", "Ãëàâíûé ñëåäÿùèé çà ãîññ. ñòðóêòóðàìè" }, { "gsgh", "ÃÑ ãåòòî", "Ãëàâíûé ñëåäÿùèé çà ãåòòî" },
    { "gsm", "ÃÑ ìàôèè", "Ãëàâíûé ñëåäÿùèé çà ìàôèÿìè" },
    { "zgsg", "ÇÃÑ ãîññ", "Çàìåñòèòåëü Ãëàâíîãî ñëåäÿùåãî çà ãîññ. ñòðóêòóðàìè" },
    { "zgsgh", "ÇÃÑ ãåòòî", "Çàìåñòèòåëü Ãëàâíîãî ñëåäÿùåãî çà ãåòòî" },
    { "zgsm", "ÇÃÑ ìàôèè", "Çàìåñòèòåëü Ãëàâíîãî ñëåäÿùåãî çà ìàôèÿìè" },
    { "pgsg", "ÏÃÑ ãîññ", "Ïîìîùíèê Ãëàâíîãî ñëåäÿùåãî çà ãîññ. ñòðóêòóðàìè" },
    { "pgsgh", "ÏÃÑ ãåòòî", "Ïîìîùíèê Ãëàâíîãî ñëåäÿùåãî çà ãåòòî" },
    { "pgsm", "ÏÃÑ ìàôèè", "Ïîìîùíèê Ãëàâíîãî ñëåäÿùåãî çà ìàôèÿìè" },
}
-- áûñòðûå íàáîðû äîëæíîñòåé
local CHK_PRESETS = {
    { "Ðóêîâîäñòâî", { "io", "zo", "po", "ks", "zks" } },
    { "Ñëåäÿùèå", { "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
    { "ÃÀ è ÇÃÀ", { "ga", "zga" } },
    { "Ãëàâíûå ñëåäÿùèå", { "gsg", "gsgh", "gsm" } },
    { "ÇÃÑ", { "zgsg", "zgsgh", "zgsm" } },
    { "ÏÃÑ", { "pgsg", "pgsgh", "pgsm" } },
    { "Âñå", { "io", "zo", "po", "ks", "zks", "ga", "zga", "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
}

-- õîä ïðîâåðêè: êòî îòâåòèë â /a
local CHK = { active = false, list = {}, seen = {}, word = "1", t0 = 0, total = 0, secs = 0, thread = nil, token = 0 }

local function chkNames(keys)
    local out = {}
    for _, k in ipairs(keys) do
        for _, r in ipairs(ROLES) do if r[1] == k then out[#out + 1] = r[3] end end
    end
    return out
end

-- ñòðîêè îáúÿâëåíèÿ â /a (sel - ïîëíûå íàçâàíèÿ äîëæíîñòåé, ïóñòî - îáùàÿ ïðîâåðêà)
local function chkLines(sel, word, secs)
    word = trim(word or "")
    if word == "" then word = "1" end
    secs = tonumber(secs) or 0
    local answer = (word == "1") and "öèôðó 1" or ("ñëîâî «" .. word .. "»")
    local tail = secs > 0 and (" Âðåìÿ: " .. math.floor(secs) .. " ñåê.") or ""
    local lines = { "/a Ïðîâåðêà àêòèâíîñòè àäìèíèñòðàöèè!" }
    if sel and #sel > 0 then
        -- ñòðîêè ñîáèðàåì ïî äëèíå â ñèìâîëàõ (ñåðâåð ðåæåò ñîîáùåíèå íà 128 áàéòàõ)
        local function clen(x)
            if #"ÿ" == 2 then return #x - select(2, x:gsub("[\128-\191]", "")) end
            return #x
        end
        local cur, first = {}, true
        local function flush(last)
            if #cur == 0 then return end
            lines[#lines + 1] = "/a " .. (first and "Îòçûâàþòñÿ: " or "") .. table.concat(cur, ", ") .. (last and "." or ",")
            first, cur = false, {}
        end
        local used = 0
        for _, name in ipairs(sel) do
            if #cur > 0 and used + 2 + clen(name) > 95 then flush(false) used = 0 end
            used = used + (#cur > 0 and 2 or 0) + clen(name)
            cur[#cur + 1] = name
        end
        flush(true)
        lines[#lines + 1] = "/a Ïîñòàâüòå ñâîé òåã è íàïèøèòå â /a " .. answer .. "." .. tail
    else
        lines[#lines + 1] = "/a Ãëàâíûå è çàìåñòèòåëè ãëàâíûõ ñëåäÿùèõ - ïîñòàâüòå ñâîé òåã."
        lines[#lines + 1] = "/a Ïîäòâåðäèòå ïðèñóòñòâèå: íàïèøèòå â /a " .. answer .. "." .. tail
    end
    return lines, word, secs
end

local function chkResultText()
    local t = { string.format("{FFFFFF}Îòìåòèëèñü: {33CC33}%d", #CHK.list) }
    t[#t + 1] = "{A9A9A9}Îòâåò: " .. CHK.word .. (CHK.active and "   (ïðîâåðêà èä¸ò)" or "   (ïðîâåðêà çàêîí÷åíà)")
    t[#t + 1] = ""
    if #CHK.list == 0 then t[#t + 1] = "{A9A9A9}Ïîêà íèêòî íå îòâåòèë." end
    for i, e in ipairs(CHK.list) do
        t[#t + 1] = string.format("{FFFFFF}%d. %s{A9A9A9}%s  - ÷åðåç %d ñåê.", i, e.name, e.id and ("[" .. e.id .. "]") or "", e.sec)
    end
    return table.concat(t, "\n")
end

local function chkShow()
    uiShow(D_CHKRES, "FH | Èòîã ïðîâåðêè àêòèâíîñòè", chkResultText(), "Çàêðûòü", "", 0)
end
uiHandlers[D_CHKRES] = function() end

-- êîíåö ïðîâåðêè; announce - ñîîáùèòü èòîã â /a
local function chkEnd(announce)
    if not CHK.active then fmsg("Ïðîâåðêà íå çàïóùåíà.") return end
    CHK.active = false
    CHK.token = CHK.token + 1
    if CHK.thread then pcall(function() CHK.thread:terminate() end) CHK.thread = nil end
    fmsg(string.format("Ïðîâåðêà çàêîí÷åíà. Îòìåòèëèñü: %d (ñïèñîê: /chkres).", #CHK.list))
    if announce then safeSend(string.format("/a Ïðîâåðêà àêòèâíîñòè çàâåðøåíà. Îòìåòèëèñü: %d.", #CHK.list)) end
end

-- âûçûâàåòñÿ äëÿ êàæäîé ñòðîêè ÷àòà: èùåò îòâåòû âèäà «Íèê[ID]: 1»
local function chkCollect(text)
    if not CHK.active then return end
    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, msg = clean:match("([%w_%.]+)%[(%d+)%]%s*:%s*(.-)%s*$")
    if not name then name, msg = clean:match("([%w_%.]+)%s*:%s*(.-)%s*$") end
    if not name or lower1251(msg) ~= lower1251(CHK.word) then return end
    if CHK.seen[name] then return end
    CHK.seen[name] = true
    CHK.list[#CHK.list + 1] = { name = name, id = id, sec = math.floor(os.clock() - CHK.t0) }
end

-- sel: ñïèñîê íàçâàíèé äîëæíîñòåé; opts: { word = "1", seconds = 60 }
local function sayA1(sel, opts)
    opts = opts or {}
    local lines, word, secs = chkLines(sel, opts.word, opts.seconds)
    CHK.active, CHK.list, CHK.seen, CHK.word, CHK.secs = false, {}, {}, word, secs
    if CHK.thread then pcall(function() CHK.thread:terminate() end) CHK.thread = nil end
    CHK.token = CHK.token + 1
    local my = CHK.token
    sendSeq(lines, SEND_GAP, function()
        if CHK.token ~= my then return end
        CHK.active, CHK.t0 = true, os.clock()
        if secs > 0 then
            CHK.thread = lua_thread.create(function()
                wait(secs * 1000)
                if CHK.token == my and CHK.active then
                    pcall(function() chkEnd(false) chkShow() end)
                end
            end)
        end
    end)
end

local function roleByToken(tok)
    tok = lower1251(tok):gsub("[%s,]", "")
    for _, r in ipairs(ROLES) do
        if r[1] == tok or lower1251(r[2]):gsub("%s", "") == tok then return r[3] end
    end
end

-- /a1 [äîëæíîñòè] [t=ñåêóíä] [w=ñëîâî]
local function sayA1Args(p)
    local sel, bad, opts = {}, {}, {}
    for tok in (p or ""):gmatch("[^%s,]+") do
        local secs = tok:match("^t=(%d+)$")
        local word = tok:match("^w=(.+)$")
        if secs then opts.seconds = tonumber(secs)
        elseif word then opts.word = word
        else
            local r = roleByToken(tok)
            if r then sel[#sel + 1] = r else bad[#bad + 1] = tok end
        end
    end
    if #bad > 0 then
        local keys = {}
        for _, r in ipairs(ROLES) do keys[#keys + 1] = r[1] end
        fmsg("Íå çíàþ: " .. table.concat(bad, ", ") .. ". Êëþ÷è: " .. table.concat(keys, " ") .. " | t=60 w=ñëîâî")
        return
    end
    sayA1(sel, opts)
end

local function uiChk()
    local t = { "{33CC33}Îáùàÿ ïðîâåðêà (áåç äîëæíîñòåé)" }
    for _, p in ipairs(CHK_PRESETS) do t[#t + 1] = "{66CCFF}Íàáîð: {FFFFFF}" .. p[1] end
    for _, r in ipairs(ROLES) do t[#t + 1] = "{FFFFFF}" .. r[2] end
    uiShow(D_CHK, "FH | Ïðîâåðêà àêòèâíîñòè", table.concat(t, "\n"), "Ïðîâåðèòü", "Çàêðûòü", 2)
end

uiHandlers[D_CHK] = function(button, list)
    if button == 0 then return end
    if list == 0 then sayA1(nil) return end
    local p = CHK_PRESETS[list]
    if p then sayA1(chkNames(p[2])) return end
    local r = ROLES[list - #CHK_PRESETS]
    sayA1(r and { r[3] } or nil)
end

local function sayRules()
    sendSeq({
        "Íîðìà îíëàéíà ëèäåðà: â áóäíè 1 ÷àñ, â âûõîäíûå 1 ÷àñ 30 ìèíóò.",
        "Íå îòûãðàëè íîðìó - ïîëó÷àåòå âûãîâîð.",
        "3/3 âûãîâîðîâ - ñíÿòèå ñ ïîñòà ëèäåðà è ×ÑË.",
        "×àñ ïèê â áóäíè: ñ 17:00 äî 20:00.",
        "×àñ ïèê â âûõîäíûå: ñ 16:00 äî 19:00.",
        "Îòñóòñòâèå â ÷àñ ïèê òîæå êàðàåòñÿ âûãîâîðîì.",
        "Âîïðîñû - ê ñëåäÿùèì âàøåé ñòðóêòóðû.",
    }, 3500)
end

local function sayInfo()
    sendSeq({
        "/aad [INFO] Óâàæàåìûå èãðîêè, àäìèíèñòðàöèÿ âñåãäà íà ñâÿçè!",
        "/aad [INFO] Íàøëè áàã èëè íàðóøåíèå - ïèøèòå â /rep.",
        "/aad [INFO] Ôîðìóëèðóéòå âîïðîñ èëè æàëîáó êîðîòêî è ïîíÿòíî.",
        "/aad [INFO] Çà ôëóä, îôôòîï è îñêîðáëåíèÿ â ðåïîðòå âûäà¸òñÿ íàêàçàíèå.",
        "/aad [INFO] Ïðèÿòíîé èãðû!",
    }, SEND_GAP)
end

local function sayTimeInfo()
    sendSeq({
        "/aad [INFO] Èãðîêè, íàïîìèíàåì îá àêöèè çà îíëàéí!",
        "/aad [INFO] Îòûãðàéòå ÷àñ íà ñåðâåðå è ïîëó÷èòå ïðèç.",
        "/aad [INFO] Íàãðàäó ìîæíî ïîëó÷àòü äî 5 ðàç â äåíü.",
        "/aad [INFO] Ïðîâåðèòü âðåìÿ è çàáðàòü ïðèç: /rep time",
        "/aad [INFO] Ñ óâàæåíèåì, àäìèíèñòðàöèÿ ïðîåêòà.",
    }, SEND_GAP)
end

local function sayGwIntro(prize)
    prize = trim(prize or "")
    local lines = {
        "/aad [Ðàçäà÷à] Âíèìàíèå, èãðîêè! Ñåé÷àñ ïðîéä¸ò áûñòðàÿ ðàçäà÷à ïðèçîâ.",
        "/aad [Ðàçäà÷à] Ïðèãîòîâüòåñü ïèñàòü êîäîâîå ñëîâî â ÷àò!",
    }
    if prize ~= "" then lines[#lines + 1] = "/aad [Ðàçäà÷à] Ïðèç: " .. prize .. "." end
    sendSeq(lines, SEND_GAP)
end

local RULES_TEXT = {
    capt = {
        "FH | Ïðàâèëà êàïòîâ",
        "{66CCFF}Ðàçðåøåíî\n" ..
        "{FFFFFF}- ñëàéäû, ïîëóñëàéäû, +C, ñáèâ ïåðåêàòà\n" ..
        "- êðûøè, íà êîòîðûå ïîïàäàþò â 2 ïðûæêà èëè ïî ëåñòíèöå\n" ..
        "- ñëèâ âíå êâàäðàòà ïîñëå 5 ìèíóò êàïòà\n" ..
        "- êàïò êóñêîì èëè îáðåçîì, ìàøèíû äëÿ áàððèêàä\n\n" ..
        "{FF6666}Íåëüçÿ (1/3, ñïàâí, äæåéë èëè âàðí)\n" ..
        "{FFFFFF}- óáèéñòâî èëè çàïðåò âõîäà â êâàäðàò äî 5 ìèíóò\n" ..
        "- êðûøè âûøå 2 ïðûæêîâ\n" ..
        "- çàõîäèòü â èíòåðüåð â áîþ, ÑÊ â èíòåðüåðå áàíäû\n" ..
        "- îáñòðåë ðåñïàâíà ñîïåðíèêà\n" ..
        "- ìàñêà, áðîíÿ, àïòå÷êè, íàðêîòèêè â áîþ\n" ..
        "- ÷óæîé ñêèí, åñëè êëèñò áàíäû íå ñîâïàäàåò ñî ñêèíîì ôðàêöèè\n\n" ..
        "{FF6666}Òÿæ¸ëûå íàðóøåíèÿ\n" ..
        "{FFFFFF}- ÄÍÊ, äæåòïàê, äîì íà êîë¸ñàõ â êâàäðàòå: 1/3\n" ..
        "- àíòèôðàã (ñóèöèä, ðåëîã, ïîäñòàâ ïîä ãîñíèêîâ): 1/3\n" ..
        "- îòêàç äàòü îïðó ñëåäÿùèì èëè ñêðûòèå ÷èòîâ: âàðí è ìèíóñ êâàäðàò\n" ..
        "- áàãîþç Double Kill, ñòðåëüáà ïî êîë¸ñàì: 2/3\n" ..
        "- ïðîâîêàöèÿ íà ñëèâ èëè ÑÊ ó ðåñïàâíà: äæåéë 10 ìèíóò\n\n" ..
        "{FFCC00}Ëèäåðàì áàíä\n" ..
        "{FFFFFF}- â êàïòå 1-3 ðàíãè ôðàêöèè èëè ïîìåõà òðåòüåé áàíäû: 1/3 ëèäåðó\n" ..
        "- êàïò ðåñïû ëþáîé áàíäû: âûãîâîð, îòìåíà êàïòà, ìèíóñ 3 êâàäðàòà\n" ..
        "- èãíîð êàïòà èëè íåïðèåçä ñîñòàâà íà çàáèâ: 1/3 ëèäåðó",
    },
    biz = {
        "FH | Ïðàâèëà áèçâàðîâ",
        "{66CCFF}Îáùåå\n" ..
        "{FFFFFF}- çàáèâàòü ñòðåëó ìîãóò òîëüêî ëèäåð èëè çàìåñòèòåëü, çà 30+ ìèíóò ÷åðåç ÂÊ\n" ..
        "- âðåìÿ ñòðåë: ñ 12:00 äî 22:00 ïî Ìîñêâå, ìèíèìóì 2 íà 2\n" ..
        "- äëèòåëüíîñòü 10 ìèíóò, íóæíà îïðà îò ëèäåðà è çàìà, åñëè íåò ñëåäÿùèõ\n" ..
        "- 3/3 ó ìàôèè: ôðàêöèÿ òåðÿåò 1 áèçíåñ\n\n" ..
        "{FF6666}Íåëüçÿ (1/3)\n" ..
        "{FFFFFF}- êðûøè è ãîðû, ñòðåëüáà ïî ìàøèíå ïðè âúåçäå âðàãà\n" ..
        "- òÿíóòü âðåìÿ âíå êâàäðàòà, êàòàòüñÿ â êâàäðàòå íà ìàøèíå äîëüøå 10 ñåêóíä (1/3 è ñïàâí)\n" ..
        "- ÷óæîé ñêèí, ïîìîùü ïîñòîðîííèõ (ìàôèè ñðàçó 3/3)\n" ..
        "- ÀÔÊ áîëüøå 30 ñåêóíä, âåðòîë¸ò èëè ëè÷íûé òðàíñïîðò, íå âïóñêàòü âðàãà â êâàäðàò\n" ..
        "- âûõîä èç êâàäðàòà, ìàñêà, áðîíÿ, îðóæèå êðîìå Desert Eagle, M4, Shotgun, Rifle\n" ..
        "- SK, DB, TK, ñëèâ èëè ñòðåëüáà âíå êâàäðàòà, èãíîð ñòðåëû è ñëåäÿùèõ\n" ..
        "- àíòèôðàã: ïðûæîê ñ ìîñòà èëè ãîðû, ñóèöèä\n\n" ..
        "{FF6666}Òÿæ¸ëûå íàðóøåíèÿ\n" ..
        "{FFFFFF}- áàãè, ñáèâ àíèìàöèé â áîþ: 2/3\n" ..
        "- ñòðåëüáà ñ ïàññàæèðñêîãî ñèäåíüÿ: 1/3 è äæåéë 10 ìèíóò\n" ..
        "- ñòðåëà âíå 12:00-22:00: îñòàíîâêà ñòðåëû è âûãîâîð ëèäåðó",
    },
}

local function showRules(kind)
    local r = RULES_TEXT[kind]
    if r then uiShow(D_RULES, r[1], r[2], "Çàêðûòü", "", 0) end
end
uiHandlers[D_RULES] = function() end

local VOPROS = {
    { "×òî òàêîå ×Ï?", "×Ï - ÷àñ ïèê, îáÿçàòåëüíîå âðåìÿ îíëàéíà ëèäåðîâ." },
    { "Êàêàÿ íîðìà îíëàéíà ó ëèäåðà â áóäíè?", "Â áóäíè íîðìà - 1 ÷àñ." },
    { "Êàêàÿ íîðìà îíëàéíà ó ëèäåðà â âûõîäíûå?", "Â âûõîäíûå íîðìà - 1 ÷àñ 30 ìèíóò." },
    { "×òî îáÿçàí äåëàòü ëèäåð ôðàêöèè?", "Ñëåäèòü çà ôðàêöèåé, ôîðóìîì è ñîñòàâîì." },
    { "×òî òàêîå áëàò?", "Áëàò - âûäà÷à âûñîêîé äîëæíîñòè áåç îò÷¸òîâ è îáçâîíà." },
    { "Ñî ñêîëüêè äî ñêîëüêè ×Ï â áóäíè?", "Â áóäíè ×Ï ñ 17:00 äî 20:00." },
    { "Ñî ñêîëüêè äî ñêîëüêè ×Ï â âûõîäíûå?", "Â âûõîäíûå ×Ï ñ 16:00 äî 19:00." },
}

local function askVopros(p)
    local n = tonumber((p or ""):match("^%d+"))
    local v = n and VOPROS[n]
    if not v then fmsg("Èñïîëüçîâàíèå: /vopros 1-" .. #VOPROS .. " (âîïðîñ ëèäåðó â ÷àò, îòâåò ïîêàæó âàì).") return end
    safeSend(v[1])
    fmsg("Îòâåò: " .. v[2])
end

local INFO = {
    a1 = sayA1, a1args = sayA1Args, chk = uiChk, chkres = chkShow, chkend = function() chkEnd(true) end, chkfin = function() chkEnd(false) end, rules = sayRules, inf = sayInfo, time = sayTimeInfo, intro = sayGwIntro,
    capt = function() showRules("capt") end, biz = function() showRules("biz") end, q = askVopros,
}
local vrThread
-- óäàëåíèå àäìèí-êàðîâ âñåãäà ñ ïðåäóïðåæäåíèåì â /a è òàéìåðîì 15 ñ
local function dvTimer(spawn)
    if vrThread then fmsg("Òàéìåð óæå èä¸ò (îñòàíîâèòü: /vrstop).") return end
    vrThread = lua_thread.create(function()
        pcall(function()
            safeSend("/a ×åðåç 15 ñåêóíä àäìèí-òðàíñïîðò áóäåò óäàë¸í" .. (spawn and " è âåñü òðàíñïîðò ñåðâåðà âîçâðàù¸í íà ìåñòà!" or "!"))
            wait(15000)
            safeSend("/dvall")
            if spawn then wait(1500) safeSend("/spawncars") end
        end)
        vrThread = nil
    end)
end
local function registerExtra(reg)
    reg("ev", function(p)
        local key, arg = p:match("^(%S+)%s*(.*)$")
        local e = key and eventByKey(key)
        if e then announceEvent(e, arg) elseif key then fmsg("Íåò òàêîãî ÌÏ: " .. key .. ". Ñïèñîê: /ev") else uiEvents() end
    end)
    local function byKey(cmd, fn)
        reg(cmd, function(p)
            local f = fractionByKey(trim(p))
            if f then fn(f) else fmsg("Óêàæèòå ôðàêöèþ: /" .. cmd .. " êëþ÷ (ñïèñîê êëþ÷åé: /fr)") end
        end)
    end
    byKey("nab", recruit) byKey("otb", tryoutAad) byKey("otbo", tryoutO) byKey("tlead", tempLeader)
    reg("fr", uiFractions)

    reg("note", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local title, text = rest:match("^(.-)%s*|%s*(.+)$")
            if not title then fmsg("Èñïîëüçîâàíèå: /note add íàçâàíèå | òåêñò") return end
            local _, msg = noteAdd(title, text) fmsg(msg)
        elseif sub == "del" then
            local n, i = findNote(rest)
            if not n then fmsg("Çàìåòêà íå íàéäåíà.") return end
            table.remove(notes, i) saveNotes() fmsg("Çàìåòêà óäàëåíà.")
        elseif sub == "show" then
            local n = findNote(rest)
            if not n then fmsg("Çàìåòêà íå íàéäåíà.") return end
            uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "Íàçàä", "Çàêðûòü", 0)
        else uiNotes() end
    end)
    reg("notes", uiNotes)

    for _, a in ipairs(ALIASES) do regAlias(reg, a) end

    reg("poll", function(p)
        local who = trim(p)
        if who == "" then fmsg("Èñïîëüçîâàíèå: /poll äîëæíîñòü è íèê (íàïðèìåð: /poll ÃÀ Ivan_Ivanov)") return end
        sendSeq({
            "/aad [Îïðîñ] Èãðîêè, óäåëèòå ìèíóòó!",
            "/aad [Îïðîñ] Îöåíèòå ðàáîòó: " .. who .. ". Îòïðàâüòå â /rep öèôðó îò 1 äî 5.",
        }, SEND_GAP)
    end)

    reg("ar", function(p) cmdAr(p:match("^(%d+)") or watchedId) end)

    reg("z", function(p)
        local key, rest = p:match("^(%S+)%s*(.*)$")
        if not key then uiClaims() return end
        local lk = lower1251(key)
        for _, c in ipairs(CLAIMS) do
            if c[1] == lk then claim(c[2], rest) return end
        end
        claim(p)   -- ñâîé òåêñò: /z o otbor mp
    end)
    reg("vr", function() dvTimer(true) end)
    reg("dva", function() dvTimer(false) end)
    reg("dvs", function() dvTimer(true) end)
    reg("ai", function(p) AI.cmdAsk(p) end)
    reg("aiset", function(p) AI.cmdSet(p) end)
    reg("aidiag", function() AI.diag() end)
    reg("fhupd", function(p) UPD.cmd(p) end)
    reg("fhdiag", function()
        local g = guiState and guiState.diag()
        fmsg("Êîäèðîâêà: " .. (enc8 and "áèáëèîòåêà encoding" or "çàïàñíàÿ (encoding íå íàéäåíà)"))
        fmsg("Îêíî /fh: " .. (g and (g.disabled and "îòêëþ÷åíî èç-çà îøèáîê" or g.init and "íå çàïóñòèëîñü" or "ãîòîâî") or "íåäîñòóïíî (íåò mimgui)"))
        local ti = guiState and guiState.tagInfo()
        fmsg("Ìåòêà íàä èãðîêîì: " .. (ti and ((ti.off and ("îøèáêà: " .. tostring(ti.err))) or ("ñïîñîá " .. (ti.mode == 0 and "imgui" or "render") .. (ti.id and (", èãðîê íàéäåí (ID " .. ti.id .. ")") or ", èãðîê íå íàéäåí"))) or "íåäîñòóïíà"))
        fmsg("Óâåäîìëåíèå î ðåïîðòå: " .. (not cfg.reptoast and "âûêëþ÷åíî â íàñòðîéêàõ" or (g and g.off) and ("ñëîìàëîñü: " .. tostring(g.err)) or "âêëþ÷åíî") ..
            ". Ðåïîðòîâ ïîëó÷åíî: " .. #reports)
    end)
    reg("reptest", function(p)
        local text = trim(p or "")
        if text == "" then text = "Òåñòîâûé ðåïîðò: ïðîâåðêà óâåäîìëåíèÿ" end
        local shown = false
        pcall(function() if guiState and guiState.ready() then shown = guiState.reportToast({ name = "Test_Player", id = "7", text = text }) end end)
        fmsg(shown and "Òåñòîâîå óâåäîìëåíèå çàïóùåíî." or "Óâåäîìëåíèå íå ïîêàçàíî. Ïîäðîáíîñòè: /fhdiag")
    end)
    reg("chkres", function() INFO.chkres() end)
    reg("chkend", function() INFO.chkend() end)
    reg("a1", function(p) if (p or "") == "" then INFO.a1() else INFO.a1args(p) end end)
    reg("chk", function(p) if (p or "") == "" then INFO.chk() else INFO.a1args(p) end end)
    reg("pravila", function() INFO.rules() end)
    reg("inf", function() INFO.inf() end)
    reg("timeinfo", function() INFO.time() end)
    reg("razdintro", function(p) INFO.intro(p) end)
    reg("captlist", function() INFO.capt() end)
    reg("bizwarlist", function() INFO.biz() end)
    reg("vopros", function(p) INFO.q(p) end)
    reg("vrstop", function()
        if vrThread then
            pcall(function() vrThread:terminate() end)
            vrThread = nil
            fmsg("Òàéìåð ðåñïàâíà îñòàíîâëåí.")
        else fmsg("Òàéìåð íå çàïóùåí.") end
    end)

    reg("tpl", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local _, msg = tplAdd(rest) fmsg(msg)
        elseif sub == "del" then
            local n = tonumber(rest)
            if n and templates[n] then table.remove(templates, n) saveTemplates() fmsg("Øàáëîí óäàë¸í.")
            else fmsg("Èñïîëüçîâàíèå: /tpl del N") end
        else
            fmsg("Øàáëîíû îòâåòîâ (îòïðàâèòü: /rt [ID] N; äîáàâèòü: /tpl add òåêñò; óäàëèòü: /tpl del N):")
            for i, t in ipairs(templates) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, t), -1) end
        end
    end)
    reg("rt", function(p)
        local id, n = p:match("^(%d+)%s+(%d+)$")
        if not id then n = p:match("^(%d+)$") id = watchedId end
        n = tonumber(n)
        if not id or not n or not templates[n] then fmsg("Èñïîëüçîâàíèå: /rt [ID] íîìåð_øàáëîíà (ñïèñîê: /tpl)") return end
        replyTo(id, templates[n])
    end)
    reg("mpa", function() armAutoMp(true) end)
    reg("fhset", function(p)
        local k, v = p:match("^(%S+)%s+(%S+)$")
        if k == "automp" and (v == "on" or v == "off") then
            cfg.automp = (v == "on") saveCfg()
            fmsg("Àâòî-/mp ïîñëå àíîíñà ÌÏ: " .. (cfg.automp and "âêëþ÷åíî" or "âûêëþ÷åíî"))
        else fmsg("Èñïîëüçîâàíèå: /fhset automp on|off (ñåé÷àñ: " .. (cfg.automp and "on" or "off") .. ")") end
    end)
    loadNotes()
end

----------------------------------------------------------------------
-- ÃËÀÂÍÎÅ ÌÅÍÞ /fh
----------------------------------------------------------------------
local D_CMDS, D_CMDPAGE = 4130, 4131
local CMD_PAGES = {
    { "Ðàçäà÷è",
      "{66CCFF}/gw ñëîâî | ïðèç {FFFFFF}- çàïóñòèòü ðàçäà÷ó\n" ..
      "{66CCFF}/gwlast ñëîâî | ïðèç {FFFFFF}- ôèíàëüíûé ðàóíä, ñàì çàêðîåò ðàçäà÷ó\n" ..
      "{66CCFF}/gwstop {FFFFFF}- îòìåíèòü ðàçäà÷ó\n\n" ..
      "{A9A9A9}Ïðèç: òèï è ÷èñëî. Ïðèìåðû: {FFFF00}áàíê 500000{A9A9A9}, {FFFF00}ëâë 3{A9A9A9}, {FFFF00}#9 15{A9A9A9} (íîìåð ñòàòû).\n" ..
      "Òèïû: áàíê, ëâë, ìàò, îïûò, çàêîí, ñèì, áîêñ, êóíã, êèê." },
    { "Ðåïîðòû",
      "{66CCFF}/reports {FFFFFF}- ïîñëåäíèå 15 ðåïîðòîâ, âûáðàëè - îòâåòèëè\n" ..
      "{66CCFF}/rr [ID] òåêñò {FFFFFF}- îòâåò èãðîêó ÷åðåç /pm\n\n" ..
      "{A9A9A9}Åñëè ID íå óêàçàí, áåð¸òñÿ èãðîê èç ïîñëåäíåé êîìàíäû /re." },
    { "Áèíäåð",
      "{66CCFF}/fbind {FFFFFF}- îêíî áèíäåðà\n" ..
      "{66CCFF}/bnd add èìÿ òåêñò {FFFFFF}- ñîçäàòü áèíä / äîáàâèòü ñòðîêó (íåñêîëüêî ÷åðåç ;;)\n" ..
      "{66CCFF}/bnd rm èìÿ N {FFFFFF}- óäàëèòü ñòðîêó\n" ..
      "{66CCFF}/bnd del èìÿ {FFFFFF}- óäàëèòü áèíä\n" ..
      "{66CCFF}/bnd delay èìÿ ìñ {FFFFFF}- ïàóçà ìåæäó ñòðîêàìè\n" ..
      "{66CCFF}/bnd show èìÿ, /bnd list {FFFFFF}- ïðîñìîòð\n\n" ..
      "{A9A9A9}Â òåêñòå: {FFFF00}{id}{A9A9A9} - ID èãðîêà, {FFFF00}{arg}{A9A9A9} - òåêñò ïîñëå êîìàíäû.\n" ..
      "Ñòðîêà ñ / óõîäèò êàê êîìàíäà, îñòàëüíîå - â îáû÷íûé ÷àò." },
    { "Ìåðîïðèÿòèÿ",
      "{66CCFF}/ev {FFFFFF}- ñïèñîê ÌÏ, âûáðàëè - îáúÿâëåíèå óøëî â /aad\n" ..
      "{66CCFF}/ev êëþ÷ {FFFFFF}- ñðàçó îáúÿâèòü (íàïðèìåð /ev svet). Äëÿ «infern»: /ev infern ID. Ïðèç: /ev svet 5êê èëè /ev infern ID 5êê\n\n" ..
      "{A9A9A9}Êëþ÷è: svet poliv derbi pryat parkur rulet kovsh myaso dogon car parash digl sultan paint krug infern" },
    { "Ôðàêöèè",
      "{66CCFF}/fr {FFFFFF}- îêíî ôðàêöèé: íàáîð, îòáîð, âðåìåííàÿ ëèäåðêà\n" ..
      "{66CCFF}/nab êëþ÷ {FFFFFF}- íàáîð â /o\n" ..
      "{66CCFF}/otb êëþ÷ {FFFFFF}- îòáîð íà ëèäåðà â /aad (ïîòîì îòêðîåòñÿ ââîä /mp)\n" ..
      "{66CCFF}/otbo êëþ÷ {FFFFFF}- îòáîð íà ëèäåðà â /o\n" ..
      "{66CCFF}/tlead êëþ÷ {FFFFFF}- âçÿòü âðåìåííóþ ëèäåðêó (/templeader)\n\n" ..
      "{A9A9A9}Êëþ÷è: rus jap ita fun out rif bal azt gro vag arm hos mer rad swt gov lsp fbi rcp sud" },
    { "Íàêàçàíèÿ",
      "{FFFFFF}Âñòàâëÿþò êîìàíäó ñ ID â ñòðîêó ââîäà: {66CCFF}/jj /mut /ww {A9A9A9}(jail, mute, warn)\n" ..
      "{FFFFFF}Ñ ïàðàìåòðàìè: {66CCFF}/bb /uw /uj /unm /ub /ib /ip /bip /ofl /mkl /gzc /bp\n" ..
      "{FFFFFF}Ïî ID èëè èç /re: {66CCFF}/gs /inv {A9A9A9}(getstats, checkinv)\n" ..
      "{FFFFFF}Áåç ïàðàìåòðîâ: {66CCFF}/fuel /gh /wh\n\n" ..
      "{A9A9A9}Ðàñøèôðîâêà: bb-ban, uw-unwarn, uj-unjail, unm-unmute, ub-unban, ib-iban, ip-pgetip,\nbip-banip, ofl-offleader, mkl-makeleader, gzc-gzcolor, bp-setbizprod, wh-warehouse." },
    { "Ïðî÷åå",
      "{66CCFF}/ar ID {FFFFFF}- îòâåò íà ðåïîðò: /pm èãðîêó + òåêñò æàëîáû â /a\n" ..
      "{66CCFF}/poll äîëæíîñòü íèê {FFFFFF}- îïðîñ èãðîêîâ îá îöåíêå ðàáîòû àäìèíà\n" ..
      "{66CCFF}/vr {FFFFFF}- ÷åðåç 15 ñåê óäàëèòü è âåðíóòü âåñü òðàíñïîðò, {66CCFF}/vrstop {FFFFFF}- îòìåíà\n" ..
      "{66CCFF}/notes {FFFFFF}- øïàðãàëêè; {66CCFF}/note add íàçâàíèå | òåêñò{FFFFFF}, {66CCFF}/note del íàçâàíèå" },
    { "Îáùåå",
      "{66CCFF}/fh {FFFFFF}- ãëàâíîå ìåíþ\n" ..
      "{66CCFF}/fcmd {FFFFFF}- ýòî îêíî ñî ñïèñêîì êîìàíä\n" ..
      "{66CCFF}/binder {FFFFFF}- ñïðàâêà ïî áèíäåðó\n\n" ..
      "{A9A9A9}Ñâîè ñîêðàùåíèÿ ñîçäàâàéòå â áèíäåðå, íàïðèìåð:\n{FFFF00}/bnd add jl /jail {id} {arg}" },
}

local function uiCommands()
    local t = {}
    for i, p in ipairs(CMD_PAGES) do t[i] = "{FFFFFF}" .. p[1] end
    uiShow(D_CMDS, "FH | Êîìàíäû", table.concat(t, "\n"), "Îòêðûòü", "Çàêðûòü", 2)
end

uiHandlers[D_CMDS] = function(button, list)
    if button == 0 then return end
    local p = CMD_PAGES[list + 1]
    if not p then return uiCommands() end
    uiShow(D_CMDPAGE, "FH | " .. p[1], p[2], "Íàçàä", "Çàêðûòü", 0)
end

uiHandlers[D_CMDPAGE] = function(button)
    if button == 1 then uiCommands() end
end

-- Îêíî /fh: òàáëèöà âñåõ êîìàíä
local function carsDo(kind)
    if kind == "spawn" then safeSend("/spawncars")
    elseif kind == "dv" then dvTimer(false)
    elseif kind == "fuel" then safeSend("/fuelcars")
    elseif kind == "dvs" then dvTimer(true)
    end
end

local function infoDo(kind, arg) local f = INFO[kind] if f then f(arg) end end

local MENU_ROWS = {
    { "#", "Ðàçäà÷è" },
    { "/gw ñëîâî | ïðèç", "çàïóñòèòü ðàçäà÷ó (áàíê 500000, ëâë 3, #9 15)" },
    { "/gwlast ñëîâî | ïðèç", "ôèíàëüíûé ðàóíä, ñàì çàêðîåò ðàçäà÷ó" },
    { "/gwstop", "îòìåíèòü ðàçäà÷ó" },
    { "#", "Ðåïîðòû" },
    { "/reports", "ïîñëåäíèå 15 ðåïîðòîâ, áûñòðûé îòâåò" },
    { "/rpl", "îáíîâèòü ñïèñîê ðåïîðòîâ èç /define" },
    { "/tagmode", "ïåðåêëþ÷èòü ñïîñîá ðèñîâàíèÿ ìåòêè íàä èãðîêîì (åñëè íå âèäíà)" },
    { "/rr [ID] òåêñò", "îòâåòèòü èãðîêó ÷åðåç /pm" },
    { "/reptest  /fhdiag", "ïðîâåðêà îâàëüíîãî óâåäîìëåíèÿ î ðåïîðòå; äèàãíîñòèêà êîäèðîâêè è îêíà" },
    { "/fhupd [install]", "ïðîâåðêà îáíîâëåíèé íà GitHub; install - ñêà÷àòü è óñòàíîâèòü" },
    { "/ai [ID]  /aiset  /aidiag", "ÈÈ-ïîäñêàçêà îòâåòà íà ðåïîðò; íàñòðîéêà API (/aiset url|key|model|prompt); /aidiag - ÷òî äîñòóïíî äëÿ çàïðîñîâ" },
    { "/ar ID", "îòâåò + òåêñò æàëîáû â /a" },
    { "/tpl  /rt [ID] N", "øàáëîíû îòâåòîâ: ñïèñîê, îòïðàâêà" },
    { "#", "Ìåðîïðèÿòèÿ è îïðîñû" },
    { "/ev [êëþ÷] [ID] [ïðèç]", "àíîíñ ÌÏ â /aad ñ ïðèçîì (ñïèñîê: /ev)" },
    { "/poll äîëæíîñòü íèê", "îïðîñ îá îöåíêå ðàáîòû àäìèíà" },
    { "#", "Ôðàêöèè" },
    { "/fr", "îêíî: íàáîð, îòáîð, ëèäåðêà" },
    { "/nab /otb /otbo /tlead êëþ÷", "íàáîð /o, îòáîð /aad, îòáîð /o, ëèäåðêà" },
    { "#", "Îáúÿâëåíèÿ è ïàìÿòêè" },
    { "/a1  /chk [èî çî gsg t=60 w=ñëîâî]", "ïðîâåðêà àêòèâíîñòè ïî äîëæíîñòÿì, òàéìåð è ñëîâî îòâåòà" },
    { "/chkres  /chkend", "êòî îòìåòèëñÿ; çàêîí÷èòü è îáúÿâèòü èòîã â /a" },
    { "/pravila", "íîðìû îíëàéíà è ÷àñ ïèê ëèäåðàì â ÷àò" },
    { "/inf  /timeinfo", "èíôî äëÿ èãðîêîâ è àêöèÿ çà îíëàéí â /aad" },
    { "/razdintro [ïðèç]", "âñòóïëåíèå ïåðåä ðàçäà÷åé â /aad" },
    { "/captlist  /bizwarlist", "ïàìÿòêè ïî ïðàâèëàì êàïòîâ è áèçâàðîâ" },
    { "/vopros 1-7", "âîïðîñ ëèäåðó â ÷àò, îòâåò ïîêàæåò âàì" },
    { "#", "Íàêàçàíèÿ" },
    { "/jj /mut /ww [ID]", "jail, mute, warn - âñòàâÿò êîìàíäó â ââîä" },
    { "/bb /uw /uj /unm /ub", "ban, unwarn, unjail, unmute, unban" },
    { "/ib /ip /bip /ofl /mkl", "iban, pgetip, banip, offleader, makeleader" },
    { "/gs /inv [ID]", "getstats, checkinv (ID èëè èç /re)" },
    { "/fuel /fc /gh /wh /gzc /bp", "fuelcars, ghetto, warehouse, gzcolor, setbizprod" },
    { "/spc /dva /dvs", "spawncars; óäàëåíèå àäìèí-êàðîâ (òàéìåð 15 ñ â /a); òî æå + spawncars" },
    { "/vr  /vrstop", "òî æå, ÷òî /dvs; îòìåíà òàéìåðà" },
    { "#", "Ïðî÷åå" },
    { "/z [êëþ÷]", "çàíÿòü çàäà÷ó: 3 ðàçà «z ...» â /a (ñïèñîê: /z)" },
    { "/vr  /vrstop", "ðåñïàâí òðàíñïîðòà ÷åðåç 15 ñåê / îòìåíà" },
    { "/mpa  /fhset automp on|off", "ââåñòè /mp è íàæàòü 1-þ ñòðîêó / àâòî-ðåæèì" },
    { "/fbind  /bnd", "ñâîé áèíäåð: îêíî è êîìàíäû (ñïðàâêà /binder)" },
    { "/notes", "øïàðãàëêè (ñâîè çàìåòêè)" },
}

local function uiMenu()
    local t = { "{A9A9A9}Êîìàíäà\t{A9A9A9}×òî äåëàåò" }
    for _, r in ipairs(MENU_ROWS) do
        if r[1] == "#" then t[#t + 1] = "{66CCFF}" .. r[2] .. "\t"
        else t[#t + 1] = "{FFFF00}" .. r[1] .. "\t{FFFFFF}" .. r[2] end
    end
    uiShow(D_MENU, "FH " .. VERSION .. " | Êîìàíäû", table.concat(t, "\n"), "Çàêðûòü", "", 5)
end

uiHandlers[D_MENU] = function() end

----------------------------------------------------------------------
-- ÎÊÍÎ MIMGUI: /fh -- ìåíþ ñëåâà, ñòðàíèöû ñïðàâà
-- Åñëè mimgui/øðèôò ñ êèðèëëèöåé íåäîñòóïíû, /fh îòêðîåò îáû÷íîå äèàëîãîâîå îêíî.
----------------------------------------------------------------------
local postedActions = {}
local function post(fn) postedActions[#postedActions + 1] = fn end
local function runPosted()
    while #postedActions > 0 do
        local fn = table.remove(postedActions, 1)
        local ok, err = pcall(fn)
        if not ok then print("[FH] gui action error: " .. tostring(err)) end
    end
end

local guiState   -- çàïîëíÿåòñÿ â setupGui; nil, åñëè îêíî íåäîñòóïíî

local function setupGui()
    if not GUI_ENCODING_OK then return nil end
    local okI, imgui = pcall(require, 'mimgui')
    if not okI or type(imgui) ~= "table" then return nil end
    local okF, ffi = pcall(require, 'ffi')
    if not okF then return nil end

    -- ðàçìåð ýêðàíà è øðèôò
    local sw, sh = 1280, 720
    pcall(function() sw, sh = getScreenResolution() end)
    local fs = math.max(14, math.min(26, math.floor(sh / 55)))

    local fontPath
    local candidates = {}
    local okD, dir = pcall(getFolderPath, 0x14)
    if okD and type(dir) == "string" then
        for _, n in ipairs({ "arial.ttf", "segoeui.ttf", "tahoma.ttf", "arialbd.ttf" }) do candidates[#candidates + 1] = dir .. "\\" .. n end
    end
    for _, p in ipairs({ "/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSans-Regular.ttf", "/system/fonts/DroidSans.ttf" }) do
        candidates[#candidates + 1] = p
    end
    for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then f:close() fontPath = p break end
    end
    if not fontPath then return nil end

    local G = { show = imgui.new.bool(false), page = 12, errors = 0, disabled = false, initFailed = false, fs = fs }
    local ACC = imgui.ImVec4(cfg.accent[1], cfg.accent[2], cfg.accent[3], 1)
    local YEL = imgui.ImVec4(1, 0.85, 0.35, 1)
    local GRAY = imgui.ImVec4(0.62, 0.65, 0.70, 1)
    local GREEN = imgui.ImVec4(0.40, 0.85, 0.50, 1)
    local RED = imgui.ImVec4(0.95, 0.40, 0.40, 1)
    local V2 = imgui.ImVec2

    -- áóôåðû ââîäà
    local function buf(n) return imgui.new.char[n]() end
    local B = {
        gwWord = buf(64), gwPrize = buf(96), reply = buf(512), evId = buf(12),
        bindName = buf(24), bindText = buf(256), noteTitle = buf(48), noteText = buf(256), tpl = buf(160), claim = buf(64), evPrize = buf(96), chkWord = buf(24), chkSecs = buf(8), search = buf(48),
        aiUrl = buf(200), aiKey = buf(200), aiModel = buf(64), aiPrompt = buf(700), aiChat = buf(600), modId = buf(48), modTxt = buf(160),
    }
    local accBuf = imgui.new.float[3](cfg.accent[1], cfg.accent[2], cfg.accent[3])
    local bgBuf = imgui.new.float[3](cfg.bg[1], cfg.bg[2], cfg.bg[3])
    local alphaBuf = imgui.new.float(cfg.alpha)
    local autoBuf = imgui.new.bool(cfg.automp)
    local glassBuf = imgui.new.bool(cfg.glass)
    local liteBuf = imgui.new.bool(cfg.lite)
    local updBuf = imgui.new.bool(cfg.autoupd)
    local repBuf = imgui.new.bool(cfg.reptoast)
    local applyStyle   -- îïðåäåëÿåòñÿ íèæå

    local function getBuf(b) return fromUi(ffi.string(b)) end
    local function cutUtf8(s, n)
        if #s <= n then return s end
        local c = s:sub(1, n)
        while #c > 0 and c:byte(#c) >= 0x80 and c:byte(#c) < 0xC0 do c = c:sub(1, -2) end
        if #c > 0 and c:byte(#c) >= 0xC0 then c = c:sub(1, -2) end
        return c
    end
    local function loadAiBufs()
        ffi.copy(B.aiUrl, cutUtf8(toUi(cfg.aiUrl), 199)) ffi.copy(B.aiKey, cutUtf8(toUi(cfg.aiKey), 199))
        ffi.copy(B.aiModel, cutUtf8(toUi(cfg.aiModel), 63)) ffi.copy(B.aiPrompt, cutUtf8(toUi(cfg.aiPrompt), 699))
    end
    loadAiBufs()
    local function saveAi()
        cfg.aiUrl, cfg.aiKey, cfg.aiModel, cfg.aiPrompt = trim(getBuf(B.aiUrl)), trim(getBuf(B.aiKey)), trim(getBuf(B.aiModel)), trim(getBuf(B.aiPrompt))
        saveCfg()
    end
    local function clearBuf(b) ffi.fill(b, ffi.sizeof(b), 0) end
    local sel = { report = 0, fraction = 0, bind = "", note = 0, roles = {} }

    local ucache, ucount = {}, 0
    local function U(s)
        local c = ucache[s]
        if not c then
            if ucount > 600 then ucache, ucount = {}, 0 end   -- íå äà¸ì êýøó ðàñòè áåñêîíå÷íî
            c = toUi(s) ucache[s] = c ucount = ucount + 1
        end
        return c
    end
    -- êðóïíûé òåêñò (âòîðîé øðèôò, åñëè óäàëîñü çàãðóçèòü)
    local function bigText(s, color)
        pcall(imgui.SetWindowFontScale, 1.45)
        imgui.TextColored(color or ACC, U(s))
        pcall(imgui.SetWindowFontScale, 1)
    end
    local function title(s, sub)
        bigText(s, ACC)
        if sub then imgui.TextColored(GRAY, U(sub)) end
        imgui.Separator() imgui.Spacing()
    end
    -- ãëàâíàÿ êíîïêà äåéñòâèÿ: öâåò àêöåíòà
    local function primary(label, size)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cfg.accent[1] * 0.85, cfg.accent[2] * 0.85, cfg.accent[3] * 0.85, 0.85))
        local clicked = imgui.Button(U(label), size)
        imgui.PopStyleColor()
        return clicked
    end
    local function hint(s) imgui.TextColored(GRAY, U(s)) end

    ------------------------------------------------------------------
    -- ñòðàíèöû
    ------------------------------------------------------------------
    local pages = {}

    pages[1] = { "Êîìàíäû", function()
        title("Âñå êîìàíäû")
        imgui.Text(U("Ïîèñê")) imgui.SameLine()
        imgui.PushItemWidth(fs * 16) imgui.InputText("##cmdsearch", B.search, 40) imgui.PopItemWidth()
        local q = lower1251(trim(getBuf(B.search)))
        local head
        for _, r in ipairs(MENU_ROWS) do
            if r[1] == "#" then
                head = r[2]
                if q == "" then imgui.Spacing() imgui.TextColored(ACC, U(r[2])) head = nil end
            elseif q == "" or (r.l or (function() r.l = lower1251(r[1] .. " " .. r[2]) return r.l end)()):find(q, 1, true) then
                if head then imgui.Spacing() imgui.TextColored(ACC, U(head)) head = nil end
                imgui.TextColored(YEL, U(r[1])) imgui.SameLine(fs * 15) imgui.TextWrapped(U(r[2]))
            end
        end
    end }

    pages[2] = { "Ðàçäà÷è", function()
        title("Ðàçäà÷à ïðèçîâ")
        imgui.Text(U("Êîäîâîå ñëîâî")) imgui.PushItemWidth(-1) imgui.InputText("##gwword", B.gwWord, 64) imgui.PopItemWidth()
        imgui.Text(U("Ïðèç")) imgui.PushItemWidth(-1) imgui.InputText("##gwprize", B.gwPrize, 96) imgui.PopItemWidth()
        hint("Ôîðìàò ïðèçà: òèï è ÷èñëî. Íàïðèìåð: áàíê 500000, ëâë 3, #9 15 (íîìåð ñòàòû).")
        imgui.Spacing()
        local function start(isLast)
            local w, p = getBuf(B.gwWord), getBuf(B.gwPrize)
            post(function() gwStart(w .. " | " .. p, isLast) end)
        end
        if imgui.Button(U("Ñòàðò"), V2(fs * 7, fs * 2)) then start(false) end
        imgui.SameLine()
        if imgui.Button(U("Ôèíàëüíûé ðàóíä"), V2(fs * 10, fs * 2)) then start(true) end
        imgui.SameLine()
        if imgui.Button(U("Ñòîï"), V2(fs * 6, fs * 2)) then post(function() gw.active = false gw.last = false fmsg("Ðàçäà÷à îòìåíåíà.") end) end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        if gw.active then
            imgui.TextColored(GREEN, U("Èä¸ò ðàçäà÷à"))
            imgui.Text(U("Ñëîâî: " .. gw.word))
            imgui.Text(U("Ïðèç: " .. gw.prize))
            if not gw.stat then imgui.TextColored(RED, U("Òèï ïðèçà íå ðàñïîçíàí - âûäàâàòü âðó÷íóþ.")) end
        else
            imgui.TextColored(GRAY, U("Ðàçäà÷à íå çàïóùåíà."))
        end
    end }

    pages[3] = { "Ðåïîðòû", function()
        title("Ïîñëåäíèå ðåïîðòû")
        if imgui.Button(U("Îáíîâèòü èç /define") .. "##rpl", V2(fs * 12, fs * 1.8)) then post(function() DEF.refresh() end) end
        imgui.SameLine() hint("Ñïèñîê áåð¸òñÿ èç êîìàíäû /define (äèàëîã íå ïîêàçûâàåòñÿ).")
        if #reports == 0 then
            hint("Ðåïîðòîâ ïîêà íåò.")
        else
            imgui.BeginChild("##replist", V2(0, fs * 9), true)
            for i, r in ipairs(reports) do
                if imgui.Selectable(toUi(string.format("[%s] %s: %s", r.id, r.name, r.text)) .. "##r" .. i, sel.report == i) then sel.report = i end
            end
            imgui.EndChild()
            local r = reports[sel.report]
            local res = AI.result
            if res and r and res.id == r.id then
                AI.result = nil
                ffi.copy(B.reply, cutUtf8(toUi(res.text), 500))
            end
            if r then
                imgui.Spacing()
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##reply", U("Îòâåò èãðîêó (óéä¸ò ÷åðåç /pm)"), B.reply, 512) imgui.PopItemWidth()
                if imgui.Button(U("Îòâåòèòü"), V2(fs * 8, fs * 2)) then
                    local text, id = getBuf(B.reply), r.id
                    post(function() if replyTo(id, text) then clearBuf(B.reply) end end)
                end
                imgui.SameLine()
                if imgui.Button(U("Ïðèíÿòü â /a"), V2(fs * 9, fs * 2)) then
                    local id = r.id
                    post(function() cmdAr(id) end)
                end
                imgui.SameLine()
                if primary("ÈÈ îòâåò##aibtn", V2(fs * 8, fs * 2)) then
                    local rr = r
                    post(function() AI.suggest(rr, function() end) end)
                end
                imgui.Spacing()
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##rpreason", U("Ïðè÷èíà íàêàçàíèÿ (îáÿçàòåëüíî)"), B.modTxt, 160) imgui.PopItemWidth()
                for _, pa in ipairs({ { "Âàðí", "/warn" }, { "Ìóò", "/mute" }, { "Äæàéë", "/jail" }, { "Áàí", "/ban" } }) do
                    if imgui.Button(U(pa[1]) .. "##rp" .. pa[2], V2(fs * 6, fs * 2)) then
                        local rtx = trim(getBuf(B.modTxt))
                        if rtx == "" then G.modMsg = "Óêàæèòå ïðè÷èíó â ïîëå âûøå."
                        else
                            local line = pa[2] .. " " .. r.id .. " " .. rtx
                            G.modMsg = "Îòïðàâëåíî: " .. line
                            post(function() safeSend(line) end)
                        end
                    end
                    imgui.SameLine()
                end
                imgui.NewLine()
                if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
                if AI.status ~= "" then imgui.TextColored(GRAY, toUi(AI.status)) end
            else hint("Âûáåðèòå ðåïîðò èç ñïèñêà.") end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Øàáëîíû îòâåòîâ (íàæìèòå - òåêñò ïîïàä¸ò â ïîëå îòâåòà)"))
        for i, t in ipairs(templates) do
            if imgui.SmallButton(U("x") .. "##td" .. i) then
                local idx = i
                post(function() table.remove(templates, idx) saveTemplates() end)
            end
            imgui.SameLine()
            if imgui.Selectable(toUi(t) .. "##tp" .. i, false) then ffi.copy(B.reply, toUi(t):sub(1, 500)) end
        end
        imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##tplnew", U("íîâûé øàáëîí"), B.tpl, 160) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Äîáàâèòü øàáëîí"), V2(fs * 8, 0)) then
            local text = getBuf(B.tpl)
            post(function()
                local ok, msg = tplAdd(text)
                fmsg(msg)
                if ok then clearBuf(B.tpl) end
            end)
        end
    end }

    pages[4] = { "Ìåðîïðèÿòèÿ", function()
        title("Àíîíñû ÌÏ â /aad")
        imgui.Text(U("ID âåäóùåãî (äëÿ «Äîãîíè Èíôåðíóñ»)")) imgui.SameLine()
        imgui.PushItemWidth(fs * 5) imgui.InputText("##evid", B.evId, 12) imgui.PopItemWidth()
        imgui.Text(U("Ïðèç (íåîáÿçàòåëüíî)")) imgui.SameLine()
        imgui.PushItemWidth(fs * 14) imgui.InputText("##evprize", B.evPrize, 90) imgui.PopItemWidth()
        imgui.Spacing()
        for i, e in ipairs(EVENTS) do
            if imgui.Button(U(e[2]) .. "##e" .. i, V2(fs * 11, fs * 2)) then
                local key, arg = e, (getBuf(B.evId) .. " " .. getBuf(B.evPrize))
                post(function() announceEvent(key, arg) end)
            end
            if i % 3 ~= 0 then imgui.SameLine() end
        end
    end }

    pages[10] = { "Òðàíñïîðò", function()
        title("Òðàíñïîðò ñåðâåðà")
        local bw = V2(fs * 14, fs * 2)
        if imgui.Button(U("Çàñïàâíèòü êàðû ñåðâåðà") .. "##cs", bw) then post(function() carsDo("spawn") end) end
        imgui.SameLine()
        if imgui.Button(U("Óäàëèòü àäìèí-êàðû") .. "##cd", bw) then post(function() carsDo("dv") end) end
        if imgui.Button(U("Óäàëèòü + çàñïàâíèòü") .. "##cds", bw) then post(function() carsDo("dvs") end) end
        imgui.SameLine()
        if imgui.Button(U("Çàïðàâèòü êàðû") .. "##cf", bw) then post(function() carsDo("fuel") end) end
        imgui.Spacing()
        imgui.Spacing()
        hint("Óäàëåíèå àäìèí-êàðîâ: ñíà÷àëà ïðåäóïðåæäåíèå â /a, ÷åðåç 15 ñåêóíä /dvall.")
        if imgui.Button(U("Îòìåíèòü óäàëåíèå") .. "##cvs", bw) then post(function() pcall(sampProcessChatInput, "/vrstop") end) end
    end }

    local function selNames()
        local names = {}
        for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
        return names
    end

    pages[12] = { "Ãëàâíàÿ", function()
        title("Ãëàâíàÿ", "Áûñòðûå äåéñòâèÿ è ñîñòîÿíèå")
        local active = CHK and CHK.active
        local function tile(id, label, value, color)
            imgui.BeginChild("##tile" .. id, V2(fs * 8.6, fs * 4.2), true)
            imgui.TextColored(GRAY, U(label))
            bigText(value, color)
            imgui.EndChild()
        end
        tile(1, "Ðåïîðòîâ â ñïèñêå", tostring(#reports), ACC) imgui.SameLine()
        tile(2, "Àâòî-/mp", cfg.automp and "âêë" or "âûêë", cfg.automp and GREEN or GRAY) imgui.SameLine()
        tile(3, "Ïðîâåðêà àêòèâíîñòè", active and ("èä¸ò: " .. #CHK.list) or "íåò", active and GREEN or GRAY) imgui.SameLine()
        tile(4, "ID èç /re", tostring(watchedId or "-"), YEL)
        if UPD.latest and verNewer(UPD.latest, VERSION) then
            imgui.BeginChild("##updbanner", V2(0, fs * 3.2), true)
            imgui.TextColored(YEL, toUi("Äîñòóïíî îáíîâëåíèå v" .. UPD.latest .. " (ó âàñ v" .. VERSION .. ")"))
            if UPD.notes ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.notes)) end
            if primary("Óñòàíîâèòü îáíîâëåíèå##updinst", V2(fs * 14, fs * 1.6)) then post(UPD.install) end
            imgui.EndChild()
        end
        imgui.Spacing()
        local bw = V2(fs * 12.5, fs * 2.4)
        local function btn(label, id, fn, same, prim)
            local clicked
            if prim then clicked = primary(label .. "##h" .. id, bw) else clicked = imgui.Button(U(label) .. "##h" .. id, bw) end
            if clicked then post(fn) end
            if same then imgui.SameLine() end
        end
        imgui.TextColored(ACC, U("ÏÐÎÂÅÐÊÈ È ÐÅÏÎÐÒÛ"))
        btn("Ïðîâåðêà àêòèâíîñòè", 1, function() INFO.a1(selNames()) end, true, true)
        btn("Ñïèñîê ðåïîðòîâ", 2, function() G.page = 3 end, true)
        btn("Ðàçäà÷à ïðèçîâ", 3, function() G.page = 2 end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("ÒÐÀÍÑÏÎÐÒ"))
        btn("Çàïðàâèòü êàðû", 4, function() carsDo("fuel") end, true)
        btn("Çàñïàâíèòü êàðû", 5, function() carsDo("spawn") end, true)
        btn("Óäàëèòü àäì-êàðû (15 ñ)", 6, function() carsDo("dv") end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("ÌÅÐÎÏÐÈßÒÈß È ÎÁÚßÂËÅÍÈß"))
        btn("Íàæàòü /mp", 7, function() armAutoMp(true) end, true)
        btn("Ïðàâèëà ëèäåðàì", 8, function() INFO.rules() end, true)
        btn("Èíôî èãðîêàì", 9, function() INFO.inf() end, false)
        imgui.Spacing()
        hint("Îñòàëüíîå - â ìåíþ ñëåâà. Âñå êîìàíäû è ïîèñê ïî íèì: ñòðàíèöà «Êîìàíäû».")
    end }

    pages[13] = { "Ïðîâåðêà", function()
        title("Ïðîâåðêà àêòèâíîñòè")
        hint("Âûáåðèòå äîëæíîñòè èëè íàáîð. Åñëè íèêîãî íå âûáðàòü - îáùàÿ ïðîâåðêà.")
        for i, p in ipairs(CHK_PRESETS) do
            if imgui.Button(U(p[1]) .. "##pre" .. i, V2(fs * 9, fs * 1.8)) then
                sel.roles = {}
                for _, k in ipairs(p[2]) do
                    for ri, r in ipairs(ROLES) do if r[1] == k then sel.roles[ri] = true end end
                end
            end
            imgui.SameLine()
        end
        if imgui.Button(U("Ñáðîñèòü") .. "##prer", V2(fs * 7, fs * 1.8)) then sel.roles = {} end
        imgui.Spacing()
        local function roleBtn(i)
            if imgui.Selectable(U(ROLES[i][2]) .. "##crole" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
        end
        imgui.TextColored(ACC, U("Ðóêîâîäÿùèå"))
        for i = 1, 7 do
            roleBtn(i)
            if i ~= 4 and i < 7 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.TextColored(ACC, U("Ñëåäÿùèå (ÃÑ, ÇÃÑ, ÏÃÑ ïî ñòðóêòóðàì)"))
        for i = 8, #ROLES do
            roleBtn(i)
            if (i - 7) % 3 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        imgui.Spacing()
        imgui.Text(U("Îòâåò")) imgui.SameLine()
        imgui.PushItemWidth(fs * 6) imgui.InputText("##chkword", B.chkWord, 20) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("Ñåêóíä")) imgui.SameLine()
        imgui.PushItemWidth(fs * 4) imgui.InputText("##chksecs", B.chkSecs, 6) imgui.PopItemWidth()
        imgui.SameLine() hint("(0 - áåç òàéìåðà)")
        local word = trim(getBuf(B.chkWord))
        local secs = tonumber(getBuf(B.chkSecs)) or 0
        imgui.Spacing()
        imgui.TextColored(YEL, U("×òî óéä¸ò â /a:"))
        local names = selNames()
        local key = table.concat(names, "|") .. "#" .. word .. "#" .. secs
        if G.chkKey ~= key then G.chkKey, G.chkPreview = key, (chkLines(names, word, secs)) end
        for _, l in ipairs(G.chkPreview) do imgui.TextWrapped(U(l)) end
        imgui.Spacing()
        local bw = V2(fs * 11, fs * 2.2)
        if primary("Íà÷àòü ïðîâåðêó##chkgo", bw) then
            local names = selNames()
            post(function() sayA1(names, { word = word, seconds = secs }) end)
        end
        imgui.SameLine()
        if imgui.Button(U("Çàâåðøèòü è îáúÿâèòü") .. "##chkfin", bw) then post(function() chkEnd(true) end) end
        imgui.SameLine()
        if imgui.Button(U("Èòîã îêíîì") .. "##chkres", bw) then post(chkShow) end
        imgui.Spacing()
        if CHK.active then imgui.TextColored(GREEN, U("Èä¸ò ïðîâåðêà. Îòìåòèëèñü: " .. #CHK.list))
        else imgui.TextColored(GRAY, U("Ïðîâåðêà íå èä¸ò. Ïîñëåäíèé ðåçóëüòàò: " .. #CHK.list)) end
        imgui.BeginChild("##chkans", V2(0, fs * 7), true)
        if #CHK.list == 0 then hint("Ïîêà íèêòî íå îòâåòèë.") end
        for i, e in ipairs(CHK.list) do
            imgui.Text(U(i .. ". " .. e.name .. (e.id and ("[" .. e.id .. "]") or "")))
            imgui.SameLine(fs * 16) imgui.TextColored(GRAY, U("÷åðåç " .. e.sec .. " ñåê."))
        end
        imgui.EndChild()
    end }

    pages[14] = { "ÈÈ", function()
        title("ÈÈ-ïîìîùíèê")
        hint("Ñïðîñèòå ÷òî óãîäíî: ïðàâèëà, ôîðìóëèðîâêè, îòâåò èãðîêó. Îòâåò ïîÿâèòñÿ íèæå.")
        imgui.InputTextMultiline("##aichat", B.aiChat, 600, V2(-1, fs * 4))
        local bw = V2(fs * 11, fs * 2)
        if primary("Ñïðîñèòü##aiask", bw) then
            local q = trim(getBuf(B.aiChat))
            if q == "" then G.aiMsg = "Íàïèøèòå âîïðîñ."
            elseif not AI.ready() then G.aiMsg = "Ñíà÷àëà çàïîëíèòå àäðåñ è êëþ÷ API â Íàñòðîéêàõ."
            else
                G.aiMsg = "Äóìàþ..."
                post(function()
                    AI.ask("Òû ïîìîùíèê àäìèíèñòðàòîðà SA-MP ñåðâåðà. Îòâå÷àé êðàòêî, ïî-ðóññêè.", q, function(ok, text)
                        G.aiMsg = ok and tostring(text) or ("Îøèáêà: " .. tostring(text))
                    end)
                end)
            end
        end
        imgui.SameLine()
        if imgui.Button(U("Î÷èñòèòü") .. "##aiclr", bw) then ffi.copy(B.aiChat, "") G.aiMsg = nil end
        imgui.BeginChild("##aians", V2(0, fs * 8), true)
        imgui.TextWrapped(U(G.aiMsg or "Îòâåò ïîÿâèòñÿ çäåñü."))
        imgui.EndChild()
    end }

    pages[15] = { "Ìîäåðàöèÿ", function()
        title("Ìîäåðàöèÿ")
        hint("Óêàæèòå ID èëè íèê è òåêñò (ïðè÷èíó). Êíîïêè îòïðàâëÿþò êîìàíäó ñðàçó, êàê ïðè ââîäå â ÷àò.")
        imgui.Text(U("ID / íèê")) imgui.SameLine()
        imgui.PushItemWidth(fs * 12) imgui.InputText("##modid", B.modId, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("Òåêñò")) imgui.SameLine()
        imgui.PushItemWidth(-1) imgui.InputText("##modtxt", B.modTxt, 160) imgui.PopItemWidth()
        local mid, mtx = trim(getBuf(B.modId)), trim(getBuf(B.modTxt))
        local bw = V2(fs * 9, fs * 2)
        local ACT = {
            { "Ãåòòî", "/ghetto", false },
            { "Ñêëàä", "/warehouse", false },
            { "Öâåò áàíäû", "/gzcolor", "text" },
            { "Âàðí", "/warn", "idtext" },
            { "Àíâàðí", "/unwarn", "id" },
            { "Ìóò", "/mute", "idtext" },
            { "Ðàçìóò", "/unmute", "id" },
            { "Äæàéë", "/jail", "idtext" },
            { "Èç äæàéëà", "/unjail", "id" },
            { "Áàí", "/ban", "idtext" },
            { "Ðàçáàí", "/unban", "id" },
            { "Ñòàòèñòèêà", "/getstats", "id" },
            { "Èíâåíòàðü", "/checkinv", "id" },
        }
        for i, a in ipairs(ACT) do
            if imgui.Button(U(a[1]) .. "##mod" .. i, bw) then
                local need = a[3]
                if (need == "id" or need == "idtext") and mid == "" then
                    G.modMsg = "Óêàæèòå ID èëè íèê."
                elseif (need == "text" or need == "idtext") and mtx == "" then
                    G.modMsg = "Çàïîëíèòå ïîëå «Òåêñò»."
                else
                    local parts = { a[2] }
                    if need == "id" or need == "idtext" then parts[#parts + 1] = mid end
                    if need == "text" or need == "idtext" then parts[#parts + 1] = mtx end
                    local line = table.concat(parts, " ")
                    G.modMsg = "Îòïðàâëåíî: " .. line
                    post(function() safeSend(line) end)
                end
            end
            if i % 4 ~= 0 and i < #ACT then imgui.SameLine() end
        end
        imgui.Spacing()
        if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
    end }

    pages[11] = { "Ïàìÿòêè", function()
        title("Îáúÿâëåíèÿ è ïàìÿòêè")
        local bw = V2(fs * 14, fs * 2)
        imgui.TextColored(YEL, U("Ïðîâåðêà àêòèâíîñòè: âûáåðèòå äîëæíîñòè"))
        for i, r in ipairs(ROLES) do
            if imgui.Selectable(U(r[2]) .. "##role" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
            if i % 5 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        if imgui.Button(U("Ïðîâåðèòü âûáðàííûõ") .. "##i1", bw) then
            local names = {}
            for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
            post(function() infoDo("a1", names) end)
        end
        imgui.Spacing()
        imgui.SameLine()
        if imgui.Button(U("Ïðàâèëà ëèäåðàì") .. "##i2", bw) then post(function() infoDo("rules") end) end
        if imgui.Button(U("Èíôî èãðîêàì") .. "##i3", bw) then post(function() infoDo("inf") end) end
        imgui.SameLine()
        if imgui.Button(U("Àêöèÿ çà îíëàéí") .. "##i4", bw) then post(function() infoDo("time") end) end
        if imgui.Button(U("Âñòóïëåíèå ê ðàçäà÷å") .. "##i5", bw) then post(function() infoDo("intro", getBuf(B.gwPrize)) end) end
        imgui.SameLine()
        hint("Ïðèç áåð¸òñÿ èç ïîëÿ ðàçäà÷.")
        imgui.Spacing()
        if imgui.Button(U("Ïðàâèëà êàïòîâ") .. "##i6", bw) then post(function() infoDo("capt") end) end
        imgui.SameLine()
        if imgui.Button(U("Ïðàâèëà áèçâàðîâ") .. "##i7", bw) then post(function() infoDo("biz") end) end
        imgui.Spacing()
        hint("Âîïðîñ ëèäåðó â ÷àò (îòâåò â ÷àòå òîëüêî âàì):")
        for i, v in ipairs(VOPROS) do
            if imgui.Button(tostring(i) .. "##q" .. i, V2(fs * 3, fs * 2)) then post(function() infoDo("q", tostring(i)) end) end
            if i < #VOPROS then imgui.SameLine() end
        end
    end }

    pages[5] = { "Ôðàêöèè", function()
        title("Íàáîðû, îòáîðû, ëèäåðêè")
        imgui.BeginChild("##frlist", V2(0, fs * 11), true)
        for i, f in ipairs(FRACTIONS) do
            if imgui.Selectable(U(f[2]) .. "##f" .. i, sel.fraction == i) then sel.fraction = i end
        end
        imgui.EndChild()
        local f = FRACTIONS[sel.fraction]
        imgui.Spacing()
        if not f then hint("Âûáåðèòå ôðàêöèþ.") return end
        imgui.TextColored(YEL, U(f[2]))
        if imgui.Button(U("Íàáîð (/o)"), V2(fs * 9, fs * 2)) then post(function() recruit(f) end) end
        imgui.SameLine()
        if imgui.Button(U("Îòáîð (/aad)"), V2(fs * 9, fs * 2)) then post(function() tryoutAad(f) end) end
        imgui.SameLine()
        if imgui.Button(U("Îòáîð (/o)"), V2(fs * 9, fs * 2)) then post(function() tryoutO(f) end) end
        if imgui.Button(U("Âçÿòü ëèäåðêó"), V2(fs * 9, fs * 2)) then post(function() tempLeader(f) end) end
    end }

    pages[6] = { "Áèíäåð", function()
        title("Ñâîè áèíäû")
        local names = sortedBindNames()
        imgui.BeginChild("##bindlist", V2(fs * 12, fs * 10), true)
        for _, n in ipairs(names) do
            if imgui.Selectable(U("/" .. n) .. "##b" .. n, sel.bind == n) then sel.bind = n end
        end
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild("##bindinfo", V2(0, fs * 10), true)
        local b = binds[sel.bind]
        if b then
            imgui.TextColored(YEL, U("/" .. sel.bind .. "  (ïàóçà " .. b.delay .. " ìñ)"))
            for i, l in ipairs(b.lines) do imgui.TextWrapped(toUi(i .. ". " .. l)) end
        else hint("Âûáåðèòå áèíä ñëåâà èëè ñîçäàéòå íîâûé íèæå.") end
        imgui.EndChild()
        if b then
            local name = sel.bind
            if imgui.Button(U("Çàïóñòèòü"), V2(fs * 8, fs * 2)) then post(function() runBind(name, "") end) end
            imgui.SameLine()
            if imgui.Button(U("Óäàëèòü áèíä"), V2(fs * 9, fs * 2)) then post(function() bindDelete(name) sel.bind = "" end) end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Íîâûé áèíä / äîáàâèòü ñòðîêó"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##bname", U("èìÿ"), B.bindName, 24) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##btext", U("òåêñò; íåñêîëüêî ñòðîê ÷åðåç ;;"), B.bindText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Äîáàâèòü"), V2(fs * 6, 0)) then
            local name, text = trim(getBuf(B.bindName)):lower(), getBuf(B.bindText)
            post(function()
                local ok, msg, n2 = bindAdd(name, text)
                bmsg(msg)
                if ok then sel.bind = n2 clearBuf(B.bindText) end
            end)
        end
    end }

    pages[7] = { "Øïàðãàëêè", function()
        title("Ñâîè çàìåòêè")
        imgui.BeginChild("##notelist", V2(fs * 12, fs * 10), true)
        for i, n in ipairs(notes) do
            if imgui.Selectable(toUi(n.title) .. "##n" .. i, sel.note == i) then sel.note = i end
        end
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild("##noteinfo", V2(0, fs * 10), true)
        local n = notes[sel.note]
        if n then for _, l in ipairs(n.lines) do imgui.TextWrapped(toUi(l)) end
        else hint("Âûáåðèòå çàìåòêó ñëåâà èëè ñîçäàéòå íîâóþ íèæå.") end
        imgui.EndChild()
        if n and imgui.Button(U("Óäàëèòü çàìåòêó"), V2(fs * 10, fs * 2)) then
            local idx = sel.note
            post(function() table.remove(notes, idx) saveNotes() sel.note = 0 end)
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Íîâàÿ çàìåòêà / äîáàâèòü ñòðîêó"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##ntitle", U("íàçâàíèå"), B.noteTitle, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##ntext", U("òåêñò; íåñêîëüêî ñòðîê ÷åðåç ;;"), B.noteText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Ñîõðàíèòü"), V2(fs * 6, 0)) then
            local t, x = getBuf(B.noteTitle), getBuf(B.noteText)
            post(function()
                local ok, msg = noteAdd(t, x)
                fmsg(msg)
                if ok then clearBuf(B.noteText) end
            end)
        end
    end }

    local function applyColors()
        cfg.accent = { accBuf[0], accBuf[1], accBuf[2] }
        cfg.bg = { bgBuf[0], bgBuf[1], bgBuf[2] }
        cfg.alpha = math.max(0.5, math.min(1, alphaBuf[0]))
        ACC = imgui.ImVec4(cfg.accent[1], cfg.accent[2], cfg.accent[3], 1)
        applyStyle()
        post(saveCfg)
    end
    local PRESETS = {
        { "Ñèíÿÿ", 0.26, 0.62, 0.96 }, { "Êðàñíàÿ", 0.92, 0.30, 0.30 }, { "Çåë¸íàÿ", 0.30, 0.78, 0.45 },
        { "Ôèîëåòîâàÿ", 0.62, 0.40, 0.95 }, { "Îðàíæåâàÿ", 0.98, 0.58, 0.20 },
    }

    pages[8] = { "Íàñòðîéêè", function()
        title("Îôîðìëåíèå îêíà")
        imgui.Text(U("Öâåò àêöåíòà")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##acc", accBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("Öâåò ôîíà")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##bg", bgBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("Ïðîçðà÷íîñòü ôîíà")) imgui.PushItemWidth(fs * 16)
        if imgui.SliderFloat("##alpha", alphaBuf, 0.5, 1.0) then applyColors() end
        imgui.PopItemWidth()
        imgui.Spacing() imgui.Text(U("Ãîòîâûå öâåòà àêöåíòà:"))
        for i, p in ipairs(PRESETS) do
            if imgui.Button(U(p[1]) .. "##pr" .. i, V2(fs * 8, fs * 1.8)) then
                accBuf[0], accBuf[1], accBuf[2] = p[2], p[3], p[4]
                applyColors()
            end
            if i < #PRESETS then imgui.SameLine() end
        end
        if imgui.Button(U("Ñáðîñèòü öâåòà"), V2(fs * 10, fs * 1.8)) then
            accBuf[0], accBuf[1], accBuf[2] = 0.26, 0.62, 0.96
            bgBuf[0], bgBuf[1], bgBuf[2] = 0.07, 0.08, 0.10
            alphaBuf[0] = 0.97
            applyColors()
        end
        imgui.Spacing()
        if imgui.Checkbox(U("Ñòèëü Liquid Glass (ñòåêëî)"), glassBuf) then
            cfg.glass = glassBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("Ïîëóïðîçðà÷íûå ïàíåëè è öâåòíûå áëèêè. Ïðîçðà÷íîñòü ðåãóëèðóåòñÿ ïîëçóíêîì âûøå.")
        if imgui.Checkbox(U("Ë¸ãêèé ðåæèì (åñëè îêíî ëàãàåò)"), liteBuf) then
            cfg.lite = liteBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("Óáèðàåò áëèêè è ïðîçðà÷íîñòü îêíà - çàìåòíî ìåíüøå íàãðóçêà íà òåëåôîíå.")
        if imgui.Button(U("Ïîêàçàòü àíèìàöèþ îòêðûòèÿ ñíîâà") .. "##introagain", V2(fs * 16, fs * 2)) then
            cfg.introDone = false
            G.t0 = nil
            post(saveCfg)
        end
        hint("Àíèìàöèÿ ïîêàçûâàåòñÿ òîëüêî ïðè ïåðâîì çàïóñêå.")
        if imgui.Checkbox(U("Îâàëüíîå óâåäîìëåíèå î íîâîì ðåïîðòå (âíèçó ýêðàíà)"), repBuf) then
            cfg.reptoast = repBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Checkbox(U("Ïðîâåðÿòü îáíîâëåíèÿ ïðè çàïóñêå"), updBuf) then
            cfg.autoupd = updBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Button(U("Ïðîâåðèòü îáíîâëåíèÿ ñåé÷àñ") .. "##updnow", V2(fs * 14, fs * 2)) then post(function() UPD.check(false) end) end
        if UPD.status ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.status)) end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("Ìåðîïðèÿòèÿ")
        if imgui.Checkbox(U("Ïîñëå àíîíñà ÌÏ ââîäèòü /mp è íàæèìàòü 1-þ ñòðîêó"), autoBuf) then
            cfg.automp = autoBuf[0] and true or false
            post(saveCfg)
        end
        hint("Òî æå âðó÷íóþ: /mpa. Ïåðåêëþ÷àòåëü êîìàíäîé: /fhset automp on|off.")
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("ÈÈ-îòâåòû íà ðåïîðòû")
        hint("Ëþáîé ñåðâèñ ñ OpenAI-ñîâìåñòèìûì API (chat/completions). Íóæíû áèáëèîòåêè effil è requests.")
        hint("Êëþ÷ õðàíèòñÿ â moonloader/config/FilippHelper_settings.txt - íå âûêëàäûâàéòå ýòîò ôàéë.")
        local pw = (imgui.InputTextFlags and imgui.InputTextFlags.Password) or 0
        imgui.Text(U("Àäðåñ API")) imgui.PushItemWidth(-1) imgui.InputText("##aiurl", B.aiUrl, 200) imgui.PopItemWidth()
        imgui.Text(U("Êëþ÷ API")) imgui.PushItemWidth(-1) imgui.InputText("##aikey", B.aiKey, 200, pw) imgui.PopItemWidth()
        imgui.Text(U("Ìîäåëü")) imgui.PushItemWidth(-1) imgui.InputText("##aimodel", B.aiModel, 60) imgui.PopItemWidth()
        imgui.Text(U("Èíñòðóêöèÿ äëÿ ÈÈ (ïðàâèëà âàøåãî ñåðâåðà, ñòèëü îòâåòà)"))
        imgui.PushItemWidth(-1) imgui.InputText("##aiprompt", B.aiPrompt, 690) imgui.PopItemWidth()
        if imgui.Button(U("Ñîõðàíèòü") .. "##aisave", V2(fs * 9, fs * 2)) then post(function() saveAi() fmsg("Íàñòðîéêè ÈÈ ñîõðàíåíû.") end) end
        imgui.SameLine()
        if imgui.Button(U("Ñîõðàíèòü è ïðîâåðèòü") .. "##aitest", V2(fs * 12, fs * 2)) then post(function() saveAi() AI.test() end) end
        if AI.status ~= "" then imgui.TextWrapped(toUi(AI.status)) end
    end }

    pages[9] = { "Çàíÿòü", function()
        title("Çàíÿòü çàäà÷ó")
        hint("Íàæìèòå êíîïêó - â /a òðè ðàçà ïîäðÿä óéä¸ò «z ...».")
        imgui.Spacing()
        for i, c in ipairs(CLAIMS) do
            if imgui.Button(toUi("z " .. c[2]) .. "##z" .. i, V2(fs * 11, fs * 2)) then
                local txt = c[2]
                post(function() claim(txt) end)
            end
            if i % 3 ~= 0 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        imgui.Text(U("Ñâîé òåêñò (ïîñëå «z »)"))
        imgui.PushItemWidth(-fs * 7) imgui.InputText("##claimtext", B.claim, 64) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Çàíÿòü") .. "##claimgo", V2(fs * 6, 0)) then
            local txt = getBuf(B.claim)
            post(function() claim(txt) end)
        end
    end }

    ------------------------------------------------------------------
    -- îêíî
    ------------------------------------------------------------------
    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then
            G.errors = G.errors + 1
            print("[FH] gui error: " .. tostring(err))
            if G.errors >= 3 then G.disabled = true G.show[0] = false end
        end
    end

    local function drawBody()
        -- ëåâîå ìåíþ
        imgui.BeginChild("##side", V2(fs * 10, 0), true)
        guarded(function()
            bigText("FilippHelper", ACC)
            imgui.TextColored(GRAY, U("by ByFilipp  ·  v" .. VERSION))
            imgui.Separator() imgui.Spacing()
            -- ãðóïïû ìåíþ; íàñòðîéêè âñåãäà â ñàìîì íèçó
            local groups = {
                { "ÃËÀÂÍÎÅ", { "Ãëàâíàÿ", "Ðåïîðòû", "Ïðîâåðêà", "Ìåðîïðèÿòèÿ", "Ðàçäà÷è" } },
                { "ÀÄÌÈÍÈÑÒÐÈÐÎÂÀÍÈÅ", { "Çàíÿòü", "Ôðàêöèè", "Òðàíñïîðò", "Ïàìÿòêè" } },
                { "ÌÎÄÅÐÀÖÈß", { "Ìîäåðàöèÿ" } },
                { "ÈÍÑÒÐÓÌÅÍÒÛ", { "ÈÈ", "Áèíäåð", "Øïàðãàëêè", "Êîìàíäû" } },
            }
            local byName, used = {}, {}
            for i, p in ipairs(pages) do byName[p[1]] = i end
            local function drawBtn(i)
                local p = pages[i]
                used[i] = true
                local active = G.page == i
                if active then imgui.PushStyleColor(imgui.Col.Button, ACC) end
                local clicked = imgui.Button(U(p[1]) .. "##p" .. i, V2(-1, fs * 2.1))
                if active then imgui.PopStyleColor() end
                if clicked then G.page = i end
            end
            for gi, g in ipairs(groups) do
                imgui.Spacing() imgui.TextColored(GRAY, U(g[1]))
                for _, name in ipairs(g[2]) do
                    local i = byName[name]
                    if i then drawBtn(i) end
                end
                if gi == #groups then
                    for i, p in ipairs(pages) do   -- ñòðàíèöû, êîòîðûõ íåò â ãðóïïàõ
                        if not used[i] and p[1] ~= "Íàñòðîéêè" then drawBtn(i) end
                    end
                end
            end
            local si = byName["Íàñòðîéêè"]
            if si then imgui.Separator() imgui.Spacing() drawBtn(si) end
            imgui.Spacing() imgui.TextColored(GRAY, U("Ïîääåðæêà: @ByFilipp123"))
        end)
        imgui.EndChild()
        imgui.SameLine()
        -- ïðàâàÿ ÷àñòü
        imgui.BeginChild("##content", V2(0, 0), true)
        guarded(function() pages[G.page][2]() end)
        imgui.EndChild()
    end

    applyStyle = function()
        local st = imgui.GetStyle()
        local c, Col = st.Colors, imgui.Col
        local function set(k, r, g, b, a) c[Col[k]] = imgui.ImVec4(r, g, b, a or 1) end
        local ar, ag, ab = cfg.accent[1], cfg.accent[2], cfg.accent[3]
        local br, bg_, bb = cfg.bg[1], cfg.bg[2], cfg.bg[3]
        local function lift(v, d) return math.max(0, math.min(1, v + d)) end
        st.WindowPadding, st.FramePadding, st.ItemSpacing = V2(12, 12), V2(8, 6), V2(8, 8)
        if cfg.glass then
            -- Liquid Glass: ïîëóïðîçðà÷íûå ïàíåëè, ñâåòëûå òîíêèå ãðàíèöû, áîëüøèå ñêðóãëåíèÿ
            st.WindowRounding, st.ChildRounding, st.FrameRounding, st.GrabRounding, st.ScrollbarRounding = 22, 16, 12, 10, 12
            st.WindowBorderSize, st.ChildBorderSize, st.FrameBorderSize = 1, 1, 1
            set("WindowBg", br, bg_, bb, cfg.lite and 1 or cfg.alpha * 0.6)
            set("ChildBg", 1, 1, 1, 0.06)
            set("Border", 1, 1, 1, 0.28)
            set("Text", 0.96, 0.97, 1.0)
            set("FrameBg", 1, 1, 1, 0.08) set("FrameBgHovered", 1, 1, 1, 0.15) set("FrameBgActive", 1, 1, 1, 0.20)
            set("TitleBg", br, bg_, bb, 0.35) set("TitleBgActive", br, bg_, bb, 0.55) set("TitleBgCollapsed", br, bg_, bb, 0.35)
            set("Button", 1, 1, 1, 0.10) set("ButtonHovered", ar, ag, ab, 0.55) set("ButtonActive", ar, ag, ab, 0.75)
            set("Header", ar, ag, ab, 0.35) set("HeaderHovered", ar, ag, ab, 0.50) set("HeaderActive", ar, ag, ab, 0.65)
            set("CheckMark", ar, ag, ab) set("SliderGrab", ar, ag, ab) set("SliderGrabActive", ar * 0.8, ag * 0.8, ab * 0.8)
            set("Separator", 1, 1, 1, 0.18)
            set("ScrollbarBg", 0, 0, 0, 0) set("ScrollbarGrab", 1, 1, 1, 0.25)
        else
            st.WindowRounding, st.ChildRounding, st.FrameRounding, st.GrabRounding, st.ScrollbarRounding = 10, 8, 6, 6, 8
            st.WindowBorderSize, st.ChildBorderSize, st.FrameBorderSize = 1, 1, 0
            set("WindowBg", br, bg_, bb, cfg.lite and 1 or cfg.alpha)
            set("ChildBg", lift(br, 0.03), lift(bg_, 0.03), lift(bb, 0.04))
            set("Border", lift(br, 0.13), lift(bg_, 0.14), lift(bb, 0.18)) set("Text", 0.92, 0.93, 0.95)
            set("FrameBg", lift(br, 0.07), lift(bg_, 0.08), lift(bb, 0.10))
            set("FrameBgHovered", lift(br, 0.11), lift(bg_, 0.13), lift(bb, 0.17)) set("FrameBgActive", lift(br, 0.13), lift(bg_, 0.16), lift(bb, 0.21))
            set("TitleBg", lift(br, 0.02), lift(bg_, 0.02), lift(bb, 0.03)) set("TitleBgActive", lift(br, 0.04), lift(bg_, 0.05), lift(bb, 0.08))
            set("Button", lift(br, 0.09), lift(bg_, 0.10), lift(bb, 0.14))
            set("ButtonHovered", ar * 0.85, ag * 0.85, ab * 0.85) set("ButtonActive", ar * 0.7, ag * 0.7, ab * 0.7)
            set("Header", ar * 0.75, ag * 0.75, ab * 0.75, 0.6) set("HeaderHovered", ar, ag, ab, 0.7) set("HeaderActive", ar, ag, ab)
            set("CheckMark", ar, ag, ab) set("SliderGrab", ar, ag, ab) set("SliderGrabActive", ar * 0.8, ag * 0.8, ab * 0.8)
            set("Separator", lift(br, 0.15), lift(bg_, 0.17), lift(bb, 0.22))
        end
    end

    -- äåêîð ñòåêëà: ìÿãêèå öâåòíûå áëèêè çà ïàíåëÿìè è ñâåòîâàÿ ïîëîñà ñâåðõó
    local function drawGlass()
        if not cfg.glass or cfg.lite or G.noDeco then return end
        local ok, err = pcall(function()
            local dl = imgui.GetWindowDrawList()
            local p, sz = imgui.GetWindowPos(), imgui.GetWindowSize()
            local w, h = sz.x, sz.y
            local function col(r, g, b, a) return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a)) end
            local ar, ag, ab = cfg.accent[1], cfg.accent[2], cfg.accent[3]
            local blobs = {
                { 0.78, 0.15, ar, ag, ab }, { 0.25, 0.90, ab, ar, ag },
            }
            local R = h * 0.35
            for _, b in ipairs(blobs) do
                for k = 0, 3 do
                    dl:AddCircleFilled(V2(p.x + w * b[1], p.y + h * b[2]), R * (1 - k * 0.22), col(b[3], b[4], b[5], 0.05), 48)
                end
            end
            local top, bot = col(1, 1, 1, 0.14), col(1, 1, 1, 0)
            dl:AddRectFilledMultiColor(V2(p.x + 22, p.y + 2), V2(p.x + w - 22, p.y + h * 0.10), top, top, bot, bot)
        end)
        if not ok then
            G.noDeco = true
            print("[FH] glass decoration disabled: " .. tostring(err))
        end
    end

    -- àíèìàöèÿ îòêðûòèÿ: âðàùàþùàÿñÿ èñêðà, ïå÷àòàþùååñÿ íàçâàíèå è íàäïèñü «ByFilipp & Claude»
    local INTRO_T = 2.3
    local function drawIntro(age)
        local dl = imgui.GetWindowDrawList()
        local p, sz = imgui.GetWindowPos(), imgui.GetWindowSize()
        local ar, ag, ab = cfg.accent[1], cfg.accent[2], cfg.accent[3]
        local function col(r, g, b, a) return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a)) end
        local k = math.min(1, age / 0.7)
        local ease = 1 - (1 - k) ^ 3
        local fade = age > INTRO_T - 0.45 and math.max(0, (INTRO_T - age) / 0.45) or 1
        local a = ease * fade
        local cx, cy = p.x + sz.x / 2, p.y + sz.y / 2 - fs * 2.2
        local R = fs * 3.4 * ease
        for i = 0, 15 do
            local ang = age * 1.6 + i * math.pi / 8
            local len = R * (i % 2 == 0 and 1 or 0.55) * (0.85 + 0.15 * math.sin(age * 5 + i))
            dl:AddLine(V2(cx, cy), V2(cx + math.cos(ang) * len, cy + math.sin(ang) * len), col(ar, ag, ab, a * 0.9), 3)
        end
        dl:AddCircleFilled(V2(cx, cy), fs * 0.7 * ease, col(1, 1, 1, a), 24)
        dl:AddCircle(V2(cx, cy), R * 1.12, col(ar, ag, ab, a * 0.35), 48, 2)
        local function centered(str, y, c, big)
            if big then pcall(imgui.SetWindowFontScale, 1.45) end
            local w = imgui.CalcTextSize(U(str)).x
            imgui.SetCursorPos(V2((sz.x - w) / 2, y))
            imgui.TextColored(c, U(str))
            if big then pcall(imgui.SetWindowFontScale, 1) end
        end
        local full = "FilippHelper"
        local n = math.max(0, math.min(#full, math.floor((age - 0.35) / 0.08)))
        centered(full:sub(1, n), sz.y / 2 + fs * 1.8, imgui.ImVec4(1, 1, 1, fade), true)
        local sa = math.max(0, math.min(1, (age - 1.1) / 0.5)) * fade
        centered("by ByFilipp  &  Claude", sz.y / 2 + fs * 4.4, imgui.ImVec4(ar, ag, ab, sa), false)
        -- ïîëîñà çàãðóçêè
        local bw, by = sz.x * 0.28, p.y + sz.y / 2 + fs * 6.6
        local bx = cx - bw / 2
        dl:AddRectFilled(V2(bx, by), V2(bx + bw, by + 4), col(1, 1, 1, 0.12 * fade), 2)
        dl:AddRectFilled(V2(bx, by), V2(bx + bw * math.min(1, age / (INTRO_T - 0.4)), by + 4), col(ar, ag, ab, 0.9 * fade), 2)
    end

    imgui.OnInitialize(function()
        local ok, err = pcall(function()
            local io = imgui.GetIO()
            io.Fonts:AddFontFromFileTTF(fontPath, fs, nil, io.Fonts:GetGlyphRangesCyrillic())
            -- âòîðîé (áîëüøîé) øðèôò íå ñîçäà¸ì: ëèøíèé àòëàñ øðèôòîâ ðîíÿë èãðó íà ñëàáûõ ÏÊ; êðóïíûé òåêñò äåëàåì ìàñøòàáîì
            applyStyle()
        end)
        if not ok then G.initFailed = true print("[FH] gui init error: " .. tostring(err)) end
    end)

    -- ìåòêà «êðóòîé ðàçðàá ñêðèïòà» íàä ãîëîâîé èãðîêà Filipp_Evans (âñåãäà âêëþ÷åíà,
    -- âèäíà âñåì, ó êîãî ñòîèò ñêðèïò). Ðèñóåòñÿ ÷åðåç imgui; çàïàñíîé ñïîñîá - render-ôóíêöèè MoonLoader (/tagmode).
    local DEV_NICK, DEV_TEXT = "Filipp_Evans", "ByFilipp"
    local devState = { id = nil, t = -10 }
    local function devScreenPos()
        -- ïîêà SAMP íå ïîäêëþ÷¸í ê ñåðâåðó, åãî ôóíêöèè âûçûâàòü íåëüçÿ (èñêëþ÷åíèå â îïêîäå)
        if isSampAvailable and not isSampAvailable() then return end
        if sampGetGamestate then
            local okG, gs = pcall(sampGetGamestate)
            if not okG or gs ~= 3 then return end
        end
        local now = os.clock()
        local okMe, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if now - devState.t > 2 then          -- ðàç â 2 ñåêóíäû èùåì íóæíîãî èãðîêà
            devState.t, devState.id = now, nil
            if okMe and sampGetPlayerNickname(myId) == DEV_NICK then devState.id = myId
            else
                for id = 0, sampGetMaxPlayerId(false) do
                    if sampIsPlayerConnected(id) and sampGetPlayerNickname(id) == DEV_NICK then devState.id = id break end
                end
            end
        end
        local id = devState.id
        if not id then return end
        local ped = PLAYER_PED
        if not (okMe and id == myId) then
            local okP, h = sampGetCharHandleBySampPlayerId(id)
            if not okP then return end
            ped = h
        end
        if not doesCharExist(ped) then return end
        local x, y, z = getCharCoordinates(ped)
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        local dx, dy, dz = x - px, y - py, z - pz
        if dx * dx + dy * dy + dz * dz > 70 * 70 then return end
        if isPointOnScreen and not isPointOnScreen(x, y, z + 1.4, 1) then return end
        local sx, sy = convert3DCoordsToScreen(x, y, z + 1.45)
        if not sx or sx < 0 or sy < 0 or sx > sw or sy > sh then return end
        return sx, sy
    end

    imgui.OnFrame(function() return cfg.tagmode == 0 and not G.noTag and not G.disabled and not G.initFailed end, function(self)
        self.HideCursor = true
        if G.tagPause and os.clock() < G.tagPause then return end
        local ok, err = pcall(function()
            local sx, sy = devScreenPos()
            if not sx then return end
            G.tagFails = 0
            local dl = (imgui.GetBackgroundDrawList or imgui.GetForegroundDrawList)()
            local t = os.clock()
            local txt = DEV_TEXT
            local total = imgui.CalcTextSize(txt).x
            local x = sx - total / 2
            local y = sy - fs * 1.6
            for i = 1, #txt do
                local ch = txt:sub(i, i)
                local k = 0.5 + 0.5 * math.sin(t * 3 - i * 0.7)          -- áåãóùàÿ âîëíà ÿðêîñòè
                local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.1 + 0.25 * k, 0.55 + 0.45 * k, 0.2 + 0.2 * k, 1))
                local shadow = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.8))
                dl:AddText(V2(x + 1, y + 1), shadow, ch)
                dl:AddText(V2(x, y), col, ch)
                x = x + imgui.CalcTextSize(ch).x
            end
        end)
        if not ok then
            -- îøèáêà íå äîëæíà óáèâàòü ñêðèïò: â ÷àò èç êàäðà íå ïèøåì, äåëàåì ïàóçó è ïðîáóåì ñíîâà
            G.tagErr = tostring(err)
            G.tagFails = (G.tagFails or 0) + 1
            G.tagPause = os.clock() + 8
            print("[FH] dev tag error: " .. tostring(err))
            if G.tagFails >= 6 then G.noTag, cfg.tagmode = true, 1 end
        end
    end)

    -- çàïàñíîé ñïîñîá: render-ôóíêöèè MoonLoader (åñëè åñòü), ðèñóåò íåçàâèñèìî îò imgui
    if renderCreateFont and renderFontDrawText then
        lua_thread.create(function()
            local font = renderCreateFont("Arial", 10, 5)
            local text = toGame(DEV_TEXT)
            while true do
                if cfg.tagmode == 1 then
                    wait(0)
                    local ok, sx, sy = pcall(devScreenPos)
                    if ok and sx then
                        pcall(function()
                            local w = renderGetFontDrawTextLength(font, text)
                            local k = 0.5 + 0.5 * math.sin(os.clock() * 3)
                            renderFontDrawText(font, text, sx - w / 2, sy - 24, 0xFF000000 + math.floor(140 + 115 * k) * 256 + math.floor(40 + 40 * k))
                        end)
                    end
                else
                    wait(300)
                end
            end
        end)
    end

    function G.tagInfo() return { id = devState.id, mode = cfg.tagmode, off = G.noTag, err = G.tagErr } end

    -- îâàëüíîå óâåäîìëåíèå î íîâîì ðåïîðòå (íèç ýêðàíà ïî öåíòðó, öâåò îò àêöåíòà /fh)
    local REP_T = 6
    imgui.OnFrame(function()
        if G.rep and (os.clock() - G.rep.t0 >= REP_T) then G.rep = nil end
        return G.rep ~= nil and cfg.reptoast and not G.disabled and not G.initFailed and not G.noRepToast
    end, function(self)
        self.HideCursor = true
        local r = G.rep
        local age = os.clock() - r.t0
        local slide = 1 - (1 - math.min(1, age / 0.45)) ^ 3
        local fade = age > REP_T - 0.6 and math.max(0, (REP_T - age) / 0.6) or 1
        local w = math.min(sw * 0.92, fs * 38)
        local ar, ag, ab = cfg.accent[1], cfg.accent[2], cfg.accent[3]
        local flags = 0
        pcall(function()
            local F = imgui.WindowFlags
            flags = F.NoTitleBar + F.NoResize + F.NoMove + F.NoInputs + F.NoScrollbar + F.AlwaysAutoResize + F.NoSavedSettings
        end)
        imgui.SetNextWindowPos(V2(sw / 2, sh - fs * 3.5 + (1 - slide) * fs * 4), imgui.Cond.Always, V2(0.5, 1))
        imgui.SetNextWindowSize(V2(w, 0), imgui.Cond.Always)
        local nVar, nCol = 0, 0
        local function pushVar(name, v) if pcall(function() imgui.PushStyleVar(imgui.StyleVar[name], v) end) then nVar = nVar + 1 end end
        local function pushCol(name, c) if pcall(function() imgui.PushStyleColor(imgui.Col[name], c) end) then nCol = nCol + 1 end end
        pushVar("Alpha", fade)
        pushVar("WindowRounding", fs * 2.2)
        pushVar("WindowBorderSize", 2)
        pushVar("WindowPadding", V2(fs * 1.6, fs * 0.9))
        pushCol("WindowBg", imgui.ImVec4(ar * 0.22, ag * 0.22, ab * 0.22, 0.94))
        pushCol("Border", imgui.ImVec4(ar, ag, ab, 0.9))
        local began = imgui.Begin("##fhreptoast", nil, flags)
        if began then
            local ok, err = pcall(function()
                local dl = imgui.GetWindowDrawList()
                local p = imgui.GetWindowPos()
                dl:AddCircleFilled(V2(p.x + fs * 0.9, p.y + fs * 1.1), fs * 0.35 * (1 + 0.25 * math.sin(age * 8)),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(ar, ag, ab, 1)), 20)
                local head = "Ðåïîðò îò " .. r.name .. "[" .. r.id .. "]"
                if r.more > 0 then head = head .. "  (+" .. r.more .. ")" end
                bigText(head, imgui.ImVec4(math.min(1, ar + 0.35), math.min(1, ag + 0.35), math.min(1, ab + 0.35), 1))
                imgui.PushTextWrapPos(w - fs * 3.2)
                local bigBody = G.big and pcall(imgui.PushFont, G.big)
                if not bigBody then pcall(imgui.SetWindowFontScale, 1.35) end
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), U(r.text))
                if bigBody then imgui.PopFont() else pcall(imgui.SetWindowFontScale, 1) end
                imgui.PopTextWrapPos()
            end)
            if not ok then
                G.noRepToast, G.repErr = true, tostring(err)
                print("[FH] report toast disabled: " .. tostring(err))
                fmsg("Óâåäîìëåíèå î ðåïîðòå îòêëþ÷åíî èç-çà îøèáêè: " .. tostring(err):sub(1, 90))
            end
        end
        imgui.End()
        if nCol > 0 then imgui.PopStyleColor(nCol) end
        if nVar > 0 then imgui.PopStyleVar(nVar) end
    end)

    function G.reportToast(rep)
        local text = rep.text or ""
        if #text > 220 then text = text:sub(1, 217) .. "..." end
        local more = (G.rep and (os.clock() - G.rep.t0) < REP_T) and (G.rep.more + 1) or 0
        G.rep = { name = rep.name, id = rep.id, text = text, t0 = os.clock(), more = more }
        return cfg.reptoast and not G.noRepToast and not G.disabled and not G.initFailed
    end

    function G.diag()
        return { toast = cfg.reptoast, off = G.noRepToast, err = G.repErr, disabled = G.disabled, init = G.initFailed }
    end

    imgui.OnFrame(function()
        local on = G.show[0] and not G.disabled and not G.initFailed
        if not on then G.t0 = nil end
        return on
    end, function(self)
        self.HideCursor = false
        imgui.SetNextWindowSize(V2(fs * 50, fs * 30), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
        if imgui.Begin("FilippHelper##fh", G.show, imgui.WindowFlags.NoCollapse) then
            drawGlass()
            if not G.t0 then G.t0 = os.clock() end
            local age = os.clock() - G.t0
            if cfg.intro and not cfg.introDone and not G.noIntro and age < INTRO_T then
                local okI, errI = pcall(drawIntro, age)
                if not okI then
                    G.noIntro = true
                    print("[FH] intro disabled: " .. tostring(errI))
                end
                local okC, clicked = pcall(imgui.IsMouseClicked, 0)
                if okC and clicked then G.t0 = os.clock() - INTRO_T end
            else
                if cfg.intro and not cfg.introDone then   -- ïåðâûé ïîêàç çàêîí÷èëñÿ: áîëüøå íå ïîâòîðÿåì
                    cfg.introDone = true
                    post(saveCfg)
                end
                guarded(drawBody)
            end
        end
        imgui.End()
    end)

    function G.ready() return not G.disabled and not G.initFailed end
    function G.toggle() G.show[0] = not G.show[0] end
    return G
end

local okG, gs = pcall(setupGui)
if okG then guiState = gs else print("[FH] gui setup error: " .. tostring(gs)) end

----------------------------------------------------------------------
-- ÎÁÐÀÁÎÒÊÀ ÑÎÎÁÙÅÍÈÉ ÑÅÐÂÅÐÀ
----------------------------------------------------------------------
local function onServerMessageImpl(color, text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
    pcall(chkCollect, text)
    if not text:find("Ðåïîðò", 1, true) then return end

    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, body = clean:match("Ðåïîðò îò ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not name then return end
    body = body:gsub("%s*|%s*Óæå%s*%d+%s*ðåïîðò[^|]*$", "")

    table.insert(reports, 1, { name = name, id = id, text = body })
    pcall(function() if guiState and guiState.ready() then guiState.reportToast(reports[1]) end end)
    if #reports > MAX_REPORTS then table.remove(reports) end

    if gw.active and not GW_IGNORE_NAMES[name] and not clean:find(GW_TAG, 1, true)
       and lower1251(trim(body)) == gw.word then
        gwFinish(name, id)
    end
end

function ev.onServerMessage(color, text)
    local ok, err = pcall(onServerMessageImpl, color, text)
    if not ok then print("[FH] onServerMessage error: " .. tostring(err)) end
end

function ev.onSendCommand(command)
    PUN.note(command)
    if type(command) ~= "string" then return end
    if command:match("^/define") then DEF.user = os.clock() end
    local id = command:match("^/re%s+(%d+)")
    if id then watchedId = id
    elseif command:match("^/re%s+off") or command:match("^/reoff") then watchedId = nil end
end

----------------------------------------------------------------------
-- ÇÀÏÓÑÊ
----------------------------------------------------------------------
-- Ïåðåíåñ¸ííûå êîìàíäû ìîäåðàöèè è îá¸ðòêè (ñâîÿ ðåàëèçàöèÿ)
local function registerPorted(reg)
    local scThread
    local function tgt(p)
        p = trim(p or "")
        if p ~= "" then return p end
        return watchedId
    end
    -- îá¸ðòêè íàä ñåðâåðíûìè êîìàíäàìè
    reg("gt", function() safeSend("/ghetto") end)
    reg("wh", function() safeSend("/warehouse") end)
    reg("cb", function(p) if trim(p or "") ~= "" then safeSend("/warehouse " .. trim(p)) else fmsg("Óêàæèòå ïàðàìåòðû: /cb [òåêñò]") end end)
    reg("gc", function(p) if trim(p or "") ~= "" then safeSend("/gzcolor " .. trim(p)) else fmsg("Óêàæèòå ïàðàìåòðû: /gc [öâåò]") end end)
    reg("sprod", function(p)
        local a, b = (p or ""):match("(%d+)%s+(%d+)")
        if a then safeSend("/setbizprod " .. a .. " " .. b) else fmsg("Èñïîëüçîâàíèå: /sprod [ID áèçíåñà] [÷èñëî]") end
    end)
    reg("wn", function(p)
        p = trim(p or "")
        if p:match("^%d+%s+%S") then safeSend("/warn " .. p)
        else fmsg("Èñïîëüçîâàíèå: /wn [ID] [ïðè÷èíà]") end
    end)
    -- êîìàíäû ñ ID: âñòàâëÿþò êîìàíäó â ñòðîêó ÷àòà (êàê ó Áðóíî, íî ID ïî óìîë÷àíèþ èç /re)
    local function regId(cmd, sCmd, input)
        reg(cmd, function(p)
            local id = tgt(p)
            if not id then fmsg("Óêàæèòå ID: /" .. cmd .. " ID (èëè ñíà÷àëà /re ID)") return end
            if input then
                if sampSetChatInputText then sampSetChatInputText("/" .. sCmd .. " " .. id .. " ") end
                if sampSetChatInputEnabled then sampSetChatInputEnabled(true) end
            else
                safeSend("/" .. sCmd .. " " .. id)
            end
        end)
    end
    regId("jl", "jail", true) regId("mt", "mute", true)
    regId("as", "getstats", false) regId("ci", "checkinv", false)
    -- ñíÿòèå è áàí
    local function regArg(cmd, sCmd)
        reg(cmd, function(p)
            p = trim(p or "")
            if p ~= "" then safeSend("/" .. sCmd .. " " .. p) else fmsg("Èñïîëüçîâàíèå: /" .. cmd .. " [ID èëè íèê]") end
        end)
    end
    regArg("uwn", "unwarn") regArg("ujl", "unjail") regArg("um", "unmute") regArg("bn", "ban") regArg("ubn", "unban")
    -- òàéìåð óäàëåíèÿ è ðåñïàâíà òðàíñïîðòà
    reg("sc", function()
        if scThread then pcall(function() scThread:terminate() end) end
        scThread = lua_thread.create(function()
            safeSend("/a Âíèìàíèå, ÷åðåç 15 ñåêóíä óäàëÿþ è ðåñïàâíþ âåñü òðàíñïîðò íà ñåðâåðå!")
            wait(15000)
            safeSend("/dvall") wait(1500)
            safeSend("/spawncars")
            scThread = nil
        end)
    end)
    reg("scc", function()
        if scThread then
            pcall(function() scThread:terminate() end)
            scThread = nil
            fmsg("Òàéìåð ðåñïàâíà òðàíñïîðòà îñòàíîâëåí.")
        else fmsg("Òàéìåð ðåñïàâíà òðàíñïîðòà íå çàïóùåí.") end
    end)
end

local function registerCommands(reg)
    registerExtra(reg)
    registerPorted(reg)
    reg("fh", function()
        if guiState and guiState.ready() then guiState.toggle() else uiMenu() end
    end)
    reg("reports", uiReports)
    reg("rpl", function() DEF.refresh() end)
    reg("tagmode", function()
        cfg.tagmode = (cfg.tagmode == 0) and 1 or 0
        saveCfg()
        fmsg("Ìåòêà íàä èãðîêîì: ñïîñîá " .. (cfg.tagmode == 0 and "imgui (îñíîâíîé)" or "render (çàïàñíîé)") .. ".")
    end)
    reg("fcmd", uiMenu)
    reg("gw", function(p) gwStart(p, false) end)
    reg("gwlast", function(p) gwStart(p, true) end)
    reg("gwstop", function()
        if gw.active then gw.active = false gw.last = false fmsg("Ðàçäà÷à îòìåíåíà.")
        else fmsg("Ñåé÷àñ íåò àêòèâíîé ðàçäà÷è.") end
    end)
    reg("rr", function(p)
        local id, text = p:match("^(%d+)%s+(.+)$")
        if not id then id, text = watchedId, p end
        if not id or not replyTo(id, text) then fmsg("Èñïîëüçîâàíèå: /rr [ID] òåêñò") end
    end)
end

function main()
    if isSampLoaded and not isSampLoaded() then return end
    if isSampfuncsLoaded and not isSampfuncsLoaded() then return end
    while isSampAvailable and not isSampAvailable() do wait(100) end

    -- Çàùèòíûå îá¸ðòêè: îáðåçêà äëèíû, pcall -- êîìàíäû è äèàëîãè íå äîëæíû ðîíÿòü èãðó
    local rawAdd, rawDialog, rawReg, rawInput = sampAddChatMessage, sampShowDialog, sampRegisterChatCommand, sampSetChatInputText
    sampAddChatMessage = function(t, c)
        t = toGame(tostring(t or ""))
        if #t > 140 then t = t:sub(1, 140) end
        pcall(rawAdd, t, c or -1)
    end
    sampShowDialog = function(id, title, text, b1, b2, style)
        text, title = toGame(tostring(text or "")), toGame(tostring(title or ""))
        if #text > 4000 then text = text:sub(1, 4000) end
        if #title > 60 then title = title:sub(1, 60) end
        pcall(rawDialog, id, title, text, toGame(tostring(b1 or "OK")), toGame(tostring(b2 or "")), style or 0)
    end
    sampSetChatInputText = function(t) pcall(rawInput, toGame(tostring(t or ""))) end
    local function guardedReg(name, fn)
        return rawReg(name, function(arg)
            local ok, err = pcall(fn, type(arg) == "string" and fromGame(arg) or "")
            if not ok then
                print("[FH] command /" .. name .. " error: " .. tostring(err))
                fmsg("{FF3333}Îøèáêà â êîìàíäå /" .. name .. ", ïîäðîáíîñòè â moonloader.log")
            end
        end)
    end

    local builtin = {}
    local function trackedReg(n, f) builtin[n] = true return guardedReg(n, f) end
    local okReg, errReg = pcall(registerCommands, trackedReg)
    if not okReg then print("[FH] register error: " .. tostring(errReg)) end
    local okB, errB = pcall(setupBinder, builtin, guardedReg)
    if not okB then print("[FH] binder setup error: " .. tostring(errB)) end

    -- âñ¸, ÷òî òðîãàåò ÷àò è SAMP, - òîëüêî êîãäà èãðà ïîäêëþ÷åíà ê ñåðâåðó
    if sampGetGamestate then
        while true do
            local okG, gs = pcall(sampGetGamestate)
            if not okG or gs == 3 then break end
            wait(250)
        end
    end
    wait(1500)
    fmsg("{FFD700}FilippHelper v" .. VERSION .. " {FFFFFF}- çàãðóæåí")
    fmsg("{A9A9A9}Àâòîð è ðàçðàáîò÷èê: {66CCFF}ByFilipp {A9A9A9}| ïðè ó÷àñòèè {66CCFF}Claude {A9A9A9}(Anthropic)")
    fmsg("{A9A9A9}Ðàçäà÷è, ðåïîðòû, ìåðîïðèÿòèÿ, ïðîâåðêà àêòèâíîñòè, òðàíñïîðò, áèíäåð è ÈÈ-îòâåòû - â îäíîì îêíå")
    fmsg("{A9A9A9}Îêíî óïðàâëåíèÿ: {FFFF00}/fh {A9A9A9}| âñå êîìàíäû: {FFFF00}/fcmd {A9A9A9}| áèíäåð: {FFFF00}/fbind")
    fmsg("{A9A9A9}Îáíîâëåíèÿ: {FFFF00}/fhupd {A9A9A9}| äèàãíîñòèêà: {FFFF00}/fhdiag {A9A9A9}| ïðîâåðêà óâåäîìëåíèÿ: {FFFF00}/reptest")
    fmsg("{A9A9A9}Ïîääåðæêà è âîïðîñû: {FFFF00}@ByFilipp123 {A9A9A9}- ïðèÿòíîé èãðû!")
    if cfg.autoupd then
        lua_thread.create(function()
            wait(15000)   -- íå ìåøàåì çàãðóçêå èãðû
            pcall(UPD.check, true)
        end)
    end

    while true do
        wait(100)
        runPosted()
        local okT, errT = pcall(uiTick)
        if not okT then print("[FH] tick error: " .. tostring(errT)) end
    end
end
