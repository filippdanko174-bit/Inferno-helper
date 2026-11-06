-- FilippHelper v2.0 (FH) — помощник администратора SA-MP для MoonLoader. Автор: ByFilipp.
-- UTF-8 source; in-game Russian strings are represented as CP1251 byte escapes.
local okEv, ev = pcall(require, 'samp.events')
if not okEv then okEv, ev = pcall(require, 'lib.samp.events') end
if not okEv or type(ev) ~= "table" then
    ev = {}
    print("[FH] samp.events unavailable; server chat/dialog hooks are disabled.")
end

-- @ENC-BEGIN (на ПК файл уже в cp1251, перекодировка не нужна)
local encOk, encoding = pcall(require, 'encoding')
local enc8
if encOk and encoding then
    encoding.default = 'CP1251'
    enc8 = encoding.UTF8
end
local GUI_ENCODING_OK = enc8 ~= nil                                     -- для окна mimgui нужна перекодировка в UTF-8
local function toUi(s) if enc8 then return enc8:encode(s) end return s end    -- cp1251 -> UTF-8
local function fromUi(s) if enc8 then return enc8:decode(s) end return s end  -- UTF-8 -> cp1251
local function toGame(s) return s end     -- строка скрипта -> игра
local function fromGame(s) return s end   -- игра -> строка скрипта
-- @ENC-END

local VERSION = "2.0"

-- Safe local wrappers: shared MoonLoader globals are never monkey-patched.
local rawSampAddChatMessage = sampAddChatMessage
local rawSampShowDialog = sampShowDialog
local rawSampSetChatInputText = sampSetChatInputText
local function callSampNative(cached, globalName, ...)
    local fn = cached
    if type(fn) ~= "function" and _G then fn = _G[globalName] end
    if type(fn) ~= "function" then return false end
    local ok, result = pcall(fn, ...)
    if not ok then print("[FH] " .. globalName .. " failed: " .. tostring(result)) end
    return ok, result
end
local sampAddChatMessage = function(message, color)
    message = tostring(message or "")
    if #message > 140 then message = message:sub(1, 140) end
    return callSampNative(rawSampAddChatMessage, "sampAddChatMessage", message, color or -1)
end
local sampShowDialog = function(id, title, body, button1, button2, style)
    title, body = tostring(title or ""), tostring(body or "")
    if #title > 64 then title = title:sub(1, 64) end
    if #body > 4000 then body = body:sub(1, 4000) end
    return callSampNative(rawSampShowDialog, "sampShowDialog", id, title, body,
        tostring(button1 or "OK"), tostring(button2 or ""), style or 0)
end
local sampSetChatInputText = function(value)
    value = tostring(value or "")
    if #value > 256 then value = value:sub(1, 256) end
    return callSampNative(rawSampSetChatInputText, "sampSetChatInputText", value)
end
local UPDATE_FILE = "FilippHelper.lua"   -- какой файл скачивать с GitHub при обновлении
local MAX_CHAT_LEN = 128   -- безопасная длина строки для sampSendChat
local SEND_GAP = 1100      -- пауза между сообщениями (антифлуд сервера)
local MAX_REPORTS = 15

local watchedId = nil
local reports = {}

