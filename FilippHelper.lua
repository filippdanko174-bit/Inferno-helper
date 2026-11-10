
local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

local encOk, encoding = pcall(require, 'encoding')
local enc8
if encOk and encoding then
    encoding.default = 'CP1251'
    enc8 = encoding.UTF8
end
local GUI_ENCODING_OK = enc8 ~= nil
local function toUi(s) if enc8 then return enc8:encode(s) end return s end
local function fromUi(s) if enc8 then return enc8:decode(s) end return s end
local function toGame(s) return s end
local function fromGame(s) return s end

local VERSION = "1.3"
local MAX_CHAT_LEN = 128
local SEND_GAP = 1100
local MAX_REPORTS = 15

local watchedId = nil
local reports = {}

local LOWER_MAP = {}
for b = 192, 223 do LOWER_MAP[string.char(b)] = string.char(b + 32) end
LOWER_MAP[string.char(168)] = string.char(184)
local function lower1251(s)
    return (s:lower():gsub("[\192-\223\168]", LOWER_MAP))
end

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function safeSend(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" then return end
    if #text > MAX_CHAT_LEN then text = text:sub(1, MAX_CHAT_LEN) end
    local ok, err = pcall(sampSendChat, text)
    if not ok then print("[FH] sampSendChat error: " .. tostring(err)) end
end

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

local BIND_MAX, BIND_LINES = 50, 20
local binds = {}
local bindFile
local bindBuiltin, bindReg = {}, nil
local bindRunning = false

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
    if not ok then bmsg("Не удалось сохранить биндер в файл!") end
end

local bindStop = false

local function bindTags(line, arg, param)
    local myId, myNick = "", ""
    local okI, id = pcall(function() local _, i = sampGetPlayerIdByCharHandle(PLAYER_PED) return i end)
    if okI and id then
        myId = tostring(id)
        local okN, nick = pcall(sampGetPlayerNickname, id)
        if okN and nick then myNick = nick end
    end
    line = line:gsub("{id}", function() return param end)
    line = line:gsub("{arg}", function() return arg end)
    line = line:gsub("{myid}", function() return myId end)
    line = line:gsub("{mynick}", function() return myNick end)
    return line
end

local function runBind(name, arg)
    local b = binds[name]
    if not b then return end
    if bindRunning then bmsg("Дождитесь окончания предыдущего бинда (или /fstop).") return end
    arg = arg or ""
    local param = tostring((arg ~= "") and arg or (watchedId or ""))
    local src, delay = b.lines, b.delay
    bindRunning, bindStop = true, false
    lua_thread.create(function()
        local ok, err = pcall(function()
            local n = #src
            for i = 1, n do
                if bindStop then break end
                local line = bindTags(src[i], arg, param)
                local w = line:match("{wait%((%d+)%)}")
                line = trim((line:gsub("{wait%(%d+%)}", "")))
                if w then wait(math.min(30000, tonumber(w) or 0)) end
                if bindStop then break end
                if line ~= "" then
                    safeSend(line)
                    if i < n then wait(delay) end
                end
            end
        end)
        bindRunning = false
        if not ok then print("[FH] bind error: " .. tostring(err)) end
    end)
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
    sampShowDialog(4109, "FH | Биндер",
        "{66CCFF}[ СВОЙ БИНДЕР ]\n\n{33CC33}/fbind {FFFFFF}- отдельное окно биндера (создание и правка без команд).\n\n" ..
        "{FFFFFF}Создаёт свои команды: набрали {FFFF00}/имя{FFFFFF} -- отправились все строки бинда по очереди.\n\n" ..
        "{66CCFF}/bnd add имя текст {FFFFFF}- создать бинд / добавить строку.\n" ..
        "{FFFFFF}  Несколько строк сразу разделяйте {FFFF00}&{FFFFFF} (или {FFFF00};;{FFFFFF}), например:\n" ..
        "{FFFF00}  /bnd add hi /aad Привет! & {wait(2000)} /aad Как дела?\n" ..
        "{66CCFF}/bnd rm имя N {FFFFFF}- удалить строку N.\n" ..
        "{66CCFF}/bnd del имя {FFFFFF}- удалить бинд целиком.\n" ..
        "{66CCFF}/bnd delay имя мс {FFFFFF}- пауза между строками (300-10000, по умолчанию 1100).\n" ..
        "{66CCFF}/bnd show имя {FFFFFF}- показать строки бинда.\n" ..
        "{66CCFF}/bnd list {FFFFFF}- список всех биндов.\n\n" ..
        "{9933FF}Подстановки в тексте: {FFFF00}{id}{FFFFFF} - ID из команды (/имя 12) или ID из /re,\n" ..
        "{FFFF00}{arg}{FFFFFF} - всё после команды, {FFFF00}{myid}{FFFFFF} и {FFFF00}{mynick}{FFFFFF} - ваш ID и ник,\n" ..
        "{FFFF00}{wait(мс)}{FFFFFF} - пауза перед строкой, {FFFF00}/fstop{FFFFFF} - остановить бинд.\n" ..
        "{9933FF}Имя: латиница, цифры и _ (до 20 символов). Лимит: " .. BIND_MAX .. " биндов по " .. BIND_LINES .. " строк.",
        "Закрыть", "", 0)
end

local function bindAdd(name, text)
    if not name:match("^[%w_]+$") or #name > 20 then return false, "Имя: латиница, цифры и _ (до 20 символов)." end
    name = name:lower()
    if bindBuiltin[name] or BIND_RESERVED[name] then return false, "Имя /" .. name .. " занято командой хелпера." end
    local b = binds[name]
    if not b then
        if #sortedBindNames() >= BIND_MAX then return false, "Достигнут лимит биндов: " .. BIND_MAX end
        b = { delay = SEND_GAP, lines = {} }
    end
    local added = 0
    for piece in ((text:gsub("%s*&%s*", ";;")) .. ";;"):gmatch("(.-);;") do
        piece = trim(piece)
        if piece ~= "" then
            if #b.lines >= BIND_LINES then break end
            b.lines[#b.lines + 1] = piece
            added = added + 1
        end
    end
    if added == 0 then return false, "Ничего не добавлено (пустой текст или лимит строк " .. BIND_LINES .. ")." end
    if not binds[name] then binds[name] = b registerBind(name) end
    saveBinds()
    return true, string.format("Бинд /%s: добавлено строк %d (всего %d).", name, added, #b.lines), name
end

local function bindDelete(name)
    binds[name] = nil
    pcall(sampUnregisterChatCommand, name)
    saveBinds()
end

local D_MAIN, D_NAME, D_ADD, D_BIND, D_LINES, D_DELAY, D_CONF, D_SHOW = 4110, 4111, 4112, 4113, 4114, 4115, 4116, 4117
local ui = { open = nil, names = {}, sel = nil }
local uiHandlers = {}

local function uiShow(id, title, text, b1, b2, style)
    sampShowDialog(id, title, text, b1, b2, style)
    ui.open = id
end

local function uiMain()
    ui.names = sortedBindNames()
    local t = { "{33CC33}[+] Создать новый бинд" }
    for _, n in ipairs(ui.names) do
        t[#t + 1] = string.format("{FFFFFF}/%s {A9A9A9}- строк: %d, пауза %d мс", n, #binds[n].lines, binds[n].delay)
    end
    uiShow(D_MAIN, "FH | Биндер", table.concat(t, "\n"), "Выбрать", "Закрыть", 2)
end

local function uiBind()
    if not binds[ui.sel] then return uiMain() end
    uiShow(D_BIND, "Бинд /" .. ui.sel,
        "Запустить\nПоказать строки\nДобавить строки\nУдалить строку\nИзменить паузу\n{FF3333}Удалить бинд\nНазад",
        "Выбрать", "Закрыть", 2)
end

local function uiAddPrompt()
    uiShow(D_ADD, "Бинд /" .. ui.sel .. " | Добавить строки",
        "Введите текст строки (команда или сообщение).\nНесколько строк сразу разделяйте {FFFF00};;\n{A9A9A9}Подстановки: {id} - ID, {arg} - текст после команды.",
        "Добавить", "Назад", 1)
end

uiHandlers[D_MAIN] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NAME, "Новый бинд", "Введите имя команды (латиница, цифры, _):", "Далее", "Назад", 1)
    else
        ui.sel = ui.names[list]
        uiBind()
    end
end

uiHandlers[D_NAME] = function(button, _, input)
    if button == 0 then return uiMain() end
    local name = trim(input):lower()
    if not name:match("^[%w_]+$") or #name > 20 then
        bmsg("Имя: латиница, цифры и _ (до 20 символов).")
        return uiShow(D_NAME, "Новый бинд", "{FF3333}Неверное имя!\n{FFFFFF}Латиница, цифры, _ (до 20 символов):", "Далее", "Назад", 1)
    end
    if bindBuiltin[name] or BIND_RESERVED[name] then
        bmsg("Имя /" .. name .. " занято командой хелпера.")
        return uiShow(D_NAME, "Новый бинд", "{FF3333}Имя занято командой хелпера!\n{FFFFFF}Введите другое:", "Далее", "Назад", 1)
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
        uiShow(D_SHOW, "Бинд /" .. ui.sel .. " | Строки", table.concat(t, "\n"), "Назад", "", 0)
    elseif list == 2 then uiAddPrompt()
    elseif list == 3 then
        local t = {}
        for i, l in ipairs(b.lines) do t[i] = i .. ". " .. l end
        uiShow(D_LINES, "Бинд /" .. ui.sel .. " | Какую строку удалить?", table.concat(t, "\n"), "Удалить", "Назад", 2)
    elseif list == 4 then
        uiShow(D_DELAY, "Бинд /" .. ui.sel .. " | Пауза",
            string.format("Пауза между строками в мс (300-10000).\nСейчас: %d", b.delay), "Готово", "Назад", 1)
    elseif list == 5 then
        uiShow(D_CONF, "Удаление бинда", "Удалить бинд /" .. ui.sel .. " целиком?", "Да", "Нет", 0)
    else uiMain() end
end

uiHandlers[D_SHOW] = function() uiBind() end

uiHandlers[D_LINES] = function(button, list)
    local b = binds[ui.sel]
    if button == 1 and b and b.lines[list + 1] then
        table.remove(b.lines, list + 1)
        if #b.lines == 0 then
            bindDelete(ui.sel)
            bmsg("Строк не осталось, бинд удалён.")
            return uiMain()
        end
        saveBinds()
        bmsg("Строка удалена.")
    end
    uiBind()
end

uiHandlers[D_DELAY] = function(button, _, input)
    local ms = tonumber(trim(input))
    if button == 1 and binds[ui.sel] then
        if ms and ms >= 300 and ms <= 10000 then
            binds[ui.sel].delay = math.floor(ms)
            saveBinds()
            bmsg(string.format("Пауза бинда /%s: %d мс.", ui.sel, ms))
        else bmsg("Нужно число от 300 до 10000.") end
    end
    uiBind()
end

uiHandlers[D_CONF] = function(button)
    if button == 1 and binds[ui.sel] then
        bindDelete(ui.sel)
        bmsg("Бинд /" .. ui.sel .. " удалён.")
        return uiMain()
    end
    uiBind()
end

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
            if not name then bmsg("Использование: /bnd add имя текст") return end
            local _, msg = bindAdd(name, text)
            bmsg(msg)
        elseif sub == "del" then
            local name = trim(rest):lower()
            if not binds[name] then bmsg("Бинд не найден: " .. name) return end
            binds[name] = nil
            pcall(sampUnregisterChatCommand, name)
            saveBinds()
            bmsg("Бинд /" .. name .. " удалён.")
        elseif sub == "rm" then
            local name, n = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            local b = name and binds[name]
            n = tonumber(n)
            if not b or not b.lines[n] then bmsg("Использование: /bnd rm имя N (номер строки из /bnd show)") return end
            table.remove(b.lines, n)
            if #b.lines == 0 then
                binds[name] = nil
                pcall(sampUnregisterChatCommand, name)
                bmsg("Строк не осталось, бинд /" .. name .. " удалён.")
            else bmsg("Строка " .. n .. " удалена.") end
            saveBinds()
        elseif sub == "delay" then
            local name, ms = rest:match("^(%S+)%s+(%d+)$")
            name = name and name:lower()
            ms = tonumber(ms)
            if not name or not binds[name] or not ms or ms < 300 or ms > 10000 then
                bmsg("Использование: /bnd delay имя мс (300-10000)") return
            end
            binds[name].delay = ms
            saveBinds()
            bmsg(string.format("Пауза бинда /%s: %d мс.", name, ms))
        elseif sub == "show" then
            local name = trim(rest):lower()
            local b = binds[name]
            if not b then bmsg("Бинд не найден: " .. name) return end
            bmsg(string.format("/%s (пауза %d мс):", name, b.delay))
            for i, l in ipairs(b.lines) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, l), -1) end
        elseif sub == "list" then
            local names = sortedBindNames()
            if #names == 0 then bmsg("Биндов пока нет. Справка: /binder") return end
            bmsg("Ваши бинды: /" .. table.concat(names, ", /"))
        else
            bindHelp()
        end
    end)
end