-- One cooperative timer queue is serviced from the main script loop.
local timerQueue = {}
local TIMER_LIMIT = 256
local function scheduleAfter(milliseconds, callback)
    if type(callback) ~= "function" then return nil end
    if #timerQueue >= TIMER_LIMIT then
        print("[FH] timer queue is full; task rejected")
        return nil
    end
    local delay = math.max(0, math.min(3600000, tonumber(milliseconds) or 0))
    local item = { deadline = os.clock() + delay / 1000, callback = callback, cancelled = false }
    timerQueue[#timerQueue + 1] = item
    return item
end

local function cancelTimer(item)
    if type(item) == "table" then item.cancelled = true end
end

local function processTimers()
    local now, processed, index = os.clock(), 0, 1
    while index <= #timerQueue and processed < 32 do
        local item = timerQueue[index]
        if item.cancelled then
            table.remove(timerQueue, index)
        elseif item.deadline <= now then
            table.remove(timerQueue, index)
            processed = processed + 1
            local ok, err = pcall(item.callback)
            if not ok then print("[FH] scheduled task error: " .. tostring(err)) end
        else
            index = index + 1
        end
    end
end

local sendQueue = {}
local SEND_QUEUE_LIMIT = 64
local SEND_SEQUENCE_LIMIT = 60
local nextGlobalSendAt = 0

local function chatReady()
    if type(sampSendChat) ~= "function" then return false end
    if type(isSampAvailable) == "function" then
        local ok, available = pcall(isSampAvailable)
        if not ok or not available then return false end
    end
    if type(sampGetGamestate) == "function" then
        local ok, state = pcall(sampGetGamestate)
        if not ok or state ~= 3 then return false end
    end
    return true
end

----------------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
----------------------------------------------------------------------
-- @LOWER-BEGIN
local LOWER_MAP = {}
for b = 192, 223 do LOWER_MAP[string.char(b)] = string.char(b + 32) end
LOWER_MAP[string.char(168)] = string.char(184) -- Ё -> ё
local function lower1251(s)
    return (s:lower():gsub("[\192-\223\168]", LOWER_MAP))
end
-- @LOWER-END

local function trim(s) return s:match("^%s*(.-)%s*$") end

-- Причина наказания: если сервер показывает список причин, выбираем подходящую по нашему тексту
local PUN = { pending = nil }
function PUN.note(raw)
    local kind, reason = tostring(raw or ""):match("^/(%a+)%s+%S+%s+(.+)$")
    if kind == "mute" or kind == "jail" or kind == "warn" or kind == "ban" then
        PUN.pending = { reason = reason, t = os.clock() }
    end
end

local function safeSend(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" or not chatReady() then return false end
    if #text > MAX_CHAT_LEN then text = text:sub(1, MAX_CHAT_LEN) end
    pcall(PUN.note, text)
    local ok, err = pcall(sampSendChat, text)
    if not ok then print("[FH] sampSendChat error: " .. tostring(err)) end
    return ok
end

-- All sequences share a FIFO and a global cooldown. This prevents overlapping
-- lua_thread coroutines from sending several messages in the same frame.
local function sendSeq(lines, gap, onDone, startDelay)
    if type(lines) ~= "table" then return nil end
    if #sendQueue >= SEND_QUEUE_LIMIT then
        print("[FH] send queue is full; sequence rejected")
        return nil
    end
    local clean = {}
    for i = 1, math.min(#lines, SEND_SEQUENCE_LIMIT) do
        local line = tostring(lines[i] or ""):gsub("%c", " ")
        if line ~= "" then clean[#clean + 1] = line end
    end
    if #clean == 0 then
        if type(onDone) == "function" then return scheduleAfter(startDelay or 0, onDone) end
        return nil
    end
    local delay = math.max(250, math.min(10000, tonumber(gap) or SEND_GAP))
    local initial = math.max(0, math.min(60000, tonumber(startDelay) or 0))
    local job = {
        lines = clean, index = 1, gap = delay,
        readyAt = os.clock() + initial / 1000,
        onDone = type(onDone) == "function" and onDone or nil,
        failures = 0,
    }
    sendQueue[#sendQueue + 1] = job
    return job
end

local function processSendQueue()
    local job = sendQueue[1]
    if not job then return end
    local now = os.clock()
    if now < job.readyAt or now < nextGlobalSendAt or not chatReady() then return end

    if job.index <= #job.lines then
        local ok = safeSend(job.lines[job.index])
        if not ok then
            job.failures = job.failures + 1
            job.readyAt = now + 0.5
            if job.failures >= 3 then
                print("[FH] dropping a chat sequence after 3 send failures")
                table.remove(sendQueue, 1)
            end
            return
        end
        job.failures = 0
        job.index = job.index + 1
        nextGlobalSendAt = now + job.gap / 1000
        job.readyAt = nextGlobalSendAt
        if job.index > #job.lines and not job.onDone then table.remove(sendQueue, 1) end
        return
    end

    table.remove(sendQueue, 1)
    if job.onDone then
        local ok, err = pcall(job.onDone)
        if not ok then print("[FH] send sequence callback error: " .. tostring(err)) end
    end
end

local function fmsg(text)
    sampAddChatMessage("{66CCFF}[FH] {FFFFFF}" .. text, -1)
end

----------------------------------------------------------------------
-- БИНДЕР: свои команды, создаются прямо в игре (/binder -- справка)
----------------------------------------------------------------------
local BIND_MAX, BIND_LINES = 50, 20
local binds = {}          -- binds[имя] = { delay = мс, lines = { ... } }
local bindFile
local bindBuiltin, bindReg = {}, nil
local bindRunning = false
-- имена, которые бинд занимать не должен (серверные/частые команды)
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
    if not ok then bmsg("\205\229 \243\228\224\235\238\241\252 \241\238\245\240\224\237\232\242\252 \225\232\237\228\229\240 \226 \244\224\233\235!") end
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
    if bindRunning then bmsg("\196\238\230\228\232\242\229\241\252 \238\234\238\237\247\224\237\232\255 \239\240\229\228\251\228\243\249\229\227\238 \225\232\237\228\224.") return end
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
    sampShowDialog(4109, "FH | \193\232\237\228\229\240",
        "{66CCFF}[ \209\194\206\201 \193\200\205\196\197\208 ]\n\n{33CC33}/fbind {FFFFFF}- \238\242\228\229\235\252\237\238\229 \238\234\237\238 \225\232\237\228\229\240\224 (\241\238\231\228\224\237\232\229 \232 \239\240\224\226\234\224 \225\229\231 \234\238\236\224\237\228).\n\n" ..
        "{FFFFFF}\209\238\231\228\224\184\242 \241\226\238\232 \234\238\236\224\237\228\251: \237\224\225\240\224\235\232 {FFFF00}/\232\236\255{FFFFFF} -- \238\242\239\240\224\226\232\235\232\241\252 \226\241\229 \241\242\240\238\234\232 \225\232\237\228\224 \239\238 \238\247\229\240\229\228\232.\n\n" ..
        "{66CCFF}/bnd add \232\236\255 \242\229\234\241\242 {FFFFFF}- \241\238\231\228\224\242\252 \225\232\237\228 / \228\238\225\224\226\232\242\252 \241\242\240\238\234\243.\n" ..
        "{FFFFFF}  \205\229\241\234\238\235\252\234\238 \241\242\240\238\234 \241\240\224\231\243 \240\224\231\228\229\235\255\233\242\229 {FFFF00};;{FFFFFF}, \237\224\239\240\232\236\229\240:\n" ..
        "{FFFF00}  /bnd add hi /aad \207\240\232\226\229\242! ;; /aad \202\224\234 \228\229\235\224?\n" ..
        "{66CCFF}/bnd rm \232\236\255 N {FFFFFF}- \243\228\224\235\232\242\252 \241\242\240\238\234\243 N.\n" ..
        "{66CCFF}/bnd del \232\236\255 {FFFFFF}- \243\228\224\235\232\242\252 \225\232\237\228 \246\229\235\232\234\238\236.\n" ..
        "{66CCFF}/bnd delay \232\236\255 \236\241 {FFFFFF}- \239\224\243\231\224 \236\229\230\228\243 \241\242\240\238\234\224\236\232 (300-10000, \239\238 \243\236\238\235\247\224\237\232\254 1100).\n" ..
        "{66CCFF}/bnd show \232\236\255 {FFFFFF}- \239\238\234\224\231\224\242\252 \241\242\240\238\234\232 \225\232\237\228\224.\n" ..
        "{66CCFF}/bnd list {FFFFFF}- \241\239\232\241\238\234 \226\241\229\245 \225\232\237\228\238\226.\n\n" ..
        "{9933FF}\207\238\228\241\242\224\237\238\226\234\232 \226 \242\229\234\241\242\229: {FFFF00}{id}{FFFFFF} - ID \232\231 \234\238\236\224\237\228\251 (/\232\236\255 12) \232\235\232 ID \232\231 /re,\n" ..
        "{FFFF00}{arg}{FFFFFF} - \226\241\184, \247\242\238 \237\224\239\232\241\224\237\238 \239\238\241\235\229 \234\238\236\224\237\228\251.\n" ..
        "{9933FF}\200\236\255: \235\224\242\232\237\232\246\224, \246\232\244\240\251 \232 _ (\228\238 20 \241\232\236\226\238\235\238\226). \203\232\236\232\242: " .. BIND_MAX .. " \225\232\237\228\238\226 \239\238 " .. BIND_LINES .. " \241\242\240\238\234.",
        "\199\224\234\240\251\242\252", "", 0)
end

local function bindAdd(name, text)
    if not name:match("^[%w_]+$") or #name > 20 then return false, "\200\236\255: \235\224\242\232\237\232\246\224, \246\232\244\240\251 \232 _ (\228\238 20 \241\232\236\226\238\235\238\226)." end
    name = name:lower()
    if bindBuiltin[name] or BIND_RESERVED[name] then return false, "\200\236\255 /" .. name .. " \231\224\237\255\242\238 \234\238\236\224\237\228\238\233 \245\229\235\239\229\240\224." end
    local b = binds[name]
    if not b then
        if #sortedBindNames() >= BIND_MAX then return false, "\196\238\241\242\232\227\237\243\242 \235\232\236\232\242 \225\232\237\228\238\226: " .. BIND_MAX end
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
    if added == 0 then return false, "\205\232\247\229\227\238 \237\229 \228\238\225\224\226\235\229\237\238 (\239\243\241\242\238\233 \242\229\234\241\242 \232\235\232 \235\232\236\232\242 \241\242\240\238\234 " .. BIND_LINES .. ")." end
    if not binds[name] then binds[name] = b registerBind(name) end
    saveBinds()
    return true, string.format("\193\232\237\228 /%s: \228\238\225\224\226\235\229\237\238 \241\242\240\238\234 %d (\226\241\229\227\238 %d).", name, added, #b.lines), name
end

local function bindDelete(name)
    binds[name] = nil
    pcall(sampUnregisterChatCommand, name)
    saveBinds()
end

----------------------------------------------------------------------
-- ОТДЕЛЬНОЕ ОКНО БИНДЕРА: /fbind (на диалогах SA-MP, работает без imgui)
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
    local t = { "{33CC33}[+] \209\238\231\228\224\242\252 \237\238\226\251\233 \225\232\237\228" }
    for _, n in ipairs(ui.names) do
        t[#t + 1] = string.format("{FFFFFF}/%s {A9A9A9}- \241\242\240\238\234: %d, \239\224\243\231\224 %d \236\241", n, #binds[n].lines, binds[n].delay)
    end
    uiShow(D_MAIN, "FH | \193\232\237\228\229\240", table.concat(t, "\n"), "\194\251\225\240\224\242\252", "\199\224\234\240\251\242\252", 2)
end

local function uiBind()
    if not binds[ui.sel] then return uiMain() end
    uiShow(D_BIND, "\193\232\237\228 /" .. ui.sel,
        "\199\224\239\243\241\242\232\242\252\n\207\238\234\224\231\224\242\252 \241\242\240\238\234\232\n\196\238\225\224\226\232\242\252 \241\242\240\238\234\232\n\211\228\224\235\232\242\252 \241\242\240\238\234\243\n\200\231\236\229\237\232\242\252 \239\224\243\231\243\n{FF3333}\211\228\224\235\232\242\252 \225\232\237\228\n\205\224\231\224\228",
        "\194\251\225\240\224\242\252", "\199\224\234\240\251\242\252", 2)
end

local function uiAddPrompt()
    uiShow(D_ADD, "\193\232\237\228 /" .. ui.sel .. " | \196\238\225\224\226\232\242\252 \241\242\240\238\234\232",
        "\194\226\229\228\232\242\229 \242\229\234\241\242 \241\242\240\238\234\232 (\234\238\236\224\237\228\224 \232\235\232 \241\238\238\225\249\229\237\232\229).\n\205\229\241\234\238\235\252\234\238 \241\242\240\238\234 \241\240\224\231\243 \240\224\231\228\229\235\255\233\242\229 {FFFF00};;\n{A9A9A9}\207\238\228\241\242\224\237\238\226\234\232: {id} - ID, {arg} - \242\229\234\241\242 \239\238\241\235\229 \234\238\236\224\237\228\251.",
        "\196\238\225\224\226\232\242\252", "\205\224\231\224\228", 1)
end

uiHandlers[D_MAIN] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NAME, "\205\238\226\251\233 \225\232\237\228", "\194\226\229\228\232\242\229 \232\236\255 \234\238\236\224\237\228\251 (\235\224\242\232\237\232\246\224, \246\232\244\240\251, _):", "\196\224\235\229\229", "\205\224\231\224\228", 1)
    else
        ui.sel = ui.names[list]
        uiBind()
    end
end

uiHandlers[D_NAME] = function(button, _, input)
    if button == 0 then return uiMain() end
    local name = trim(input):lower()
    if not name:match("^[%w_]+$") or #name > 20 then
        bmsg("\200\236\255: \235\224\242\232\237\232\246\224, \246\232\244\240\251 \232 _ (\228\238 20 \241\232\236\226\238\235\238\226).")
        return uiShow(D_NAME, "\205\238\226\251\233 \225\232\237\228", "{FF3333}\205\229\226\229\240\237\238\229 \232\236\255!\n{FFFFFF}\203\224\242\232\237\232\246\224, \246\232\244\240\251, _ (\228\238 20 \241\232\236\226\238\235\238\226):", "\196\224\235\229\229", "\205\224\231\224\228", 1)
    end
    if bindBuiltin[name] or BIND_RESERVED[name] then
        bmsg("\200\236\255 /" .. name .. " \231\224\237\255\242\238 \234\238\236\224\237\228\238\233 \245\229\235\239\229\240\224.")
        return uiShow(D_NAME, "\205\238\226\251\233 \225\232\237\228", "{FF3333}\200\236\255 \231\224\237\255\242\238 \234\238\236\224\237\228\238\233 \245\229\235\239\229\240\224!\n{FFFFFF}\194\226\229\228\232\242\229 \228\240\243\227\238\229:", "\196\224\235\229\229", "\205\224\231\224\228", 1)
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
        uiShow(D_SHOW, "\193\232\237\228 /" .. ui.sel .. " | \209\242\240\238\234\232", table.concat(t, "\n"), "\205\224\231\224\228", "", 0)
    elseif list == 2 then uiAddPrompt()
    elseif list == 3 then
        local t = {}
        for i, l in ipairs(b.lines) do t[i] = i .. ". " .. l end
        uiShow(D_LINES, "\193\232\237\228 /" .. ui.sel .. " | \202\224\234\243\254 \241\242\240\238\234\243 \243\228\224\235\232\242\252?", table.concat(t, "\n"), "\211\228\224\235\232\242\252", "\205\224\231\224\228", 2)
    elseif list == 4 then
        uiShow(D_DELAY, "\193\232\237\228 /" .. ui.sel .. " | \207\224\243\231\224",
            string.format("\207\224\243\231\224 \236\229\230\228\243 \241\242\240\238\234\224\236\232 \226 \236\241 (300-10000).\n\209\229\233\247\224\241: %d", b.delay), "\195\238\242\238\226\238", "\205\224\231\224\228", 1)
    elseif list == 5 then
        uiShow(D_CONF, "\211\228\224\235\229\237\232\229 \225\232\237\228\224", "\211\228\224\235\232\242\252 \225\232\237\228 /" .. ui.sel .. " \246\229\235\232\234\238\236?", "\196\224", "\205\229\242", 0)
    else uiMain() end
end

uiHandlers[D_SHOW] = function() uiBind() end

uiHandlers[D_LINES] = function(button, list)
    local b = binds[ui.sel]
    if button == 1 and b and b.lines[list + 1] then
        table.remove(b.lines, list + 1)
        if #b.lines == 0 then
            bindDelete(ui.sel)
            bmsg("\209\242\240\238\234 \237\229 \238\241\242\224\235\238\241\252, \225\232\237\228 \243\228\224\235\184\237.")
            return uiMain()
        end
        saveBinds()
        bmsg("\209\242\240\238\234\224 \243\228\224\235\229\237\224.")
    end
    uiBind()
end

uiHandlers[D_DELAY] = function(button, _, input)
    local ms = tonumber(trim(input))
    if button == 1 and binds[ui.sel] then
        if ms and ms >= 300 and ms <= 10000 then
            binds[ui.sel].delay = math.floor(ms)
            saveBinds()
            bmsg(string.format("\207\224\243\231\224 \225\232\237\228\224 /%s: %d \236\241.", ui.sel, ms))
        else bmsg("\205\243\230\237\238 \247\232\241\235\238 \238\242 300 \228\238 10000.") end
    end
    uiBind()
end

uiHandlers[D_CONF] = function(button)
    if button == 1 and binds[ui.sel] then
        bindDelete(ui.sel)
        bmsg("\193\232\237\228 /" .. ui.sel .. " \243\228\224\235\184\237.")
        return uiMain()
    end
    uiBind()
end

-- вызывается из главного цикла
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
            if not name then bmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /bnd add \232\236\255 \242\229\234\241\242") return end
            local _, msg = bindAdd(name, text)
            bmsg(msg)
        elseif sub == "del" then
            local name = trim(rest):lower()
            if not binds[name] then bmsg("\193\232\237\228 \237\229 \237\224\233\228\229\237: " .. name) return end
            binds[name] = nil
            pcall(sampUnregisterChatCommand, name)
            saveBinds()
            bmsg("\193\232\237\228 /" .. name .. " \243\228\224\235\184\237.")
        elseif sub == "rm" then
            local name, n = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            local b = name and binds[name]
            n = tonumber(n)
            if not b or not b.lines[n] then bmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /bnd rm \232\236\255 N (\237\238\236\229\240 \241\242\240\238\234\232 \232\231 /bnd show)") return end
            table.remove(b.lines, n)
            if #b.lines == 0 then
                binds[name] = nil
                pcall(sampUnregisterChatCommand, name)
                bmsg("\209\242\240\238\234 \237\229 \238\241\242\224\235\238\241\252, \225\232\237\228 /" .. name .. " \243\228\224\235\184\237.")
            else bmsg("\209\242\240\238\234\224 " .. n .. " \243\228\224\235\229\237\224.") end
            saveBinds()
        elseif sub == "delay" then
            local name, ms = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            ms = tonumber(ms)
            if not name or not binds[name] or not ms or ms < 300 or ms > 10000 then
                bmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /bnd delay \232\236\255 \236\241 (300-10000)") return
            end
            binds[name].delay = ms
            saveBinds()
            bmsg(string.format("\207\224\243\231\224 \225\232\237\228\224 /%s: %d \236\241.", name, ms))
        elseif sub == "show" then
            local name = trim(rest):lower()
            local b = binds[name]
            if not b then bmsg("\193\232\237\228 \237\229 \237\224\233\228\229\237: " .. name) return end
            bmsg(string.format("/%s (\239\224\243\231\224 %d \236\241):", name, b.delay))
            for i, l in ipairs(b.lines) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, l), -1) end
        elseif sub == "list" then
            local names = sortedBindNames()
            if #names == 0 then bmsg("\193\232\237\228\238\226 \239\238\234\224 \237\229\242. \209\239\240\224\226\234\224: /binder") return end
            bmsg("\194\224\248\232 \225\232\237\228\251: /" .. table.concat(names, ", /"))
        else
            bindHelp()
        end
    end)
end


----------------------------------------------------------------------
-- НАСТРОЙКИ, ШАБЛОНЫ ОТВЕТОВ, АВТО-/mp
----------------------------------------------------------------------
local LITE_DEFAULT = false   -- на ПК по умолчанию полный стиль
local cfg = {
    automp = true,                  -- после анонса МП вводить /mp и нажимать 1-ю строку
    accent = { 0.26, 0.62, 0.96 },  -- цвет акцента окна
    bg = { 0.07, 0.08, 0.10 },      -- цвет фона окна
    alpha = 0.97,                   -- прозрачность фона
    glass = false,                   -- стиль Liquid Glass (стекло)
    tagmode = 2,                    -- developer tag disabled in v2
    autoupd = false,                 -- проверять обновления при запуске
    reptoast = true,                -- овальное уведомление о репорте
    intro = false,                   -- анимация открытия окна (только при первом запуске)
    introDone = false,              -- анимация уже показана
    lite = true,            -- лёгкий режим: без бликов и прозрачности (меньше лагов)
    aiUrl = "https://api.openai.com/v1/chat/completions",
    aiKey = "",
    aiModel = "gpt-4o-mini",
    aiPrompt = "\210\251 \239\238\236\238\249\237\232\234 \224\228\236\232\237\232\241\242\240\224\242\238\240\224 SA-MP \241\229\240\226\229\240\224. \206\242\226\229\242\252 \232\227\240\238\234\243 \237\224 \240\229\239\238\240\242 \226\229\230\235\232\226\238 \232 \239\238 \228\229\235\243 \238\228\237\232\236 \234\238\240\238\242\234\232\236 \241\238\238\225\249\229\237\232\229\236 (\228\238 100 \241\232\236\226\238\235\238\226), \225\229\231 markdown. \197\241\235\232 \228\224\237\237\251\245 \236\224\235\238 - \239\238\239\240\238\241\232 \243\242\238\247\237\232\242\252 ID \237\224\240\243\248\232\242\229\235\255. \205\229 \226\251\228\243\236\251\226\224\233 \239\240\224\226\232\235\224 \232 \237\229 \238\225\229\249\224\233 \237\224\234\224\231\224\237\232\233.",
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
            elseif k == "tagmode" then cfg.tagmode = 2
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

-- Шаблоны ответов на репорты
local templates = {}
local TPL_MAX, TPL_LEN = 30, 120
local DEFAULT_TEMPLATES = {
    "\199\228\240\224\226\241\242\226\243\233\242\229! \194\224\248\224 \230\224\235\238\225\224 \239\240\232\237\255\242\224, \240\224\231\225\232\240\224\229\236\241\255.",
    "\207\229\240\229\228\224\237\238 \237\224 \240\224\241\241\236\238\242\240\229\237\232\229 \241\242\224\240\248\229\233 \224\228\236\232\237\232\241\242\240\224\246\232\232.",
    "\211\242\238\247\237\232\242\229, \239\238\230\224\235\243\233\241\242\224: ID \237\224\240\243\248\232\242\229\235\255 \232 \247\242\238 \239\240\238\232\231\238\248\235\238.",
    "\205\224\240\243\248\229\237\232\233 \237\229 \238\225\237\224\240\243\230\229\237\238.",
    "\200\227\240\238\234 \237\224\234\224\231\224\237, \241\239\224\241\232\225\238 \231\224 \238\225\240\224\249\229\237\232\229!",
    "\209 \242\224\234\232\236 \226\238\239\240\238\241\238\236 \238\225\240\224\242\232\242\229\241\252 \237\224 \244\238\240\243\236 \239\240\238\229\234\242\224.",
    "\207\240\232\255\242\237\238\233 \232\227\240\251 \237\224 \237\224\248\229\236 \241\229\240\226\229\240\229!",
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
    if text == "" then return false, "\207\243\241\242\238\233 \248\224\225\235\238\237." end
    if #templates >= TPL_MAX then return false, "\203\232\236\232\242 \248\224\225\235\238\237\238\226: " .. TPL_MAX end
    templates[#templates + 1] = text:sub(1, TPL_LEN)
    saveTemplates()
    return true, "\216\224\225\235\238\237 \228\238\225\224\226\235\229\237 (\226\241\229\227\238 " .. #templates .. ")."
end

-- Авто-/mp: ввести /mp и нажать первую строку открывшегося списка
local autoMp = { armed = false, t0 = 0 }
local function armAutoMp(force)
    if not force and not cfg.automp then return end
    autoMp.armed, autoMp.t0 = true, os.clock()
    safeSend("/mp")
end

----------------------------------------------------------------------
-- СПИСОК РЕПОРТОВ ИЗ /define
-- /rpl (или кнопка в /fh) шлёт /define, перехватывает диалог со списком,
-- разбирает его и заменяет им список репортов. Сам диалог не показывается.
-- Сырой текст диалога сохраняется в config/FilippHelper_define.txt.
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

-- вызывается из onShowDialog; ours - диалог вызван нашим запросом (его прячем)
function DEF.onDialog(id, title, text, ours)
    DEF.waiting = false
    pcall(function()
        local f = io.open(configDir() .. "/FilippHelper_define.txt", "wb")
        if f then f:write(tostring(title or ""), "\n", tostring(text or "")) f:close() end
    end)
    local list = defineParse(fromGame(tostring(text or "")))
    if #list == 0 then
        fmsg("\205\229 \243\228\224\235\238\241\252 \240\224\231\238\225\240\224\242\252 /define. \212\238\240\236\224\242 \231\224\239\232\241\224\237 \226 config/FilippHelper_define.txt - \239\240\232\248\235\232\242\229 \253\242\238\242 \244\224\233\235 \240\224\231\240\224\225\238\242\247\232\234\243.")
    else
        for i = #reports, 1, -1 do reports[i] = nil end
        for _, r in ipairs(list) do reports[#reports + 1] = r end
        fmsg("\209\239\232\241\238\234 \240\229\239\238\240\242\238\226 \238\225\237\238\226\235\184\237 \232\231 /define: " .. #list .. ".")
    end
    if ours then
        scheduleAfter(100, function() pcall(sampSendDialogResponse, id, 0, -1, "") end)
        return false
    end
end

function DEF.refresh()
    if DEF.waiting then return end
    DEF.waiting, DEF.t0 = true, os.clock()
    DEF.token = DEF.token + 1
    local my = DEF.token
    safeSend("/define")
     scheduleAfter(5000, function()
        if DEF.waiting and DEF.token == my then
            DEF.waiting = false
            fmsg("/define \237\229 \238\242\226\229\242\232\235 (\237\229\242 \228\238\241\242\243\239\224 \232\235\232 \228\240\243\227\238\233 \244\238\240\236\224\242).")
        end
    end)
end

-- подбирает пункт списка причин от сервера по словам из нашей причины
function PUN.handle(id, style, text)
    local p = PUN.pending
    if not p then return false end
    if os.clock() - p.t > 12 then PUN.pending = nil return false end
    if style == 1 then
        local reasonG = toGame(p.reason)
        PUN.pending = nil
        scheduleAfter(150, function() pcall(sampSendDialogResponse, id, 1, 0, reasonG) end)
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
    scheduleAfter(150, function() pcall(sampSendDialogResponse, id, 1, idx, "") end)
    fmsg("\207\240\232\247\232\237\224 \226\251\225\240\224\237\224: " .. trim(best))
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
    if style ~= 2 and style ~= 4 and style ~= 5 then return end   -- только списки
    autoMp.armed = false
    scheduleAfter(150, function()
        pcall(sampSendDialogResponse, id, 1, 0, "")
    end)
    return false
end

loadCfg()
loadTemplates()

----------------------------------------------------------------------
-- РЕПОРТЫ: журнал последних обращений и быстрый ответ
----------------------------------------------------------------------
local D_MENU, D_RLIST, D_RREPLY, D_GWSTART = 4120, 4121, 4122, 4123

local function replyTo(id, text)
    text = trim(text or "")
    if text == "" then return false end
    safeSend(string.format("/pm %s %s", id, text))
    return true
end

----------------------------------------------------------------------
-- ИИ-ПОДСКАЗКА ОТВЕТА НА РЕПОРТ (любой сервис с OpenAI-совместимым API)
-- Нужны библиотеки effil и requests. Ключ хранится только в config/FilippHelper_settings.txt.
----------------------------------------------------------------------
local AI = { busy = false, status = "", result = nil }

function AI.ready() return trim(cfg.aiKey or "") ~= "" and trim(cfg.aiUrl or "") ~= "" end

local function aiClean(text)
    text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    return trim(text)
end

-- мини-JSON на случай, если в загрузчике нет encodeJson/decodeJson
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

-- отправка POST-запроса; вызывается из потока lua_thread. Возвращает код, текст или nil, ошибка.
-- Перебираем способы: effil+requests (без подвисаний) -> requests -> ssl.https -> curl.
function AI.http(url, key, body, method)
    method = method or "POST"
    body = body or ""
    key = tostring(key or "")
    url = tostring(url or "")
    if not url:match("^https?://") then return nil, "invalid API URL" end

    local okE, effil = pcall(require, "effil")
    if not okE or type(effil) ~= "table" or type(effil.thread) ~= "function" then
        return nil, "Install effil + requests for non-blocking HTTP"
    end
    local okR = pcall(require, "requests")
    if not okR then return nil, "requests library is unavailable" end

    local makeWorker = effil.thread(function(u, k, payload, m)
        local okReq, requests = pcall(require, "requests")
        if not okReq or type(requests) ~= "table" or type(requests.request) ~= "function" then
            return 0, "requests library is unavailable in worker"
        end
        local headers = {}
        if m ~= "GET" then headers["Content-Type"] = "application/json" end
        if k ~= "" then headers["Authorization"] = "Bearer " .. k end
        local options = { headers = headers, timeout = 30 }
        if payload ~= "" then options.data = payload end
        local okCall, response = pcall(requests.request, m, u, options)
        if not okCall then return 0, tostring(response) end
        if type(response) ~= "table" then return 0, "invalid HTTP response" end
        return tonumber(response.status_code) or 0, tostring(response.text or "")
    end)

    local okCreate, worker = pcall(makeWorker, url, key, body, method)
    if not okCreate or not worker then return nil, "failed to start HTTP worker: " .. tostring(worker) end

    local deadline = os.clock() + 40
    while true do
        local okStatus, status = pcall(function() return worker:status() end)
        if not okStatus then return nil, "HTTP worker status error: " .. tostring(status) end
        if status == "completed" then break end
        if status == "failed" or status == "canceled" then return nil, "HTTP worker " .. tostring(status) end
        if os.clock() >= deadline then
            pcall(function() worker:cancel() end)
            return nil, "HTTP request timed out (40s)"
        end
        wait(100)
    end

    local okGet, code, responseText = pcall(function() return worker:get() end)
    if not okGet then return nil, "HTTP worker result error: " .. tostring(code) end
    return tonumber(code) or 0, tostring(responseText or "")
end

-- /aidiag: что доступно в загрузчике для запросов к API
function AI.diag()
    local names = { "effil", "requests", "ssl.https", "ltn12", "socket", "copas", "cjson", "dkjson", "lib.requests" }
    local have, miss = {}, {}
    for _, n in ipairs(names) do
        if pcall(require, n) then have[#have + 1] = n else miss[#miss + 1] = n end
    end
    fmsg("\197\241\242\252: " .. (#have > 0 and table.concat(have, ", ") or "\237\232\247\229\227\238"))
    fmsg("\205\229\242: " .. table.concat(miss, ", "))
    fmsg("encodeJson: " .. (encodeJson and "\228\224" or "\237\229\242 (\236\232\237\232-JSON)") .. ", io.popen: " .. (io.popen and "\228\224" or "\237\229\242"))
end

function AI.suggest(r, cb)
    AI.status = "\200\200 \228\243\236\224\229\242..."
    AI.ask(cfg.aiPrompt, "\208\229\239\238\240\242 \238\242 \232\227\240\238\234\224 " .. r.name .. ": " .. r.text, function(ok, text)
        AI.status = ok and "\206\242\226\229\242 \227\238\242\238\226, \239\240\238\226\229\240\252\242\229 \232 \238\242\239\240\224\226\252\242\229." or ("\206\248\232\225\234\224: " .. tostring(text))
        if ok then AI.result = { id = r.id, text = text } end
        cb(ok, text)
    end)
end

function AI.test()
    AI.status = "\207\240\238\226\229\240\255\254 \241\226\255\231\252..."
    AI.ask(cfg.aiPrompt, "\207\240\232\226\229\242! \206\242\226\229\242\252 \238\228\237\232\236 \234\238\240\238\242\234\232\236 \239\240\229\228\235\238\230\229\237\232\229\236.", function(ok, text)
        AI.status = ok and ("\208\224\225\238\242\224\229\242: " .. text) or ("\206\248\232\225\234\224: " .. tostring(text))
    end)
end

-- /ai [ID]: подсказка по репорту, текст попадает в строку ввода как /rr ID текст
function AI.cmdAsk(p)
    local id = (p or ""):match("^(%d+)")
    local r
    for _, x in ipairs(reports) do
        if not id or x.id == id then r = x break end
    end
    if not r then fmsg("\208\229\239\238\240\242 \237\229 \237\224\233\228\229\237. \209\239\232\241\238\234: /reports") return end
    fmsg("\209\239\240\224\248\232\226\224\254 \200\200 \239\240\238 \240\229\239\238\240\242 \238\242 " .. r.name .. "...")
    AI.suggest(r, function(ok, text)
        fmsg("\200\200: " .. tostring(text))
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
        fmsg("/aiset url|key|model|prompt \231\237\224\247\229\237\232\229. \209\229\233\247\224\241: \234\235\254\247 " .. (trim(cfg.aiKey) ~= "" and "\231\224\228\224\237" or "\237\229 \231\224\228\224\237") ..
            ", \236\238\228\229\235\252 " .. cfg.aiModel .. ". \207\240\238\226\229\240\234\224: /ai ID")
        return
    end
    cfg[f] = v:gsub("[\r\n]+", " ")
    saveCfg()
    fmsg("\200\200: " .. k .. " \241\238\245\240\224\237\229\237\238.")
end

----------------------------------------------------------------------
-- ПРОВЕРКА ОБНОВЛЕНИЙ ПО GITHUB
-- В репозитории лежит version.txt: 1-я строка - версия, 2-я - что нового.
----------------------------------------------------------------------
local UPD = {
    base = "https://raw.githubusercontent.com/filippdanko174-bit/inferno-helper/rewrite/filipphelper-v2/",
    file = UPDATE_FILE,
    latest = nil, notes = "", checked = false, busy = false, status = "",
}

local function verParts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    return t
end

local function verNewer(a, b)   -- a новее b?
    local x, y = verParts(a), verParts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- silent: не писать «у вас последняя версия»
function UPD.check(silent)
    if UPD.busy then return end
    UPD.busy = true
    UPD.status = "\207\240\238\226\229\240\255\254 \238\225\237\238\226\235\229\237\232\255..."
    lua_thread.create(function()
        local ok, code, text = pcall(AI.http, UPD.base .. "version.txt", "", "", "GET")
        UPD.busy = false
        if not ok or not code or code ~= 200 or type(text) ~= "string" then
            UPD.status = "\205\229 \243\228\224\235\238\241\252 \239\240\238\226\229\240\232\242\252 \238\225\237\238\226\235\229\237\232\255."
            if not silent then fmsg("\205\229 \243\228\224\235\238\241\252 \239\240\238\226\229\240\232\242\252 \238\225\237\238\226\235\229\237\232\255 (" .. tostring(ok and (code or text) or code) .. ").") end
            return
        end
        local ver, notes = text:match("^%s*([%d%.]+)[^\n]*\n?(.*)$")
        if not ver then UPD.status = "\205\229 \243\228\224\235\238\241\252 \240\224\231\238\225\240\224\242\252 version.txt." return end
        UPD.checked, UPD.latest, UPD.notes = true, ver, trim(fromUi((notes or ""):gsub("[\r\n]+", " ")))
        if verNewer(ver, VERSION) then
            UPD.status = "\196\238\241\242\243\239\237\224 \226\229\240\241\232\255 " .. ver
            fmsg("{FFD700}\196\238\241\242\243\239\237\238 \238\225\237\238\226\235\229\237\232\229 {FFFFFF}v" .. ver .. " {A9A9A9}(\243 \226\224\241 v" .. VERSION .. ")")
            if UPD.notes ~= "" then fmsg("{A9A9A9}\215\242\238 \237\238\226\238\227\238: {FFFFFF}" .. UPD.notes) end
            fmsg("{A9A9A9}\211\241\242\224\237\238\226\232\242\252: {FFFF00}/fhupd install {A9A9A9}\232\235\232 \234\237\238\239\234\224 \226 /fh \237\224 \171\195\235\224\226\237\238\233\187")
        else
            UPD.latest = nil
            UPD.status = "\211 \226\224\241 \239\238\241\235\229\228\237\255\255 \226\229\240\241\232\255 (v" .. VERSION .. ")."
            if not silent then fmsg(UPD.status) end
        end
    end)
end

function UPD.install()
    if UPD.busy then return end
    if not UPD.latest then fmsg("\209\237\224\247\224\235\224 \239\240\238\226\229\240\252\242\229 \238\225\237\238\226\235\229\237\232\255: /fhupd") return end
    UPD.busy = true
    UPD.status = "\209\234\224\247\232\226\224\254 \238\225\237\238\226\235\229\237\232\229..."
    fmsg("\209\234\224\247\232\226\224\254 v" .. UPD.latest .. "...")
    lua_thread.create(function()
        local ok, err = pcall(function()
            local code, text = AI.http(UPD.base .. UPD.file, "", "", "GET")
            if code ~= 200 or type(text) ~= "string" then error("\238\248\232\225\234\224 \231\224\227\240\243\231\234\232 (" .. tostring(code) .. ")") end
            if #text < 20000 or #text > 500000 or not text:find("FilippHelper", 1, true) then error("invalid update file") end
            local fileVersion = text:match('local VERSION = "([%d%.]+)"')
            if not fileVersion or fileVersion ~= tostring(UPD.latest) then error("version.txt and script version do not match") end
            local chunk, cerr = (loadstring or load)(text)
            if not chunk then error("\244\224\233\235 \237\229 \234\238\236\239\232\235\232\240\243\229\242\241\255: " .. tostring(cerr)) end
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
            UPD.status = "\206\225\237\238\226\235\229\237\238 \228\238 v" .. tostring(UPD.latest) .. ", \239\229\240\229\231\224\227\240\243\231\234\224..."
            fmsg("{66FF66}\206\225\237\238\226\235\229\237\238 \228\238 v" .. tostring(UPD.latest) .. ". \207\229\240\229\231\224\227\240\243\230\224\254 \241\234\240\232\239\242...")
            wait(800)
            pcall(function() thisScript():reload() end)
        else
            UPD.status = "\206\248\232\225\234\224 \238\225\237\238\226\235\229\237\232\255: " .. tostring(err)
            fmsg("{FF6666}\206\225\237\238\226\235\229\237\232\229 \237\229 \243\228\224\235\238\241\252: " .. tostring(err))
        end
    end)
end

function UPD.cmd(p)
    p = trim(p or "")
    if p == "install" then UPD.install() else UPD.check(false) end
end

local function uiReports()
    if #reports == 0 then
        fmsg("\208\229\239\238\240\242\238\226 \239\238\234\224 \237\229\242.")
        return
    end
    local t = {}
    for i, r in ipairs(reports) do
        t[i] = string.format("{FFFF00}[%s] {FFFFFF}%s: {A9A9A9}%s", r.id, r.name, r.text)
    end
    uiShow(D_RLIST, "FH | \207\238\241\235\229\228\237\232\229 \240\229\239\238\240\242\251", table.concat(t, "\n"), "\206\242\226\229\242\232\242\252", "\199\224\234\240\251\242\252", 2)
end

local D_RTPL = 4147
local function findReport(id)
    for _, r in ipairs(reports) do if r.id == id then return r end end
end

local function uiTemplatesFor(r)
    local t = { "{33CC33}\205\224\239\232\241\224\242\252 \241\226\238\233 \238\242\226\229\242" }
    for _, x in ipairs(templates) do t[#t + 1] = "{FFFFFF}" .. x end
    uiShow(D_RTPL, "\206\242\226\229\242: " .. r.name .. "[" .. r.id .. "]", table.concat(t, "\n"), "\206\242\239\240\224\226\232\242\252", "\205\224\231\224\228", 2)
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
        uiShow(D_RREPLY, "\206\242\226\229\242 \232\227\240\238\234\243 " .. r.name .. "[" .. r.id .. "]",
            "\198\224\235\238\225\224: " .. r.text .. "\n\n\194\226\229\228\232\242\229 \238\242\226\229\242 (\243\233\228\184\242 \247\229\240\229\231 /pm):", "\206\242\239\240\224\226\232\242\252", "\205\224\231\224\228", 1)
    elseif templates[list] then
        replyTo(r.id, templates[list])
    end
end

uiHandlers[D_RREPLY] = function(button, _, input)
    if button == 1 and ui.replyId and replyTo(ui.replyId, input) then return end
    uiReports()
end

----------------------------------------------------------------------
-- РАЗДАЧА ПРИЗОВ
----------------------------------------------------------------------
local gw = { active = false, last = false, word = "", prize = "", stat = nil, amount = nil, t0 = 0 }
local GW_TAG = "[\208\224\231\228\224\247\224]"
local GW_IGNORE_NAMES = { Admin = true, Utka_News = true }

-- {номер статы на сервере, названия приза...}
local PRIZE_TYPES = {
    { 7,  "bank", "\225\224\237\234", "\228\229\237\252\227\232", "money", "\240\243\225" },
    { 1,  "lvl", "\235\226\235", "\243\240\238\226\229\237\252", "level" },
    { 3,  "mat", "\236\224\242" },
    { 6,  "exp", "\238\239\251\242" },
    { 2,  "\231\224\234\238\237" },
    { 5,  "sim", "\241\232\236", "\237\238\236\229\240" },
    { 12, "box", "\225\238\234\241" },
    { 13, "kung", "\234\243\237\227" },
    { 14, "kick", "\234\232\234" },
}

-- "банк 500.000" -> 7, "500000"; "#9 15" -> 9, "15"; не распознано -> nil
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
    if not gw.active then return false end
    name, id = tostring(name or ""), tostring(id or "")
    if name == "" or #name > 24 or not name:match("^[A-Za-z0-9_]+$") or not id:match("^%d%d?%d?%d?%d?$") then
        print("[FH] invalid giveaway winner data; finish ignored")
        return false
    end
    gw.active = false
    local isLast = gw.last
    gw.last = false
    local sec = math.max(1, math.floor(os.clock() - gw.t0 + 0.5))
    local lines = { string.format("/aad %s \207\238\225\229\228\232\242\229\235\252 - %s! \194\240\229\236\255: %d \241\229\234.", GW_TAG, name, sec) }
    if gw.stat then
        lines[#lines + 1] = string.format("/pm %s \207\238\231\228\240\224\226\235\255\254, \226\251 \239\229\240\226\251\233! \207\240\232\231 \241\229\233\247\224\241 \225\243\228\229\242 \226\251\228\224\237.", id)
        lines[#lines + 1] = string.format("/setstat %s %d %s", id, gw.stat, gw.amount)
        lines[#lines + 1] = string.format("/pm %s \207\240\232\231 \226\251\228\224\237, \239\240\232\255\242\237\238\233 \232\227\240\251!", id)
    else
        fmsg(string.format("{FFFF00}\194\251\228\224\233\242\229 \239\240\232\231 \226\240\243\247\237\243\254: %s [%s] -> %s", name, id, gw.prize))
        lines[#lines + 1] = string.format("/pm %s \207\238\231\228\240\224\226\235\255\254, \226\251 \239\229\240\226\251\233! \207\240\232\231 \226\251\228\224\236 \226 \225\235\232\230\224\233\248\229\229 \226\240\229\236\255.", id)
    end
    if isLast then lines[#lines + 1] = "/aad " .. GW_TAG .. " \208\224\231\228\224\247\224 \231\224\226\229\240\248\229\237\224, \241\239\224\241\232\225\238 \226\241\229\236 \231\224 \243\247\224\241\242\232\229!" end
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
    if gw.active then fmsg("\211\230\229 \232\228\184\242 \224\234\242\232\226\237\224\255 \240\224\231\228\224\247\224. \209\237\224\247\224\235\224 \238\242\236\229\237\232\242\229 \229\184: /gwstop") return end
    local word, prize = gwParse(param)
    if not word then
        fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /" .. (isLast and "gwlast" or "gw") .. " \241\235\238\226\238 | \239\240\232\231   (\237\224\239\240\232\236\229\240: /gw \234\238\242\232\234 | \225\224\237\234 500000)")
        return
    end
    gw.word, gw.prize, gw.last = lower1251(word), prize, isLast
    gw.stat, gw.amount = parsePrize(prize)
    gw.t0 = os.clock()
    gw.active = true
    local head = isLast and "\212\200\205\192\203! " or ""
    sendSeq({
        string.format("/aad %s %s\207\240\232\231: %s", GW_TAG, head, prize),
        string.format("/aad %s \202\242\238 \239\229\240\226\251\236 \238\242\239\240\224\226\232\242 \226 /rep \241\235\238\226\238 \171%s\187 - \242\238\242 \239\238\225\229\228\232\235!", GW_TAG, word),
    }, SEND_GAP)
    if gw.stat then
        fmsg(string.format("\208\224\231\228\224\247\224 \231\224\239\243\249\229\237\224. \209\235\238\226\238: {FFFF00}%s{FFFFFF}. \207\240\232\231 \226\251\228\224\241\242\241\255 \241\224\236 (\241\242\224\242\224 %d, \234\238\235-\226\238 %s).", word, gw.stat, gw.amount))
    else
        fmsg(string.format("\208\224\231\228\224\247\224 \231\224\239\243\249\229\237\224. \209\235\238\226\238: {FFFF00}%s{FFFFFF}. \210\232\239 \239\240\232\231\224 \237\229 \240\224\241\239\238\231\237\224\237 - \226\251\228\224\226\224\242\252 \239\240\232\228\184\242\241\255 \226\240\243\247\237\243\254.", word))
    end
end

uiHandlers[D_GWSTART] = function(button, _, input)
    if button == 1 then gwStart(input, false) end
end

----------------------------------------------------------------------
-- ЗАНЯТЬ ЗАДАЧУ: "z ..." несколько раз в /a
----------------------------------------------------------------------
local D_Z = 4148
local CLAIM_COUNT = 3
-- {ключ, текст после "z "}
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
    uiShow(D_Z, "FH | \199\224\237\255\242\252", table.concat(t, "\n"), "\199\224\237\255\242\252", "\199\224\234\240\251\242\252", 2)
end

uiHandlers[D_Z] = function(button, list)
    if button == 0 then return end
    local c = CLAIMS[list + 1]
    if c then claim(c[2]) end
end

----------------------------------------------------------------------
-- МЕРОПРИЯТИЯ: готовые анонсы в /aad
----------------------------------------------------------------------
local D_EV, D_FR, D_FRACT, D_NOTES, D_NOTE, D_NOTEADD = 4140, 4141, 4142, 4144, 4145, 4146
local D_EVPRIZE = 4149

-- {ключ, название, строки анонса}. {id} подставляется для интерактивных МП.
local EVENTS = {
    { "svet", "\209\226\229\242\238\244\238\240", "\193\229\230\232\236 \234 \244\232\237\232\248\243 \237\224 \171\199\229\235\184\237\251\233\187 \232 \231\224\236\232\240\224\229\236 \237\224 \171\202\240\224\241\237\251\233\187.", "\202\242\238 \228\226\232\237\243\235\241\255 \237\224 \234\240\224\241\237\251\233 - \226\251\235\229\242\224\229\242. \207\238\225\229\230\228\224\229\242 \239\229\240\226\251\233 \237\224 \244\232\237\232\248\229." },
    { "poliv", "\207\238\235\232\226\224\235\234\224", "\205\243\230\237\238 \243\228\229\240\230\224\242\252\241\255 \237\224 \234\240\251\248\229, \239\238\234\224 \226\224\241 \239\238\235\232\226\224\254\242 \232\231 \193\210\208.", "\206\240\243\230\232\229 \232 \242\238\235\247\234\232 \231\224\239\240\229\249\229\237\251. \207\238\225\229\230\228\224\229\242 \239\238\241\235\229\228\237\232\233 \238\241\242\224\226\248\232\233\241\255." },
    { "derbi", "\196\229\240\225\232", "\209\224\228\232\236\241\255 \226 \236\224\248\232\237\251 \232 \242\224\240\224\237\232\242\229\241\252 \237\224 \224\240\229\237\229.", "\207\238\225\229\230\228\224\229\242 \242\238\242, \247\252\255 \236\224\248\232\237\224 \238\241\242\224\235\224\241\252 \237\224 \245\238\228\243 \239\238\241\235\229\228\237\229\233." },
    { "pryat", "\207\240\255\242\234\232", "\207\240\255\247\252\242\229\241\252 \238\242 \226\229\228\243\249\229\227\238 \227\228\229 \243\227\238\228\237\238 \237\224 \235\238\234\224\246\232\232.", "\207\238 \234\238\236\224\237\228\229 \236\238\230\237\238 \239\238\235\252\231\238\226\224\242\252\241\255 \236\224\241\234\224\236\232 \232 \224\237\232\236\224\246\232\255\236\232." },
    { "parkur", "\207\224\240\234\243\240", "\202\242\238 \225\251\241\242\240\229\229 \226\241\229\245 \228\238\225\229\240\184\242\241\255 \228\238 \226\229\240\248\232\237\251 \239\224\240\234\243\240-\231\238\237\251?", "\193\229\231 \238\240\243\230\232\255, \239\238\236\229\245 \228\240\243\227\232\236 \232 \225\224\227\238\226." },
    { "rulet", "\208\243\241\241\234\224\255 \240\243\235\229\242\234\224", "\194\241\242\224\184\236 \226 \241\242\240\238\233 \232 \239\238 \238\247\229\240\229\228\232 \239\251\242\224\229\236 \243\228\224\247\243.", "\209\242\240\238\233 \237\229 \237\224\240\243\248\224\242\252, \238\240\243\230\232\229 \232 \224\237\232\236\224\246\232\232 \237\229 \232\241\239\238\235\252\231\238\226\224\242\252." },
    { "kovsh", "\195\238\237\234\232 \238\242 \202\238\226\248\224", "\200\227\240\238\234\232 \237\224 \234\226\224\228\240\238\246\232\234\235\224\245 \243\226\238\240\224\247\232\226\224\254\242\241\255 \238\242 \195\229\235\232\234\224 \241 \234\238\226\248\238\236.", "\193\224\227\232, \240\229\236\238\237\242 \236\224\248\232\237 \232 \241\242\238\240\238\237\237\232\233 \241\238\244\242 \231\224\239\240\229\249\229\237\251. \194\251\230\232\226\224\229\242 \239\238\241\235\229\228\237\232\233." },
    { "myaso", "\204\255\241\238\240\243\225\234\224", "\193\229\227\224\229\236 \239\238 \235\238\234\224\246\232\232 \232 \243\245\238\228\232\236 \238\242 \225\229\237\231\238\239\232\235\251 \226\229\228\243\249\229\227\238.", "\193\229\231 \238\240\243\230\232\255, \225\240\238\237\232 \232 \236\224\241\238\234. \207\238\225\229\230\228\224\229\242 \239\238\241\235\229\228\237\232\233 \226\251\230\232\226\248\232\233." },
    { "dogon", "\196\238\227\238\237\255\235\234\232", "\194\229\228\243\249\232\233 \227\238\237\232\242\241\255 \231\224 \232\227\240\238\234\224\236\232.", "\202\238\227\238 \243\228\224\240\232\235\232 \234\243\235\224\234\238\236 - \242\238\242 \226\251\225\251\235. \192\237\232\236\224\246\232\232 \232 \225\224\227\232 \231\224\239\240\229\249\229\237\251." },
    { "car", "\214\224\240\252 \227\238\240\251", "\199\224\225\229\240\232\242\229\241\252 \237\224 \226\229\240\248\232\237\243 \227\238\240\251 \232\231 \238\225\250\229\234\242\238\226 \232 \228\229\240\230\232\242\229\241\252.", "\210\238\235\252\234\238 \234\243\235\224\234\232, \225\229\231 \238\240\243\230\232\255 \232 \236\224\241\238\234. \207\238\225\229\230\228\224\229\242 \242\238\242, \234\242\238 \238\241\242\224\235\241\255 \237\224\226\229\240\245\243." },
    { "parash", "\207\240\251\230\234\232 \241 \239\224\240\224\248\254\242\238\236", "\194\241\229 \239\238\235\243\247\224\254\242 \239\224\240\224\248\254\242\251 \232 \239\240\232\231\229\236\235\255\254\242\241\255 \237\224 \236\229\242\234\243 \226\229\228\243\249\229\227\238.", "\207\240\238\236\224\231\224\235 \232\235\232 \240\224\231\225\232\235\241\255 - \226\251\225\251\235. \194\224\230\237\224 \242\238\247\237\238\241\242\252." },
    { "digl", "\202\238\240\238\235\252 \196\232\227\235\224", "\202\224\230\228\238\236\243 \226\251\228\224\184\242\241\255 Deagle.", "\205\243\230\237\238 \243\225\240\224\242\252 \226\241\229\245 \241\238\239\229\240\237\232\234\238\226. \207\238\225\229\230\228\224\229\242 \239\238\241\235\229\228\237\232\233 \230\232\226\238\233." },
    { "sultan", "\211\226\229\240\237\232\241\252 \238\242 \209\243\235\242\224\237\224", "\200\227\240\238\234\232 \226 \241\242\240\238\254, \226\229\228\243\249\232\233 \229\228\229\242 \237\224 \236\224\248\232\237\229.", "\202\238\227\238 \231\224\228\229\235\232 - \242\238\242 \226\251\225\251\235. \205\243\230\237\238 \226\238\226\240\229\236\255 \239\238\228\239\240\251\227\237\243\242\252." },
    { "paint", "\207\229\233\237\242\225\238\235", "\202\224\230\228\251\233 \241\224\236 \231\224 \241\229\225\255, \241\247\232\242\224\254\242\241\255 \243\225\232\233\241\242\226\224.", "\207\238\225\229\230\228\224\229\242 \242\238\242, \243 \234\238\227\238 \226 \234\238\237\246\229 \225\238\235\252\248\229 \244\240\224\227\236\229\237\242\238\226." },
    { "krug", "\202\240\243\227 \209\236\229\240\242\232", "\200\227\240\238\234\232 \226\241\242\224\254\242 \234\240\243\227\238\236, \226\229\228\243\249\232\233 \226\251\228\224\184\242 Deagle \241 \238\228\237\232\236 \239\224\242\240\238\237\238\236.", "\199\224\228\224\247\224 - \226\251\241\242\240\229\235\232\242\252 \226 \238\239\239\238\237\229\237\242\224." },
    { "infern", "\196\238\227\238\237\232 \200\237\244\229\240\237\243\241", "\205\224\233\228\232\242\229 \237\224 \234\224\240\242\229 \215\168\208\205\219\201 INFERNUS \226\229\228\243\249\229\227\238 \232 \239\229\240\229\228\224\233\242\229 \229\236\243 1 \240\243\225\235\252: /pay {id} 1.", "\215\232\242\251 \232 \239\238\236\229\245\232 \231\224\239\240\229\249\229\237\251. \207\238\225\229\230\228\224\229\242 \239\229\240\226\251\233, \234\242\238 \239\229\240\229\228\224\235." },
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
        if not id then fmsg("\205\243\230\229\237 ID \226\229\228\243\249\229\227\238: /ev " .. e[1] .. " ID [\239\240\232\231]") return end
    end
    prize = trim(prize or "")
    local lines = {
        string.format("/aad [\204\207] \194\237\232\236\224\237\232\229, \232\227\240\238\234\232! \209\234\238\240\238 \241\242\224\240\242\243\229\242 \236\229\240\238\239\240\232\255\242\232\229 \171%s\187.", e[2]),
    }
    for k = 3, #e do
        lines[#lines + 1] = "/aad [\204\207] " .. e[k]:gsub("{id}", id or "")
    end
    if prize ~= "" then lines[#lines + 1] = "/aad [\204\207] \207\240\232\231 \239\238\225\229\228\232\242\229\235\254: " .. prize .. "." end
    lines[#lines + 1] = "/aad [\204\207] \211\247\224\241\242\232\229 \241\226\238\225\238\228\237\238\229 \228\235\255 \226\241\229\245. \198\228\232\242\229 \238\242\234\240\251\242\232\255 \242\229\235\229\239\238\240\242\224."
    lines[#lines + 1] = "/aad [\204\207] \205\224\240\243\248\232\242\229\235\232 \239\240\224\226\232\235 \204\207 \225\243\228\243\242 \243\228\224\235\229\237\251 \225\229\231 \239\240\224\226\224 \237\224 \239\240\232\231."
    sendSeq(lines, SEND_GAP, cfg.automp and function() armAutoMp() end or nil)
end

local function uiEvents()
    local t = {}
    for i, e in ipairs(EVENTS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(/ev %s)", e[2], e[1]) end
    uiShow(D_EV, "FH | \204\229\240\238\239\240\232\255\242\232\255", table.concat(t, "\n"), "\206\225\250\255\226\232\242\252", "\199\224\234\240\251\242\252", 2)
end

uiHandlers[D_EV] = function(button, list)
    if button == 0 then return end
    local e = EVENTS[list + 1]
    if not e then return end
    ui.evPick = e
    uiShow(D_EVPRIZE, "FH | \207\240\232\231 \228\235\255 \204\207 \171" .. e[2] .. "\187",
        "{FFFFFF}\194\226\229\228\232\242\229 \239\240\232\231 (\236\238\230\237\238 \238\241\242\224\226\232\242\252 \239\243\241\242\251\236).\n" ..
        (e[1] == "infern" and "{FFCC00}\196\235\255 \253\242\238\227\238 \204\207: ID \226\229\228\243\249\229\227\238, \231\224\242\229\236 \239\240\232\231. \207\240\232\236\229\240: 55 5\234\234\n" or "{A9A9A9}\207\240\232\236\229\240: 5\234\234"),
        "\206\225\250\255\226\232\242\252", "\205\224\231\224\228", 1)
end

uiHandlers[D_EVPRIZE] = function(button, _, input)
    local e = ui.evPick
    ui.evPick = nil
    if button == 0 or not e then return uiEvents() end
    announceEvent(e, input or "")
end

----------------------------------------------------------------------
-- ФРАКЦИИ: наборы, отборы на лидера, временные лидерки
----------------------------------------------------------------------
-- {ключ, название, id для /templeader, тип}
local FRACTIONS = {
    { "rus", "\208\243\241\241\234\224\255 \236\224\244\232\255", 14, "mafia" }, { "jap", "\223\239\238\237\241\234\224\255 \236\224\244\232\255", 6, "mafia" }, { "ita", "\200\242\224\235\252\255\237\241\234\224\255 \236\224\244\232\255", 5, "mafia" },
    { "fun", "\207\238\245\238\240\238\237\237\238\229 \225\254\240\238", 23, "mafia" }, { "out", "Outlaws MC", 28, "mafia" },
    { "rif", "Rifa Gang", 18, "gang" }, { "bal", "Ballas Gang", 12, "gang" }, { "azt", "Aztec Gang", 17, "gang" },
    { "gro", "Grove Street", 15, "gang" }, { "vag", "LS Vagos", 13, "gang" },
    { "arm", "\192\240\236\232\255 \203\209", 3, "gov" }, { "hos", "\193\238\235\252\237\232\246\224 \203\209", 4, "gov" }, { "mer", "\204\253\240\232\255", 7, "gov" },
    { "rad", "\208\224\228\232\238\246\229\237\242\240", 16, "gov" }, { "swt", "S.W.A.T", 25, "gov" }, { "gov", "\207\240\224\226\232\242\229\235\252\241\242\226\238", 26, "gov" },
    { "lsp", "LSPD", 1, "gov" }, { "fbi", "FBI", 2, "gov" }, { "rcp", "RCPD", 27, "gov" }, { "sud", "\194\229\240\245\238\226\237\251\233 \241\243\228", 29, "gov" },
}
local RULES_BY_KIND = { mafia = "\239\240\224\226\232\235 \225\232\231\226\224\240\238\226", gang = "\239\240\224\226\232\235 \234\224\239\242\238\226", gov = "\238\225\249\232\245 \239\240\224\226\232\235 \235\232\228\229\240\238\226" }

local function fractionByKey(key)
    key = lower1251(key or "")
    for _, f in ipairs(FRACTIONS) do if f[1] == key then return f end end
end

local function recruit(f)
    sendSeq({
        "/o [\205\224\225\238\240] \194\237\232\236\224\237\232\229! \206\242\234\240\251\242 \237\224\225\238\240 \226 \171" .. f[2] .. "\187.",
        "/o [\205\224\225\238\240] \207\238\228\224\233\242\229 \231\224\255\226\234\243 \247\229\240\229\231 /rep +.",
    }, 2500)
end

local function tryoutAad(f)
    sendSeq({
        "/aad [\206\242\225\238\240] \194\237\232\236\224\237\232\229! \207\240\238\245\238\228\232\242 \238\242\225\238\240 \237\224 \239\238\241\242 \235\232\228\229\240\224: " .. f[2] .. ".",
        "/aad [\206\242\225\238\240] \210\240\229\225\238\226\224\237\232\255: \226\238\231\240\224\241\242 13+, \241\226\255\231\252 \194\202, \231\237\224\237\232\229 " .. RULES_BY_KIND[f[4]] .. ".",
        "/aad [\206\242\225\238\240] \198\228\232\242\229 \238\242\234\240\251\242\232\255 \242\229\235\229\239\238\240\242\224.",
    }, SEND_GAP, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tryoutO(f)
    sendSeq({
        "/o [\206\242\225\238\240] \200\228\184\242 \238\242\225\238\240 \237\224 \239\238\241\242 \235\232\228\229\240\224: " .. f[2] .. ".",
        "/o [\206\242\225\238\240] \205\243\230\237\238: 13+, \241\226\255\231\252 \194\202, \231\237\224\237\232\229 " .. RULES_BY_KIND[f[4]] .. ".",
        "/o [\206\242\225\238\240] \198\229\235\224\254\249\232\229 - \239\232\248\232\242\229 /gomp.",
    }, 2500, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tempLeader(f) safeSend("/templeader " .. f[3]) end

local function uiFractions()
    local t = {}
    for i, f in ipairs(FRACTIONS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(%s)", f[2], f[1]) end
    uiShow(D_FR, "FH | \212\240\224\234\246\232\232", table.concat(t, "\n"), "\194\251\225\240\224\242\252", "\199\224\234\240\251\242\252", 2)
end

uiHandlers[D_FR] = function(button, list)
    if button == 0 then return end
    local f = FRACTIONS[list + 1]
    if not f then return uiFractions() end
    ui.fr = list + 1
    uiShow(D_FRACT, f[2],
        "\205\224\225\238\240 (\226 \238\225\249\232\233 \247\224\242 /o)\n\206\242\225\238\240 \237\224 \235\232\228\229\240\224 (/aad)\n\206\242\225\238\240 \237\224 \235\232\228\229\240\224 (\238\225\249\232\233 \247\224\242 /o)\n\194\231\255\242\252 \226\240\229\236\229\237\237\243\254 \235\232\228\229\240\234\243 \241\229\225\229\n\205\224\231\224\228",
        "\194\251\225\240\224\242\252", "\199\224\234\240\251\242\252", 2)
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
-- ШПАРГАЛКИ: свои заметки (правила, ответы), хранятся в файле
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
    if not ok then fmsg("\205\229 \243\228\224\235\238\241\252 \241\238\245\240\224\237\232\242\252 \231\224\236\229\242\234\232 \226 \244\224\233\235!") end
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
    if title == "" or #title > 40 then return false, "\205\224\231\226\224\237\232\229: \228\238 40 \241\232\236\226\238\235\238\226." end
    local n = findNote(title)
    if not n then
        if #notes >= NOTE_MAX then return false, "\203\232\236\232\242 \231\224\236\229\242\238\234: " .. NOTE_MAX end
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
        return false, "\207\243\241\242\238\233 \242\229\234\241\242, \237\232\247\229\227\238 \237\229 \228\238\225\224\226\235\229\237\238."
    end
    saveNotes()
    return true, string.format("\199\224\236\229\242\234\224 \171%s\187: \228\238\225\224\226\235\229\237\238 \241\242\240\238\234 %d (\226\241\229\227\238 %d).", n.title, added, #n.lines)
end

local function uiNotes()
    local t = { "{33CC33}[+] \205\238\226\224\255 \231\224\236\229\242\234\224" }
    for _, n in ipairs(notes) do t[#t + 1] = string.format("{FFFFFF}%s {A9A9A9}- \241\242\240\238\234: %d", n.title, #n.lines) end
    uiShow(D_NOTES, "FH | \216\239\224\240\227\224\235\234\232", table.concat(t, "\n"), "\206\242\234\240\251\242\252", "\199\224\234\240\251\242\252", 2)
end

uiHandlers[D_NOTES] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NOTEADD, "\205\238\226\224\255 \231\224\236\229\242\234\224",
            "\212\238\240\236\224\242: \237\224\231\226\224\237\232\229 | \242\229\234\241\242\n\205\229\241\234\238\235\252\234\238 \241\242\240\238\234 \240\224\231\228\229\235\255\233\242\229 {FFFF00};;\n{A9A9A9}\207\240\232\236\229\240: \205\238\240\236\251 | \193\243\228\237\232 - 1 \247\224\241 ;; \194\251\245\238\228\237\251\229 - 1.5 \247\224\241\224",
            "\209\238\245\240\224\237\232\242\252", "\205\224\231\224\228", 1)
    else
        local n = notes[list]
        if not n then return uiNotes() end
        ui.note = list
        uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "\205\224\231\224\228", "\211\228\224\235\232\242\252", 0)
    end
end

uiHandlers[D_NOTEADD] = function(button, _, input)
    if button == 0 then return uiNotes() end
    local title, text = input:match("^(.-)%s*|%s*(.+)$")
    if not title then fmsg("\212\238\240\236\224\242: \237\224\231\226\224\237\232\229 | \242\229\234\241\242") return uiNotes() end
    local _, msg = noteAdd(title, text)
    fmsg(msg)
    uiNotes()
end

uiHandlers[D_NOTE] = function(button)
    if button == 0 and ui.note and notes[ui.note] then
        fmsg("\199\224\236\229\242\234\224 \171" .. notes[ui.note].title .. "\187 \243\228\224\235\229\237\224.")
        table.remove(notes, ui.note)
        saveNotes()
    end
    uiNotes()
end

----------------------------------------------------------------------
-- КОМАНДЫ-СОКРАЩЕНИЯ, ОПРОС, ТАЙМЕР РЕСПАВНА
----------------------------------------------------------------------
-- {короткое имя, полная команда, режим}
-- args - нужны параметры; idin - вставить "/cmd ID " в строку ввода; idopt - ID из аргумента или из /re;
-- optargs - параметры необязательны; none - без параметров
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
            if not id then fmsg("\211\234\224\230\232\242\229 ID: /" .. short .. " ID") return end
            if mode == "idin" then
                sampSetChatInputText(string.format("/%s %s ", full, id)) sampSetChatInputEnabled(true)
            else safeSend(string.format("/%s %s", full, id)) end
            return
        end
        if p == "" then fmsg("\211\234\224\230\232\242\229 \239\224\240\224\236\229\242\240\251: /" .. short .. " ...") return end
        safeSend("/" .. full .. " " .. p)
    end)
end

local function cmdAr(id)
    if not id then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /ar ID") return end
    local text
    local name = "ID " .. id
    for _, r in ipairs(reports) do
        if r.id == id then text = r.text name = r.name .. "[" .. id .. "]" break end
    end
    sendSeq({
        string.format("/pm %s \199\228\240\224\226\241\242\226\243\233\242\229, \226\224\248\224 \230\224\235\238\225\224 \239\240\232\237\255\242\224, \239\229\240\229\228\224\254 \229\184 \224\228\236\232\237\232\241\242\240\224\246\232\232.", id),
        "/a \202\238\235\235\229\227\232, \238\242\226\229\247\224\229\236 \237\224 \240\229\239\238\240\242!",
        string.format("/a %s | \198\224\235\238\225\224: %s", name, text or "\242\229\234\241\242 \237\229 \237\224\233\228\229\237, \241\236\238\242\240\232\242\229 /report"),
    }, SEND_GAP)
end

----------------------------------------------------------------------
-- ОБЪЯВЛЕНИЯ, ПАМЯТКИ И ПРОВЕРКИ
----------------------------------------------------------------------
local D_RULES = 4150

local D_CHK, D_CHKRES = 4151, 4152
local ROLES = {
    { "io", "\200\206", "\200.\206. \206\241\237\238\226\224\242\229\235\255" }, { "zo", "\199\206", "\199\224\236\229\241\242\232\242\229\235\252 \206\241\237\238\226\224\242\229\235\255" }, { "po", "\207\206", "\207\238\236\238\249\237\232\234 \206\241\237\238\226\224\242\229\235\255" },
    { "ks", "\202\209", "\202\243\240\224\242\238\240 \241\229\240\226\229\240\224" }, { "zks", "\199\202\209", "\199\224\236\229\241\242\232\242\229\235\252 \202\243\240\224\242\238\240\224 \241\229\240\226\229\240\224" },
    { "ga", "\195\192", "\195\235\224\226\237\251\233 \224\228\236\232\237\232\241\242\240\224\242\238\240" }, { "zga", "\199\195\192", "\199\224\236\229\241\242\232\242\229\235\252 \195\235\224\226\237\238\227\238 \224\228\236\232\237\232\241\242\240\224\242\238\240\224" },
    { "gsg", "\195\209 \227\238\241\241", "\195\235\224\226\237\251\233 \241\235\229\228\255\249\232\233 \231\224 \227\238\241\241. \241\242\240\243\234\242\243\240\224\236\232" }, { "gsgh", "\195\209 \227\229\242\242\238", "\195\235\224\226\237\251\233 \241\235\229\228\255\249\232\233 \231\224 \227\229\242\242\238" },
    { "gsm", "\195\209 \236\224\244\232\232", "\195\235\224\226\237\251\233 \241\235\229\228\255\249\232\233 \231\224 \236\224\244\232\255\236\232" },
    { "zgsg", "\199\195\209 \227\238\241\241", "\199\224\236\229\241\242\232\242\229\235\252 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \227\238\241\241. \241\242\240\243\234\242\243\240\224\236\232" },
    { "zgsgh", "\199\195\209 \227\229\242\242\238", "\199\224\236\229\241\242\232\242\229\235\252 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \227\229\242\242\238" },
    { "zgsm", "\199\195\209 \236\224\244\232\232", "\199\224\236\229\241\242\232\242\229\235\252 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \236\224\244\232\255\236\232" },
    { "pgsg", "\207\195\209 \227\238\241\241", "\207\238\236\238\249\237\232\234 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \227\238\241\241. \241\242\240\243\234\242\243\240\224\236\232" },
    { "pgsgh", "\207\195\209 \227\229\242\242\238", "\207\238\236\238\249\237\232\234 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \227\229\242\242\238" },
    { "pgsm", "\207\195\209 \236\224\244\232\232", "\207\238\236\238\249\237\232\234 \195\235\224\226\237\238\227\238 \241\235\229\228\255\249\229\227\238 \231\224 \236\224\244\232\255\236\232" },
}
-- быстрые наборы должностей
local CHK_PRESETS = {
    { "\208\243\234\238\226\238\228\241\242\226\238", { "io", "zo", "po", "ks", "zks" } },
    { "\209\235\229\228\255\249\232\229", { "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
    { "\195\192 \232 \199\195\192", { "ga", "zga" } },
    { "\195\235\224\226\237\251\229 \241\235\229\228\255\249\232\229", { "gsg", "gsgh", "gsm" } },
    { "\199\195\209", { "zgsg", "zgsgh", "zgsm" } },
    { "\207\195\209", { "pgsg", "pgsgh", "pgsm" } },
    { "\194\241\229", { "io", "zo", "po", "ks", "zks", "ga", "zga", "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
}

-- ход проверки: кто ответил в /a
local CHK = { active = false, list = {}, seen = {}, word = "1", t0 = 0, total = 0, secs = 0, thread = nil, token = 0 }

local function chkNames(keys)
    local out = {}
    for _, k in ipairs(keys) do
        for _, r in ipairs(ROLES) do if r[1] == k then out[#out + 1] = r[3] end end
    end
    return out
end

-- строки объявления в /a (sel - полные названия должностей, пусто - общая проверка)
local function chkLines(sel, word, secs)
    word = trim(word or "")
    if word == "" then word = "1" end
    secs = tonumber(secs) or 0
    local answer = (word == "1") and "\246\232\244\240\243 1" or ("\241\235\238\226\238 \171" .. word .. "\187")
    local tail = secs > 0 and (" \194\240\229\236\255: " .. math.floor(secs) .. " \241\229\234.") or ""
    local lines = { "/a \207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232 \224\228\236\232\237\232\241\242\240\224\246\232\232!" }
    if sel and #sel > 0 then
        -- строки собираем по длине в символах (сервер режет сообщение на 128 байтах)
        local function clen(x)
            if #"\255" == 2 then return #x - select(2, x:gsub("[\128-\191]", "")) end
            return #x
        end
        local cur, first = {}, true
        local function flush(last)
            if #cur == 0 then return end
            lines[#lines + 1] = "/a " .. (first and "\206\242\231\251\226\224\254\242\241\255: " or "") .. table.concat(cur, ", ") .. (last and "." or ",")
            first, cur = false, {}
        end
        local used = 0
        for _, name in ipairs(sel) do
            if #cur > 0 and used + 2 + clen(name) > 95 then flush(false) used = 0 end
            used = used + (#cur > 0 and 2 or 0) + clen(name)
            cur[#cur + 1] = name
        end
        flush(true)
        lines[#lines + 1] = "/a \207\238\241\242\224\226\252\242\229 \241\226\238\233 \242\229\227 \232 \237\224\239\232\248\232\242\229 \226 /a " .. answer .. "." .. tail
    else
        lines[#lines + 1] = "/a \195\235\224\226\237\251\229 \232 \231\224\236\229\241\242\232\242\229\235\232 \227\235\224\226\237\251\245 \241\235\229\228\255\249\232\245 - \239\238\241\242\224\226\252\242\229 \241\226\238\233 \242\229\227."
        lines[#lines + 1] = "/a \207\238\228\242\226\229\240\228\232\242\229 \239\240\232\241\243\242\241\242\226\232\229: \237\224\239\232\248\232\242\229 \226 /a " .. answer .. "." .. tail
    end
    return lines, word, secs
end

local function chkResultText()
    local t = { string.format("{FFFFFF}\206\242\236\229\242\232\235\232\241\252: {33CC33}%d", #CHK.list) }
    t[#t + 1] = "{A9A9A9}\206\242\226\229\242: " .. CHK.word .. (CHK.active and "   (\239\240\238\226\229\240\234\224 \232\228\184\242)" or "   (\239\240\238\226\229\240\234\224 \231\224\234\238\237\247\229\237\224)")
    t[#t + 1] = ""
    if #CHK.list == 0 then t[#t + 1] = "{A9A9A9}\207\238\234\224 \237\232\234\242\238 \237\229 \238\242\226\229\242\232\235." end
    for i, e in ipairs(CHK.list) do
        t[#t + 1] = string.format("{FFFFFF}%d. %s{A9A9A9}%s  - \247\229\240\229\231 %d \241\229\234.", i, e.name, e.id and ("[" .. e.id .. "]") or "", e.sec)
    end
    return table.concat(t, "\n")
end

local function chkShow()
    uiShow(D_CHKRES, "FH | \200\242\238\227 \239\240\238\226\229\240\234\232 \224\234\242\232\226\237\238\241\242\232", chkResultText(), "\199\224\234\240\251\242\252", "", 0)
end
uiHandlers[D_CHKRES] = function() end

-- конец проверки; announce - сообщить итог в /a
local function chkEnd(announce)
    if not CHK.active then fmsg("\207\240\238\226\229\240\234\224 \237\229 \231\224\239\243\249\229\237\224.") return end
    CHK.active = false
    CHK.token = CHK.token + 1
    if CHK.thread then cancelTimer(CHK.thread) CHK.thread = nil end
    fmsg(string.format("\207\240\238\226\229\240\234\224 \231\224\234\238\237\247\229\237\224. \206\242\236\229\242\232\235\232\241\252: %d (\241\239\232\241\238\234: /chkres).", #CHK.list))
    if announce then safeSend(string.format("/a \207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232 \231\224\226\229\240\248\229\237\224. \206\242\236\229\242\232\235\232\241\252: %d.", #CHK.list)) end
end

-- вызывается для каждой строки чата: ищет ответы вида «Ник[ID]: 1»
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

-- sel: список названий должностей; opts: { word = "1", seconds = 60 }
local function sayA1(sel, opts)
    opts = opts or {}
    local lines, word, secs = chkLines(sel, opts.word, opts.seconds)
    CHK.active, CHK.list, CHK.seen, CHK.word, CHK.secs = false, {}, {}, word, secs
    if CHK.thread then cancelTimer(CHK.thread) CHK.thread = nil end
    CHK.token = CHK.token + 1
    local my = CHK.token
    sendSeq(lines, SEND_GAP, function()
        if CHK.token ~= my then return end
        CHK.active, CHK.t0 = true, os.clock()
        if secs > 0 then
            CHK.thread = scheduleAfter(secs * 1000, function()
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

-- /a1 [должности] [t=секунд] [w=слово]
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
        fmsg("\205\229 \231\237\224\254: " .. table.concat(bad, ", ") .. ". \202\235\254\247\232: " .. table.concat(keys, " ") .. " | t=60 w=\241\235\238\226\238")
        return
    end
    sayA1(sel, opts)
end

local function uiChk()
    local t = { "{33CC33}\206\225\249\224\255 \239\240\238\226\229\240\234\224 (\225\229\231 \228\238\235\230\237\238\241\242\229\233)" }
    for _, p in ipairs(CHK_PRESETS) do t[#t + 1] = "{66CCFF}\205\224\225\238\240: {FFFFFF}" .. p[1] end
    for _, r in ipairs(ROLES) do t[#t + 1] = "{FFFFFF}" .. r[2] end
    uiShow(D_CHK, "FH | \207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232", table.concat(t, "\n"), "\207\240\238\226\229\240\232\242\252", "\199\224\234\240\251\242\252", 2)
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
        "\205\238\240\236\224 \238\237\235\224\233\237\224 \235\232\228\229\240\224: \226 \225\243\228\237\232 1 \247\224\241, \226 \226\251\245\238\228\237\251\229 1 \247\224\241 30 \236\232\237\243\242.",
        "\205\229 \238\242\251\227\240\224\235\232 \237\238\240\236\243 - \239\238\235\243\247\224\229\242\229 \226\251\227\238\226\238\240.",
        "3/3 \226\251\227\238\226\238\240\238\226 - \241\237\255\242\232\229 \241 \239\238\241\242\224 \235\232\228\229\240\224 \232 \215\209\203.",
        "\215\224\241 \239\232\234 \226 \225\243\228\237\232: \241 17:00 \228\238 20:00.",
        "\215\224\241 \239\232\234 \226 \226\251\245\238\228\237\251\229: \241 16:00 \228\238 19:00.",
        "\206\242\241\243\242\241\242\226\232\229 \226 \247\224\241 \239\232\234 \242\238\230\229 \234\224\240\224\229\242\241\255 \226\251\227\238\226\238\240\238\236.",
        "\194\238\239\240\238\241\251 - \234 \241\235\229\228\255\249\232\236 \226\224\248\229\233 \241\242\240\243\234\242\243\240\251.",
    }, 3500)
end

local function sayInfo()
    sendSeq({
        "/aad [INFO] \211\226\224\230\224\229\236\251\229 \232\227\240\238\234\232, \224\228\236\232\237\232\241\242\240\224\246\232\255 \226\241\229\227\228\224 \237\224 \241\226\255\231\232!",
        "/aad [INFO] \205\224\248\235\232 \225\224\227 \232\235\232 \237\224\240\243\248\229\237\232\229 - \239\232\248\232\242\229 \226 /rep.",
        "/aad [INFO] \212\238\240\236\243\235\232\240\243\233\242\229 \226\238\239\240\238\241 \232\235\232 \230\224\235\238\225\243 \234\238\240\238\242\234\238 \232 \239\238\237\255\242\237\238.",
        "/aad [INFO] \199\224 \244\235\243\228, \238\244\244\242\238\239 \232 \238\241\234\238\240\225\235\229\237\232\255 \226 \240\229\239\238\240\242\229 \226\251\228\224\184\242\241\255 \237\224\234\224\231\224\237\232\229.",
        "/aad [INFO] \207\240\232\255\242\237\238\233 \232\227\240\251!",
    }, SEND_GAP)
end

local function sayTimeInfo()
    sendSeq({
        "/aad [INFO] \200\227\240\238\234\232, \237\224\239\238\236\232\237\224\229\236 \238\225 \224\234\246\232\232 \231\224 \238\237\235\224\233\237!",
        "/aad [INFO] \206\242\251\227\240\224\233\242\229 \247\224\241 \237\224 \241\229\240\226\229\240\229 \232 \239\238\235\243\247\232\242\229 \239\240\232\231.",
        "/aad [INFO] \205\224\227\240\224\228\243 \236\238\230\237\238 \239\238\235\243\247\224\242\252 \228\238 5 \240\224\231 \226 \228\229\237\252.",
        "/aad [INFO] \207\240\238\226\229\240\232\242\252 \226\240\229\236\255 \232 \231\224\225\240\224\242\252 \239\240\232\231: /rep time",
        "/aad [INFO] \209 \243\226\224\230\229\237\232\229\236, \224\228\236\232\237\232\241\242\240\224\246\232\255 \239\240\238\229\234\242\224.",
    }, SEND_GAP)
end

local function sayGwIntro(prize)
    prize = trim(prize or "")
    local lines = {
        "/aad [\208\224\231\228\224\247\224] \194\237\232\236\224\237\232\229, \232\227\240\238\234\232! \209\229\233\247\224\241 \239\240\238\233\228\184\242 \225\251\241\242\240\224\255 \240\224\231\228\224\247\224 \239\240\232\231\238\226.",
        "/aad [\208\224\231\228\224\247\224] \207\240\232\227\238\242\238\226\252\242\229\241\252 \239\232\241\224\242\252 \234\238\228\238\226\238\229 \241\235\238\226\238 \226 \247\224\242!",
    }
    if prize ~= "" then lines[#lines + 1] = "/aad [\208\224\231\228\224\247\224] \207\240\232\231: " .. prize .. "." end
    sendSeq(lines, SEND_GAP)
end

local RULES_TEXT = {
    capt = {
        "FH | \207\240\224\226\232\235\224 \234\224\239\242\238\226",
        "{66CCFF}\208\224\231\240\229\248\229\237\238\n" ..
        "{FFFFFF}- \241\235\224\233\228\251, \239\238\235\243\241\235\224\233\228\251, +C, \241\225\232\226 \239\229\240\229\234\224\242\224\n" ..
        "- \234\240\251\248\232, \237\224 \234\238\242\238\240\251\229 \239\238\239\224\228\224\254\242 \226 2 \239\240\251\230\234\224 \232\235\232 \239\238 \235\229\241\242\237\232\246\229\n" ..
        "- \241\235\232\226 \226\237\229 \234\226\224\228\240\224\242\224 \239\238\241\235\229 5 \236\232\237\243\242 \234\224\239\242\224\n" ..
        "- \234\224\239\242 \234\243\241\234\238\236 \232\235\232 \238\225\240\229\231\238\236, \236\224\248\232\237\251 \228\235\255 \225\224\240\240\232\234\224\228\n\n" ..
        "{FF6666}\205\229\235\252\231\255 (1/3, \241\239\224\226\237, \228\230\229\233\235 \232\235\232 \226\224\240\237)\n" ..
        "{FFFFFF}- \243\225\232\233\241\242\226\238 \232\235\232 \231\224\239\240\229\242 \226\245\238\228\224 \226 \234\226\224\228\240\224\242 \228\238 5 \236\232\237\243\242\n" ..
        "- \234\240\251\248\232 \226\251\248\229 2 \239\240\251\230\234\238\226\n" ..
        "- \231\224\245\238\228\232\242\252 \226 \232\237\242\229\240\252\229\240 \226 \225\238\254, \209\202 \226 \232\237\242\229\240\252\229\240\229 \225\224\237\228\251\n" ..
        "- \238\225\241\242\240\229\235 \240\229\241\239\224\226\237\224 \241\238\239\229\240\237\232\234\224\n" ..
        "- \236\224\241\234\224, \225\240\238\237\255, \224\239\242\229\247\234\232, \237\224\240\234\238\242\232\234\232 \226 \225\238\254\n" ..
        "- \247\243\230\238\233 \241\234\232\237, \229\241\235\232 \234\235\232\241\242 \225\224\237\228\251 \237\229 \241\238\226\239\224\228\224\229\242 \241\238 \241\234\232\237\238\236 \244\240\224\234\246\232\232\n\n" ..
        "{FF6666}\210\255\230\184\235\251\229 \237\224\240\243\248\229\237\232\255\n" ..
        "{FFFFFF}- \196\205\202, \228\230\229\242\239\224\234, \228\238\236 \237\224 \234\238\235\184\241\224\245 \226 \234\226\224\228\240\224\242\229: 1/3\n" ..
        "- \224\237\242\232\244\240\224\227 (\241\243\232\246\232\228, \240\229\235\238\227, \239\238\228\241\242\224\226 \239\238\228 \227\238\241\237\232\234\238\226): 1/3\n" ..
        "- \238\242\234\224\231 \228\224\242\252 \238\239\240\243 \241\235\229\228\255\249\232\236 \232\235\232 \241\234\240\251\242\232\229 \247\232\242\238\226: \226\224\240\237 \232 \236\232\237\243\241 \234\226\224\228\240\224\242\n" ..
        "- \225\224\227\238\254\231 Double Kill, \241\242\240\229\235\252\225\224 \239\238 \234\238\235\184\241\224\236: 2/3\n" ..
        "- \239\240\238\226\238\234\224\246\232\255 \237\224 \241\235\232\226 \232\235\232 \209\202 \243 \240\229\241\239\224\226\237\224: \228\230\229\233\235 10 \236\232\237\243\242\n\n" ..
        "{FFCC00}\203\232\228\229\240\224\236 \225\224\237\228\n" ..
        "{FFFFFF}- \226 \234\224\239\242\229 1-3 \240\224\237\227\232 \244\240\224\234\246\232\232 \232\235\232 \239\238\236\229\245\224 \242\240\229\242\252\229\233 \225\224\237\228\251: 1/3 \235\232\228\229\240\243\n" ..
        "- \234\224\239\242 \240\229\241\239\251 \235\254\225\238\233 \225\224\237\228\251: \226\251\227\238\226\238\240, \238\242\236\229\237\224 \234\224\239\242\224, \236\232\237\243\241 3 \234\226\224\228\240\224\242\224\n" ..
        "- \232\227\237\238\240 \234\224\239\242\224 \232\235\232 \237\229\239\240\232\229\231\228 \241\238\241\242\224\226\224 \237\224 \231\224\225\232\226: 1/3 \235\232\228\229\240\243",
    },
    biz = {
        "FH | \207\240\224\226\232\235\224 \225\232\231\226\224\240\238\226",
        "{66CCFF}\206\225\249\229\229\n" ..
        "{FFFFFF}- \231\224\225\232\226\224\242\252 \241\242\240\229\235\243 \236\238\227\243\242 \242\238\235\252\234\238 \235\232\228\229\240 \232\235\232 \231\224\236\229\241\242\232\242\229\235\252, \231\224 30+ \236\232\237\243\242 \247\229\240\229\231 \194\202\n" ..
        "- \226\240\229\236\255 \241\242\240\229\235: \241 12:00 \228\238 22:00 \239\238 \204\238\241\234\226\229, \236\232\237\232\236\243\236 2 \237\224 2\n" ..
        "- \228\235\232\242\229\235\252\237\238\241\242\252 10 \236\232\237\243\242, \237\243\230\237\224 \238\239\240\224 \238\242 \235\232\228\229\240\224 \232 \231\224\236\224, \229\241\235\232 \237\229\242 \241\235\229\228\255\249\232\245\n" ..
        "- 3/3 \243 \236\224\244\232\232: \244\240\224\234\246\232\255 \242\229\240\255\229\242 1 \225\232\231\237\229\241\n\n" ..
        "{FF6666}\205\229\235\252\231\255 (1/3)\n" ..
        "{FFFFFF}- \234\240\251\248\232 \232 \227\238\240\251, \241\242\240\229\235\252\225\224 \239\238 \236\224\248\232\237\229 \239\240\232 \226\250\229\231\228\229 \226\240\224\227\224\n" ..
        "- \242\255\237\243\242\252 \226\240\229\236\255 \226\237\229 \234\226\224\228\240\224\242\224, \234\224\242\224\242\252\241\255 \226 \234\226\224\228\240\224\242\229 \237\224 \236\224\248\232\237\229 \228\238\235\252\248\229 10 \241\229\234\243\237\228 (1/3 \232 \241\239\224\226\237)\n" ..
        "- \247\243\230\238\233 \241\234\232\237, \239\238\236\238\249\252 \239\238\241\242\238\240\238\237\237\232\245 (\236\224\244\232\232 \241\240\224\231\243 3/3)\n" ..
        "- \192\212\202 \225\238\235\252\248\229 30 \241\229\234\243\237\228, \226\229\240\242\238\235\184\242 \232\235\232 \235\232\247\237\251\233 \242\240\224\237\241\239\238\240\242, \237\229 \226\239\243\241\234\224\242\252 \226\240\224\227\224 \226 \234\226\224\228\240\224\242\n" ..
        "- \226\251\245\238\228 \232\231 \234\226\224\228\240\224\242\224, \236\224\241\234\224, \225\240\238\237\255, \238\240\243\230\232\229 \234\240\238\236\229 Desert Eagle, M4, Shotgun, Rifle\n" ..
        "- SK, DB, TK, \241\235\232\226 \232\235\232 \241\242\240\229\235\252\225\224 \226\237\229 \234\226\224\228\240\224\242\224, \232\227\237\238\240 \241\242\240\229\235\251 \232 \241\235\229\228\255\249\232\245\n" ..
        "- \224\237\242\232\244\240\224\227: \239\240\251\230\238\234 \241 \236\238\241\242\224 \232\235\232 \227\238\240\251, \241\243\232\246\232\228\n\n" ..
        "{FF6666}\210\255\230\184\235\251\229 \237\224\240\243\248\229\237\232\255\n" ..
        "{FFFFFF}- \225\224\227\232, \241\225\232\226 \224\237\232\236\224\246\232\233 \226 \225\238\254: 2/3\n" ..
        "- \241\242\240\229\235\252\225\224 \241 \239\224\241\241\224\230\232\240\241\234\238\227\238 \241\232\228\229\237\252\255: 1/3 \232 \228\230\229\233\235 10 \236\232\237\243\242\n" ..
        "- \241\242\240\229\235\224 \226\237\229 12:00-22:00: \238\241\242\224\237\238\226\234\224 \241\242\240\229\235\251 \232 \226\251\227\238\226\238\240 \235\232\228\229\240\243",
    },
}

local function showRules(kind)
    local r = RULES_TEXT[kind]
    if r then uiShow(D_RULES, r[1], r[2], "\199\224\234\240\251\242\252", "", 0) end
end
uiHandlers[D_RULES] = function() end

local VOPROS = {
    { "\215\242\238 \242\224\234\238\229 \215\207?", "\215\207 - \247\224\241 \239\232\234, \238\225\255\231\224\242\229\235\252\237\238\229 \226\240\229\236\255 \238\237\235\224\233\237\224 \235\232\228\229\240\238\226." },
    { "\202\224\234\224\255 \237\238\240\236\224 \238\237\235\224\233\237\224 \243 \235\232\228\229\240\224 \226 \225\243\228\237\232?", "\194 \225\243\228\237\232 \237\238\240\236\224 - 1 \247\224\241." },
    { "\202\224\234\224\255 \237\238\240\236\224 \238\237\235\224\233\237\224 \243 \235\232\228\229\240\224 \226 \226\251\245\238\228\237\251\229?", "\194 \226\251\245\238\228\237\251\229 \237\238\240\236\224 - 1 \247\224\241 30 \236\232\237\243\242." },
    { "\215\242\238 \238\225\255\231\224\237 \228\229\235\224\242\252 \235\232\228\229\240 \244\240\224\234\246\232\232?", "\209\235\229\228\232\242\252 \231\224 \244\240\224\234\246\232\229\233, \244\238\240\243\236\238\236 \232 \241\238\241\242\224\226\238\236." },
    { "\215\242\238 \242\224\234\238\229 \225\235\224\242?", "\193\235\224\242 - \226\251\228\224\247\224 \226\251\241\238\234\238\233 \228\238\235\230\237\238\241\242\232 \225\229\231 \238\242\247\184\242\238\226 \232 \238\225\231\226\238\237\224." },
    { "\209\238 \241\234\238\235\252\234\232 \228\238 \241\234\238\235\252\234\232 \215\207 \226 \225\243\228\237\232?", "\194 \225\243\228\237\232 \215\207 \241 17:00 \228\238 20:00." },
    { "\209\238 \241\234\238\235\252\234\232 \228\238 \241\234\238\235\252\234\232 \215\207 \226 \226\251\245\238\228\237\251\229?", "\194 \226\251\245\238\228\237\251\229 \215\207 \241 16:00 \228\238 19:00." },
}

local function askVopros(p)
    local n = tonumber((p or ""):match("^%d+"))
    local v = n and VOPROS[n]
    if not v then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /vopros 1-" .. #VOPROS .. " (\226\238\239\240\238\241 \235\232\228\229\240\243 \226 \247\224\242, \238\242\226\229\242 \239\238\234\224\230\243 \226\224\236).") return end
    safeSend(v[1])
    fmsg("\206\242\226\229\242: " .. v[2])
end

local INFO = {
    a1 = sayA1, a1args = sayA1Args, chk = uiChk, chkres = chkShow, chkend = function() chkEnd(true) end, chkfin = function() chkEnd(false) end, rules = sayRules, inf = sayInfo, time = sayTimeInfo, intro = sayGwIntro,
    capt = function() showRules("capt") end, biz = function() showRules("biz") end, q = askVopros,
}
local vrThread
-- Timed vehicle actions are serviced by the main-loop scheduler.
local function dvTimer(spawn)
    if vrThread and not vrThread.cancelled then
        fmsg("\210\224\233\236\229\240 \243\230\229 \232\228\184\242 (\238\241\242\224\237\238\226\232\242\252: /vrstop).")
        return
    end
    safeSend("/a \215\229\240\229\231 15 \241\229\234\243\237\228 \224\228\236\232\237-\242\240\224\237\241\239\238\240\242 \225\243\228\229\242 \243\228\224\235\184\237" .. (spawn and " \232 \226\229\241\252 \242\240\224\237\241\239\238\240\242 \241\229\240\226\229\240\224 \226\238\231\226\240\224\249\184\237 \237\224 \236\229\241\242\224!" or "!"))
    vrThread = scheduleAfter(15000, function()
        vrThread = nil
        safeSend("/dvall")
        if spawn then
            vrThread = scheduleAfter(1500, function()
                vrThread = nil
                safeSend("/spawncars")
            end)
        end
    end)
end
local function registerExtra(reg)
    reg("ev", function(p)
        local key, arg = p:match("^(%S+)%s*(.*)$")
        local e = key and eventByKey(key)
        if e then announceEvent(e, arg) elseif key then fmsg("\205\229\242 \242\224\234\238\227\238 \204\207: " .. key .. ". \209\239\232\241\238\234: /ev") else uiEvents() end
    end)
    local function byKey(cmd, fn)
        reg(cmd, function(p)
            local f = fractionByKey(trim(p))
            if f then fn(f) else fmsg("\211\234\224\230\232\242\229 \244\240\224\234\246\232\254: /" .. cmd .. " \234\235\254\247 (\241\239\232\241\238\234 \234\235\254\247\229\233: /fr)") end
        end)
    end
    byKey("nab", recruit) byKey("otb", tryoutAad) byKey("otbo", tryoutO) byKey("tlead", tempLeader)
    reg("fr", uiFractions)

    reg("note", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local title, text = rest:match("^(.-)%s*|%s*(.+)$")
            if not title then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /note add \237\224\231\226\224\237\232\229 | \242\229\234\241\242") return end
            local _, msg = noteAdd(title, text) fmsg(msg)
        elseif sub == "del" then
            local n, i = findNote(rest)
            if not n then fmsg("\199\224\236\229\242\234\224 \237\229 \237\224\233\228\229\237\224.") return end
            table.remove(notes, i) saveNotes() fmsg("\199\224\236\229\242\234\224 \243\228\224\235\229\237\224.")
        elseif sub == "show" then
            local n = findNote(rest)
            if not n then fmsg("\199\224\236\229\242\234\224 \237\229 \237\224\233\228\229\237\224.") return end
            uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "\205\224\231\224\228", "\199\224\234\240\251\242\252", 0)
        else uiNotes() end
    end)
    reg("notes", uiNotes)

    for _, a in ipairs(ALIASES) do regAlias(reg, a) end

    reg("poll", function(p)
        local who = trim(p)
        if who == "" then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /poll \228\238\235\230\237\238\241\242\252 \232 \237\232\234 (\237\224\239\240\232\236\229\240: /poll \195\192 Ivan_Ivanov)") return end
        sendSeq({
            "/aad [\206\239\240\238\241] \200\227\240\238\234\232, \243\228\229\235\232\242\229 \236\232\237\243\242\243!",
            "/aad [\206\239\240\238\241] \206\246\229\237\232\242\229 \240\224\225\238\242\243: " .. who .. ". \206\242\239\240\224\226\252\242\229 \226 /rep \246\232\244\240\243 \238\242 1 \228\238 5.",
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
        claim(p)   -- свой текст: /z o otbor mp
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
        fmsg("\202\238\228\232\240\238\226\234\224: " .. (enc8 and "\225\232\225\235\232\238\242\229\234\224 encoding" or "\231\224\239\224\241\237\224\255 (encoding \237\229 \237\224\233\228\229\237\224)"))
        fmsg("\206\234\237\238 /fh: " .. (g and (g.disabled and "\238\242\234\235\254\247\229\237\238 \232\231-\231\224 \238\248\232\225\238\234" or g.init and "\237\229 \231\224\239\243\241\242\232\235\238\241\252" or "\227\238\242\238\226\238") or "\237\229\228\238\241\242\243\239\237\238 (\237\229\242 mimgui)"))
        local ti = guiState and guiState.tagInfo()
        fmsg("\204\229\242\234\224 \237\224\228 \232\227\240\238\234\238\236: " .. (ti and ((ti.off and ("\238\248\232\225\234\224: " .. tostring(ti.err))) or ("\241\239\238\241\238\225 " .. (ti.mode == 0 and "imgui" or "render") .. (ti.id and (", \232\227\240\238\234 \237\224\233\228\229\237 (ID " .. ti.id .. ")") or ", \232\227\240\238\234 \237\229 \237\224\233\228\229\237"))) or "\237\229\228\238\241\242\243\239\237\224"))
        fmsg("\211\226\229\228\238\236\235\229\237\232\229 \238 \240\229\239\238\240\242\229: " .. (not cfg.reptoast and "\226\251\234\235\254\247\229\237\238 \226 \237\224\241\242\240\238\233\234\224\245" or (g and g.off) and ("\241\235\238\236\224\235\238\241\252: " .. tostring(g.err)) or "\226\234\235\254\247\229\237\238") ..
            ". \208\229\239\238\240\242\238\226 \239\238\235\243\247\229\237\238: " .. #reports)
    end)
    reg("reptest", function(p)
        local text = trim(p or "")
        if text == "" then text = "\210\229\241\242\238\226\251\233 \240\229\239\238\240\242: \239\240\238\226\229\240\234\224 \243\226\229\228\238\236\235\229\237\232\255" end
        local shown = false
        pcall(function() if guiState and guiState.ready() then shown = guiState.reportToast({ name = "Test_Player", id = "7", text = text }) end end)
        fmsg(shown and "\210\229\241\242\238\226\238\229 \243\226\229\228\238\236\235\229\237\232\229 \231\224\239\243\249\229\237\238." or "\211\226\229\228\238\236\235\229\237\232\229 \237\229 \239\238\234\224\231\224\237\238. \207\238\228\240\238\225\237\238\241\242\232: /fhdiag")
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
            cancelTimer(vrThread)
            vrThread = nil
            fmsg("\210\224\233\236\229\240 \240\229\241\239\224\226\237\224 \238\241\242\224\237\238\226\235\229\237.")
        else fmsg("\210\224\233\236\229\240 \237\229 \231\224\239\243\249\229\237.") end
    end)

    reg("tpl", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local _, msg = tplAdd(rest) fmsg(msg)
        elseif sub == "del" then
            local n = tonumber(rest)
            if n and templates[n] then table.remove(templates, n) saveTemplates() fmsg("\216\224\225\235\238\237 \243\228\224\235\184\237.")
            else fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /tpl del N") end
        else
            fmsg("\216\224\225\235\238\237\251 \238\242\226\229\242\238\226 (\238\242\239\240\224\226\232\242\252: /rt [ID] N; \228\238\225\224\226\232\242\252: /tpl add \242\229\234\241\242; \243\228\224\235\232\242\252: /tpl del N):")
            for i, t in ipairs(templates) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, t), -1) end
        end
    end)
    reg("rt", function(p)
        local id, n = p:match("^(%d+)%s+(%d+)$")
        if not id then n = p:match("^(%d+)$") id = watchedId end
        n = tonumber(n)
        if not id or not n or not templates[n] then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /rt [ID] \237\238\236\229\240_\248\224\225\235\238\237\224 (\241\239\232\241\238\234: /tpl)") return end
        replyTo(id, templates[n])
    end)
    reg("mpa", function() armAutoMp(true) end)
    reg("fhset", function(p)
        local k, v = p:match("^(%S+)%s+(%S+)$")
        if k == "automp" and (v == "on" or v == "off") then
            cfg.automp = (v == "on") saveCfg()
            fmsg("\192\226\242\238-/mp \239\238\241\235\229 \224\237\238\237\241\224 \204\207: " .. (cfg.automp and "\226\234\235\254\247\229\237\238" or "\226\251\234\235\254\247\229\237\238"))
        else fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /fhset automp on|off (\241\229\233\247\224\241: " .. (cfg.automp and "on" or "off") .. ")") end
    end)
    loadNotes()
end

----------------------------------------------------------------------
-- ГЛАВНОЕ МЕНЮ /fh
----------------------------------------------------------------------
local D_CMDS, D_CMDPAGE = 4130, 4131
local CMD_PAGES = {
    { "\208\224\231\228\224\247\232",
      "{66CCFF}/gw \241\235\238\226\238 | \239\240\232\231 {FFFFFF}- \231\224\239\243\241\242\232\242\252 \240\224\231\228\224\247\243\n" ..
      "{66CCFF}/gwlast \241\235\238\226\238 | \239\240\232\231 {FFFFFF}- \244\232\237\224\235\252\237\251\233 \240\224\243\237\228, \241\224\236 \231\224\234\240\238\229\242 \240\224\231\228\224\247\243\n" ..
      "{66CCFF}/gwstop {FFFFFF}- \238\242\236\229\237\232\242\252 \240\224\231\228\224\247\243\n\n" ..
      "{A9A9A9}\207\240\232\231: \242\232\239 \232 \247\232\241\235\238. \207\240\232\236\229\240\251: {FFFF00}\225\224\237\234 500000{A9A9A9}, {FFFF00}\235\226\235 3{A9A9A9}, {FFFF00}#9 15{A9A9A9} (\237\238\236\229\240 \241\242\224\242\251).\n" ..
      "\210\232\239\251: \225\224\237\234, \235\226\235, \236\224\242, \238\239\251\242, \231\224\234\238\237, \241\232\236, \225\238\234\241, \234\243\237\227, \234\232\234." },
    { "\208\229\239\238\240\242\251",
      "{66CCFF}/reports {FFFFFF}- \239\238\241\235\229\228\237\232\229 15 \240\229\239\238\240\242\238\226, \226\251\225\240\224\235\232 - \238\242\226\229\242\232\235\232\n" ..
      "{66CCFF}/rr [ID] \242\229\234\241\242 {FFFFFF}- \238\242\226\229\242 \232\227\240\238\234\243 \247\229\240\229\231 /pm\n\n" ..
      "{A9A9A9}\197\241\235\232 ID \237\229 \243\234\224\231\224\237, \225\229\240\184\242\241\255 \232\227\240\238\234 \232\231 \239\238\241\235\229\228\237\229\233 \234\238\236\224\237\228\251 /re." },
    { "\193\232\237\228\229\240",
      "{66CCFF}/fbind {FFFFFF}- \238\234\237\238 \225\232\237\228\229\240\224\n" ..
      "{66CCFF}/bnd add \232\236\255 \242\229\234\241\242 {FFFFFF}- \241\238\231\228\224\242\252 \225\232\237\228 / \228\238\225\224\226\232\242\252 \241\242\240\238\234\243 (\237\229\241\234\238\235\252\234\238 \247\229\240\229\231 ;;)\n" ..
      "{66CCFF}/bnd rm \232\236\255 N {FFFFFF}- \243\228\224\235\232\242\252 \241\242\240\238\234\243\n" ..
      "{66CCFF}/bnd del \232\236\255 {FFFFFF}- \243\228\224\235\232\242\252 \225\232\237\228\n" ..
      "{66CCFF}/bnd delay \232\236\255 \236\241 {FFFFFF}- \239\224\243\231\224 \236\229\230\228\243 \241\242\240\238\234\224\236\232\n" ..
      "{66CCFF}/bnd show \232\236\255, /bnd list {FFFFFF}- \239\240\238\241\236\238\242\240\n\n" ..
      "{A9A9A9}\194 \242\229\234\241\242\229: {FFFF00}{id}{A9A9A9} - ID \232\227\240\238\234\224, {FFFF00}{arg}{A9A9A9} - \242\229\234\241\242 \239\238\241\235\229 \234\238\236\224\237\228\251.\n" ..
      "\209\242\240\238\234\224 \241 / \243\245\238\228\232\242 \234\224\234 \234\238\236\224\237\228\224, \238\241\242\224\235\252\237\238\229 - \226 \238\225\251\247\237\251\233 \247\224\242." },
    { "\204\229\240\238\239\240\232\255\242\232\255",
      "{66CCFF}/ev {FFFFFF}- \241\239\232\241\238\234 \204\207, \226\251\225\240\224\235\232 - \238\225\250\255\226\235\229\237\232\229 \243\248\235\238 \226 /aad\n" ..
      "{66CCFF}/ev \234\235\254\247 {FFFFFF}- \241\240\224\231\243 \238\225\250\255\226\232\242\252 (\237\224\239\240\232\236\229\240 /ev svet). \196\235\255 \171infern\187: /ev infern ID. \207\240\232\231: /ev svet 5\234\234 \232\235\232 /ev infern ID 5\234\234\n\n" ..
      "{A9A9A9}\202\235\254\247\232: svet poliv derbi pryat parkur rulet kovsh myaso dogon car parash digl sultan paint krug infern" },
    { "\212\240\224\234\246\232\232",
      "{66CCFF}/fr {FFFFFF}- \238\234\237\238 \244\240\224\234\246\232\233: \237\224\225\238\240, \238\242\225\238\240, \226\240\229\236\229\237\237\224\255 \235\232\228\229\240\234\224\n" ..
      "{66CCFF}/nab \234\235\254\247 {FFFFFF}- \237\224\225\238\240 \226 /o\n" ..
      "{66CCFF}/otb \234\235\254\247 {FFFFFF}- \238\242\225\238\240 \237\224 \235\232\228\229\240\224 \226 /aad (\239\238\242\238\236 \238\242\234\240\238\229\242\241\255 \226\226\238\228 /mp)\n" ..
      "{66CCFF}/otbo \234\235\254\247 {FFFFFF}- \238\242\225\238\240 \237\224 \235\232\228\229\240\224 \226 /o\n" ..
      "{66CCFF}/tlead \234\235\254\247 {FFFFFF}- \226\231\255\242\252 \226\240\229\236\229\237\237\243\254 \235\232\228\229\240\234\243 (/templeader)\n\n" ..
      "{A9A9A9}\202\235\254\247\232: rus jap ita fun out rif bal azt gro vag arm hos mer rad swt gov lsp fbi rcp sud" },
    { "\205\224\234\224\231\224\237\232\255",
      "{FFFFFF}\194\241\242\224\226\235\255\254\242 \234\238\236\224\237\228\243 \241 ID \226 \241\242\240\238\234\243 \226\226\238\228\224: {66CCFF}/jj /mut /ww {A9A9A9}(jail, mute, warn)\n" ..
      "{FFFFFF}\209 \239\224\240\224\236\229\242\240\224\236\232: {66CCFF}/bb /uw /uj /unm /ub /ib /ip /bip /ofl /mkl /gzc /bp\n" ..
      "{FFFFFF}\207\238 ID \232\235\232 \232\231 /re: {66CCFF}/gs /inv {A9A9A9}(getstats, checkinv)\n" ..
      "{FFFFFF}\193\229\231 \239\224\240\224\236\229\242\240\238\226: {66CCFF}/fuel /gh /wh\n\n" ..
      "{A9A9A9}\208\224\241\248\232\244\240\238\226\234\224: bb-ban, uw-unwarn, uj-unjail, unm-unmute, ub-unban, ib-iban, ip-pgetip,\nbip-banip, ofl-offleader, mkl-makeleader, gzc-gzcolor, bp-setbizprod, wh-warehouse." },
    { "\207\240\238\247\229\229",
      "{66CCFF}/ar ID {FFFFFF}- \238\242\226\229\242 \237\224 \240\229\239\238\240\242: /pm \232\227\240\238\234\243 + \242\229\234\241\242 \230\224\235\238\225\251 \226 /a\n" ..
      "{66CCFF}/poll \228\238\235\230\237\238\241\242\252 \237\232\234 {FFFFFF}- \238\239\240\238\241 \232\227\240\238\234\238\226 \238\225 \238\246\229\237\234\229 \240\224\225\238\242\251 \224\228\236\232\237\224\n" ..
      "{66CCFF}/vr {FFFFFF}- \247\229\240\229\231 15 \241\229\234 \243\228\224\235\232\242\252 \232 \226\229\240\237\243\242\252 \226\229\241\252 \242\240\224\237\241\239\238\240\242, {66CCFF}/vrstop {FFFFFF}- \238\242\236\229\237\224\n" ..
      "{66CCFF}/notes {FFFFFF}- \248\239\224\240\227\224\235\234\232; {66CCFF}/note add \237\224\231\226\224\237\232\229 | \242\229\234\241\242{FFFFFF}, {66CCFF}/note del \237\224\231\226\224\237\232\229" },
    { "\206\225\249\229\229",
      "{66CCFF}/fh {FFFFFF}- \227\235\224\226\237\238\229 \236\229\237\254\n" ..
      "{66CCFF}/fcmd {FFFFFF}- \253\242\238 \238\234\237\238 \241\238 \241\239\232\241\234\238\236 \234\238\236\224\237\228\n" ..
      "{66CCFF}/binder {FFFFFF}- \241\239\240\224\226\234\224 \239\238 \225\232\237\228\229\240\243\n\n" ..
      "{A9A9A9}\209\226\238\232 \241\238\234\240\224\249\229\237\232\255 \241\238\231\228\224\226\224\233\242\229 \226 \225\232\237\228\229\240\229, \237\224\239\240\232\236\229\240:\n{FFFF00}/bnd add jl /jail {id} {arg}" },
}

local function uiCommands()
    local t = {}
    for i, p in ipairs(CMD_PAGES) do t[i] = "{FFFFFF}" .. p[1] end
    uiShow(D_CMDS, "FH | \202\238\236\224\237\228\251", table.concat(t, "\n"), "\206\242\234\240\251\242\252", "\199\224\234\240\251\242\252", 2)
end

uiHandlers[D_CMDS] = function(button, list)
    if button == 0 then return end
    local p = CMD_PAGES[list + 1]
    if not p then return uiCommands() end
    uiShow(D_CMDPAGE, "FH | " .. p[1], p[2], "\205\224\231\224\228", "\199\224\234\240\251\242\252", 0)
end

uiHandlers[D_CMDPAGE] = function(button)
    if button == 1 then uiCommands() end
end

-- Окно /fh: таблица всех команд
local function carsDo(kind)
    if kind == "spawn" then safeSend("/spawncars")
    elseif kind == "dv" then dvTimer(false)
    elseif kind == "fuel" then safeSend("/fuelcars")
    elseif kind == "dvs" then dvTimer(true)
    end
end

local function infoDo(kind, arg) local f = INFO[kind] if f then f(arg) end end

local MENU_ROWS = {
    { "#", "\208\224\231\228\224\247\232" },
    { "/gw \241\235\238\226\238 | \239\240\232\231", "\231\224\239\243\241\242\232\242\252 \240\224\231\228\224\247\243 (\225\224\237\234 500000, \235\226\235 3, #9 15)" },
    { "/gwlast \241\235\238\226\238 | \239\240\232\231", "\244\232\237\224\235\252\237\251\233 \240\224\243\237\228, \241\224\236 \231\224\234\240\238\229\242 \240\224\231\228\224\247\243" },
    { "/gwstop", "\238\242\236\229\237\232\242\252 \240\224\231\228\224\247\243" },
    { "#", "\208\229\239\238\240\242\251" },
    { "/reports", "\239\238\241\235\229\228\237\232\229 15 \240\229\239\238\240\242\238\226, \225\251\241\242\240\251\233 \238\242\226\229\242" },
    { "/rpl", "\238\225\237\238\226\232\242\252 \241\239\232\241\238\234 \240\229\239\238\240\242\238\226 \232\231 /define" },
    { "/tagmode", "\239\229\240\229\234\235\254\247\232\242\252 \241\239\238\241\238\225 \240\232\241\238\226\224\237\232\255 \236\229\242\234\232 \237\224\228 \232\227\240\238\234\238\236 (\229\241\235\232 \237\229 \226\232\228\237\224)" },
    { "/rr [ID] \242\229\234\241\242", "\238\242\226\229\242\232\242\252 \232\227\240\238\234\243 \247\229\240\229\231 /pm" },
    { "/reptest  /fhdiag", "\239\240\238\226\229\240\234\224 \238\226\224\235\252\237\238\227\238 \243\226\229\228\238\236\235\229\237\232\255 \238 \240\229\239\238\240\242\229; \228\232\224\227\237\238\241\242\232\234\224 \234\238\228\232\240\238\226\234\232 \232 \238\234\237\224" },
    { "/fhupd [install]", "\239\240\238\226\229\240\234\224 \238\225\237\238\226\235\229\237\232\233 \237\224 GitHub; install - \241\234\224\247\224\242\252 \232 \243\241\242\224\237\238\226\232\242\252" },
    { "/ai [ID]  /aiset  /aidiag", "\200\200-\239\238\228\241\234\224\231\234\224 \238\242\226\229\242\224 \237\224 \240\229\239\238\240\242; \237\224\241\242\240\238\233\234\224 API (/aiset url|key|model|prompt); /aidiag - \247\242\238 \228\238\241\242\243\239\237\238 \228\235\255 \231\224\239\240\238\241\238\226" },
    { "/ar ID", "\238\242\226\229\242 + \242\229\234\241\242 \230\224\235\238\225\251 \226 /a" },
    { "/tpl  /rt [ID] N", "\248\224\225\235\238\237\251 \238\242\226\229\242\238\226: \241\239\232\241\238\234, \238\242\239\240\224\226\234\224" },
    { "#", "\204\229\240\238\239\240\232\255\242\232\255 \232 \238\239\240\238\241\251" },
    { "/ev [\234\235\254\247] [ID] [\239\240\232\231]", "\224\237\238\237\241 \204\207 \226 /aad \241 \239\240\232\231\238\236 (\241\239\232\241\238\234: /ev)" },
    { "/poll \228\238\235\230\237\238\241\242\252 \237\232\234", "\238\239\240\238\241 \238\225 \238\246\229\237\234\229 \240\224\225\238\242\251 \224\228\236\232\237\224" },
    { "#", "\212\240\224\234\246\232\232" },
    { "/fr", "\238\234\237\238: \237\224\225\238\240, \238\242\225\238\240, \235\232\228\229\240\234\224" },
    { "/nab /otb /otbo /tlead \234\235\254\247", "\237\224\225\238\240 /o, \238\242\225\238\240 /aad, \238\242\225\238\240 /o, \235\232\228\229\240\234\224" },
    { "#", "\206\225\250\255\226\235\229\237\232\255 \232 \239\224\236\255\242\234\232" },
    { "/a1  /chk [\232\238 \231\238 gsg t=60 w=\241\235\238\226\238]", "\239\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232 \239\238 \228\238\235\230\237\238\241\242\255\236, \242\224\233\236\229\240 \232 \241\235\238\226\238 \238\242\226\229\242\224" },
    { "/chkres  /chkend", "\234\242\238 \238\242\236\229\242\232\235\241\255; \231\224\234\238\237\247\232\242\252 \232 \238\225\250\255\226\232\242\252 \232\242\238\227 \226 /a" },
    { "/pravila", "\237\238\240\236\251 \238\237\235\224\233\237\224 \232 \247\224\241 \239\232\234 \235\232\228\229\240\224\236 \226 \247\224\242" },
    { "/inf  /timeinfo", "\232\237\244\238 \228\235\255 \232\227\240\238\234\238\226 \232 \224\234\246\232\255 \231\224 \238\237\235\224\233\237 \226 /aad" },
    { "/razdintro [\239\240\232\231]", "\226\241\242\243\239\235\229\237\232\229 \239\229\240\229\228 \240\224\231\228\224\247\229\233 \226 /aad" },
    { "/captlist  /bizwarlist", "\239\224\236\255\242\234\232 \239\238 \239\240\224\226\232\235\224\236 \234\224\239\242\238\226 \232 \225\232\231\226\224\240\238\226" },
    { "/vopros 1-7", "\226\238\239\240\238\241 \235\232\228\229\240\243 \226 \247\224\242, \238\242\226\229\242 \239\238\234\224\230\229\242 \226\224\236" },
    { "#", "\205\224\234\224\231\224\237\232\255" },
    { "/jj /mut /ww [ID]", "jail, mute, warn - \226\241\242\224\226\255\242 \234\238\236\224\237\228\243 \226 \226\226\238\228" },
    { "/bb /uw /uj /unm /ub", "ban, unwarn, unjail, unmute, unban" },
    { "/ib /ip /bip /ofl /mkl", "iban, pgetip, banip, offleader, makeleader" },
    { "/gs /inv [ID]", "getstats, checkinv (ID \232\235\232 \232\231 /re)" },
    { "/fuel /fc /gh /wh /gzc /bp", "fuelcars, ghetto, warehouse, gzcolor, setbizprod" },
    { "/spc /dva /dvs", "spawncars; \243\228\224\235\229\237\232\229 \224\228\236\232\237-\234\224\240\238\226 (\242\224\233\236\229\240 15 \241 \226 /a); \242\238 \230\229 + spawncars" },
    { "/vr  /vrstop", "\242\238 \230\229, \247\242\238 /dvs; \238\242\236\229\237\224 \242\224\233\236\229\240\224" },
    { "#", "\207\240\238\247\229\229" },
    { "/z [\234\235\254\247]", "\231\224\237\255\242\252 \231\224\228\224\247\243: 3 \240\224\231\224 \171z ...\187 \226 /a (\241\239\232\241\238\234: /z)" },
    { "/vr  /vrstop", "\240\229\241\239\224\226\237 \242\240\224\237\241\239\238\240\242\224 \247\229\240\229\231 15 \241\229\234 / \238\242\236\229\237\224" },
    { "/mpa  /fhset automp on|off", "\226\226\229\241\242\232 /mp \232 \237\224\230\224\242\252 1-\254 \241\242\240\238\234\243 / \224\226\242\238-\240\229\230\232\236" },
    { "/fbind  /bnd", "\241\226\238\233 \225\232\237\228\229\240: \238\234\237\238 \232 \234\238\236\224\237\228\251 (\241\239\240\224\226\234\224 /binder)" },
    { "/notes", "\248\239\224\240\227\224\235\234\232 (\241\226\238\232 \231\224\236\229\242\234\232)" },
}

local function uiMenu()
    local t = { "{A9A9A9}\202\238\236\224\237\228\224\t{A9A9A9}\215\242\238 \228\229\235\224\229\242" }
    for _, r in ipairs(MENU_ROWS) do
        if r[1] == "#" then t[#t + 1] = "{66CCFF}" .. r[2] .. "\t"
        else t[#t + 1] = "{FFFF00}" .. r[1] .. "\t{FFFFFF}" .. r[2] end
    end
    uiShow(D_MENU, "FH " .. VERSION .. " | \202\238\236\224\237\228\251", table.concat(t, "\n"), "\199\224\234\240\251\242\252", "", 5)
end

uiHandlers[D_MENU] = function() end

----------------------------------------------------------------------
-- ОКНО MIMGUI: /fh -- меню слева, страницы справа
-- Если mimgui/шрифт с кириллицей недоступны, /fh откроет обычное диалоговое окно.
----------------------------------------------------------------------
local postedActions = {}
local function post(fn)
    if type(fn) ~= "function" then return end
    if #postedActions >= 256 then
        print("[FH] GUI action queue is full; action rejected")
        return
    end
    postedActions[#postedActions + 1] = fn
end
local function runPosted()
    local processed = 0
    while #postedActions > 0 and processed < 32 do
        local fn = table.remove(postedActions, 1)
        processed = processed + 1
        local ok, err = pcall(fn)
        if not ok then print("[FH] gui action error: " .. tostring(err)) end
    end
end

local guiState   -- заполняется в setupGui; nil, если окно недоступно

local function setupGui()
    if not GUI_ENCODING_OK then return nil end
    local okI, imgui = pcall(require, 'mimgui')
    if not okI or type(imgui) ~= "table" then return nil end
    local okF, ffi = pcall(require, 'ffi')
    if not okF then return nil end

    -- размер экрана и шрифт
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

    -- буферы ввода
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
    local applyStyle   -- определяется ниже

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
            if ucount > 600 then ucache, ucount = {}, 0 end   -- не даём кэшу расти бесконечно
            c = toUi(s) ucache[s] = c ucount = ucount + 1
        end
        return c
    end
    -- крупный текст (второй шрифт, если удалось загрузить)
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
    -- главная кнопка действия: цвет акцента
    local function primary(label, size)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cfg.accent[1] * 0.85, cfg.accent[2] * 0.85, cfg.accent[3] * 0.85, 0.85))
        local clicked = imgui.Button(U(label), size)
        imgui.PopStyleColor()
        return clicked
    end
    local function hint(s) imgui.TextColored(GRAY, U(s)) end

    ------------------------------------------------------------------
    -- страницы
    ------------------------------------------------------------------
    local pages = {}

    pages[1] = { "\202\238\236\224\237\228\251", function()
        title("\194\241\229 \234\238\236\224\237\228\251")
        imgui.Text(U("\207\238\232\241\234")) imgui.SameLine()
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

    pages[2] = { "\208\224\231\228\224\247\232", function()
        title("\208\224\231\228\224\247\224 \239\240\232\231\238\226")
        imgui.Text(U("\202\238\228\238\226\238\229 \241\235\238\226\238")) imgui.PushItemWidth(-1) imgui.InputText("##gwword", B.gwWord, 64) imgui.PopItemWidth()
        imgui.Text(U("\207\240\232\231")) imgui.PushItemWidth(-1) imgui.InputText("##gwprize", B.gwPrize, 96) imgui.PopItemWidth()
        hint("\212\238\240\236\224\242 \239\240\232\231\224: \242\232\239 \232 \247\232\241\235\238. \205\224\239\240\232\236\229\240: \225\224\237\234 500000, \235\226\235 3, #9 15 (\237\238\236\229\240 \241\242\224\242\251).")
        imgui.Spacing()
        local function start(isLast)
            local w, p = getBuf(B.gwWord), getBuf(B.gwPrize)
            post(function() gwStart(w .. " | " .. p, isLast) end)
        end
        if imgui.Button(U("\209\242\224\240\242"), V2(fs * 7, fs * 2)) then start(false) end
        imgui.SameLine()
        if imgui.Button(U("\212\232\237\224\235\252\237\251\233 \240\224\243\237\228"), V2(fs * 10, fs * 2)) then start(true) end
        imgui.SameLine()
        if imgui.Button(U("\209\242\238\239"), V2(fs * 6, fs * 2)) then post(function() gw.active = false gw.last = false fmsg("\208\224\231\228\224\247\224 \238\242\236\229\237\229\237\224.") end) end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        if gw.active then
            imgui.TextColored(GREEN, U("\200\228\184\242 \240\224\231\228\224\247\224"))
            imgui.Text(U("\209\235\238\226\238: " .. gw.word))
            imgui.Text(U("\207\240\232\231: " .. gw.prize))
            if not gw.stat then imgui.TextColored(RED, U("\210\232\239 \239\240\232\231\224 \237\229 \240\224\241\239\238\231\237\224\237 - \226\251\228\224\226\224\242\252 \226\240\243\247\237\243\254.")) end
        else
            imgui.TextColored(GRAY, U("\208\224\231\228\224\247\224 \237\229 \231\224\239\243\249\229\237\224."))
        end
    end }

    pages[3] = { "\208\229\239\238\240\242\251", function()
        title("\207\238\241\235\229\228\237\232\229 \240\229\239\238\240\242\251")
        if imgui.Button(U("\206\225\237\238\226\232\242\252 \232\231 /define") .. "##rpl", V2(fs * 12, fs * 1.8)) then post(function() DEF.refresh() end) end
        imgui.SameLine() hint("\209\239\232\241\238\234 \225\229\240\184\242\241\255 \232\231 \234\238\236\224\237\228\251 /define (\228\232\224\235\238\227 \237\229 \239\238\234\224\231\251\226\224\229\242\241\255).")
        if #reports == 0 then
            hint("\208\229\239\238\240\242\238\226 \239\238\234\224 \237\229\242.")
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
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##reply", U("\206\242\226\229\242 \232\227\240\238\234\243 (\243\233\228\184\242 \247\229\240\229\231 /pm)"), B.reply, 512) imgui.PopItemWidth()
                if imgui.Button(U("\206\242\226\229\242\232\242\252"), V2(fs * 8, fs * 2)) then
                    local text, id = getBuf(B.reply), r.id
                    post(function() if replyTo(id, text) then clearBuf(B.reply) end end)
                end
                imgui.SameLine()
                if imgui.Button(U("\207\240\232\237\255\242\252 \226 /a"), V2(fs * 9, fs * 2)) then
                    local id = r.id
                    post(function() cmdAr(id) end)
                end
                imgui.SameLine()
                if primary("\200\200 \238\242\226\229\242##aibtn", V2(fs * 8, fs * 2)) then
                    local rr = r
                    post(function() AI.suggest(rr, function() end) end)
                end
                imgui.Spacing()
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##rpreason", U("\207\240\232\247\232\237\224 \237\224\234\224\231\224\237\232\255 (\238\225\255\231\224\242\229\235\252\237\238)"), B.modTxt, 160) imgui.PopItemWidth()
                for _, pa in ipairs({ { "\194\224\240\237", "/warn" }, { "\204\243\242", "/mute" }, { "\196\230\224\233\235", "/jail" }, { "\193\224\237", "/ban" } }) do
                    if imgui.Button(U(pa[1]) .. "##rp" .. pa[2], V2(fs * 6, fs * 2)) then
                        local rtx = trim(getBuf(B.modTxt))
                        if rtx == "" then G.modMsg = "\211\234\224\230\232\242\229 \239\240\232\247\232\237\243 \226 \239\238\235\229 \226\251\248\229."
                        else
                            local line = pa[2] .. " " .. r.id .. " " .. rtx
                            G.modMsg = "\206\242\239\240\224\226\235\229\237\238: " .. line
                            post(function() safeSend(line) end)
                        end
                    end
                    imgui.SameLine()
                end
                imgui.NewLine()
                if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
                if AI.status ~= "" then imgui.TextColored(GRAY, toUi(AI.status)) end
            else hint("\194\251\225\229\240\232\242\229 \240\229\239\238\240\242 \232\231 \241\239\232\241\234\224.") end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("\216\224\225\235\238\237\251 \238\242\226\229\242\238\226 (\237\224\230\236\232\242\229 - \242\229\234\241\242 \239\238\239\224\228\184\242 \226 \239\238\235\229 \238\242\226\229\242\224)"))
        for i, t in ipairs(templates) do
            if imgui.SmallButton(U("x") .. "##td" .. i) then
                local idx = i
                post(function() table.remove(templates, idx) saveTemplates() end)
            end
            imgui.SameLine()
            if imgui.Selectable(toUi(t) .. "##tp" .. i, false) then ffi.copy(B.reply, toUi(t):sub(1, 500)) end
        end
        imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##tplnew", U("\237\238\226\251\233 \248\224\225\235\238\237"), B.tpl, 160) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("\196\238\225\224\226\232\242\252 \248\224\225\235\238\237"), V2(fs * 8, 0)) then
            local text = getBuf(B.tpl)
            post(function()
                local ok, msg = tplAdd(text)
                fmsg(msg)
                if ok then clearBuf(B.tpl) end
            end)
        end
    end }

    pages[4] = { "\204\229\240\238\239\240\232\255\242\232\255", function()
        title("\192\237\238\237\241\251 \204\207 \226 /aad")
        imgui.Text(U("ID \226\229\228\243\249\229\227\238 (\228\235\255 \171\196\238\227\238\237\232 \200\237\244\229\240\237\243\241\187)")) imgui.SameLine()
        imgui.PushItemWidth(fs * 5) imgui.InputText("##evid", B.evId, 12) imgui.PopItemWidth()
        imgui.Text(U("\207\240\232\231 (\237\229\238\225\255\231\224\242\229\235\252\237\238)")) imgui.SameLine()
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

    pages[10] = { "\210\240\224\237\241\239\238\240\242", function()
        title("\210\240\224\237\241\239\238\240\242 \241\229\240\226\229\240\224")
        local bw = V2(fs * 14, fs * 2)
        if imgui.Button(U("\199\224\241\239\224\226\237\232\242\252 \234\224\240\251 \241\229\240\226\229\240\224") .. "##cs", bw) then post(function() carsDo("spawn") end) end
        imgui.SameLine()
        if imgui.Button(U("\211\228\224\235\232\242\252 \224\228\236\232\237-\234\224\240\251") .. "##cd", bw) then post(function() carsDo("dv") end) end
        if imgui.Button(U("\211\228\224\235\232\242\252 + \231\224\241\239\224\226\237\232\242\252") .. "##cds", bw) then post(function() carsDo("dvs") end) end
        imgui.SameLine()
        if imgui.Button(U("\199\224\239\240\224\226\232\242\252 \234\224\240\251") .. "##cf", bw) then post(function() carsDo("fuel") end) end
        imgui.Spacing()
        imgui.Spacing()
        hint("\211\228\224\235\229\237\232\229 \224\228\236\232\237-\234\224\240\238\226: \241\237\224\247\224\235\224 \239\240\229\228\243\239\240\229\230\228\229\237\232\229 \226 /a, \247\229\240\229\231 15 \241\229\234\243\237\228 /dvall.")
        if imgui.Button(U("\206\242\236\229\237\232\242\252 \243\228\224\235\229\237\232\229") .. "##cvs", bw) then post(function() pcall(sampProcessChatInput, "/vrstop") end) end
    end }

    local function selNames()
        local names = {}
        for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
        return names
    end

    pages[12] = { "\195\235\224\226\237\224\255", function()
        title("\195\235\224\226\237\224\255", "\193\251\241\242\240\251\229 \228\229\233\241\242\226\232\255 \232 \241\238\241\242\238\255\237\232\229")
        local active = CHK and CHK.active
        local function tile(id, label, value, color)
            imgui.BeginChild("##tile" .. id, V2(fs * 8.6, fs * 4.2), true)
            imgui.TextColored(GRAY, U(label))
            bigText(value, color)
            imgui.EndChild()
        end
        tile(1, "\208\229\239\238\240\242\238\226 \226 \241\239\232\241\234\229", tostring(#reports), ACC) imgui.SameLine()
        tile(2, "\192\226\242\238-/mp", cfg.automp and "\226\234\235" or "\226\251\234\235", cfg.automp and GREEN or GRAY) imgui.SameLine()
        tile(3, "\207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232", active and ("\232\228\184\242: " .. #CHK.list) or "\237\229\242", active and GREEN or GRAY) imgui.SameLine()
        tile(4, "ID \232\231 /re", tostring(watchedId or "-"), YEL)
        if UPD.latest and verNewer(UPD.latest, VERSION) then
            imgui.BeginChild("##updbanner", V2(0, fs * 3.2), true)
            imgui.TextColored(YEL, toUi("\196\238\241\242\243\239\237\238 \238\225\237\238\226\235\229\237\232\229 v" .. UPD.latest .. " (\243 \226\224\241 v" .. VERSION .. ")"))
            if UPD.notes ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.notes)) end
            if primary("\211\241\242\224\237\238\226\232\242\252 \238\225\237\238\226\235\229\237\232\229##updinst", V2(fs * 14, fs * 1.6)) then post(UPD.install) end
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
        imgui.TextColored(ACC, U("\207\208\206\194\197\208\202\200 \200 \208\197\207\206\208\210\219"))
        btn("\207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232", 1, function() INFO.a1(selNames()) end, true, true)
        btn("\209\239\232\241\238\234 \240\229\239\238\240\242\238\226", 2, function() G.page = 3 end, true)
        btn("\208\224\231\228\224\247\224 \239\240\232\231\238\226", 3, function() G.page = 2 end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("\210\208\192\205\209\207\206\208\210"))
        btn("\199\224\239\240\224\226\232\242\252 \234\224\240\251", 4, function() carsDo("fuel") end, true)
        btn("\199\224\241\239\224\226\237\232\242\252 \234\224\240\251", 5, function() carsDo("spawn") end, true)
        btn("\211\228\224\235\232\242\252 \224\228\236-\234\224\240\251 (15 \241)", 6, function() carsDo("dv") end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("\204\197\208\206\207\208\200\223\210\200\223 \200 \206\193\218\223\194\203\197\205\200\223"))
        btn("\205\224\230\224\242\252 /mp", 7, function() armAutoMp(true) end, true)
        btn("\207\240\224\226\232\235\224 \235\232\228\229\240\224\236", 8, function() INFO.rules() end, true)
        btn("\200\237\244\238 \232\227\240\238\234\224\236", 9, function() INFO.inf() end, false)
        imgui.Spacing()
        hint("\206\241\242\224\235\252\237\238\229 - \226 \236\229\237\254 \241\235\229\226\224. \194\241\229 \234\238\236\224\237\228\251 \232 \239\238\232\241\234 \239\238 \237\232\236: \241\242\240\224\237\232\246\224 \171\202\238\236\224\237\228\251\187.")
    end }

    pages[13] = { "\207\240\238\226\229\240\234\224", function()
        title("\207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232")
        hint("\194\251\225\229\240\232\242\229 \228\238\235\230\237\238\241\242\232 \232\235\232 \237\224\225\238\240. \197\241\235\232 \237\232\234\238\227\238 \237\229 \226\251\225\240\224\242\252 - \238\225\249\224\255 \239\240\238\226\229\240\234\224.")
        for i, p in ipairs(CHK_PRESETS) do
            if imgui.Button(U(p[1]) .. "##pre" .. i, V2(fs * 9, fs * 1.8)) then
                sel.roles = {}
                for _, k in ipairs(p[2]) do
                    for ri, r in ipairs(ROLES) do if r[1] == k then sel.roles[ri] = true end end
                end
            end
            imgui.SameLine()
        end
        if imgui.Button(U("\209\225\240\238\241\232\242\252") .. "##prer", V2(fs * 7, fs * 1.8)) then sel.roles = {} end
        imgui.Spacing()
        local function roleBtn(i)
            if imgui.Selectable(U(ROLES[i][2]) .. "##crole" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
        end
        imgui.TextColored(ACC, U("\208\243\234\238\226\238\228\255\249\232\229"))
        for i = 1, 7 do
            roleBtn(i)
            if i ~= 4 and i < 7 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.TextColored(ACC, U("\209\235\229\228\255\249\232\229 (\195\209, \199\195\209, \207\195\209 \239\238 \241\242\240\243\234\242\243\240\224\236)"))
        for i = 8, #ROLES do
            roleBtn(i)
            if (i - 7) % 3 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        imgui.Spacing()
        imgui.Text(U("\206\242\226\229\242")) imgui.SameLine()
        imgui.PushItemWidth(fs * 6) imgui.InputText("##chkword", B.chkWord, 20) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("\209\229\234\243\237\228")) imgui.SameLine()
        imgui.PushItemWidth(fs * 4) imgui.InputText("##chksecs", B.chkSecs, 6) imgui.PopItemWidth()
        imgui.SameLine() hint("(0 - \225\229\231 \242\224\233\236\229\240\224)")
        local word = trim(getBuf(B.chkWord))
        local secs = tonumber(getBuf(B.chkSecs)) or 0
        imgui.Spacing()
        imgui.TextColored(YEL, U("\215\242\238 \243\233\228\184\242 \226 /a:"))
        local names = selNames()
        local key = table.concat(names, "|") .. "#" .. word .. "#" .. secs
        if G.chkKey ~= key then G.chkKey, G.chkPreview = key, (chkLines(names, word, secs)) end
        for _, l in ipairs(G.chkPreview) do imgui.TextWrapped(U(l)) end
        imgui.Spacing()
        local bw = V2(fs * 11, fs * 2.2)
        if primary("\205\224\247\224\242\252 \239\240\238\226\229\240\234\243##chkgo", bw) then
            local names = selNames()
            post(function() sayA1(names, { word = word, seconds = secs }) end)
        end
        imgui.SameLine()
        if imgui.Button(U("\199\224\226\229\240\248\232\242\252 \232 \238\225\250\255\226\232\242\252") .. "##chkfin", bw) then post(function() chkEnd(true) end) end
        imgui.SameLine()
        if imgui.Button(U("\200\242\238\227 \238\234\237\238\236") .. "##chkres", bw) then post(chkShow) end
        imgui.Spacing()
        if CHK.active then imgui.TextColored(GREEN, U("\200\228\184\242 \239\240\238\226\229\240\234\224. \206\242\236\229\242\232\235\232\241\252: " .. #CHK.list))
        else imgui.TextColored(GRAY, U("\207\240\238\226\229\240\234\224 \237\229 \232\228\184\242. \207\238\241\235\229\228\237\232\233 \240\229\231\243\235\252\242\224\242: " .. #CHK.list)) end
        imgui.BeginChild("##chkans", V2(0, fs * 7), true)
        if #CHK.list == 0 then hint("\207\238\234\224 \237\232\234\242\238 \237\229 \238\242\226\229\242\232\235.") end
        for i, e in ipairs(CHK.list) do
            imgui.Text(U(i .. ". " .. e.name .. (e.id and ("[" .. e.id .. "]") or "")))
            imgui.SameLine(fs * 16) imgui.TextColored(GRAY, U("\247\229\240\229\231 " .. e.sec .. " \241\229\234."))
        end
        imgui.EndChild()
    end }

    pages[14] = { "\200\200", function()
        title("\200\200-\239\238\236\238\249\237\232\234")
        hint("\209\239\240\238\241\232\242\229 \247\242\238 \243\227\238\228\237\238: \239\240\224\226\232\235\224, \244\238\240\236\243\235\232\240\238\226\234\232, \238\242\226\229\242 \232\227\240\238\234\243. \206\242\226\229\242 \239\238\255\226\232\242\241\255 \237\232\230\229.")
        imgui.InputTextMultiline("##aichat", B.aiChat, 600, V2(-1, fs * 4))
        local bw = V2(fs * 11, fs * 2)
        if primary("\209\239\240\238\241\232\242\252##aiask", bw) then
            local q = trim(getBuf(B.aiChat))
            if q == "" then G.aiMsg = "\205\224\239\232\248\232\242\229 \226\238\239\240\238\241."
            elseif not AI.ready() then G.aiMsg = "\209\237\224\247\224\235\224 \231\224\239\238\235\237\232\242\229 \224\228\240\229\241 \232 \234\235\254\247 API \226 \205\224\241\242\240\238\233\234\224\245."
            else
                G.aiMsg = "\196\243\236\224\254..."
                post(function()
                    AI.ask("\210\251 \239\238\236\238\249\237\232\234 \224\228\236\232\237\232\241\242\240\224\242\238\240\224 SA-MP \241\229\240\226\229\240\224. \206\242\226\229\247\224\233 \234\240\224\242\234\238, \239\238-\240\243\241\241\234\232.", q, function(ok, text)
                        G.aiMsg = ok and tostring(text) or ("\206\248\232\225\234\224: " .. tostring(text))
                    end)
                end)
            end
        end
        imgui.SameLine()
        if imgui.Button(U("\206\247\232\241\242\232\242\252") .. "##aiclr", bw) then ffi.copy(B.aiChat, "") G.aiMsg = nil end
        imgui.BeginChild("##aians", V2(0, fs * 8), true)
        imgui.TextWrapped(U(G.aiMsg or "\206\242\226\229\242 \239\238\255\226\232\242\241\255 \231\228\229\241\252."))
        imgui.EndChild()
    end }

    pages[15] = { "\204\238\228\229\240\224\246\232\255", function()
        title("\204\238\228\229\240\224\246\232\255")
        hint("\211\234\224\230\232\242\229 ID \232\235\232 \237\232\234 \232 \242\229\234\241\242 (\239\240\232\247\232\237\243). \202\237\238\239\234\232 \238\242\239\240\224\226\235\255\254\242 \234\238\236\224\237\228\243 \241\240\224\231\243, \234\224\234 \239\240\232 \226\226\238\228\229 \226 \247\224\242.")
        imgui.Text(U("ID / \237\232\234")) imgui.SameLine()
        imgui.PushItemWidth(fs * 12) imgui.InputText("##modid", B.modId, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("\210\229\234\241\242")) imgui.SameLine()
        imgui.PushItemWidth(-1) imgui.InputText("##modtxt", B.modTxt, 160) imgui.PopItemWidth()
        local mid, mtx = trim(getBuf(B.modId)), trim(getBuf(B.modTxt))
        local bw = V2(fs * 9, fs * 2)
        local ACT = {
            { "\195\229\242\242\238", "/ghetto", false },
            { "\209\234\235\224\228", "/warehouse", false },
            { "\214\226\229\242 \225\224\237\228\251", "/gzcolor", "text" },
            { "\194\224\240\237", "/warn", "idtext" },
            { "\192\237\226\224\240\237", "/unwarn", "id" },
            { "\204\243\242", "/mute", "idtext" },
            { "\208\224\231\236\243\242", "/unmute", "id" },
            { "\196\230\224\233\235", "/jail", "idtext" },
            { "\200\231 \228\230\224\233\235\224", "/unjail", "id" },
            { "\193\224\237", "/ban", "idtext" },
            { "\208\224\231\225\224\237", "/unban", "id" },
            { "\209\242\224\242\232\241\242\232\234\224", "/getstats", "id" },
            { "\200\237\226\229\237\242\224\240\252", "/checkinv", "id" },
        }
        for i, a in ipairs(ACT) do
            if imgui.Button(U(a[1]) .. "##mod" .. i, bw) then
                local need = a[3]
                if (need == "id" or need == "idtext") and mid == "" then
                    G.modMsg = "\211\234\224\230\232\242\229 ID \232\235\232 \237\232\234."
                elseif (need == "text" or need == "idtext") and mtx == "" then
                    G.modMsg = "\199\224\239\238\235\237\232\242\229 \239\238\235\229 \171\210\229\234\241\242\187."
                else
                    local parts = { a[2] }
                    if need == "id" or need == "idtext" then parts[#parts + 1] = mid end
                    if need == "text" or need == "idtext" then parts[#parts + 1] = mtx end
                    local line = table.concat(parts, " ")
                    G.modMsg = "\206\242\239\240\224\226\235\229\237\238: " .. line
                    post(function() safeSend(line) end)
                end
            end
            if i % 4 ~= 0 and i < #ACT then imgui.SameLine() end
        end
        imgui.Spacing()
        if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
    end }

    pages[11] = { "\207\224\236\255\242\234\232", function()
        title("\206\225\250\255\226\235\229\237\232\255 \232 \239\224\236\255\242\234\232")
        local bw = V2(fs * 14, fs * 2)
        imgui.TextColored(YEL, U("\207\240\238\226\229\240\234\224 \224\234\242\232\226\237\238\241\242\232: \226\251\225\229\240\232\242\229 \228\238\235\230\237\238\241\242\232"))
        for i, r in ipairs(ROLES) do
            if imgui.Selectable(U(r[2]) .. "##role" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
            if i % 5 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        if imgui.Button(U("\207\240\238\226\229\240\232\242\252 \226\251\225\240\224\237\237\251\245") .. "##i1", bw) then
            local names = {}
            for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
            post(function() infoDo("a1", names) end)
        end
        imgui.Spacing()
        imgui.SameLine()
        if imgui.Button(U("\207\240\224\226\232\235\224 \235\232\228\229\240\224\236") .. "##i2", bw) then post(function() infoDo("rules") end) end
        if imgui.Button(U("\200\237\244\238 \232\227\240\238\234\224\236") .. "##i3", bw) then post(function() infoDo("inf") end) end
        imgui.SameLine()
        if imgui.Button(U("\192\234\246\232\255 \231\224 \238\237\235\224\233\237") .. "##i4", bw) then post(function() infoDo("time") end) end
        if imgui.Button(U("\194\241\242\243\239\235\229\237\232\229 \234 \240\224\231\228\224\247\229") .. "##i5", bw) then post(function() infoDo("intro", getBuf(B.gwPrize)) end) end
        imgui.SameLine()
        hint("\207\240\232\231 \225\229\240\184\242\241\255 \232\231 \239\238\235\255 \240\224\231\228\224\247.")
        imgui.Spacing()
        if imgui.Button(U("\207\240\224\226\232\235\224 \234\224\239\242\238\226") .. "##i6", bw) then post(function() infoDo("capt") end) end
        imgui.SameLine()
        if imgui.Button(U("\207\240\224\226\232\235\224 \225\232\231\226\224\240\238\226") .. "##i7", bw) then post(function() infoDo("biz") end) end
        imgui.Spacing()
        hint("\194\238\239\240\238\241 \235\232\228\229\240\243 \226 \247\224\242 (\238\242\226\229\242 \226 \247\224\242\229 \242\238\235\252\234\238 \226\224\236):")
        for i, v in ipairs(VOPROS) do
            if imgui.Button(tostring(i) .. "##q" .. i, V2(fs * 3, fs * 2)) then post(function() infoDo("q", tostring(i)) end) end
            if i < #VOPROS then imgui.SameLine() end
        end
    end }

    pages[5] = { "\212\240\224\234\246\232\232", function()
        title("\205\224\225\238\240\251, \238\242\225\238\240\251, \235\232\228\229\240\234\232")
        imgui.BeginChild("##frlist", V2(0, fs * 11), true)
        for i, f in ipairs(FRACTIONS) do
            if imgui.Selectable(U(f[2]) .. "##f" .. i, sel.fraction == i) then sel.fraction = i end
        end
        imgui.EndChild()
        local f = FRACTIONS[sel.fraction]
        imgui.Spacing()
        if not f then hint("\194\251\225\229\240\232\242\229 \244\240\224\234\246\232\254.") return end
        imgui.TextColored(YEL, U(f[2]))
        if imgui.Button(U("\205\224\225\238\240 (/o)"), V2(fs * 9, fs * 2)) then post(function() recruit(f) end) end
        imgui.SameLine()
        if imgui.Button(U("\206\242\225\238\240 (/aad)"), V2(fs * 9, fs * 2)) then post(function() tryoutAad(f) end) end
        imgui.SameLine()
        if imgui.Button(U("\206\242\225\238\240 (/o)"), V2(fs * 9, fs * 2)) then post(function() tryoutO(f) end) end
        if imgui.Button(U("\194\231\255\242\252 \235\232\228\229\240\234\243"), V2(fs * 9, fs * 2)) then post(function() tempLeader(f) end) end
    end }

    pages[6] = { "\193\232\237\228\229\240", function()
        title("\209\226\238\232 \225\232\237\228\251")
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
            imgui.TextColored(YEL, U("/" .. sel.bind .. "  (\239\224\243\231\224 " .. b.delay .. " \236\241)"))
            for i, l in ipairs(b.lines) do imgui.TextWrapped(toUi(i .. ". " .. l)) end
        else hint("\194\251\225\229\240\232\242\229 \225\232\237\228 \241\235\229\226\224 \232\235\232 \241\238\231\228\224\233\242\229 \237\238\226\251\233 \237\232\230\229.") end
        imgui.EndChild()
        if b then
            local name = sel.bind
            if imgui.Button(U("\199\224\239\243\241\242\232\242\252"), V2(fs * 8, fs * 2)) then post(function() runBind(name, "") end) end
            imgui.SameLine()
            if imgui.Button(U("\211\228\224\235\232\242\252 \225\232\237\228"), V2(fs * 9, fs * 2)) then post(function() bindDelete(name) sel.bind = "" end) end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("\205\238\226\251\233 \225\232\237\228 / \228\238\225\224\226\232\242\252 \241\242\240\238\234\243"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##bname", U("\232\236\255"), B.bindName, 24) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##btext", U("\242\229\234\241\242; \237\229\241\234\238\235\252\234\238 \241\242\240\238\234 \247\229\240\229\231 ;;"), B.bindText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("\196\238\225\224\226\232\242\252"), V2(fs * 6, 0)) then
            local name, text = trim(getBuf(B.bindName)):lower(), getBuf(B.bindText)
            post(function()
                local ok, msg, n2 = bindAdd(name, text)
                bmsg(msg)
                if ok then sel.bind = n2 clearBuf(B.bindText) end
            end)
        end
    end }

    pages[7] = { "\216\239\224\240\227\224\235\234\232", function()
        title("\209\226\238\232 \231\224\236\229\242\234\232")
        imgui.BeginChild("##notelist", V2(fs * 12, fs * 10), true)
        for i, n in ipairs(notes) do
            if imgui.Selectable(toUi(n.title) .. "##n" .. i, sel.note == i) then sel.note = i end
        end
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild("##noteinfo", V2(0, fs * 10), true)
        local n = notes[sel.note]
        if n then for _, l in ipairs(n.lines) do imgui.TextWrapped(toUi(l)) end
        else hint("\194\251\225\229\240\232\242\229 \231\224\236\229\242\234\243 \241\235\229\226\224 \232\235\232 \241\238\231\228\224\233\242\229 \237\238\226\243\254 \237\232\230\229.") end
        imgui.EndChild()
        if n and imgui.Button(U("\211\228\224\235\232\242\252 \231\224\236\229\242\234\243"), V2(fs * 10, fs * 2)) then
            local idx = sel.note
            post(function() table.remove(notes, idx) saveNotes() sel.note = 0 end)
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("\205\238\226\224\255 \231\224\236\229\242\234\224 / \228\238\225\224\226\232\242\252 \241\242\240\238\234\243"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##ntitle", U("\237\224\231\226\224\237\232\229"), B.noteTitle, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##ntext", U("\242\229\234\241\242; \237\229\241\234\238\235\252\234\238 \241\242\240\238\234 \247\229\240\229\231 ;;"), B.noteText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("\209\238\245\240\224\237\232\242\252"), V2(fs * 6, 0)) then
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
        { "\209\232\237\255\255", 0.26, 0.62, 0.96 }, { "\202\240\224\241\237\224\255", 0.92, 0.30, 0.30 }, { "\199\229\235\184\237\224\255", 0.30, 0.78, 0.45 },
        { "\212\232\238\235\229\242\238\226\224\255", 0.62, 0.40, 0.95 }, { "\206\240\224\237\230\229\226\224\255", 0.98, 0.58, 0.20 },
    }

    pages[8] = { "\205\224\241\242\240\238\233\234\232", function()
        title("\206\244\238\240\236\235\229\237\232\229 \238\234\237\224")
        imgui.Text(U("\214\226\229\242 \224\234\246\229\237\242\224")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##acc", accBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("\214\226\229\242 \244\238\237\224")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##bg", bgBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("\207\240\238\231\240\224\247\237\238\241\242\252 \244\238\237\224")) imgui.PushItemWidth(fs * 16)
        if imgui.SliderFloat("##alpha", alphaBuf, 0.5, 1.0) then applyColors() end
        imgui.PopItemWidth()
        imgui.Spacing() imgui.Text(U("\195\238\242\238\226\251\229 \246\226\229\242\224 \224\234\246\229\237\242\224:"))
        for i, p in ipairs(PRESETS) do
            if imgui.Button(U(p[1]) .. "##pr" .. i, V2(fs * 8, fs * 1.8)) then
                accBuf[0], accBuf[1], accBuf[2] = p[2], p[3], p[4]
                applyColors()
            end
            if i < #PRESETS then imgui.SameLine() end
        end
        if imgui.Button(U("\209\225\240\238\241\232\242\252 \246\226\229\242\224"), V2(fs * 10, fs * 1.8)) then
            accBuf[0], accBuf[1], accBuf[2] = 0.26, 0.62, 0.96
            bgBuf[0], bgBuf[1], bgBuf[2] = 0.07, 0.08, 0.10
            alphaBuf[0] = 0.97
            applyColors()
        end
        imgui.Spacing()
        if imgui.Checkbox(U("\209\242\232\235\252 Liquid Glass (\241\242\229\234\235\238)"), glassBuf) then
            cfg.glass = glassBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("\207\238\235\243\239\240\238\231\240\224\247\237\251\229 \239\224\237\229\235\232 \232 \246\226\229\242\237\251\229 \225\235\232\234\232. \207\240\238\231\240\224\247\237\238\241\242\252 \240\229\227\243\235\232\240\243\229\242\241\255 \239\238\235\231\243\237\234\238\236 \226\251\248\229.")
        if imgui.Checkbox(U("\203\184\227\234\232\233 \240\229\230\232\236 (\229\241\235\232 \238\234\237\238 \235\224\227\224\229\242)"), liteBuf) then
            cfg.lite = liteBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("\211\225\232\240\224\229\242 \225\235\232\234\232 \232 \239\240\238\231\240\224\247\237\238\241\242\252 \238\234\237\224 - \231\224\236\229\242\237\238 \236\229\237\252\248\229 \237\224\227\240\243\231\234\224 \237\224 \242\229\235\229\244\238\237\229.")
        if imgui.Button(U("\207\238\234\224\231\224\242\252 \224\237\232\236\224\246\232\254 \238\242\234\240\251\242\232\255 \241\237\238\226\224") .. "##introagain", V2(fs * 16, fs * 2)) then
            cfg.introDone = false
            G.t0 = nil
            post(saveCfg)
        end
        hint("\192\237\232\236\224\246\232\255 \239\238\234\224\231\251\226\224\229\242\241\255 \242\238\235\252\234\238 \239\240\232 \239\229\240\226\238\236 \231\224\239\243\241\234\229.")
        if imgui.Checkbox(U("\206\226\224\235\252\237\238\229 \243\226\229\228\238\236\235\229\237\232\229 \238 \237\238\226\238\236 \240\229\239\238\240\242\229 (\226\237\232\231\243 \253\234\240\224\237\224)"), repBuf) then
            cfg.reptoast = repBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Checkbox(U("\207\240\238\226\229\240\255\242\252 \238\225\237\238\226\235\229\237\232\255 \239\240\232 \231\224\239\243\241\234\229"), updBuf) then
            cfg.autoupd = updBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Button(U("\207\240\238\226\229\240\232\242\252 \238\225\237\238\226\235\229\237\232\255 \241\229\233\247\224\241") .. "##updnow", V2(fs * 14, fs * 2)) then post(function() UPD.check(false) end) end
        if UPD.status ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.status)) end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("\204\229\240\238\239\240\232\255\242\232\255")
        if imgui.Checkbox(U("\207\238\241\235\229 \224\237\238\237\241\224 \204\207 \226\226\238\228\232\242\252 /mp \232 \237\224\230\232\236\224\242\252 1-\254 \241\242\240\238\234\243"), autoBuf) then
            cfg.automp = autoBuf[0] and true or false
            post(saveCfg)
        end
        hint("\210\238 \230\229 \226\240\243\247\237\243\254: /mpa. \207\229\240\229\234\235\254\247\224\242\229\235\252 \234\238\236\224\237\228\238\233: /fhset automp on|off.")
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("\200\200-\238\242\226\229\242\251 \237\224 \240\229\239\238\240\242\251")
        hint("\203\254\225\238\233 \241\229\240\226\232\241 \241 OpenAI-\241\238\226\236\229\241\242\232\236\251\236 API (chat/completions). \205\243\230\237\251 \225\232\225\235\232\238\242\229\234\232 effil \232 requests.")
        hint("\202\235\254\247 \245\240\224\237\232\242\241\255 \226 moonloader/config/FilippHelper_settings.txt - \237\229 \226\251\234\235\224\228\251\226\224\233\242\229 \253\242\238\242 \244\224\233\235.")
        local pw = (imgui.InputTextFlags and imgui.InputTextFlags.Password) or 0
        imgui.Text(U("\192\228\240\229\241 API")) imgui.PushItemWidth(-1) imgui.InputText("##aiurl", B.aiUrl, 200) imgui.PopItemWidth()
        imgui.Text(U("\202\235\254\247 API")) imgui.PushItemWidth(-1) imgui.InputText("##aikey", B.aiKey, 200, pw) imgui.PopItemWidth()
        imgui.Text(U("\204\238\228\229\235\252")) imgui.PushItemWidth(-1) imgui.InputText("##aimodel", B.aiModel, 60) imgui.PopItemWidth()
        imgui.Text(U("\200\237\241\242\240\243\234\246\232\255 \228\235\255 \200\200 (\239\240\224\226\232\235\224 \226\224\248\229\227\238 \241\229\240\226\229\240\224, \241\242\232\235\252 \238\242\226\229\242\224)"))
        imgui.PushItemWidth(-1) imgui.InputText("##aiprompt", B.aiPrompt, 690) imgui.PopItemWidth()
        if imgui.Button(U("\209\238\245\240\224\237\232\242\252") .. "##aisave", V2(fs * 9, fs * 2)) then post(function() saveAi() fmsg("\205\224\241\242\240\238\233\234\232 \200\200 \241\238\245\240\224\237\229\237\251.") end) end
        imgui.SameLine()
        if imgui.Button(U("\209\238\245\240\224\237\232\242\252 \232 \239\240\238\226\229\240\232\242\252") .. "##aitest", V2(fs * 12, fs * 2)) then post(function() saveAi() AI.test() end) end
        if AI.status ~= "" then imgui.TextWrapped(toUi(AI.status)) end
    end }

    pages[9] = { "\199\224\237\255\242\252", function()
        title("\199\224\237\255\242\252 \231\224\228\224\247\243")
        hint("\205\224\230\236\232\242\229 \234\237\238\239\234\243 - \226 /a \242\240\232 \240\224\231\224 \239\238\228\240\255\228 \243\233\228\184\242 \171z ...\187.")
        imgui.Spacing()
        for i, c in ipairs(CLAIMS) do
            if imgui.Button(toUi("z " .. c[2]) .. "##z" .. i, V2(fs * 11, fs * 2)) then
                local txt = c[2]
                post(function() claim(txt) end)
            end
            if i % 3 ~= 0 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        imgui.Text(U("\209\226\238\233 \242\229\234\241\242 (\239\238\241\235\229 \171z \187)"))
        imgui.PushItemWidth(-fs * 7) imgui.InputText("##claimtext", B.claim, 64) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("\199\224\237\255\242\252") .. "##claimgo", V2(fs * 6, 0)) then
            local txt = getBuf(B.claim)
            post(function() claim(txt) end)
        end
    end }

    ------------------------------------------------------------------
    -- окно
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
        -- левое меню
        imgui.BeginChild("##side", V2(fs * 10, 0), true)
        guarded(function()
            bigText("FilippHelper", ACC)
            imgui.TextColored(GRAY, U("by ByFilipp  \183  v" .. VERSION))
            imgui.Separator() imgui.Spacing()
            -- группы меню; настройки всегда в самом низу
            local groups = {
                { "\195\203\192\194\205\206\197", { "\195\235\224\226\237\224\255", "\208\229\239\238\240\242\251", "\207\240\238\226\229\240\234\224", "\204\229\240\238\239\240\232\255\242\232\255", "\208\224\231\228\224\247\232" } },
                { "\192\196\204\200\205\200\209\210\208\200\208\206\194\192\205\200\197", { "\199\224\237\255\242\252", "\212\240\224\234\246\232\232", "\210\240\224\237\241\239\238\240\242", "\207\224\236\255\242\234\232" } },
                { "\204\206\196\197\208\192\214\200\223", { "\204\238\228\229\240\224\246\232\255" } },
                { "\200\205\209\210\208\211\204\197\205\210\219", { "\200\200", "\193\232\237\228\229\240", "\216\239\224\240\227\224\235\234\232", "\202\238\236\224\237\228\251" } },
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
                    for i, p in ipairs(pages) do   -- страницы, которых нет в группах
                        if not used[i] and p[1] ~= "\205\224\241\242\240\238\233\234\232" then drawBtn(i) end
                    end
                end
            end
            local si = byName["\205\224\241\242\240\238\233\234\232"]
            if si then imgui.Separator() imgui.Spacing() drawBtn(si) end
            imgui.Spacing() imgui.TextColored(GRAY, U("\207\238\228\228\229\240\230\234\224: @ByFilipp123"))
        end)
        imgui.EndChild()
        imgui.SameLine()
        -- правая часть
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
            -- Liquid Glass: полупрозрачные панели, светлые тонкие границы, большие скругления
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

    -- декор стекла: мягкие цветные блики за панелями и световая полоса сверху
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

    -- анимация открытия: вращающаяся искра, печатающееся название и надпись «ByFilipp & Claude»
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
        -- полоса загрузки
        local bw, by = sz.x * 0.28, p.y + sz.y / 2 + fs * 6.6
        local bx = cx - bw / 2
        dl:AddRectFilled(V2(bx, by), V2(bx + bw, by + 4), col(1, 1, 1, 0.12 * fade), 2)
        dl:AddRectFilled(V2(bx, by), V2(bx + bw * math.min(1, age / (INTRO_T - 0.4)), by + 4), col(ar, ag, ab, 0.9 * fade), 2)
    end

    imgui.OnInitialize(function()
        local ok, err = pcall(function()
            local io = imgui.GetIO()
            io.Fonts:AddFontFromFileTTF(fontPath, fs, nil, io.Fonts:GetGlyphRangesCyrillic())
            -- второй (большой) шрифт не создаём: лишний атлас шрифтов ронял игру на слабых ПК; крупный текст делаем масштабом
            applyStyle()
        end)
        if not ok then G.initFailed = true print("[FH] gui init error: " .. tostring(err)) end
    end)

    -- The old world-to-screen label called game natives on every ImGui frame.
    -- It is disabled in v2 so drawing callbacks only render UI primitives.
    function G.tagInfo()
        return { id = nil, mode = 2, off = true, err = "developer tag disabled for stability" }
    end

    -- овальное уведомление о новом репорте (низ экрана по центру, цвет от акцента /fh)
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
                local head = "\208\229\239\238\240\242 \238\242 " .. r.name .. "[" .. r.id .. "]"
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
                fmsg("\211\226\229\228\238\236\235\229\237\232\229 \238 \240\229\239\238\240\242\229 \238\242\234\235\254\247\229\237\238 \232\231-\231\224 \238\248\232\225\234\232: " .. tostring(err):sub(1, 90))
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
                if cfg.intro and not cfg.introDone then   -- первый показ закончился: больше не повторяем
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
-- ОБРАБОТКА СООБЩЕНИЙ СЕРВЕРА
----------------------------------------------------------------------
local function onServerMessageImpl(color, text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
    pcall(chkCollect, text)
    if not text:find("\208\229\239\238\240\242", 1, true) then return end

    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, body = clean:match("\208\229\239\238\240\242 \238\242 ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not name then return end
    body = body:gsub("%s*|%s*\211\230\229%s*%d+%s*\240\229\239\238\240\242[^|]*$", "")

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
    local ok, err = pcall(function()
        if type(command) ~= "string" then return end
        PUN.note(command)
        if command:match("^/define") then DEF.user = os.clock() end
        local id = command:match("^/re%s+(%d+)")
        if id then watchedId = id
        elseif command:match("^/re%s+off") or command:match("^/reoff") then watchedId = nil end
    end)
    if not ok then print("[FH] onSendCommand error: " .. tostring(err)) end
end

----------------------------------------------------------------------
-- ЗАПУСК
----------------------------------------------------------------------
-- Перенесённые команды модерации и обёртки (своя реализация)
local function registerPorted(reg)
    local scThread
    local function tgt(p)
        p = trim(p or "")
        if p ~= "" then return p end
        return watchedId
    end
    -- обёртки над серверными командами
    reg("gt", function() safeSend("/ghetto") end)
    reg("wh", function() safeSend("/warehouse") end)
    reg("cb", function(p) if trim(p or "") ~= "" then safeSend("/warehouse " .. trim(p)) else fmsg("\211\234\224\230\232\242\229 \239\224\240\224\236\229\242\240\251: /cb [\242\229\234\241\242]") end end)
    reg("gc", function(p) if trim(p or "") ~= "" then safeSend("/gzcolor " .. trim(p)) else fmsg("\211\234\224\230\232\242\229 \239\224\240\224\236\229\242\240\251: /gc [\246\226\229\242]") end end)
    reg("sprod", function(p)
        local a, b = (p or ""):match("(%d+)%s+(%d+)")
        if a then safeSend("/setbizprod " .. a .. " " .. b) else fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /sprod [ID \225\232\231\237\229\241\224] [\247\232\241\235\238]") end
    end)
    reg("wn", function(p)
        p = trim(p or "")
        if p:match("^%d+%s+%S") then safeSend("/warn " .. p)
        else fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /wn [ID] [\239\240\232\247\232\237\224]") end
    end)
    -- команды с ID: вставляют команду в строку чата (как у Бруно, но ID по умолчанию из /re)
    local function regId(cmd, sCmd, input)
        reg(cmd, function(p)
            local id = tgt(p)
            if not id then fmsg("\211\234\224\230\232\242\229 ID: /" .. cmd .. " ID (\232\235\232 \241\237\224\247\224\235\224 /re ID)") return end
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
    -- снятие и бан
    local function regArg(cmd, sCmd)
        reg(cmd, function(p)
            p = trim(p or "")
            if p ~= "" then safeSend("/" .. sCmd .. " " .. p) else fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /" .. cmd .. " [ID \232\235\232 \237\232\234]") end
        end)
    end
    regArg("uwn", "unwarn") regArg("ujl", "unjail") regArg("um", "unmute") regArg("bn", "ban") regArg("ubn", "unban")
    -- таймер удаления и респавна транспорта
    reg("sc", function()
        if scThread then cancelTimer(scThread) end
        safeSend("/a \194\237\232\236\224\237\232\229, \247\229\240\229\231 15 \241\229\234\243\237\228 \243\228\224\235\255\254 \232 \240\229\241\239\224\226\237\254 \226\229\241\252 \242\240\224\237\241\239\238\240\242 \237\224 \241\229\240\226\229\240\229!")
        scThread = scheduleAfter(15000, function()
            safeSend("/dvall")
            scThread = scheduleAfter(1500, function()
                safeSend("/spawncars")
                scThread = nil
            end)
        end)
    end)
    reg("scc", function()
        if scThread then
            cancelTimer(scThread)
            scThread = nil
            fmsg("\210\224\233\236\229\240 \240\229\241\239\224\226\237\224 \242\240\224\237\241\239\238\240\242\224 \238\241\242\224\237\238\226\235\229\237.")
        else fmsg("\210\224\233\236\229\240 \240\229\241\239\224\226\237\224 \242\240\224\237\241\239\238\240\242\224 \237\229 \231\224\239\243\249\229\237.") end
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
        cfg.tagmode = 2
        saveCfg()
        fmsg("\204\229\242\234\224 ByFilipp \226 v2 \226\240\229\236\229\237\237\238 \238\242\234\235\254\247\229\237\224 \228\235\255 \241\242\224\225\232\235\252\237\238\241\242\232.")
    end)
    reg("fcmd", uiMenu)
    reg("gw", function(p) gwStart(p, false) end)
    reg("gwlast", function(p) gwStart(p, true) end)
    reg("gwstop", function()
        if gw.active then gw.active = false gw.last = false fmsg("\208\224\231\228\224\247\224 \238\242\236\229\237\229\237\224.")
        else fmsg("\209\229\233\247\224\241 \237\229\242 \224\234\242\232\226\237\238\233 \240\224\231\228\224\247\232.") end
    end)
    reg("rr", function(p)
        local id, text = p:match("^(%d+)%s+(.+)$")
        if not id then id, text = watchedId, p end
        if not id or not replyTo(id, text) then fmsg("\200\241\239\238\235\252\231\238\226\224\237\232\229: /rr [ID] \242\229\234\241\242") end
    end)
end

function main()
    -- Wait for the SA-MP module; do not unload just because it initialized late.
    while true do
        local loaded = true
        if type(isSampLoaded) == "function" then
            local ok, value = pcall(isSampLoaded)
            loaded = ok and value == true
        end
        if loaded and type(sampRegisterChatCommand) == "function" then break end
        wait(250)
    end

    local rawReg = sampRegisterChatCommand
    local function guardedReg(name, fn)
        if type(name) ~= "string" or type(fn) ~= "function" then return false end
        local ok, err = pcall(rawReg, name, function(arg)
            local runOk, runErr = pcall(fn, type(arg) == "string" and fromGame(arg) or "")
            if not runOk then
                print("[FH] command /" .. name .. " error: " .. tostring(runErr))
                fmsg("{FF3333}\206\248\232\225\234\224 \226 \234\238\236\224\237\228\229 /" .. name .. ", \239\238\228\240\238\225\237\238\241\242\\232 \\226 moonloader.log")
            end
        end)
        if not ok then print("[FH] failed to register /" .. name .. ": " .. tostring(err)) end
        return ok
    end

    local builtin = {}
    local function trackedReg(name, callback)
        builtin[name] = true
        return guardedReg(name, callback)
    end

    local okReg, errReg = pcall(registerCommands, trackedReg)
    if not okReg then print("[FH] command registration error: " .. tostring(errReg)) end
    local okBinder, errBinder = pcall(setupBinder, builtin, guardedReg)
    if not okBinder then print("[FH] binder setup error: " .. tostring(errBinder)) end

    local announced = false
    local updateScheduled = false
    while true do
        wait(50)
        processTimers()
        processSendQueue()
        runPosted()
        local okTick, errTick = pcall(uiTick)
        if not okTick then print("[FH] tick error: " .. tostring(errTick)) end

        if not announced and chatReady() then
            announced = true
            fmsg("{FFD700}FilippHelper v" .. VERSION .. " {FFFFFF}- \231\224\227\240\243\230\229\237")
            fmsg("{A9A9A9}\192\226\242\238\240: {66CCFF}ByFilipp {A9A9A9}| переработанное ядро v2")
            fmsg("{A9A9A9}Раздачи, репорты, мероприятия, проверка активности, транспорт и биндер")
            fmsg("{A9A9A9}Управление: {FFFF00}/fh {A9A9A9}| команды: {FFFF00}/fcmd {A9A9A9}| биндер: {FFFF00}/fbind")
            if cfg.autoupd and not updateScheduled then
                updateScheduled = true
                scheduleAfter(15000, function() pcall(UPD.check, true) end)
            end
        end
    end
end