local LITE_DEFAULT = false
local cfg = {
    automp = true,
    accent = { 0.26, 0.62, 0.96 },
    bg = { 0.07, 0.08, 0.10 },
    alpha = 0.97,
    glass = true,
    devtag = true,
    intro = true,
    lite = LITE_DEFAULT,
    aiUrl = "https://api.openai.com/v1/chat/completions",
    aiKey = "",
    aiModel = "gpt-4o-mini",
    aiPrompt = "Ты помощник администратора SA-MP сервера. Ответь игроку на репорт вежливо и по делу одним коротким сообщением (до 100 символов), без markdown. Если данных мало - попроси уточнить ID нарушителя. Не выдумывай правила и не обещай наказаний.",
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
        f:write("glass=", cfg.glass and "1" or "0", "\r\n", "lite=", cfg.lite and "1" or "0", "\r\n", "devtag=", cfg.devtag and "1" or "0", "\r\n", "intro=", cfg.intro and "1" or "0", "\r\n")
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
            elseif k == "devtag" then cfg.devtag = (v == "1")
            elseif k == "intro" then cfg.intro = (v == "1")
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

local templates = {}
local TPL_MAX, TPL_LEN = 30, 120
local DEFAULT_TEMPLATES = {
    "Здравствуйте! Ваша жалоба принята, разбираемся.",
    "Передано на рассмотрение старшей администрации.",
    "Уточните, пожалуйста: ID нарушителя и что произошло.",
    "Нарушений не обнаружено.",
    "Игрок наказан, спасибо за обращение!",
    "С таким вопросом обратитесь на форум проекта.",
    "Приятной игры на нашем сервере!",
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
    if text == "" then return false, "Пустой шаблон." end
    if #templates >= TPL_MAX then return false, "Лимит шаблонов: " .. TPL_MAX end
    templates[#templates + 1] = text:sub(1, TPL_LEN)
    saveTemplates()
    return true, "Шаблон добавлен (всего " .. #templates .. ")."
end

local autoMp = { armed = false, t0 = 0 }
local function armAutoMp(force)
    if not force and not cfg.automp then return end
    autoMp.armed, autoMp.t0 = true, os.clock()
    safeSend("/mp")
end

local AD
local LD = { expect = nil, got = false, busy = false, status = "", all = {}, online = {}, rows = {}, raw = {}, rawMiss = {},
    norm = { ghetto = 120, mafia = 120, gov = 120 }, pageIdx = 14 }

function ev.onShowDialog(id, style, title, b1, b2, text)
    if AD and AD.expect then
        local okA, swA = pcall(AD.dialog, id, style, title, text)
        if okA and swA then return false end
    end
    if LD.expect and LD.capture then
        local okC, swallow = pcall(LD.capture, id, style, title, text)
        if okC and swallow then return false end
    end
    if not autoMp.armed then return end
    if os.clock() - autoMp.t0 > 6 then autoMp.armed = false return end
    if style ~= 2 and style ~= 4 and style ~= 5 then return end
    autoMp.armed = false
    lua_thread.create(function()
        wait(150)
        pcall(sampSendDialogResponse, id, 1, 0, "")
    end)
    return false
end

loadCfg()
loadTemplates()

local D_MENU, D_RLIST, D_RREPLY, D_GWSTART = 4120, 4121, 4122, 4123

local function replyTo(id, text)
    text = trim(text or "")
    if text == "" then return false end
    safeSend(string.format("/pm %s %s", id, text))
    return true
end

local AI = { busy = false, status = "", result = nil }

function AI.ready() return trim(cfg.aiKey or "") ~= "" and trim(cfg.aiUrl or "") ~= "" end

local function aiClean(text)
    text = tostring(text or ""):gsub("[\r\n]+", " "):gsub("%s+", " ")
    return trim(text)
end

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
            if st == "failed" or st == "canceled" then return nil, "запрос не выполнен" end
            if os.clock() - t0 > 40 then pcall(function() h:cancel() end) return nil, "таймаут ответа (40 с)" end
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
    return nil, "нет способа отправить запрос (нужны effil+requests, ssl.https или curl). Команда /aidiag покажет, что есть"
end

function AI.ask(system, user, cb)
    if AI.busy then cb(false, "предыдущий запрос ещё идёт") return end
    if not AI.ready() then cb(false, "не заполнены адрес API и ключ (/fh - Настройки или /aiset)") return end
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
            if url:match("/v1$") then url = url .. "/chat/completions" end
            local code, text = AI.http(url, trim(cfg.aiKey), body)
            if not code then return false, text end
            if code == 0 then return false, "нет связи: " .. tostring(text):sub(1, 80) end
            local okJ, data = pcall(dec, text)
            if not okJ or type(data) ~= "table" then return false, "ответ не JSON (код " .. tostring(code) .. ")" end
            if type(data.error) == "table" and data.error.message then return false, "API: " .. tostring(data.error.message):sub(1, 100) end
            local msg = data.choices and data.choices[1] and data.choices[1].message
            local content = msg and msg.content
            if type(content) ~= "string" or content == "" then return false, "пустой ответ (код " .. tostring(code) .. ")" end
            return true, aiClean(fromUi(content))
        end)
        AI.busy = false
        if not ok then a, b = false, tostring(a) end
        pcall(cb, a, b)
    end)
end

function AI.diag()
    local names = { "effil", "requests", "ssl.https", "ltn12", "socket", "copas", "cjson", "dkjson", "lib.requests" }
    local have, miss = {}, {}
    for _, n in ipairs(names) do
        if pcall(require, n) then have[#have + 1] = n else miss[#miss + 1] = n end
    end
    fmsg("Есть: " .. (#have > 0 and table.concat(have, ", ") or "ничего"))
    fmsg("Нет: " .. table.concat(miss, ", "))
    fmsg("encodeJson: " .. (encodeJson and "да" or "нет (мини-JSON)") .. ", io.popen: " .. (io.popen and "да" or "нет"))
end

function AI.suggest(r, cb)
    AI.status = "ИИ думает..."
    AI.ask(cfg.aiPrompt, "Репорт от игрока " .. r.name .. ": " .. r.text, function(ok, text)
        AI.status = ok and "Ответ готов, проверьте и отправьте." or ("Ошибка: " .. tostring(text))
        if ok then AI.result = { id = r.id, text = text } end
        cb(ok, text)
    end)
end

function AI.test()
    AI.status = "Проверяю связь..."
    AI.ask(cfg.aiPrompt, "Привет! Ответь одним коротким предложением.", function(ok, text)
        AI.status = ok and ("Работает: " .. text) or ("Ошибка: " .. tostring(text))
    end)
end

function AI.cmdAsk(p)
    local id = (p or ""):match("^(%d+)")
    local r
    for _, x in ipairs(reports) do
        if not id or x.id == id then r = x break end
    end
    if not r then fmsg("Репорт не найден. Список: /reports") return end
    fmsg("Спрашиваю ИИ про репорт от " .. r.name .. "...")
    AI.suggest(r, function(ok, text)
        fmsg("ИИ: " .. tostring(text))
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
        fmsg("/aiset url|key|model|prompt значение. Сейчас: ключ " .. (trim(cfg.aiKey) ~= "" and "задан" or "не задан") ..
            ", модель " .. cfg.aiModel .. ". Проверка: /ai ID")
        return
    end
    cfg[f] = v:gsub("[\r\n]+", " ")
    saveCfg()
    fmsg("ИИ: " .. k .. " сохранено.")
end

local function uiReports()
    if #reports == 0 then
        fmsg("Репортов пока нет.")
        return
    end
    local t = {}
    for i, r in ipairs(reports) do
        t[i] = string.format("{FFFF00}[%s] {FFFFFF}%s: {A9A9A9}%s", r.id, r.name, r.text)
    end
    uiShow(D_RLIST, "FH | Последние репорты", table.concat(t, "\n"), "Ответить", "Закрыть", 2)
end

local D_RTPL = 4147
local function findReport(id)
    for _, r in ipairs(reports) do if r.id == id then return r end end
end

local function uiTemplatesFor(r)
    local t = { "{33CC33}Написать свой ответ" }
    for _, x in ipairs(templates) do t[#t + 1] = "{FFFFFF}" .. x end
    uiShow(D_RTPL, "Ответ: " .. r.name .. "[" .. r.id .. "]", table.concat(t, "\n"), "Отправить", "Назад", 2)
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
        uiShow(D_RREPLY, "Ответ игроку " .. r.name .. "[" .. r.id .. "]",
            "Жалоба: " .. r.text .. "\n\nВведите ответ (уйдёт через /pm):", "Отправить", "Назад", 1)
    elseif templates[list] then
        replyTo(r.id, templates[list])
    end
end

uiHandlers[D_RREPLY] = function(button, _, input)
    if button == 1 and ui.replyId and replyTo(ui.replyId, input) then return end
    uiReports()
end

local gw = { active = false, last = false, word = "", prize = "", stat = nil, amount = nil, t0 = 0 }
local GW_TAG = "[Раздача]"
local GW_IGNORE_NAMES = { Admin = true, Utka_News = true }

local PRIZE_TYPES = {
    { 7,  "bank", "банк", "деньги", "money", "руб" },
    { 1,  "lvl", "лвл", "уровень", "level" },
    { 3,  "mat", "мат" },
    { 6,  "exp", "опыт" },
    { 2,  "закон" },
    { 5,  "sim", "сим", "номер" },
    { 12, "box", "бокс" },
    { 13, "kung", "кунг" },
    { 14, "kick", "кик" },
}

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
    local lines = { string.format("/aad %s Победитель - %s! Время: %d сек.", GW_TAG, name, sec) }
    if gw.stat then
        lines[#lines + 1] = string.format("/pm %s Поздравляю, вы первый! Приз сейчас будет выдан.", id)
        lines[#lines + 1] = string.format("/setstat %s %d %s", id, gw.stat, gw.amount)
        lines[#lines + 1] = string.format("/pm %s Приз выдан, приятной игры!", id)
    else
        fmsg(string.format("{FFFF00}Выдайте приз вручную: %s [%s] -> %s", name, id, gw.prize))
        lines[#lines + 1] = string.format("/pm %s Поздравляю, вы первый! Приз выдам в ближайшее время.", id)
    end
    if isLast then lines[#lines + 1] = "/aad " .. GW_TAG .. " Раздача завершена, спасибо всем за участие!" end
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
        fmsg("Использование: /" .. (isLast and "gwlast" or "gw") .. " слово | приз   (например: /gw котик | банк 500000)")
        return
    end
    gw.word, gw.prize, gw.last = lower1251(word), prize, isLast
    gw.stat, gw.amount = parsePrize(prize)
    gw.t0 = os.clock()
    gw.active = true
    local head = isLast and "ФИНАЛ! " or ""
    sendSeq({
        string.format("/aad %s %sПриз: %s", GW_TAG, head, prize),
        string.format("/aad %s Кто первым отправит в /rep слово «%s» - тот победил!", GW_TAG, word),
    }, SEND_GAP)
    if gw.stat then
        fmsg(string.format("Раздача запущена. Слово: {FFFF00}%s{FFFFFF}. Приз выдастся сам (стата %d, кол-во %s).", word, gw.stat, gw.amount))
    else
        fmsg(string.format("Раздача запущена. Слово: {FFFF00}%s{FFFFFF}. Тип приза не распознан - выдавать придётся вручную.", word))
    end
end

uiHandlers[D_GWSTART] = function(button, _, input)
    if button == 1 then gwStart(input, false) end
end

local D_Z = 4148
local CLAIM_COUNT = 3

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
    uiShow(D_Z, "FH | Занять", table.concat(t, "\n"), "Занять", "Закрыть", 2)
end

uiHandlers[D_Z] = function(button, list)
    if button == 0 then return end
    local c = CLAIMS[list + 1]
    if c then claim(c[2]) end
end

local D_EV, D_FR, D_FRACT, D_NOTES, D_NOTE, D_NOTEADD = 4140, 4141, 4142, 4144, 4145, 4146
local D_EVPRIZE = 4149

local EVENTS = {
    { "svet", "Светофор", "Бежим к финишу на «Зелёный» и замираем на «Красный».", "Кто двинулся на красный - вылетает. Побеждает первый на финише." },
    { "poliv", "Поливалка", "Нужно удержаться на крыше, пока вас поливают из БТР.", "Оружие и толчки запрещены. Побеждает последний оставшийся." },
    { "derbi", "Дерби", "Садимся в машины и таранитесь на арене.", "Побеждает тот, чья машина осталась на ходу последней." },
    { "pryat", "Прятки", "Прячьтесь от ведущего где угодно на локации.", "По команде можно пользоваться масками и анимациями." },
    { "parkur", "Паркур", "Кто быстрее всех доберётся до вершины паркур-зоны?", "Без оружия, помех другим и багов." },
    { "rulet", "Русская рулетка", "Встаём в строй и по очереди пытаем удачу.", "Строй не нарушать, оружие и анимации не использовать." },
    { "kovsh", "Гонки от Ковша", "Игроки на квадроциклах уворачиваются от Гелика с ковшом.", "Баги, ремонт машин и сторонний софт запрещены. Выживает последний." },
    { "myaso", "Мясорубка", "Бегаем по локации и уходим от бензопилы ведущего.", "Без оружия, брони и масок. Побеждает последний выживший." },
    { "dogon", "Догонялки", "Ведущий гонится за игроками.", "Кого ударили кулаком - тот выбыл. Анимации и баги запрещены." },
    { "car", "Царь горы", "Заберитесь на вершину горы из объектов и держитесь.", "Только кулаки, без оружия и масок. Побеждает тот, кто остался наверху." },
    { "parash", "Прыжки с парашютом", "Все получают парашюты и приземляются на метку ведущего.", "Промазал или разбился - выбыл. Важна точность." },
    { "digl", "Король Дигла", "Каждому выдаётся Deagle.", "Нужно убрать всех соперников. Побеждает последний живой." },
    { "sultan", "Увернись от Султана", "Игроки в строю, ведущий едет на машине.", "Кого задели - тот выбыл. Нужно вовремя подпрыгнуть." },
    { "paint", "Пейнтбол", "Каждый сам за себя, считаются убийства.", "Побеждает тот, у кого в конце больше фрагментов." },
    { "krug", "Круг Смерти", "Игроки встают кругом, ведущий выдаёт Deagle с одним патроном.", "Задача - выстрелить в оппонента." },
    { "infern", "Догони Инфернус", "Найдите на карте ЧЁРНЫЙ INFERNUS ведущего и передайте ему 1 рубль: /pay {id} 1.", "Читы и помехи запрещены. Побеждает первый, кто передал." },
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
        if not id then fmsg("Нужен ID ведущего: /ev " .. e[1] .. " ID [приз]") return end
    end
    prize = trim(prize or "")
    local lines = {
        string.format("/aad [МП] Внимание, игроки! Скоро стартует мероприятие «%s».", e[2]),
    }
    for k = 3, #e do
        lines[#lines + 1] = "/aad [МП] " .. e[k]:gsub("{id}", id or "")
    end
    if prize ~= "" then lines[#lines + 1] = "/aad [МП] Приз победителю: " .. prize .. "." end
    lines[#lines + 1] = "/aad [МП] Участие свободное для всех. Ждите открытия телепорта."
    lines[#lines + 1] = "/aad [МП] Нарушители правил МП будут удалены без права на приз."
    sendSeq(lines, SEND_GAP, cfg.automp and function() armAutoMp() end or nil)
end

local function uiEvents()
    local t = {}
    for i, e in ipairs(EVENTS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(/ev %s)", e[2], e[1]) end
    uiShow(D_EV, "FH | Мероприятия", table.concat(t, "\n"), "Объявить", "Закрыть", 2)
end

uiHandlers[D_EV] = function(button, list)
    if button == 0 then return end
    local e = EVENTS[list + 1]
    if not e then return end
    ui.evPick = e
    uiShow(D_EVPRIZE, "FH | Приз для МП «" .. e[2] .. "»",
        "{FFFFFF}Введите приз (можно оставить пустым).\n" ..
        (e[1] == "infern" and "{FFCC00}Для этого МП: ID ведущего, затем приз. Пример: 55 5кк\n" or "{A9A9A9}Пример: 5кк"),
        "Объявить", "Назад", 1)
end

uiHandlers[D_EVPRIZE] = function(button, _, input)
    local e = ui.evPick
    ui.evPick = nil
    if button == 0 or not e then return uiEvents() end
    announceEvent(e, input or "")
end

local FRACTIONS = {
    { "rus", "Русская мафия", 14, "mafia" }, { "jap", "Японская мафия", 6, "mafia" }, { "ita", "Итальянская мафия", 5, "mafia" },
    { "fun", "Похоронное бюро", 23, "mafia" }, { "out", "Outlaws MC", 28, "mafia" },
    { "rif", "Rifa Gang", 18, "gang" }, { "bal", "Ballas Gang", 12, "gang" }, { "azt", "Aztec Gang", 17, "gang" },
    { "gro", "Grove Street", 15, "gang" }, { "vag", "LS Vagos", 13, "gang" },
    { "arm", "Армия ЛС", 3, "gov" }, { "hos", "Больница ЛС", 4, "gov" }, { "mer", "Мэрия", 7, "gov" },
    { "rad", "Радиоцентр", 16, "gov" }, { "swt", "S.W.A.T", 25, "gov" }, { "gov", "Правительство", 26, "gov" },
    { "lsp", "LSPD", 1, "gov" }, { "fbi", "FBI", 2, "gov" }, { "rcp", "RCPD", 27, "gov" }, { "sud", "Верховный суд", 29, "gov" },
}
local RULES_BY_KIND = { mafia = "правил бизваров", gang = "правил каптов", gov = "общих правил лидеров" }

local function fractionByKey(key)
    key = lower1251(key or "")
    for _, f in ipairs(FRACTIONS) do if f[1] == key then return f end end
end

local function recruit(f)
    sendSeq({
        "/o [Набор] Внимание! Открыт набор в «" .. f[2] .. "».",
        "/o [Набор] Подайте заявку через /rep +.",
    }, 2500)
end

local function tryoutAad(f)
    sendSeq({
        "/aad [Отбор] Внимание! Проходит отбор на пост лидера: " .. f[2] .. ".",
        "/aad [Отбор] Требования: возраст 13+, связь ВК, знание " .. RULES_BY_KIND[f[4]] .. ".",
        "/aad [Отбор] Ждите открытия телепорта.",
    }, SEND_GAP, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tryoutO(f)
    sendSeq({
        "/o [Отбор] Идёт отбор на пост лидера: " .. f[2] .. ".",
        "/o [Отбор] Нужно: 13+, связь ВК, знание " .. RULES_BY_KIND[f[4]] .. ".",
        "/o [Отбор] Желающие - пишите /gomp.",
    }, 2500, function()
        if cfg.automp then armAutoMp() else sampSetChatInputText("/mp ") sampSetChatInputEnabled(true) end
    end)
end

local function tempLeader(f) safeSend("/templeader " .. f[3]) end

local function uiFractions()
    local t = {}
    for i, f in ipairs(FRACTIONS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(%s)", f[2], f[1]) end
    uiShow(D_FR, "FH | Фракции", table.concat(t, "\n"), "Выбрать", "Закрыть", 2)
end

uiHandlers[D_FR] = function(button, list)
    if button == 0 then return end
    local f = FRACTIONS[list + 1]
    if not f then return uiFractions() end
    ui.fr = list + 1
    uiShow(D_FRACT, f[2],
        "Набор (в общий чат /o)\nОтбор на лидера (/aad)\nОтбор на лидера (общий чат /o)\nВзять временную лидерку себе\nНазад",
        "Выбрать", "Закрыть", 2)
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

local notes = {}
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
    if not ok then fmsg("Не удалось сохранить заметки в файл!") end
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
    if title == "" or #title > 40 then return false, "Название: до 40 символов." end
    local n = findNote(title)
    if not n then
        if #notes >= NOTE_MAX then return false, "Лимит заметок: " .. NOTE_MAX end
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
        return false, "Пустой текст, ничего не добавлено."
    end
    saveNotes()
    return true, string.format("Заметка «%s»: добавлено строк %d (всего %d).", n.title, added, #n.lines)
end

local function uiNotes()
    local t = { "{33CC33}[+] Новая заметка" }
    for _, n in ipairs(notes) do t[#t + 1] = string.format("{FFFFFF}%s {A9A9A9}- строк: %d", n.title, #n.lines) end
    uiShow(D_NOTES, "FH | Шпаргалки", table.concat(t, "\n"), "Открыть", "Закрыть", 2)
end

uiHandlers[D_NOTES] = function(button, list)
    if button == 0 then return end
    if list == 0 then
        uiShow(D_NOTEADD, "Новая заметка",
            "Формат: название | текст\nНесколько строк разделяйте {FFFF00};;\n{A9A9A9}Пример: Нормы | Будни - 1 час ;; Выходные - 1.5 часа",
            "Сохранить", "Назад", 1)
    else
        local n = notes[list]
        if not n then return uiNotes() end
        ui.note = list
        uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "Назад", "Удалить", 0)
    end
end

uiHandlers[D_NOTEADD] = function(button, _, input)
    if button == 0 then return uiNotes() end
    local title, text = input:match("^(.-)%s*|%s*(.+)$")
    if not title then fmsg("Формат: название | текст") return uiNotes() end
    local _, msg = noteAdd(title, text)
    fmsg(msg)
    uiNotes()
end

uiHandlers[D_NOTE] = function(button)
    if button == 0 and ui.note and notes[ui.note] then
        fmsg("Заметка «" .. notes[ui.note].title .. "» удалена.")
        table.remove(notes, ui.note)
        saveNotes()
    end
    uiNotes()
end

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
            if not id then fmsg("Укажите ID: /" .. short .. " ID") return end
            if mode == "idin" then
                sampSetChatInputText(string.format("/%s %s ", full, id)) sampSetChatInputEnabled(true)
            else safeSend(string.format("/%s %s", full, id)) end
            return
        end
        if p == "" then fmsg("Укажите параметры: /" .. short .. " ...") return end
        safeSend("/" .. full .. " " .. p)
    end)
end

local function cmdAr(id)
    if not id then fmsg("Использование: /ar ID") return end
    local text
    local name = "ID " .. id
    for _, r in ipairs(reports) do
        if r.id == id then text = r.text name = r.name .. "[" .. id .. "]" break end
    end
    sendSeq({
        string.format("/pm %s Здравствуйте, ваша жалоба принята, передаю её администрации.", id),
        "/a Коллеги, отвечаем на репорт!",
        string.format("/a %s | Жалоба: %s", name, text or "текст не найден, смотрите /report"),
    }, SEND_GAP)
end

local D_RULES = 4150

local D_CHK, D_CHKRES = 4151, 4152
local ROLES = {
    { "io", "ИО", "И.О. Основателя" }, { "zo", "ЗО", "Заместитель Основателя" }, { "po", "ПО", "Помощник Основателя" },
    { "ks", "КС", "Куратор сервера" }, { "zks", "ЗКС", "Заместитель Куратора сервера" },
    { "ga", "ГА", "Главный администратор" }, { "zga", "ЗГА", "Заместитель Главного администратора" },
    { "gsg", "ГС госс", "Главный следящий за госс. структурами" }, { "gsgh", "ГС гетто", "Главный следящий за гетто" },
    { "gsm", "ГС мафии", "Главный следящий за мафиями" },
    { "zgsg", "ЗГС госс", "Заместитель Главного следящего за госс. структурами" },
    { "zgsgh", "ЗГС гетто", "Заместитель Главного следящего за гетто" },
    { "zgsm", "ЗГС мафии", "Заместитель Главного следящего за мафиями" },
    { "pgsg", "ПГС госс", "Помощник Главного следящего за госс. структурами" },
    { "pgsgh", "ПГС гетто", "Помощник Главного следящего за гетто" },
    { "pgsm", "ПГС мафии", "Помощник Главного следящего за мафиями" },
}

local CHK_PRESETS = {
    { "Руководство", { "io", "zo", "po", "ks", "zks" } },
    { "Следящие", { "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
    { "ГА и ЗГА", { "ga", "zga" } },
    { "Главные следящие", { "gsg", "gsgh", "gsm" } },
    { "ЗГС", { "zgsg", "zgsgh", "zgsm" } },
    { "ПГС", { "pgsg", "pgsgh", "pgsm" } },
    { "Все", { "io", "zo", "po", "ks", "zks", "ga", "zga", "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
}

local CHK = { active = false, list = {}, seen = {}, word = "1", t0 = 0, total = 0, secs = 0, thread = nil, token = 0 }

local function chkNames(keys)
    local out = {}
    for _, k in ipairs(keys) do
        for _, r in ipairs(ROLES) do if r[1] == k then out[#out + 1] = r[3] end end
    end
    return out
end

local function chkLines(sel, word, secs)
    word = trim(word or "")
    if word == "" then word = "1" end
    secs = tonumber(secs) or 0
    local answer = (word == "1") and "цифру 1" or ("слово «" .. word .. "»")
    local tail = secs > 0 and (" Время: " .. math.floor(secs) .. " сек.") or ""
    local lines = { "/a Проверка активности администрации!" }
    if sel and #sel > 0 then

        local function clen(x)
            if #"я" == 2 then return #x - select(2, x:gsub("[\128-\191]", "")) end
            return #x
        end
        local cur, first = {}, true
        local function flush(last)
            if #cur == 0 then return end
            lines[#lines + 1] = "/a " .. (first and "Отзываются: " or "") .. table.concat(cur, ", ") .. (last and "." or ",")
            first, cur = false, {}
        end
        local used = 0
        for _, name in ipairs(sel) do
            if #cur > 0 and used + 2 + clen(name) > 95 then flush(false) used = 0 end
            used = used + (#cur > 0 and 2 or 0) + clen(name)
            cur[#cur + 1] = name
        end
        flush(true)
        lines[#lines + 1] = "/a Поставьте свой тег и напишите в /a " .. answer .. "." .. tail
    else
        lines[#lines + 1] = "/a Главные и заместители главных следящих - поставьте свой тег."
        lines[#lines + 1] = "/a Подтвердите присутствие: напишите в /a " .. answer .. "." .. tail
    end
    return lines, word, secs
end

local function chkResultText()
    local t = { string.format("{FFFFFF}Отметились: {33CC33}%d", #CHK.list) }
    t[#t + 1] = "{A9A9A9}Ответ: " .. CHK.word .. (CHK.active and "   (проверка идёт)" or "   (проверка закончена)")
    t[#t + 1] = ""
    if #CHK.list == 0 then t[#t + 1] = "{A9A9A9}Пока никто не ответил." end
    for i, e in ipairs(CHK.list) do
        t[#t + 1] = string.format("{FFFFFF}%d. %s{A9A9A9}%s  - через %d сек.", i, e.name, e.id and ("[" .. e.id .. "]") or "", e.sec)
    end
    return table.concat(t, "\n")
end

local function chkShow()
    uiShow(D_CHKRES, "FH | Итог проверки активности", chkResultText(), "Закрыть", "", 0)
end
uiHandlers[D_CHKRES] = function() end

local function chkEnd(announce)
    if not CHK.active then fmsg("Проверка не запущена.") return end
    CHK.active = false
    CHK.token = CHK.token + 1
    if CHK.thread then pcall(function() CHK.thread:terminate() end) CHK.thread = nil end
    fmsg(string.format("Проверка закончена. Отметились: %d (список: /chkres).", #CHK.list))
    if announce then safeSend(string.format("/a Проверка активности завершена. Отметились: %d.", #CHK.list)) end
end

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
        fmsg("Не знаю: " .. table.concat(bad, ", ") .. ". Ключи: " .. table.concat(keys, " ") .. " | t=60 w=слово")
        return
    end
    sayA1(sel, opts)
end

local function uiChk()
    local t = { "{33CC33}Общая проверка (без должностей)" }
    for _, p in ipairs(CHK_PRESETS) do t[#t + 1] = "{66CCFF}Набор: {FFFFFF}" .. p[1] end
    for _, r in ipairs(ROLES) do t[#t + 1] = "{FFFFFF}" .. r[2] end
    uiShow(D_CHK, "FH | Проверка активности", table.concat(t, "\n"), "Проверить", "Закрыть", 2)
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
        "Норма онлайна лидера: в будни 1 час, в выходные 1 час 30 минут.",
        "Не отыграли норму - получаете выговор.",
        "3/3 выговоров - снятие с поста лидера и ЧСЛ.",
        "Час пик в будни: с 17:00 до 20:00.",
        "Час пик в выходные: с 16:00 до 19:00.",
        "Отсутствие в час пик тоже карается выговором.",
        "Вопросы - к следящим вашей структуры.",
    }, 3500)
end

local function sayInfo()
    sendSeq({
        "/aad [INFO] Уважаемые игроки, администрация всегда на связи!",
        "/aad [INFO] Нашли баг или нарушение - пишите в /rep.",
        "/aad [INFO] Формулируйте вопрос или жалобу коротко и понятно.",
        "/aad [INFO] За флуд, оффтоп и оскорбления в репорте выдаётся наказание.",
        "/aad [INFO] Приятной игры!",
    }, SEND_GAP)
end

local function sayTimeInfo()
    sendSeq({
        "/aad [INFO] Игроки, напоминаем об акции за онлайн!",
        "/aad [INFO] Отыграйте час на сервере и получите приз.",
        "/aad [INFO] Награду можно получать до 5 раз в день.",
        "/aad [INFO] Проверить время и забрать приз: /rep time",
        "/aad [INFO] С уважением, администрация проекта.",
    }, SEND_GAP)
end

local function sayGwIntro(prize)
    prize = trim(prize or "")
    local lines = {
        "/aad [Раздача] Внимание, игроки! Сейчас пройдёт быстрая раздача призов.",
        "/aad [Раздача] Приготовьтесь писать кодовое слово в чат!",
    }
    if prize ~= "" then lines[#lines + 1] = "/aad [Раздача] Приз: " .. prize .. "." end
    sendSeq(lines, SEND_GAP)
end

local RULES_TEXT = {
    capt = {
        "FH | Правила каптов",
        "{66CCFF}Разрешено\n" ..
        "{FFFFFF}- слайды, полуслайды, +C, сбив переката\n" ..
        "- крыши, на которые попадают в 2 прыжка или по лестнице\n" ..
        "- слив вне квадрата после 5 минут капта\n" ..
        "- капт куском или обрезом, машины для баррикад\n\n" ..
        "{FF6666}Нельзя (1/3, спавн, джейл или варн)\n" ..
        "{FFFFFF}- убийство или запрет входа в квадрат до 5 минут\n" ..
        "- крыши выше 2 прыжков\n" ..
        "- заходить в интерьер в бою, СК в интерьере банды\n" ..
        "- обстрел респавна соперника\n" ..
        "- маска, броня, аптечки, наркотики в бою\n" ..
        "- чужой скин, если клист банды не совпадает со скином фракции\n\n" ..
        "{FF6666}Тяжёлые нарушения\n" ..
        "{FFFFFF}- ДНК, джетпак, дом на колёсах в квадрате: 1/3\n" ..
        "- антифраг (суицид, релог, подстав под госников): 1/3\n" ..
        "- отказ дать опру следящим или скрытие читов: варн и минус квадрат\n" ..
        "- багоюз Double Kill, стрельба по колёсам: 2/3\n" ..
        "- провокация на слив или СК у респавна: джейл 10 минут\n\n" ..
        "{FFCC00}Лидерам банд\n" ..
        "{FFFFFF}- в капте 1-3 ранги фракции или помеха третьей банды: 1/3 лидеру\n" ..
        "- капт респы любой банды: выговор, отмена капта, минус 3 квадрата\n" ..
        "- игнор капта или неприезд состава на забив: 1/3 лидеру",
    },
    biz = {
        "FH | Правила бизваров",
        "{66CCFF}Общее\n" ..
        "{FFFFFF}- забивать стрелу могут только лидер или заместитель, за 30+ минут через ВК\n" ..
        "- время стрел: с 12:00 до 22:00 по Москве, минимум 2 на 2\n" ..
        "- длительность 10 минут, нужна опра от лидера и зама, если нет следящих\n" ..
        "- 3/3 у мафии: фракция теряет 1 бизнес\n\n" ..
        "{FF6666}Нельзя (1/3)\n" ..
        "{FFFFFF}- крыши и горы, стрельба по машине при въезде врага\n" ..
        "- тянуть время вне квадрата, кататься в квадрате на машине дольше 10 секунд (1/3 и спавн)\n" ..
        "- чужой скин, помощь посторонних (мафии сразу 3/3)\n" ..
        "- АФК больше 30 секунд, вертолёт или личный транспорт, не впускать врага в квадрат\n" ..
        "- выход из квадрата, маска, броня, оружие кроме Desert Eagle, M4, Shotgun, Rifle\n" ..
        "- SK, DB, TK, слив или стрельба вне квадрата, игнор стрелы и следящих\n" ..
        "- антифраг: прыжок с моста или горы, суицид\n\n" ..
        "{FF6666}Тяжёлые нарушения\n" ..
        "{FFFFFF}- баги, сбив анимаций в бою: 2/3\n" ..
        "- стрельба с пассажирского сиденья: 1/3 и джейл 10 минут\n" ..
        "- стрела вне 12:00-22:00: остановка стрелы и выговор лидеру",
    },
}

local function showRules(kind)
    local r = RULES_TEXT[kind]
    if r then uiShow(D_RULES, r[1], r[2], "Закрыть", "", 0) end
end
uiHandlers[D_RULES] = function() end

local VOPROS = {
    { "Что такое ЧП?", "ЧП - час пик, обязательное время онлайна лидеров." },
    { "Какая норма онлайна у лидера в будни?", "В будни норма - 1 час." },
    { "Какая норма онлайна у лидера в выходные?", "В выходные норма - 1 час 30 минут." },
    { "Что обязан делать лидер фракции?", "Следить за фракцией, форумом и составом." },
    { "Что такое блат?", "Блат - выдача высокой должности без отчётов и обзвона." },
    { "Со скольки до скольки ЧП в будни?", "В будни ЧП с 17:00 до 20:00." },
    { "Со скольки до скольки ЧП в выходные?", "В выходные ЧП с 16:00 до 19:00." },
}

local function askVopros(p)
    local n = tonumber((p or ""):match("^%d+"))
    local v = n and VOPROS[n]
    if not v then fmsg("Использование: /vopros 1-" .. #VOPROS .. " (вопрос лидеру в чат, ответ покажу вам).") return end
    safeSend(v[1])
    fmsg("Ответ: " .. v[2])
end

local INFO = {
    a1 = sayA1, a1args = sayA1Args, chk = uiChk, chkres = chkShow, chkend = function() chkEnd(true) end, chkfin = function() chkEnd(false) end, rules = sayRules, inf = sayInfo, time = sayTimeInfo, intro = sayGwIntro,
    capt = function() showRules("capt") end, biz = function() showRules("biz") end, q = askVopros,
}
local vrThread

local function dvTimer(spawn)
    if vrThread then fmsg("Таймер уже идёт (остановить: /vrstop).") return end
    vrThread = lua_thread.create(function()
        pcall(function()
            safeSend("/a Через 15 секунд админ-транспорт будет удалён" .. (spawn and " и весь транспорт сервера возвращён на места!" or "!"))
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
        if e then announceEvent(e, arg) elseif key then fmsg("Нет такого МП: " .. key .. ". Список: /ev") else uiEvents() end
    end)
    local function byKey(cmd, fn)
        reg(cmd, function(p)
            local f = fractionByKey(trim(p))
            if f then fn(f) else fmsg("Укажите фракцию: /" .. cmd .. " ключ (список ключей: /fr)") end
        end)
    end
    byKey("nab", recruit) byKey("otb", tryoutAad) byKey("otbo", tryoutO) byKey("tlead", tempLeader)
    reg("fr", uiFractions)

    reg("note", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local title, text = rest:match("^(.-)%s*|%s*(.+)$")
            if not title then fmsg("Использование: /note add название | текст") return end
            local _, msg = noteAdd(title, text) fmsg(msg)
        elseif sub == "del" then
            local n, i = findNote(rest)
            if not n then fmsg("Заметка не найдена.") return end
            table.remove(notes, i) saveNotes() fmsg("Заметка удалена.")
        elseif sub == "show" then
            local n = findNote(rest)
            if not n then fmsg("Заметка не найдена.") return end
            uiShow(D_NOTE, n.title, table.concat(n.lines, "\n"), "Назад", "Закрыть", 0)
        else uiNotes() end
    end)
    reg("notes", uiNotes)

    for _, a in ipairs(ALIASES) do regAlias(reg, a) end

    reg("poll", function(p)
        local who = trim(p)
        if who == "" then fmsg("Использование: /poll должность и ник (например: /poll ГА Ivan_Ivanov)") return end
        sendSeq({
            "/aad [Опрос] Игроки, уделите минуту!",
            "/aad [Опрос] Оцените работу: " .. who .. ". Отправьте в /rep цифру от 1 до 5.",
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
        claim(p)
    end)
    reg("vr", function() dvTimer(true) end)
    reg("dva", function() dvTimer(false) end)
    reg("dvs", function() dvTimer(true) end)
    reg("ai", function(p) AI.cmdAsk(p) end)
    reg("aiset", function(p) AI.cmdSet(p) end)
    reg("aidiag", function() AI.diag() end)
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
            fmsg("Таймер респавна остановлен.")
        else fmsg("Таймер не запущен.") end
    end)

    reg("tpl", function(p)
        local sub, rest = p:match("^(%S+)%s*(.*)$")
        if sub == "add" then
            local _, msg = tplAdd(rest) fmsg(msg)
        elseif sub == "del" then
            local n = tonumber(rest)
            if n and templates[n] then table.remove(templates, n) saveTemplates() fmsg("Шаблон удалён.")
            else fmsg("Использование: /tpl del N") end
        else
            fmsg("Шаблоны ответов (отправить: /rt [ID] N; добавить: /tpl add текст; удалить: /tpl del N):")
            for i, t in ipairs(templates) do sampAddChatMessage(string.format("{FFFF00}%d. {FFFFFF}%s", i, t), -1) end
        end
    end)
    reg("rt", function(p)
        local id, n = p:match("^(%d+)%s+(%d+)$")
        if not id then n = p:match("^(%d+)$") id = watchedId end
        n = tonumber(n)
        if not id or not n or not templates[n] then fmsg("Использование: /rt [ID] номер_шаблона (список: /tpl)") return end
        replyTo(id, templates[n])
    end)
    reg("mpa", function() armAutoMp(true) end)
    reg("fhset", function(p)
        local k, v = p:match("^(%S+)%s+(%S+)$")
        if k == "automp" and (v == "on" or v == "off") then
            cfg.automp = (v == "on") saveCfg()
            fmsg("Авто-/mp после анонса МП: " .. (cfg.automp and "включено" or "выключено"))
        else fmsg("Использование: /fhset automp on|off (сейчас: " .. (cfg.automp and "on" or "off") .. ")") end
    end)
    loadNotes()
end

local D_CMDS, D_CMDPAGE = 4130, 4131
local CMD_PAGES = {
    { "Раздачи",
      "{66CCFF}/gw слово | приз {FFFFFF}- запустить раздачу\n" ..
      "{66CCFF}/gwlast слово | приз {FFFFFF}- финальный раунд, сам закроет раздачу\n" ..
      "{66CCFF}/gwstop {FFFFFF}- отменить раздачу\n\n" ..
      "{A9A9A9}Приз: тип и число. Примеры: {FFFF00}банк 500000{A9A9A9}, {FFFF00}лвл 3{A9A9A9}, {FFFF00}#9 15{A9A9A9} (номер статы).\n" ..
      "Типы: банк, лвл, мат, опыт, закон, сим, бокс, кунг, кик." },
    { "Репорты",
      "{66CCFF}/reports {FFFFFF}- последние 15 репортов, выбрали - ответили\n" ..
      "{66CCFF}/rr [ID] текст {FFFFFF}- ответ игроку через /pm\n\n" ..
      "{A9A9A9}Если ID не указан, берётся игрок из последней команды /re." },
    { "Биндер",
      "{66CCFF}/fbind {FFFFFF}- окно биндера\n" ..
      "{66CCFF}/bnd add имя текст {FFFFFF}- создать бинд / добавить строку (несколько через ;;)\n" ..
      "{66CCFF}/bnd rm имя N {FFFFFF}- удалить строку\n" ..
      "{66CCFF}/bnd del имя {FFFFFF}- удалить бинд\n" ..
      "{66CCFF}/bnd delay имя мс {FFFFFF}- пауза между строками\n" ..
      "{66CCFF}/bnd show имя, /bnd list {FFFFFF}- просмотр\n\n" ..
      "{A9A9A9}В тексте: {FFFF00}{id}{A9A9A9} - ID игрока, {FFFF00}{arg}{A9A9A9} - текст после команды.\n" ..
      "Строка с / уходит как команда, остальное - в обычный чат." },
    { "Мероприятия",
      "{66CCFF}/ev {FFFFFF}- список МП, выбрали - объявление ушло в /aad\n" ..
      "{66CCFF}/ev ключ {FFFFFF}- сразу объявить (например /ev svet). Для «infern»: /ev infern ID. Приз: /ev svet 5кк или /ev infern ID 5кк\n\n" ..
      "{A9A9A9}Ключи: svet poliv derbi pryat parkur rulet kovsh myaso dogon car parash digl sultan paint krug infern" },
    { "Фракции",
      "{66CCFF}/fr {FFFFFF}- окно фракций: набор, отбор, временная лидерка\n" ..
      "{66CCFF}/nab ключ {FFFFFF}- набор в /o\n" ..
      "{66CCFF}/otb ключ {FFFFFF}- отбор на лидера в /aad (потом откроется ввод /mp)\n" ..
      "{66CCFF}/otbo ключ {FFFFFF}- отбор на лидера в /o\n" ..
      "{66CCFF}/tlead ключ {FFFFFF}- взять временную лидерку (/templeader)\n\n" ..
      "{A9A9A9}Ключи: rus jap ita fun out rif bal azt gro vag arm hos mer rad swt gov lsp fbi rcp sud" },
    { "Наказания",
      "{FFFFFF}Вставляют команду с ID в строку ввода: {66CCFF}/jj /mut /ww {A9A9A9}(jail, mute, warn)\n" ..
      "{FFFFFF}С параметрами: {66CCFF}/bb /uw /uj /unm /ub /ib /ip /bip /ofl /mkl /gzc /bp\n" ..
      "{FFFFFF}По ID или из /re: {66CCFF}/gs /inv {A9A9A9}(getstats, checkinv)\n" ..
      "{FFFFFF}Без параметров: {66CCFF}/fuel /gh /wh\n\n" ..
      "{A9A9A9}Расшифровка: bb-ban, uw-unwarn, uj-unjail, unm-unmute, ub-unban, ib-iban, ip-pgetip,\nbip-banip, ofl-offleader, mkl-makeleader, gzc-gzcolor, bp-setbizprod, wh-warehouse." },
    { "Прочее",
      "{66CCFF}/ar ID {FFFFFF}- ответ на репорт: /pm игроку + текст жалобы в /a\n" ..
      "{66CCFF}/poll должность ник {FFFFFF}- опрос игроков об оценке работы админа\n" ..
      "{66CCFF}/vr {FFFFFF}- через 15 сек удалить и вернуть весь транспорт, {66CCFF}/vrstop {FFFFFF}- отмена\n" ..
      "{66CCFF}/notes {FFFFFF}- шпаргалки; {66CCFF}/note add название | текст{FFFFFF}, {66CCFF}/note del название" },
    { "Общее",
      "{66CCFF}/fh {FFFFFF}- главное меню\n" ..
      "{66CCFF}/fcmd {FFFFFF}- это окно со списком команд\n" ..
      "{66CCFF}/binder {FFFFFF}- справка по биндеру\n\n" ..
      "{A9A9A9}Свои сокращения создавайте в биндере, например:\n{FFFF00}/bnd add jl /jail {id} {arg}" },
}

local function uiCommands()
    local t = {}
    for i, p in ipairs(CMD_PAGES) do t[i] = "{FFFFFF}" .. p[1] end
    uiShow(D_CMDS, "FH | Команды", table.concat(t, "\n"), "Открыть", "Закрыть", 2)
end

uiHandlers[D_CMDS] = function(button, list)
    if button == 0 then return end
    local p = CMD_PAGES[list + 1]
    if not p then return uiCommands() end
    uiShow(D_CMDPAGE, "FH | " .. p[1], p[2], "Назад", "Закрыть", 0)
end

uiHandlers[D_CMDPAGE] = function(button)
    if button == 1 then uiCommands() end
end

local function carsDo(kind)
    if kind == "spawn" then safeSend("/spawncars")
    elseif kind == "dv" then dvTimer(false)
    elseif kind == "fuel" then safeSend("/fuelcars")
    elseif kind == "dvs" then dvTimer(true)
    end
end

local function infoDo(kind, arg) local f = INFO[kind] if f then f(arg) end end

local MENU_ROWS = {
    { "#", "Раздачи" },
    { "/gw слово | приз", "запустить раздачу (банк 500000, лвл 3, #9 15)" },
    { "/gwlast слово | приз", "финальный раунд, сам закроет раздачу" },
    { "/gwstop", "отменить раздачу" },
    { "#", "Репорты" },
    { "/reports", "последние 15 репортов, быстрый ответ" },
    { "/rr [ID] текст", "ответить игроку через /pm" },
    { "/ai [ID]  /aiset  /aidiag", "ИИ-подсказка ответа на репорт; настройка API (/aiset url|key|model|prompt); /aidiag - что доступно для запросов" },
    { "/ar ID", "ответ + текст жалобы в /a" },
    { "/tpl  /rt [ID] N", "шаблоны ответов: список, отправка" },
    { "#", "Мероприятия и опросы" },
    { "/ev [ключ] [ID] [приз]", "анонс МП в /aad с призом (список: /ev)" },
    { "/poll должность ник", "опрос об оценке работы админа" },
    { "#", "Фракции" },
    { "/fr", "окно: набор, отбор, лидерка" },
    { "/nab /otb /otbo /tlead ключ", "набор /o, отбор /aad, отбор /o, лидерка" },
    { "#", "Объявления и памятки" },
    { "/a1  /chk [ио зо gsg t=60 w=слово]", "проверка активности по должностям, таймер и слово ответа" },
    { "/chkres  /chkend", "кто отметился; закончить и объявить итог в /a" },
    { "/pravila", "нормы онлайна и час пик лидерам в чат" },
    { "/inf  /timeinfo", "инфо для игроков и акция за онлайн в /aad" },
    { "/razdintro [приз]", "вступление перед раздачей в /aad" },
    { "/captlist  /bizwarlist", "памятки по правилам каптов и бизваров" },
    { "/vopros 1-7", "вопрос лидеру в чат, ответ покажет вам" },
    { "#", "Наказания" },
    { "/jj /mut /ww [ID]", "jail, mute, warn - вставят команду в ввод" },
    { "/bb /uw /uj /unm /ub", "ban, unwarn, unjail, unmute, unban" },
    { "/ib /ip /bip /ofl /mkl", "iban, pgetip, banip, offleader, makeleader" },
    { "/admnorm /admcheck [ник]", "норма админов: окно (нлист из ВК), проверка через /getoffstats" },
    { "/lds /ldrefresh /ldnorm [ghetto|mafia|gov|all]", "лидеры: окно, обновить из /aleaders и /leaders, норма в файл (list - простой список, иначе BBCode)" },
    { "/gs /inv [ID]", "getstats, checkinv (ID или из /re)" },
    { "/fuel /fc /gh /wh /gzc /bp", "fuelcars, ghetto, warehouse, gzcolor, setbizprod" },
    { "/spc /dva /dvs", "spawncars; удаление админ-каров (таймер 15 с в /a); то же + spawncars" },
    { "/vr  /vrstop", "то же, что /dvs; отмена таймера" },
    { "#", "Прочее" },
    { "/z [ключ]", "занять задачу: 3 раза «z ...» в /a (список: /z)" },
    { "/vr  /vrstop", "респавн транспорта через 15 сек / отмена" },
    { "/mpa  /fhset automp on|off", "ввести /mp и нажать 1-ю строку / авто-режим" },
    { "/fbind  /bnd", "свой биндер: окно и команды (справка /binder)" },
    { "/notes", "шпаргалки (свои заметки)" },
}

local function uiMenu()
    local t = { "{A9A9A9}Команда\t{A9A9A9}Что делает" }
    for _, r in ipairs(MENU_ROWS) do
        if r[1] == "#" then t[#t + 1] = "{66CCFF}" .. r[2] .. "\t"
        else t[#t + 1] = "{FFFF00}" .. r[1] .. "\t{FFFFFF}" .. r[2] end
    end
    uiShow(D_MENU, "FH " .. VERSION .. " | Команды", table.concat(t, "\n"), "Закрыть", "", 5)
end

uiHandlers[D_MENU] = function() end

local postedActions = {}
local function post(fn) postedActions[#postedActions + 1] = fn end
local function runPosted()
    while #postedActions > 0 do
        local fn = table.remove(postedActions, 1)
        local ok, err = pcall(fn)
        if not ok then print("[FH] gui action error: " .. tostring(err)) end
    end
end

local guiState

local LD_GHETTO = {
    { key = "ballas", name = "Southside Ballas", color = "FF1493" },
    { key = "vagos", name = "LS Vagos", color = "FFD700" },
    { key = "grove", name = "Grove Street", color = "3FB950" },
    { key = "aztecas", name = "Varios Los Aztecas", color = "87CEEB" },
    { key = "rifa", name = "Rifa Gang", color = "4169E1" },
}
local LD_CATCOL = { mafia = "FF8C00", gov = "1E90FF" }
local LD_ORDER = { ghetto = 1, mafia = 2, gov = 3 }

local function ldCat(fr)
    local low = fr:lower()
    for _, g in ipairs(LD_GHETTO) do
        if low:find(g.key, 1, true) then return "ghetto" end
    end
    if fr:find("афия", 1, true) or low:find("yakuza", 1, true) then return "mafia" end
    return "gov"
end

local function ldHM(min)
    return string.format("%d:%02d", math.floor(min / 60), min % 60)
end

local function ldParse(text)
    local list = {}
    text = fromGame(tostring(text or "")):gsub("{%x%x%x%x%x%x}", ""):gsub("\r", "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("\t", " "))
        local fr, nick, rest = line:match("^Лидер%s+(.-):%s*([%w_%.%[%]]+)(.*)$")
        if not fr then
            fr, nick, rest = line:match("^(.-):%s*([%a][%w%.%[%]]*_[%w_%.%[%]]+)(.*)$")
        end
        if fr and nick and trim(fr) ~= "" then
            local h, m = (rest or ""):match("%[%s*(%d+)%D-(%d+)%D-%]")
            list[#list + 1] = { fr = trim(fr), nick = nick, min = h and (tonumber(h) * 60 + tonumber(m)) or nil }
        end
    end
    return list
end

local function ldDir()
    local dir = getWorkingDirectory() .. "/config"
    pcall(createDirectory, dir)
    return dir
end

function LD.capture(id, style, title, text)
    local list = ldParse(text)
    local body = fromGame(tostring(text or ""))
    if #list == 0 then
        local ttl = fromGame(tostring(title or ""))
        if not (ttl:find("идер", 1, true) or body:find("идер", 1, true)) then return false end
        LD.rawMiss[LD.expect] = body
    else
        LD.raw[LD.expect] = body
        if LD.expect == "all" then LD.all = list else LD.online = list end
    end
    LD.got = true
    lua_thread.create(function()
        wait(200)
        pcall(sampSendDialogResponse, id, 0, 0, "")
    end)
    return true
end

function LD.merge()
    local src = (#LD.all > 0) and LD.all or LD.online
    local on, seen, rows = {}, {}, {}
    for _, o in ipairs(LD.online) do on[o.nick:lower()] = o end
    for _, l in ipairs(src) do
        local o = on[l.nick:lower()]
        seen[l.nick:lower()] = true
        rows[#rows + 1] = { fr = l.fr, nick = l.nick, min = (o and o.min) or l.min or 0, online = o ~= nil, cat = ldCat(l.fr) }
    end
    for _, o in ipairs(LD.online) do
        if not seen[o.nick:lower()] then
            rows[#rows + 1] = { fr = o.fr, nick = o.nick, min = o.min or 0, online = true, cat = ldCat(o.fr) }
        end
    end
    table.sort(rows, function(a, b)
        if a.cat ~= b.cat then return LD_ORDER[a.cat] < LD_ORDER[b.cat] end
        if a.fr ~= b.fr then return a.fr < b.fr end
        return a.nick < b.nick
    end)
    LD.rows = rows
end

function LD.saveRaw()
    pcall(function()
        local f = assert(io.open(ldDir() .. "/FilippHelper_leaders_raw.txt", "wb"))
        for _, k in ipairs { "all", "online" } do
            f:write("=== ", k == "all" and "/aleaders" or "/leaders", " ===\r\n")
            f:write(((LD.raw[k] or LD.rawMiss[k] or "(диалог не пришёл)"):gsub("\r?\n", "\r\n")), "\r\n")
        end
        f:close()
    end)
end

function LD.refresh()
    if LD.busy then return end
    LD.busy = true
    LD.status = "Запрашиваю /aleaders..."
    LD.raw, LD.rawMiss = {}, {}
    lua_thread.create(function()
        local ok, err = pcall(function()
            local function ask(cmd, kind)
                LD.expect, LD.got = kind, false
                safeSend(cmd)
                local t0 = os.clock()
                while not LD.got and os.clock() - t0 < 5 do wait(100) end
                LD.expect = nil
                return LD.got
            end
            ask("/aleaders", "all")
            LD.status = "Запрашиваю /leaders..."
            wait(1200)
            ask("/leaders", "online")
            LD.merge()
            LD.saveRaw()
        end)
        LD.busy, LD.expect = false, nil
        if not ok then
            print("[FH] leaders error: " .. tostring(err))
            LD.status = "Ошибка, смотрите moonloader.log"
            return
        end
        if #LD.rows == 0 then
            LD.status = "Лидеры не найдены (формат диалога не распознан)."
            fmsg("{FF6666}Не удалось разобрать диалоги. Сырой текст сохранён: {FFFFFF}moonloader/config/FilippHelper_leaders_raw.txt")
        else
            LD.status = string.format("Лидеров: %d (в сети: %d)", #LD.rows, #LD.online)
            fmsg("{66FF66}" .. LD.status .. ". {A9A9A9}Окно: {FFFF00}/lds")
        end
    end)
end

function LD.report(scope)
    local out = { "[CENTER][SIZE=4][B][COLOR=#FFD700]ОНЛАЙН СТРУКТУР НА " .. os.date("%d.%m") .. "[/COLOR][/B][/SIZE][/CENTER]", "" }
    local function block(name, color, items, cat)
        out[#out + 1] = string.format("[COLOR=#%s][B]%s:[/B][/COLOR]", color, name)
        if #items == 0 then
            out[#out + 1] = "[COLOR=#C9D1D9]Лидер: отсутствует[/COLOR]"
        else
            for _, r in ipairs(items) do
                out[#out + 1] = string.format("[COLOR=#C9D1D9]Лидер: %s | Онлайн: %s | %s[/COLOR]", r.nick, ldHM(r.min),
                    r.min >= LD.norm[cat] and "Выполнено" or "Не выполнено")
            end
        end
        out[#out + 1] = ""
    end
    if scope == "all" or scope == "ghetto" then
        for _, g in ipairs(LD_GHETTO) do
            local items = {}
            for _, r in ipairs(LD.rows) do
                if r.cat == "ghetto" and r.fr:lower():find(g.key, 1, true) then items[#items + 1] = r end
            end
            block(g.name, g.color, items, "ghetto")
        end
    end
    for _, cat in ipairs { "mafia", "gov" } do
        if scope == "all" or scope == cat then
            local order, by = {}, {}
            for _, r in ipairs(LD.rows) do
                if r.cat == cat then
                    if not by[r.fr] then by[r.fr] = {} order[#order + 1] = r.fr end
                    by[r.fr][#by[r.fr] + 1] = r
                end
            end
            for _, fr in ipairs(order) do block(fr, LD_CATCOL[cat], by[fr], cat) end
        end
    end
    while out[#out] == "" do out[#out] = nil end
    return table.concat(out, "\n")
end

function LD.plain(scope)
    local out = {}
    local function add(name, items)
        if #items == 0 then
            out[#out + 1] = name .. ": отсутствует"
        else
            for _, r in ipairs(items) do out[#out + 1] = string.format("%s: %s | %s", name, r.nick, ldHM(r.min)) end
        end
    end
    if scope == "all" or scope == "ghetto" then
        for _, g in ipairs(LD_GHETTO) do
            local items = {}
            for _, r in ipairs(LD.rows) do
                if r.cat == "ghetto" and r.fr:lower():find(g.key, 1, true) then items[#items + 1] = r end
            end
            add(g.name, items)
        end
    end
    for _, cat in ipairs { "mafia", "gov" } do
        if scope == "all" or scope == cat then
            local order, by = {}, {}
            for _, r in ipairs(LD.rows) do
                if r.cat == cat then
                    if not by[r.fr] then by[r.fr] = {} order[#order + 1] = r.fr end
                    by[r.fr][#by[r.fr] + 1] = r
                end
            end
            for _, fr in ipairs(order) do add(fr, by[fr]) end
        end
    end
    return table.concat(out, "\n")
end

function LD.build(scope, fmt)
    if fmt == "list" then return LD.plain(scope) end
    return LD.report(scope)
end

function LD.press(kind, nick)
    if kind == "off" then return "/offleader " .. nick end
end

function LD.saveReport(text)
    local path = ldDir() .. "/FilippHelper_norm.txt"
    local ok = pcall(function()
        local f = assert(io.open(path, "wb"))
        f:write((text:gsub("\n", "\r\n")))
        f:close()
    end)
    return ok and path or nil
end

function LD.saveNorm()
    pcall(function()
        local f = assert(io.open(ldDir() .. "/FilippHelper_norm_cfg.txt", "wb"))
        f:write("ghetto=", LD.norm.ghetto, "\r\nmafia=", LD.norm.mafia, "\r\ngov=", LD.norm.gov, "\r\n")
        f:close()
    end)
end

function LD.loadNorm()
    local f = io.open(ldDir() .. "/FilippHelper_norm_cfg.txt", "rb")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%a+)=(%d+)")
        if k and LD.norm[k] then LD.norm[k] = math.min(1440, tonumber(v)) end
    end
    f:close()
end
pcall(LD.loadNorm)

function LD.cmdNorm(p)
    local scope, fmt = "all", "forum"
    for w in trim(p or ""):lower():gmatch("%S+") do
        if w == "list" then fmt = "list"
        elseif ({ ghetto = true, mafia = true, gov = true, all = true })[w] then scope = w end
    end
    if #LD.rows == 0 then fmsg("Список лидеров пуст. Сначала /ldrefresh.") return end
    local path = LD.saveReport(LD.build(scope, fmt))
    if path then fmsg("{66FF66}Норма сохранена в файл: {FFFFFF}" .. path)
    else fmsg("{FF6666}Не удалось сохранить файл нормы.") end
end

local IS_UTF8 = ("я"):byte(1) == 209
local function lowAny(s)
    s = tostring(s or ""):lower()
    if IS_UTF8 then return lower1251(s) end
    return (s:gsub("[\192-\223]", function(c) return string.char(c:byte() + 32) end))
end

AD = { list = {}, res = {}, expect = nil, cap = nil, busy = false, status = "", norm = 120, key = "онлайн", pageIdx = 15 }

function AD.parse(text)
    local out = {}
    text = tostring(text or ""):gsub("{%x%x%x%x%x%x}", ""):gsub("\r", "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("\t", " "))
        local nick, rest = line:match("^%d+%.%s*.-%s%-%s+([%a][%w%.%[%]]*_[%w_%.%[%]]+)(.*)$")
        if not nick then nick, rest = line:match("^.-%s%-%s+([%a][%w%.%[%]]*_[%w_%.%[%]]+)(.*)$") end
        if nick then
            rest = rest:gsub("^%s*|%s*", ""):gsub("^%s+I%s+", "")
            local role = rest:match("^(.-)%s*|") or rest
            role = role:match("^(.-)%s+I%s") or role
            role = trim(role:gsub("%s+%d+%.%d+.*$", ""))
            out[#out + 1] = { nick = nick, role = role }
        end
    end
    return out
end

function AD.save()
    pcall(function()
        local f = assert(io.open(ldDir() .. "/FilippHelper_admins.txt", "wb"))
        for _, a in ipairs(AD.list) do f:write(a.nick, "|", a.role, "\r\n") end
        f:close()
    end)
end

function AD.saveCfg()
    pcall(function()
        local f = assert(io.open(ldDir() .. "/FilippHelper_adm_cfg.txt", "wb"))
        f:write("norm=", AD.norm, "\r\nkey=", AD.key, "\r\n")
        f:close()
    end)
end

function AD.load()
    local f = io.open(ldDir() .. "/FilippHelper_admins.txt", "rb")
    if f then
        for line in f:lines() do
            local n, r = line:gsub("\r", ""):match("^([^|]+)|(.*)$")
            if n then AD.list[#AD.list + 1] = { nick = n, role = r } end
        end
        f:close()
    end
    f = io.open(ldDir() .. "/FilippHelper_adm_cfg.txt", "rb")
    if f then
        for line in f:lines() do
            line = line:gsub("\r", "")
            local k, v = line:match("^(%a+)=(.*)$")
            if k == "norm" and tonumber(v) then AD.norm = math.min(100000, tonumber(v)) end
            if k == "key" then AD.key = v end
        end
        f:close()
    end
end
pcall(AD.load)

function AD.add(text)
    local added, upd = 0, 0
    for _, p in ipairs(AD.parse(text)) do
        local found
        for _, a in ipairs(AD.list) do
            if a.nick:lower() == p.nick:lower() then found = a break end
        end
        if found then
            if p.role ~= "" and found.role ~= p.role then found.role = p.role upd = upd + 1 end
        else
            AD.list[#AD.list + 1] = p
            added = added + 1
        end
    end
    if added + upd > 0 then AD.save() end
    return added, upd
end

function AD.remove(nick)
    for i, a in ipairs(AD.list) do
        if a.nick == nick then table.remove(AD.list, i) break end
    end
    AD.res[nick:lower()] = nil
    AD.save()
end

function AD.dialog(id, style, title, text)
    local cap = AD.cap
    if not (AD.expect and cap) then return false end
    local body = fromGame(tostring(text or ""))
    local ttl = fromGame(tostring(title or ""))
    local nl = AD.expect:lower()
    if not (body:lower():find(nl, 1, true) or ttl:lower():find(nl, 1, true) or lowAny(ttl):find("стат", 1, true)) then return false end
    body = body:gsub("{%x%x%x%x%x%x}", ""):gsub("\r", "")
    for line in (body .. "\n"):gmatch("(.-)\n") do
        line = trim(line:gsub("\t", " "))
        if line ~= "" and #cap.lines < 80 then cap.lines[#cap.lines + 1] = line end
    end
    cap.dialog = true
    cap.last = os.clock()
    lua_thread.create(function()
        wait(200)
        pcall(sampSendDialogResponse, id, 0, 0, "")
    end)
    return true
end

function AD.chat(text)
    local cap = AD.cap
    if not (AD.expect and cap) then return end
    local clean = trim(text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", ""))
    if clean == "" or #cap.lines >= 80 then return end
    cap.lines[#cap.lines + 1] = clean
    cap.last = os.clock()
end

function AD.extract(lines)
    local key = lowAny(AD.key)
    if key == "" then return nil end
    for _, ln in ipairs(lines) do
        local s, e = lowAny(ln):find(key, 1, true)
        if s then
            local tail = ln:sub(e + 1)
            local h, m = tail:match("(%d+)%s*ч%D-(%d+)%s*м")
            if not h then h, m = tail:match("(%d+):(%d+)") end
            if h then return tonumber(h) * 60 + tonumber(m), ln end
            local n = tail:match("(%d+)")
            if n then return tonumber(n), ln end
        end
    end
    return nil
end

function AD.recalc()
    for _, a in ipairs(AD.list) do
        local r = AD.res[a.nick:lower()]
        if r then r.value, r.line = AD.extract(r.lines) end
    end
end

function AD.saveRaw()
    pcall(function()
        local f = assert(io.open(ldDir() .. "/FilippHelper_getoffstats_raw.txt", "wb"))
        for _, a in ipairs(AD.list) do
            local r = AD.res[a.nick:lower()]
            if r then
                f:write("=== ", a.nick, " ===\r\n")
                if #r.lines == 0 then f:write("(ответа не было)\r\n") end
                for _, ln in ipairs(r.lines) do f:write(ln, "\r\n") end
            end
        end
        f:close()
    end)
end

function AD.run(nicks)
    if AD.busy then return end
    if #nicks == 0 then AD.status = "Список админов пуст." return end
    local queue = {}
    for i, a in ipairs(nicks) do queue[i] = a end
    AD.busy = true
    lua_thread.create(function()
        local ok, err = pcall(function()
            for i, a in ipairs(queue) do
                AD.status = string.format("Проверка %d/%d: %s", i, #queue, a.nick)
                local cap = { lines = {}, last = nil, dialog = false }
                AD.cap, AD.expect = cap, a.nick
                safeSend("/getoffstats " .. a.nick)
                local t0 = os.clock()
                while os.clock() - t0 < 5 do
                    wait(100)
                    if cap.last and os.clock() - cap.last > (cap.dialog and 0.4 or 1.2) then break end
                end
                AD.expect, AD.cap = nil, nil
                local v, line = AD.extract(cap.lines)
                AD.res[a.nick:lower()] = { lines = cap.lines, value = v, line = line }
                if i < #queue then wait(SEND_GAP) end
            end
        end)
        AD.busy, AD.expect, AD.cap = false, nil, nil
        if not ok then
            print("[FH] AD.run error: " .. tostring(err))
            AD.status = "Ошибка, смотрите moonloader.log"
        else
            local got = 0
            for _, a in ipairs(queue) do
                local r = AD.res[a.nick:lower()]
                if r and r.value then got = got + 1 end
            end
            AD.status = string.format("Проверено: %d, норма найдена у %d", #queue, got)
            pcall(AD.saveRaw)
            fmsg("{66FF66}" .. AD.status .. ". {A9A9A9}Окно: {FFFF00}/admnorm")
        end
    end)
end

function AD.report()
    local lines = { "Норма админов (" .. AD.key .. " >= " .. AD.norm .. ")" }
    for _, a in ipairs(AD.list) do
        local r = AD.res[a.nick:lower()]
        local st
        if r and r.value then st = r.value .. " | " .. (r.value >= AD.norm and "Выполнено" or "Не выполнено")
        else st = "нет данных" end
        lines[#lines + 1] = a.nick .. " | " .. a.role .. " | " .. st
    end
    return table.concat(lines, "\n")
end

function AD.saveReport()
    local path = ldDir() .. "/FilippHelper_adm_norm.txt"
    local ok = pcall(function()
        local f = assert(io.open(path, "wb"))
        f:write((AD.report():gsub("\n", "\r\n")))
        f:close()
    end)
    return ok and path or nil
end

local function setupGui()
    if not GUI_ENCODING_OK then return nil end
    local okI, imgui = pcall(require, 'mimgui')
    if not okI or type(imgui) ~= "table" then return nil end
    local okF, ffi = pcall(require, 'ffi')
    if not okF then return nil end

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

    local function buf(n) return imgui.new.char[n]() end
    local B = {
        gwWord = buf(64), gwPrize = buf(96), reply = buf(512), evId = buf(12),
        bindName = buf(24), bindText = buf(256), noteTitle = buf(48), noteText = buf(256), tpl = buf(160), claim = buf(64), evPrize = buf(96), chkWord = buf(24), chkSecs = buf(8), search = buf(48),
        aiUrl = buf(200), aiKey = buf(200), aiModel = buf(64), aiPrompt = buf(700),
    }
    local accBuf = imgui.new.float[3](cfg.accent[1], cfg.accent[2], cfg.accent[3])
    local bgBuf = imgui.new.float[3](cfg.bg[1], cfg.bg[2], cfg.bg[3])
    local alphaBuf = imgui.new.float(cfg.alpha)
    local autoBuf = imgui.new.bool(cfg.automp)
    local glassBuf = imgui.new.bool(cfg.glass)
    local liteBuf = imgui.new.bool(cfg.lite)
    local introBuf = imgui.new.bool(cfg.intro)
    local tagBuf = imgui.new.bool(cfg.devtag)
    local applyStyle

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

    local ucache = {}
    local function U(s)
        local c = ucache[s]
        if not c then c = toUi(s) ucache[s] = c end
        return c
    end

    local function bigText(s, color)
        local pushed = G.big and pcall(imgui.PushFont, G.big)
        imgui.TextColored(color or ACC, U(s))
        if pushed then imgui.PopFont() end
    end
    local function title(s, sub)
        bigText(s, ACC)
        if sub then imgui.TextColored(GRAY, U(sub)) end
        imgui.Separator() imgui.Spacing()
    end

    local function primary(label, size)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cfg.accent[1] * 0.85, cfg.accent[2] * 0.85, cfg.accent[3] * 0.85, 0.85))
        local clicked = imgui.Button(U(label), size)
        imgui.PopStyleColor()
        return clicked
    end
    local function hint(s) imgui.TextColored(GRAY, U(s)) end

    local pages = {}

    pages[1] = { "Команды", function()
        title("Все команды")
        imgui.Text(U("Поиск")) imgui.SameLine()
        imgui.PushItemWidth(fs * 16) imgui.InputText("##cmdsearch", B.search, 40) imgui.PopItemWidth()
        local q = lower1251(trim(getBuf(B.search)))
        local head
        for _, r in ipairs(MENU_ROWS) do
            if r[1] == "#" then
                head = r[2]
                if q == "" then imgui.Spacing() imgui.TextColored(ACC, U(r[2])) head = nil end
            elseif q == "" or lower1251(r[1]):find(q, 1, true) or lower1251(r[2]):find(q, 1, true) then
                if head then imgui.Spacing() imgui.TextColored(ACC, U(head)) head = nil end
                imgui.TextColored(YEL, U(r[1])) imgui.SameLine(fs * 15) imgui.TextWrapped(U(r[2]))
            end
        end
    end }

    pages[2] = { "Раздачи", function()
        title("Раздача призов")
        imgui.Text(U("Кодовое слово")) imgui.PushItemWidth(-1) imgui.InputText("##gwword", B.gwWord, 64) imgui.PopItemWidth()
        imgui.Text(U("Приз")) imgui.PushItemWidth(-1) imgui.InputText("##gwprize", B.gwPrize, 96) imgui.PopItemWidth()
        hint("Формат приза: тип и число. Например: банк 500000, лвл 3, #9 15 (номер статы).")
        imgui.Spacing()
        local function start(isLast)
            local w, p = getBuf(B.gwWord), getBuf(B.gwPrize)
            post(function() gwStart(w .. " | " .. p, isLast) end)
        end
        if imgui.Button(U("Старт"), V2(fs * 7, fs * 2)) then start(false) end
        imgui.SameLine()
        if imgui.Button(U("Финальный раунд"), V2(fs * 10, fs * 2)) then start(true) end
        imgui.SameLine()
        if imgui.Button(U("Стоп"), V2(fs * 6, fs * 2)) then post(function() gw.active = false gw.last = false fmsg("Раздача отменена.") end) end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        if gw.active then
            imgui.TextColored(GREEN, U("Идёт раздача"))
            imgui.Text(U("Слово: " .. gw.word))
            imgui.Text(U("Приз: " .. gw.prize))
            if not gw.stat then imgui.TextColored(RED, U("Тип приза не распознан - выдавать вручную.")) end
        else
            imgui.TextColored(GRAY, U("Раздача не запущена."))
        end
    end }

    pages[3] = { "Репорты", function()
        title("Последние репорты")
        if #reports == 0 then
            hint("Репортов пока нет.")
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
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##reply", U("Ответ игроку (уйдёт через /pm)"), B.reply, 512) imgui.PopItemWidth()
                if imgui.Button(U("Ответить"), V2(fs * 8, fs * 2)) then
                    local text, id = getBuf(B.reply), r.id
                    post(function() if replyTo(id, text) then clearBuf(B.reply) end end)
                end
                imgui.SameLine()
                if imgui.Button(U("Принять в /a"), V2(fs * 9, fs * 2)) then
                    local id = r.id
                    post(function() cmdAr(id) end)
                end
                imgui.SameLine()
                if primary("ИИ ответ##aibtn", V2(fs * 8, fs * 2)) then
                    local rr = r
                    post(function() AI.suggest(rr, function() end) end)
                end
                if AI.status ~= "" then imgui.TextColored(GRAY, toUi(AI.status)) end
            else hint("Выберите репорт из списка.") end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Шаблоны ответов (нажмите - текст попадёт в поле ответа)"))
        for i, t in ipairs(templates) do
            if imgui.SmallButton(U("x") .. "##td" .. i) then
                local idx = i
                post(function() table.remove(templates, idx) saveTemplates() end)
            end
            imgui.SameLine()
            if imgui.Selectable(toUi(t) .. "##tp" .. i, false) then ffi.copy(B.reply, toUi(t):sub(1, 500)) end
        end
        imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##tplnew", U("новый шаблон"), B.tpl, 160) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Добавить шаблон"), V2(fs * 8, 0)) then
            local text = getBuf(B.tpl)
            post(function()
                local ok, msg = tplAdd(text)
                fmsg(msg)
                if ok then clearBuf(B.tpl) end
            end)
        end
    end }

    pages[4] = { "Мероприятия", function()
        title("Анонсы МП в /aad")
        imgui.Text(U("ID ведущего (для «Догони Инфернус»)")) imgui.SameLine()
        imgui.PushItemWidth(fs * 5) imgui.InputText("##evid", B.evId, 12) imgui.PopItemWidth()
        imgui.Text(U("Приз (необязательно)")) imgui.SameLine()
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

    pages[10] = { "Транспорт", function()
        title("Транспорт сервера")
        local bw = V2(fs * 14, fs * 2)
        if imgui.Button(U("Заспавнить кары сервера") .. "##cs", bw) then post(function() carsDo("spawn") end) end
        imgui.SameLine()
        if imgui.Button(U("Удалить админ-кары") .. "##cd", bw) then post(function() carsDo("dv") end) end
        if imgui.Button(U("Удалить + заспавнить") .. "##cds", bw) then post(function() carsDo("dvs") end) end
        imgui.SameLine()
        if imgui.Button(U("Заправить кары") .. "##cf", bw) then post(function() carsDo("fuel") end) end
        imgui.Spacing()
        imgui.Spacing()
        hint("Удаление админ-каров: сначала предупреждение в /a, через 15 секунд /dvall.")
        if imgui.Button(U("Отменить удаление") .. "##cvs", bw) then post(function() pcall(sampProcessChatInput, "/vrstop") end) end
    end }

    local function selNames()
        local names = {}
        for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
        return names
    end

    pages[12] = { "Главная", function()
        title("Главная", "Быстрые действия и состояние")
        local active = CHK and CHK.active
        local function tile(id, label, value, color)
            imgui.BeginChild("##tile" .. id, V2(fs * 8.6, fs * 4.2), true)
            imgui.TextColored(GRAY, U(label))
            bigText(value, color)
            imgui.EndChild()
        end
        tile(1, "Репортов в списке", tostring(#reports), ACC) imgui.SameLine()
        tile(2, "Авто-/mp", cfg.automp and "вкл" or "выкл", cfg.automp and GREEN or GRAY) imgui.SameLine()
        tile(3, "Проверка активности", active and ("идёт: " .. #CHK.list) or "нет", active and GREEN or GRAY) imgui.SameLine()
        tile(4, "ID из /re", tostring(watchedId or "-"), YEL)
        imgui.Spacing()
        local bw = V2(fs * 12.5, fs * 2.4)
        local function btn(label, id, fn, same, prim)
            local clicked
            if prim then clicked = primary(label .. "##h" .. id, bw) else clicked = imgui.Button(U(label) .. "##h" .. id, bw) end
            if clicked then post(fn) end
            if same then imgui.SameLine() end
        end
        imgui.TextColored(ACC, U("ПРОВЕРКИ И РЕПОРТЫ"))
        btn("Проверка активности", 1, function() INFO.a1(selNames()) end, true, true)
        btn("Список репортов", 2, function() G.page = 3 end, true)
        btn("Раздача призов", 3, function() G.page = 2 end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("ТРАНСПОРТ"))
        btn("Заправить кары", 4, function() carsDo("fuel") end, true)
        btn("Заспавнить кары", 5, function() carsDo("spawn") end, true)
        btn("Удалить адм-кары (15 с)", 6, function() carsDo("dv") end, false)
        imgui.Spacing() imgui.TextColored(ACC, U("МЕРОПРИЯТИЯ И ОБЪЯВЛЕНИЯ"))
        btn("Нажать /mp", 7, function() armAutoMp(true) end, true)
        btn("Правила лидерам", 8, function() INFO.rules() end, true)
        btn("Инфо игрокам", 9, function() INFO.inf() end, false)
        imgui.Spacing()
        hint("Остальное - в меню слева. Все команды и поиск по ним: страница «Команды».")
    end }

    pages[13] = { "Проверка", function()
        title("Проверка активности")
        hint("Выберите должности или набор. Если никого не выбрать - общая проверка.")
        for i, p in ipairs(CHK_PRESETS) do
            if imgui.Button(U(p[1]) .. "##pre" .. i, V2(fs * 9, fs * 1.8)) then
                sel.roles = {}
                for _, k in ipairs(p[2]) do
                    for ri, r in ipairs(ROLES) do if r[1] == k then sel.roles[ri] = true end end
                end
            end
            imgui.SameLine()
        end
        if imgui.Button(U("Сбросить") .. "##prer", V2(fs * 7, fs * 1.8)) then sel.roles = {} end
        imgui.Spacing()
        local function roleBtn(i)
            if imgui.Selectable(U(ROLES[i][2]) .. "##crole" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
        end
        imgui.TextColored(ACC, U("Руководящие"))
        for i = 1, 7 do
            roleBtn(i)
            if i ~= 4 and i < 7 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.TextColored(ACC, U("Следящие (ГС, ЗГС, ПГС по структурам)"))
        for i = 8, #ROLES do
            roleBtn(i)
            if (i - 7) % 3 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        imgui.Spacing()
        imgui.Text(U("Ответ")) imgui.SameLine()
        imgui.PushItemWidth(fs * 6) imgui.InputText("##chkword", B.chkWord, 20) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("Секунд")) imgui.SameLine()
        imgui.PushItemWidth(fs * 4) imgui.InputText("##chksecs", B.chkSecs, 6) imgui.PopItemWidth()
        imgui.SameLine() hint("(0 - без таймера)")
        local word = trim(getBuf(B.chkWord))
        local secs = tonumber(getBuf(B.chkSecs)) or 0
        imgui.Spacing()
        imgui.TextColored(YEL, U("Что уйдёт в /a:"))
        local lines = chkLines(selNames(), word, secs)
        for _, l in ipairs(lines) do imgui.TextWrapped(U(l)) end
        imgui.Spacing()
        local bw = V2(fs * 11, fs * 2.2)
        if primary("Начать проверку##chkgo", bw) then
            local names = selNames()
            post(function() sayA1(names, { word = word, seconds = secs }) end)
        end
        imgui.SameLine()
        if imgui.Button(U("Завершить и объявить") .. "##chkfin", bw) then post(function() chkEnd(true) end) end
        imgui.SameLine()
        if imgui.Button(U("Итог окном") .. "##chkres", bw) then post(chkShow) end
        imgui.Spacing()
        if CHK.active then imgui.TextColored(GREEN, U("Идёт проверка. Отметились: " .. #CHK.list))
        else imgui.TextColored(GRAY, U("Проверка не идёт. Последний результат: " .. #CHK.list)) end
        imgui.BeginChild("##chkans", V2(0, fs * 7), true)
        if #CHK.list == 0 then hint("Пока никто не ответил.") end
        for i, e in ipairs(CHK.list) do
            imgui.Text(U(i .. ". " .. e.name .. (e.id and ("[" .. e.id .. "]") or "")))
            imgui.SameLine(fs * 16) imgui.TextColored(GRAY, U("через " .. e.sec .. " сек."))
        end
        imgui.EndChild()
    end }

    pages[11] = { "Памятки", function()
        title("Объявления и памятки")
        local bw = V2(fs * 14, fs * 2)
        imgui.TextColored(YEL, U("Проверка активности: выберите должности"))
        for i, r in ipairs(ROLES) do
            if imgui.Selectable(U(r[2]) .. "##role" .. i, sel.roles[i] == true, 0, V2(fs * 6, fs * 1.4)) then sel.roles[i] = not sel.roles[i] end
            if i % 5 ~= 0 and i < #ROLES then imgui.SameLine() end
        end
        if imgui.Button(U("Проверить выбранных") .. "##i1", bw) then
            local names = {}
            for i, r in ipairs(ROLES) do if sel.roles[i] then names[#names + 1] = r[3] end end
            post(function() infoDo("a1", names) end)
        end
        imgui.Spacing()
        imgui.SameLine()
        if imgui.Button(U("Правила лидерам") .. "##i2", bw) then post(function() infoDo("rules") end) end
        if imgui.Button(U("Инфо игрокам") .. "##i3", bw) then post(function() infoDo("inf") end) end
        imgui.SameLine()
        if imgui.Button(U("Акция за онлайн") .. "##i4", bw) then post(function() infoDo("time") end) end
        if imgui.Button(U("Вступление к раздаче") .. "##i5", bw) then post(function() infoDo("intro", getBuf(B.gwPrize)) end) end
        imgui.SameLine()
        hint("Приз берётся из поля раздач.")
        imgui.Spacing()
        if imgui.Button(U("Правила каптов") .. "##i6", bw) then post(function() infoDo("capt") end) end
        imgui.SameLine()
        if imgui.Button(U("Правила бизваров") .. "##i7", bw) then post(function() infoDo("biz") end) end
        imgui.Spacing()
        hint("Вопрос лидеру в чат (ответ в чате только вам):")
        for i, v in ipairs(VOPROS) do
            if imgui.Button(tostring(i) .. "##q" .. i, V2(fs * 3, fs * 2)) then post(function() infoDo("q", tostring(i)) end) end
            if i < #VOPROS then imgui.SameLine() end
        end
    end }

    pages[5] = { "Фракции", function()
        title("Наборы, отборы, лидерки")
        imgui.BeginChild("##frlist", V2(0, fs * 11), true)
        for i, f in ipairs(FRACTIONS) do
            if imgui.Selectable(U(f[2]) .. "##f" .. i, sel.fraction == i) then sel.fraction = i end
        end
        imgui.EndChild()
        local f = FRACTIONS[sel.fraction]
        imgui.Spacing()
        if not f then hint("Выберите фракцию.") return end
        imgui.TextColored(YEL, U(f[2]))
        if imgui.Button(U("Набор (/o)"), V2(fs * 9, fs * 2)) then post(function() recruit(f) end) end
        imgui.SameLine()
        if imgui.Button(U("Отбор (/aad)"), V2(fs * 9, fs * 2)) then post(function() tryoutAad(f) end) end
        imgui.SameLine()
        if imgui.Button(U("Отбор (/o)"), V2(fs * 9, fs * 2)) then post(function() tryoutO(f) end) end
        if imgui.Button(U("Взять лидерку"), V2(fs * 9, fs * 2)) then post(function() tempLeader(f) end) end
    end }

    pages[6] = { "Биндер", function()
        title("Свои бинды")
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
            imgui.TextColored(YEL, U("/" .. sel.bind .. "  (пауза " .. b.delay .. " мс)"))
            for i, l in ipairs(b.lines) do imgui.TextWrapped(toUi(i .. ". " .. l)) end
        else hint("Выберите бинд слева или создайте новый ниже.") end
        imgui.EndChild()
        if b then
            local name = sel.bind
            if imgui.Button(U("Запустить"), V2(fs * 8, fs * 2)) then post(function() runBind(name, "") end) end
            imgui.SameLine()
            if imgui.Button(U("Удалить бинд"), V2(fs * 9, fs * 2)) then post(function() bindDelete(name) sel.bind = "" end) end
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Новый бинд / добавить строку"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##bname", U("имя"), B.bindName, 24) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##btext", U("текст; несколько строк через ;;"), B.bindText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Добавить"), V2(fs * 6, 0)) then
            local name, text = trim(getBuf(B.bindName)):lower(), getBuf(B.bindText)
            post(function()
                local ok, msg, n2 = bindAdd(name, text)
                bmsg(msg)
                if ok then sel.bind = n2 clearBuf(B.bindText) end
            end)
        end
    end }

    pages[7] = { "Шпаргалки", function()
        title("Свои заметки")
        imgui.BeginChild("##notelist", V2(fs * 12, fs * 10), true)
        for i, n in ipairs(notes) do
            if imgui.Selectable(toUi(n.title) .. "##n" .. i, sel.note == i) then sel.note = i end
        end
        imgui.EndChild()
        imgui.SameLine()
        imgui.BeginChild("##noteinfo", V2(0, fs * 10), true)
        local n = notes[sel.note]
        if n then for _, l in ipairs(n.lines) do imgui.TextWrapped(toUi(l)) end
        else hint("Выберите заметку слева или создайте новую ниже.") end
        imgui.EndChild()
        if n and imgui.Button(U("Удалить заметку"), V2(fs * 10, fs * 2)) then
            local idx = sel.note
            post(function() table.remove(notes, idx) saveNotes() sel.note = 0 end)
        end
        imgui.Spacing() imgui.Separator() imgui.TextColored(ACC, U("Новая заметка / добавить строку"))
        imgui.PushItemWidth(fs * 10) imgui.InputTextWithHint("##ntitle", U("название"), B.noteTitle, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.PushItemWidth(-fs * 7) imgui.InputTextWithHint("##ntext", U("текст; несколько строк через ;;"), B.noteText, 256) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Сохранить"), V2(fs * 6, 0)) then
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
        { "Синяя", 0.26, 0.62, 0.96 }, { "Красная", 0.92, 0.30, 0.30 }, { "Зелёная", 0.30, 0.78, 0.45 },
        { "Фиолетовая", 0.62, 0.40, 0.95 }, { "Оранжевая", 0.98, 0.58, 0.20 },
    }

    pages[8] = { "Настройки", function()
        title("Оформление окна")
        imgui.Text(U("Цвет акцента")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##acc", accBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("Цвет фона")) imgui.PushItemWidth(fs * 16)
        if imgui.ColorEdit3("##bg", bgBuf) then applyColors() end
        imgui.PopItemWidth()
        imgui.Text(U("Прозрачность фона")) imgui.PushItemWidth(fs * 16)
        if imgui.SliderFloat("##alpha", alphaBuf, 0.5, 1.0) then applyColors() end
        imgui.PopItemWidth()
        imgui.Spacing() imgui.Text(U("Готовые цвета акцента:"))
        for i, p in ipairs(PRESETS) do
            if imgui.Button(U(p[1]) .. "##pr" .. i, V2(fs * 8, fs * 1.8)) then
                accBuf[0], accBuf[1], accBuf[2] = p[2], p[3], p[4]
                applyColors()
            end
            if i < #PRESETS then imgui.SameLine() end
        end
        if imgui.Button(U("Сбросить цвета"), V2(fs * 10, fs * 1.8)) then
            accBuf[0], accBuf[1], accBuf[2] = 0.26, 0.62, 0.96
            bgBuf[0], bgBuf[1], bgBuf[2] = 0.07, 0.08, 0.10
            alphaBuf[0] = 0.97
            applyColors()
        end
        imgui.Spacing()
        if imgui.Checkbox(U("Стиль Liquid Glass (стекло)"), glassBuf) then
            cfg.glass = glassBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("Полупрозрачные панели и цветные блики. Прозрачность регулируется ползунком выше.")
        if imgui.Checkbox(U("Лёгкий режим (если окно лагает)"), liteBuf) then
            cfg.lite = liteBuf[0] and true or false
            applyStyle()
            post(saveCfg)
        end
        hint("Убирает блики и прозрачность окна - заметно меньше нагрузка на телефоне.")
        if imgui.Checkbox(U("Анимация открытия окна"), introBuf) then
            cfg.intro = introBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Checkbox(U("Метка «крутой разраб скрипта» у Filipp_Evans в чате"), tagBuf) then
            cfg.devtag = tagBuf[0] and true or false
            post(saveCfg)
        end
        hint("Метка видна только вам (меняется только ваш чат).")
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("Мероприятия")
        if imgui.Checkbox(U("После анонса МП вводить /mp и нажимать 1-ю строку"), autoBuf) then
            cfg.automp = autoBuf[0] and true or false
            post(saveCfg)
        end
        hint("То же вручную: /mpa. Переключатель командой: /fhset automp on|off.")
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        title("ИИ-ответы на репорты")
        hint("Любой сервис с OpenAI-совместимым API (chat/completions). Нужны библиотеки effil и requests.")
        hint("Ключ хранится в moonloader/config/FilippHelper_settings.txt - не выкладывайте этот файл.")
        local pw = (imgui.InputTextFlags and imgui.InputTextFlags.Password) or 0
        imgui.Text(U("Адрес API")) imgui.PushItemWidth(-1) imgui.InputText("##aiurl", B.aiUrl, 200) imgui.PopItemWidth()
        imgui.Text(U("Ключ API")) imgui.PushItemWidth(-1) imgui.InputText("##aikey", B.aiKey, 200, pw) imgui.PopItemWidth()
        imgui.Text(U("Модель")) imgui.PushItemWidth(-1) imgui.InputText("##aimodel", B.aiModel, 60) imgui.PopItemWidth()
        imgui.Text(U("Инструкция для ИИ (правила вашего сервера, стиль ответа)"))
        imgui.PushItemWidth(-1) imgui.InputText("##aiprompt", B.aiPrompt, 690) imgui.PopItemWidth()
        if imgui.Button(U("Сохранить") .. "##aisave", V2(fs * 9, fs * 2)) then post(function() saveAi() fmsg("Настройки ИИ сохранены.") end) end
        imgui.SameLine()
        if imgui.Button(U("Сохранить и проверить") .. "##aitest", V2(fs * 12, fs * 2)) then post(function() saveAi() AI.test() end) end
        if AI.status ~= "" then imgui.TextWrapped(toUi(AI.status)) end
    end }

    pages[9] = { "Занять", function()
        title("Занять задачу")
        hint("Нажмите кнопку - в /a три раза подряд уйдёт «z ...».")
        imgui.Spacing()
        for i, c in ipairs(CLAIMS) do
            if imgui.Button(toUi("z " .. c[2]) .. "##z" .. i, V2(fs * 11, fs * 2)) then
                local txt = c[2]
                post(function() claim(txt) end)
            end
            if i % 3 ~= 0 then imgui.SameLine() end
        end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        imgui.Text(U("Свой текст (после «z »)"))
        imgui.PushItemWidth(-fs * 7) imgui.InputText("##claimtext", B.claim, 64) imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(U("Занять") .. "##claimgo", V2(fs * 6, 0)) then
            local txt = getBuf(B.claim)
            post(function() claim(txt) end)
        end
    end }

    local function guarded(fn)
        local ok, err = pcall(fn)
        if not ok then
            G.errors = G.errors + 1
            print("[FH] gui error: " .. tostring(err))
            if G.errors >= 3 then G.disabled = true G.show[0] = false end
        end
    end

    local ldBuf = { ghetto = imgui.new.int(LD.norm.ghetto), mafia = imgui.new.int(LD.norm.mafia), gov = imgui.new.int(LD.norm.gov) }
    local ldScope, ldFmt = "all", "forum"
    local LD_SCOPES = { { "all", "Все" }, { "ghetto", "Гетто" }, { "mafia", "Мафии" }, { "gov", "Госс" } }
    pages[14] = { "Лидеры", function()
        title("Норма лидеров", "Список из /aleaders, онлайн из /leaders, норма и снятие")
        if primary("Обновить##ldref", V2(fs * 9, fs * 2)) then post(function() LD.refresh() end) end
        imgui.SameLine()
        imgui.TextColored(LD.busy and YEL or GRAY, U(LD.status ~= "" and LD.status or "Нажмите «Обновить»."))
        imgui.Spacing()
        for i, sc in ipairs(LD_SCOPES) do
            if i > 1 then imgui.SameLine() end
            local act = ldScope == sc[1]
            if act then imgui.PushStyleColor(imgui.Col.Button, ACC) end
            if imgui.Button(U(sc[2]) .. "##ldsc" .. i, V2(fs * 6, fs * 1.8)) then ldScope = sc[1] end
            if act then imgui.PopStyleColor() end
        end
        imgui.Spacing()
        for i, f in ipairs { { "forum", "Для форума" }, { "list", "Простой список" } } do
            if i > 1 then imgui.SameLine() end
            local act = ldFmt == f[1]
            if act then imgui.PushStyleColor(imgui.Col.Button, ACC) end
            if imgui.Button(U(f[2]) .. "##ldfmt" .. i, V2(fs * 9, fs * 1.8)) then ldFmt = f[1] end
            if act then imgui.PopStyleColor() end
        end
        imgui.Spacing()
        hint("Норма, минут онлайн:")
        for i, k in ipairs { "ghetto", "mafia", "gov" } do
            if i > 1 then imgui.SameLine() end
            imgui.Text(U(k == "ghetto" and "Гетто" or (k == "mafia" and "Мафии" or "Госс")))
            imgui.SameLine() imgui.PushItemWidth(fs * 5)
            if imgui.InputInt("##ldn" .. k, ldBuf[k], 0) then
                LD.norm[k] = math.max(0, math.min(1440, ldBuf[k][0]))
                post(LD.saveNorm)
            end
            imgui.PopItemWidth()
        end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        local shown = 0
        for i, r in ipairs(LD.rows) do
            if ldScope == "all" or r.cat == ldScope then
                shown = shown + 1
                local done = r.min >= LD.norm[r.cat]
                local w = imgui.GetContentRegionAvail().x
                imgui.TextColored(GRAY, U(r.fr))
                imgui.SameLine(w * 0.30) imgui.Text(U(r.nick))
                imgui.SameLine(w * 0.58) imgui.TextColored(r.online and GREEN or GRAY, U(ldHM(r.min)))
                imgui.SameLine(w * 0.70) imgui.TextColored(done and GREEN or RED, U(done and "Выполнено" or "Не выполнено"))
                imgui.Indent(fs * 1.5)
                local function act(kind, label, bw)
                    local armed = LD.arm and LD.arm.nick == r.nick and LD.arm.kind == kind and os.clock() - LD.arm.t < 5
                    if armed then imgui.PushStyleColor(imgui.Col.Button, RED) end
                    local clicked = imgui.Button(U(armed and "Точно?" or label) .. "##ld" .. kind .. i, V2(bw, 0))
                    if armed then imgui.PopStyleColor() end
                    if clicked then
                        local cmd, why = LD.press(kind, r.nick)
                        if not cmd then
                            LD.status = why
                        elseif armed then
                            LD.arm = nil
                            post(function() safeSend(cmd) fmsg("{FFFF00}" .. cmd) end)
                        else
                            LD.arm = { nick = r.nick, t = os.clock(), kind = kind }
                        end
                    end
                end
                act("off", "Снять", fs * 5)
                imgui.Unindent(fs * 1.5)
                imgui.Spacing()
            end
        end
        if shown == 0 then hint("Пусто. Нажмите «Обновить».") end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        if primary("Скопировать норму##ldcopy", V2(fs * 11, fs * 2)) then
            imgui.SetClipboardText(toUi(LD.build(ldScope, ldFmt)))
            LD.status = "Норма скопирована в буфер."
        end
        imgui.SameLine()
        if imgui.Button(U("Сохранить в файл") .. "##ldsave", V2(fs * 11, fs * 2)) then
            post(function() LD.cmdNorm(ldScope .. (ldFmt == "list" and " list" or "")) end)
        end
        hint("/offleader: нажмите кнопку, затем «Точно?» в течение 5 секунд.")
    end }

    local adNorm = imgui.new.int(AD.norm)
    local adKey = buf(40)
    ffi.copy(adKey, cutUtf8(toUi(AD.key), 39))
    local adPaste = buf(8192)
    pages[15] = { "Админы", function()
        title("Норма админов", "Ник и должность из нлиста, статистика через /getoffstats ник")
        if primary("Проверить всех##adall", V2(fs * 10, fs * 2)) then post(function() AD.run(AD.list) end) end
        imgui.SameLine()
        imgui.TextColored(AD.busy and YEL or GRAY, U(AD.status ~= "" and AD.status or "Нажмите «Проверить всех»."))
        imgui.Spacing()
        hint("Норма считается по строке ответа, где есть это слово, и числу после него:")
        imgui.PushItemWidth(fs * 10)
        if imgui.InputText("##adkey", adKey, 40) then
            AD.key = getBuf(adKey)
            post(function() AD.recalc() AD.saveCfg() end)
        end
        imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("минимум"))
        imgui.SameLine() imgui.PushItemWidth(fs * 5)
        if imgui.InputInt("##adnorm", adNorm, 0) then
            AD.norm = math.max(0, math.min(100000, adNorm[0]))
            post(AD.saveCfg)
        end
        imgui.PopItemWidth()
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        hint("Вставьте нлист из ВК (берутся только ник и должность):")
        imgui.InputTextMultiline("##adpaste", adPaste, 8192, V2(-1, fs * 6))
        if imgui.Button(U("Добавить из поля") .. "##adaddf", V2(fs * 10, fs * 1.9)) then
            local text = getBuf(adPaste)
            post(function()
                local a, u = AD.add(text)
                AD.status = string.format("Добавлено: %d, обновлено: %d, всего: %d", a, u, #AD.list)
                ffi.fill(adPaste, ffi.sizeof(adPaste), 0)
            end)
        end
        imgui.SameLine()
        if imgui.Button(U("Добавить из буфера") .. "##adaddc", V2(fs * 11, fs * 1.9)) then
            local okc, clip = pcall(function() return ffi.string(imgui.GetClipboardText()) end)
            if okc and clip then
                clip = fromUi(clip)
                post(function()
                    local a, u = AD.add(clip)
                    AD.status = string.format("Добавлено: %d, обновлено: %d, всего: %d", a, u, #AD.list)
                end)
            else
                AD.status = "Буфер обмена пуст."
            end
        end
        imgui.SameLine()
        local armedClr = AD.armClear and os.clock() - AD.armClear < 5
        if armedClr then imgui.PushStyleColor(imgui.Col.Button, RED) end
        if imgui.Button(U(armedClr and "Точно?" or "Очистить список") .. "##adclr", V2(fs * 9, fs * 1.9)) then
            if armedClr then
                AD.armClear = nil
                post(function() AD.list, AD.res = {}, {} AD.save() AD.status = "Список очищен." end)
            else
                AD.armClear = os.clock()
            end
        end
        if armedClr then imgui.PopStyleColor() end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        for i, a in ipairs(AD.list) do
            local r = AD.res[a.nick:lower()]
            local w = imgui.GetContentRegionAvail().x
            imgui.Text(U(a.nick))
            imgui.SameLine(w * 0.34) imgui.TextColored(GRAY, U(a.role))
            imgui.SameLine(w * 0.64)
            if r and r.value then
                local done = r.value >= AD.norm
                imgui.TextColored(done and GREEN or RED, U(tostring(r.value) .. "  " .. (done and "Выполнено" or "Не выполнено")))
            else
                imgui.TextColored(GRAY, U(r and "нет данных" or "не проверен"))
            end
            imgui.Indent(fs * 1.5)
            if imgui.Button(U("Проверить") .. "##adck" .. i, V2(fs * 6, 0)) then
                local one = { a }
                post(function() AD.run(one) end)
            end
            imgui.SameLine()
            if imgui.Button(U("Убрать") .. "##addel" .. i, V2(fs * 5, 0)) then
                local nk = a.nick
                post(function() AD.remove(nk) end)
            end
            if r then
                local shown = r.line or r.lines[1]
                if shown then imgui.SameLine() imgui.TextColored(GRAY, cutUtf8(toUi(shown), 70)) end
            end
            imgui.Unindent(fs * 1.5)
            imgui.Spacing()
        end
        if #AD.list == 0 then hint("Список пуст. Вставьте нлист и нажмите «Добавить».") end
        imgui.Spacing() imgui.Separator() imgui.Spacing()
        if primary("Скопировать норму##adcopy", V2(fs * 11, fs * 2)) then
            imgui.SetClipboardText(toUi(AD.report()))
            AD.status = "Норма скопирована в буфер."
        end
        imgui.SameLine()
        if imgui.Button(U("Сохранить в файл") .. "##adsave", V2(fs * 11, fs * 2)) then
            post(function()
                local p = AD.saveReport()
                AD.status = p and "Сохранено в config/FilippHelper_adm_norm.txt" or "Не удалось сохранить файл."
            end)
        end
        hint("Ответ /getoffstats целиком сохраняется в config/FilippHelper_getoffstats_raw.txt.")
    end }

    local function drawBody()

        imgui.BeginChild("##side", V2(fs * 10, 0), true)
        guarded(function()
            bigText("FilippHelper", ACC)
            imgui.TextColored(GRAY, U("by ByFilipp  ·  v" .. VERSION))
            imgui.Separator() imgui.Spacing()

            local groups = {
                { "ГЛАВНОЕ", { "Главная", "Проверка", "Репорты", "Раздачи", "Мероприятия" } },
                { "АДМИНИСТРИРОВАНИЕ", { "Фракции", "Транспорт", "Памятки", "Занять" } },
                { "НОРМА", { "Лидеры", "Админы" } },
                { "ИНСТРУМЕНТЫ", { "Биндер", "Шпаргалки", "Команды" } },
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
                    for i, p in ipairs(pages) do
                        if not used[i] and p[1] ~= "Настройки" then drawBtn(i) end
                    end
                end
            end
            local si = byName["Настройки"]
            if si then imgui.Separator() imgui.Spacing() drawBtn(si) end
            imgui.Spacing() imgui.TextColored(GRAY, U("Поддержка: @ByFilipp123"))
        end)
        imgui.EndChild()
        imgui.SameLine()

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
            local pushed = big and G.big and pcall(imgui.PushFont, G.big)
            local w = imgui.CalcTextSize(U(str)).x
            imgui.SetCursorPos(V2((sz.x - w) / 2, y))
            imgui.TextColored(c, U(str))
            if pushed then imgui.PopFont() end
        end
        local full = "FilippHelper"
        local n = math.max(0, math.min(#full, math.floor((age - 0.35) / 0.08)))
        centered(full:sub(1, n), sz.y / 2 + fs * 1.8, imgui.ImVec4(1, 1, 1, fade), true)
        local sa = math.max(0, math.min(1, (age - 1.1) / 0.5)) * fade
        centered("by ByFilipp  &  Claude", sz.y / 2 + fs * 4.4, imgui.ImVec4(ar, ag, ab, sa), false)

        local bw, by = sz.x * 0.28, p.y + sz.y / 2 + fs * 6.6
        local bx = cx - bw / 2
        dl:AddRectFilled(V2(bx, by), V2(bx + bw, by + 4), col(1, 1, 1, 0.12 * fade), 2)
        dl:AddRectFilled(V2(bx, by), V2(bx + bw * math.min(1, age / (INTRO_T - 0.4)), by + 4), col(ar, ag, ab, 0.9 * fade), 2)
    end

    imgui.OnInitialize(function()
        local ok, err = pcall(function()
            local io = imgui.GetIO()
            io.Fonts:AddFontFromFileTTF(fontPath, fs, nil, io.Fonts:GetGlyphRangesCyrillic())
            pcall(function() G.big = io.Fonts:AddFontFromFileTTF(fontPath, math.floor(fs * 1.45), nil, io.Fonts:GetGlyphRangesCyrillic()) end)
            applyStyle()
        end)
        if not ok then G.initFailed = true print("[FH] gui init error: " .. tostring(err)) end
    end)

    local TOAST_T = 6
    imgui.OnFrame(function()
        if G.toastT0 and (os.clock() - G.toastT0 >= TOAST_T) then G.toastT0 = nil end
        return G.toastT0 ~= nil and cfg.intro and not G.disabled and not G.initFailed and not G.noToast
    end, function(self)
        self.HideCursor = true
        local age = os.clock() - G.toastT0
        local slide = 1 - (1 - math.min(1, age / 0.5)) ^ 3
        local fade = age > TOAST_T - 0.6 and math.max(0, (TOAST_T - age) / 0.6) or 1
        local w = fs * 22
        local flags = 0
        pcall(function()
            local F = imgui.WindowFlags
            flags = F.NoTitleBar + F.NoResize + F.NoMove + F.NoInputs + F.NoScrollbar + F.AlwaysAutoResize
        end)
        imgui.SetNextWindowPos(V2(sw - (w + fs) * slide, fs * 3), imgui.Cond.Always)
        imgui.SetNextWindowSize(V2(w, 0), imgui.Cond.Always)
        local pushed = pcall(function() imgui.PushStyleVar(imgui.StyleVar.Alpha, fade) end)
        local began = imgui.Begin("##fhtoast", nil, flags)
        if began then
            local ok, err = pcall(function()
                local dl = imgui.GetWindowDrawList()
                local p, sz = imgui.GetWindowPos(), imgui.GetWindowSize()
                dl:AddRectFilled(p, V2(p.x + 5, p.y + sz.y), imgui.ColorConvertFloat4ToU32(ACC), 2)
                bigText("FilippHelper загружен", ACC)
                imgui.TextColored(GRAY, U("Автор: ByFilipp  ·  при участии Claude"))
                imgui.TextColored(YEL, U("Меню: /fh   ·   команды: /fcmd"))
                imgui.TextColored(GRAY, U("Поддержка: @ByFilipp123"))
            end)
            if not ok then G.noToast = true print("[FH] toast disabled: " .. tostring(err)) end
        end
        imgui.End()
        if pushed then imgui.PopStyleVar() end
    end)

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
            if cfg.intro and not G.noIntro and age < INTRO_T then
                local okI, errI = pcall(drawIntro, age)
                if not okI then
                    G.noIntro = true
                    print("[FH] intro disabled: " .. tostring(errI))
                end
                local okC, clicked = pcall(imgui.IsMouseClicked, 0)
                if okC and clicked then G.t0 = os.clock() - INTRO_T end
            else
                guarded(drawBody)
            end
        end
        imgui.End()
    end)

    function G.ready() return not G.disabled and not G.initFailed end
    function G.toggle() G.show[0] = not G.show[0] end
    function G.notify() G.toastT0 = os.clock() end
    return G
end

local okG, gs = pcall(setupGui)
if okG then guiState = gs else print("[FH] gui setup error: " .. tostring(gs)) end

local function onServerMessageImpl(color, text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
    pcall(chkCollect, text)
    if AD.expect then pcall(AD.chat, text) end
    if not text:find("Репорт", 1, true) then return end

    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, body = clean:match("Репорт от ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not name then return end
    body = body:gsub("%s*|%s*Уже%s*%d+%s*репорт[^|]*$", "")

    table.insert(reports, 1, { name = name, id = id, text = body })
    if #reports > MAX_REPORTS then table.remove(reports) end

    if gw.active and not GW_IGNORE_NAMES[name] and not clean:find(GW_TAG, 1, true)
       and lower1251(trim(body)) == gw.word then
        gwFinish(name, id)
    end
end

local DEV_NICK = "Filipp_Evans"
local function devTagText(color, text)
    if not text:find(DEV_NICK, 1, true) or text:find(toGame("разраб скрипта"), 1, true) then return nil end
    local rgb = math.floor((tonumber(color) or 0) % 4294967296 / 256) % 16777216
    local tag = toGame(" {FFD700}[Крутой разраб скрипта]{" .. string.format("%06X", rgb) .. "}")
    local out, n = text:gsub("(" .. DEV_NICK .. "%[?%d*%]?)", "%1" .. tag:gsub("%%", "%%%%"), 1)
    if n == 0 then return nil end
    return out
end

function ev.onServerMessage(color, text)
    local ok, err = pcall(onServerMessageImpl, color, text)
    if not ok then print("[FH] onServerMessage error: " .. tostring(err)) end
    if cfg.devtag and type(text) == "string" then
        local okT, newText = pcall(devTagText, color, text)
        if okT and newText then return { color, newText } end
    end
end

function ev.onSendCommand(command)
    if type(command) ~= "string" then return end
    local id = command:match("^/re%s+(%d+)")
    if id then watchedId = id
    elseif command:match("^/re%s+off") or command:match("^/reoff") then watchedId = nil end
end

local function registerCommands(reg)
    registerExtra(reg)
    reg("ldrefresh", function() LD.refresh() end)
    reg("ldnorm", function(p) LD.cmdNorm(p) end)
    reg("lds", function()
        if guiState and guiState.ready() then guiState.page = LD.pageIdx guiState.show[0] = true else LD.cmdNorm("all") end
    end)
    reg("admnorm", function()
        if guiState and guiState.ready() then guiState.page = AD.pageIdx guiState.show[0] = true else fmsg("Окно недоступно.") end
    end)
    reg("admcheck", function(p)
        p = trim(p or "")
        if p == "" then AD.run(AD.list) return end
        for _, a in ipairs(AD.list) do
            if a.nick:lower() == p:lower() then AD.run({ a }) return end
        end
        AD.run({ { nick = p, role = "" } })
    end)
    reg("fstop", function() bindStop = true bmsg("Бинд остановлен.") end)
    reg("fh", function()
        if guiState and guiState.ready() then guiState.toggle() else uiMenu() end
    end)
    reg("reports", uiReports)
    reg("fcmd", uiMenu)
    reg("gw", function(p) gwStart(p, false) end)
    reg("gwlast", function(p) gwStart(p, true) end)
    reg("gwstop", function()
        if gw.active then gw.active = false gw.last = false fmsg("Раздача отменена.")
        else fmsg("Сейчас нет активной раздачи.") end
    end)
    reg("rr", function(p)
        local id, text = p:match("^(%d+)%s+(.+)$")
        if not id then id, text = watchedId, p end
        if not id or not replyTo(id, text) then fmsg("Использование: /rr [ID] текст") end
    end)
end

function main()
    if isSampLoaded and not isSampLoaded() then return end
    if isSampfuncsLoaded and not isSampfuncsLoaded() then return end
    while isSampAvailable and not isSampAvailable() do wait(100) end

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
                fmsg("{FF3333}Ошибка в команде /" .. name .. ", подробности в moonloader.log")
            end
        end)
    end

    local builtin = {}
    local function trackedReg(n, f) builtin[n] = true return guardedReg(n, f) end
    local okReg, errReg = pcall(registerCommands, trackedReg)
    if not okReg then print("[FH] register error: " .. tostring(errReg)) end
    local okB, errB = pcall(setupBinder, builtin, guardedReg)
    if not okB then print("[FH] binder setup error: " .. tostring(errB)) end

    fmsg("{FFD700}FilippHelper v" .. VERSION .. " {FFFFFF}- загружен")
    fmsg("{A9A9A9}Автор: {66CCFF}ByFilipp {A9A9A9}| при участии {66CCFF}Claude {A9A9A9}(Anthropic)")
    fmsg("{A9A9A9}Меню: {FFFF00}/fh {A9A9A9}| команды: {FFFF00}/fcmd {A9A9A9}| поддержка: {FFFF00}@ByFilipp123")
    pcall(function() if guiState and guiState.ready() then guiState.notify() end end)

    while true do
        wait(100)
        runPosted()
        local okT, errT = pcall(uiTick)
        if not okT then print("[FH] tick error: " .. tostring(errT)) end
    end
end
