-- FilippHelper (FH) -- помощник администратора SA-MP для MoonLoader. Автор: ByFilipp.
-- Файл на ПК должен быть в кодировке Windows-1251 (cp1251).
local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

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

local VERSION = "1.1"
local UPDATE_FILE = "FilippHelper.lua"   -- какой файл скачивать с GitHub при обновлении
local MAX_CHAT_LEN = 128   -- безопасная длина строки для sampSendChat
local SEND_GAP = 1100      -- пауза между сообщениями (антифлуд сервера)
local MAX_REPORTS = 15

local watchedId = nil   -- ID игрока из /re
local reports = {}            -- последние репорты, новые в начале

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

-- ответ на диалог только если он реально открыт (ответ на закрытый диалог может уронить игру)
local function dlgReply(id, btn, list, input)
    if sampIsDialogActive and sampGetCurrentDialogId then
        local ok, act = pcall(sampIsDialogActive)
        if not ok or not act then return end
        local ok2, cur = pcall(sampGetCurrentDialogId)
        if not ok2 or cur ~= id then return end
    end
    pcall(sampSendDialogResponse, id, btn, list, input or "")
end

local function safeSend(text)
    PUN.note(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" then return end
    if #text > MAX_CHAT_LEN then text = text:sub(1, MAX_CHAT_LEN) end
    local ok, err = pcall(sampSendChat, text)
    if not ok then print("[FH] sampSendChat error: " .. tostring(err)) end
end

-- Отправка списка строк одним потоком с паузами
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
    if not ok then bmsg("Не удалось сохранить биндер в файл!") end
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
    if bindRunning then bmsg("Дождитесь окончания предыдущего бинда.") return end
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
    sampShowDialog(4109, "FH | Биндер",
        "{66CCFF}[ СВОЙ БИНДЕР ]\n\n{33CC33}/fbind {FFFFFF}- отдельное окно биндера (создание и правка без команд).\n\n" ..
        "{FFFFFF}Создаёт свои команды: набрали {FFFF00}/имя{FFFFFF} -- отправились все строки бинда по очереди.\n\n" ..
        "{66CCFF}/bnd add имя текст {FFFFFF}- создать бинд / добавить строку.\n" ..
        "{FFFFFF}  Несколько строк сразу разделяйте {FFFF00};;{FFFFFF}, например:\n" ..
        "{FFFF00}  /bnd add hi /aad Привет! ;; /aad Как дела?\n" ..
        "{66CCFF}/bnd rm имя N {FFFFFF}- удалить строку N.\n" ..
        "{66CCFF}/bnd del имя {FFFFFF}- удалить бинд целиком.\n" ..
        "{66CCFF}/bnd delay имя мс {FFFFFF}- пауза между строками (300-10000, по умолчанию 1100).\n" ..
        "{66CCFF}/bnd show имя {FFFFFF}- показать строки бинда.\n" ..
        "{66CCFF}/bnd list {FFFFFF}- список всех биндов.\n\n" ..
        "{9933FF}Подстановки в тексте: {FFFF00}{id}{FFFFFF} - ID из команды (/имя 12) или ID из /re,\n" ..
        "{FFFF00}{arg}{FFFFFF} - всё, что написано после команды.\n" ..
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
    for piece in (text .. ";;"):gmatch("(.-);;") do
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


----------------------------------------------------------------------
-- НАСТРОЙКИ, ШАБЛОНЫ ОТВЕТОВ, АВТО-/mp
----------------------------------------------------------------------
local LITE_DEFAULT = false   -- на ПК по умолчанию полный стиль
local cfg = {
    automp = false,                 -- после анонса МП вводить /mp и нажимать 1-ю строку
    accent = { 0.26, 0.62, 0.96 },  -- цвет акцента окна
    bg = { 0.07, 0.08, 0.10 },      -- цвет фона окна
    alpha = 0.97,                   -- прозрачность фона
    glass = true,                   -- стиль Liquid Glass (стекло)
    autoupd = true,                 -- проверять обновления при запуске
    safe = false,                   -- безопасный режим: вместо окна /fh диалоги и чат
    force = false,                  -- принудительно включить окно (/fhgui on)
    reptoast = true,                -- овальное уведомление о репорте
    intro = true,                   -- анимация открытия окна (только при первом запуске)
    introDone = false,              -- анимация уже показана
    lite = LITE_DEFAULT,            -- лёгкий режим: без бликов и прозрачности (меньше лагов)
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
        f:write("glass=", cfg.glass and "1" or "0", "\r\n", "lite=", cfg.lite and "1" or "0", "\r\n", "safe=", cfg.safe and "1" or "0", "\r\n", "force=", cfg.force and "1" or "0", "\r\n", "intro=", cfg.intro and "1" or "0", "\r\n", "reptoast=", cfg.reptoast and "1" or "0", "\r\n", "introdone=", cfg.introDone and "1" or "0", "\r\n", "autoupd=", cfg.autoupd and "1" or "0", "\r\n")
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
            elseif k == "safe" then cfg.safe = (v == "1")
            elseif k == "force" then cfg.force = (v == "1")
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
        fmsg("Не удалось разобрать /define. Формат записан в config/FilippHelper_define.txt - пришлите этот файл разработчику.")
    else
        for i = #reports, 1, -1 do reports[i] = nil end
        for _, r in ipairs(list) do reports[#reports + 1] = r end
        fmsg("Список репортов обновлён из /define: " .. #list .. ".")
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
            fmsg("/define не ответил (нет доступа или другой формат).")
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
    fmsg("Причина выбрана: " .. trim(best))
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
    lua_thread.create(function()
        wait(150)
        dlgReply(id, 1, 0, "")
    end)
    return false
end

loadCfg()
loadTemplates()
-- Защита от вылетов окна: пока окно или уведомление на экране, лежит файл-метка. Если игра упала,
-- метка остаётся, и при следующем запуске включается безопасный режим (диалоги и чат вместо imgui-окна).
local GUARD = { on = false, notice = nil, warned = false }
function GUARD.path() return configDir() .. "/FilippHelper.gui" end
function GUARD.set(on)
    if on == GUARD.on then return end
    GUARD.on = on
    pcall(function()
        if on then
            local f = io.open(GUARD.path(), "wb")
            if f then f:write("1") f:close() end
        else
            os.remove(GUARD.path())
        end
    end)
end
local function guiAllowed()
    if cfg.safe then return false end
    if cfg.force then return true end
    return not (package.loaded and package.loaded["imgui"])   -- старый imgui в одной игре с mimgui конфликтует
end
pcall(function()
    local f = io.open(GUARD.path(), "rb")
    if f then
        f:close()
        os.remove(GUARD.path())
        cfg.safe, cfg.force = true, false
        GUARD.notice = true
        saveCfg()
    end
end)


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

-- запрос в отдельном потоке; cb(ok, текст_или_ошибка) вызывается из этого потока
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
            if url:match("/v1$") then url = url .. "/chat/completions" end   -- адрес вида .../v1 дополняем сами
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

-- /aidiag: что доступно в загрузчике для запросов к API
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

-- /ai [ID]: подсказка по репорту, текст попадает в строку ввода как /rr ID текст
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

----------------------------------------------------------------------
-- ПРОВЕРКА ОБНОВЛЕНИЙ ПО GITHUB
-- В репозитории лежит version.txt: 1-я строка - версия, 2-я - что нового.
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
    UPD.status = "Проверяю обновления..."
    lua_thread.create(function()
        local ok, code, text = pcall(AI.http, UPD.base .. "version.txt", "", "", "GET")
        UPD.busy = false
        if not ok or not code or code ~= 200 or type(text) ~= "string" then
            UPD.status = "Не удалось проверить обновления."
            if not silent then fmsg("Не удалось проверить обновления (" .. tostring(ok and (code or text) or code) .. ").") end
            return
        end
        local ver, notes = text:match("^%s*([%d%.]+)[^\n]*\n?(.*)$")
        if not ver then UPD.status = "Не удалось разобрать version.txt." return end
        UPD.checked, UPD.latest, UPD.notes = true, ver, trim(fromUi((notes or ""):gsub("[\r\n]+", " ")))
        if verNewer(ver, VERSION) then
            UPD.status = "Доступна версия " .. ver
            fmsg("{FFD700}Доступно обновление {FFFFFF}v" .. ver .. " {A9A9A9}(у вас v" .. VERSION .. ")")
            if UPD.notes ~= "" then fmsg("{A9A9A9}Что нового: {FFFFFF}" .. UPD.notes) end
            fmsg("{A9A9A9}Установить: {FFFF00}/fhupd install {A9A9A9}или кнопка в /fh на «Главной»")
        else
            UPD.latest = nil
            UPD.status = "У вас последняя версия (v" .. VERSION .. ")."
            if not silent then fmsg(UPD.status) end
        end
    end)
end

function UPD.install()
    if UPD.busy then return end
    if not UPD.latest then fmsg("Сначала проверьте обновления: /fhupd") return end
    UPD.busy = true
    UPD.status = "Скачиваю обновление..."
    fmsg("Скачиваю v" .. UPD.latest .. "...")
    lua_thread.create(function()
        local ok, err = pcall(function()
            local code, text = AI.http(UPD.base .. UPD.file, "", "", "GET")
            if code ~= 200 or type(text) ~= "string" then error("ошибка загрузки (" .. tostring(code) .. ")") end
            if #text < 20000 or not text:find("FilippHelper", 1, true) then error("файл повреждён или неполный") end
            local chunk, cerr = (loadstring or load)(text)
            if not chunk then error("файл не компилируется: " .. tostring(cerr)) end
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
            UPD.status = "Обновлено до v" .. tostring(UPD.latest) .. ", перезагрузка..."
            fmsg("{66FF66}Обновлено до v" .. tostring(UPD.latest) .. ". Перезагружаю скрипт...")
            wait(800)
            pcall(function() thisScript():reload() end)
        else
            UPD.status = "Ошибка обновления: " .. tostring(err)
            fmsg("{FF6666}Обновление не удалось: " .. tostring(err))
        end
    end)
end

function UPD.cmd(p)
    p = trim(p or "")
    if p == "install" then UPD.install() else UPD.check(false) end
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

----------------------------------------------------------------------
-- РАЗДАЧА ПРИЗОВ
----------------------------------------------------------------------
local gw = { active = false, last = false, word = "", prize = "", stat = nil, amount = nil, t0 = 0 }
local GW_TAG = "[Раздача]"
local GW_IGNORE_NAMES = { Admin = true, Utka_News = true }

-- {номер статы на сервере, названия приза...}
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
    uiShow(D_Z, "FH | Занять", table.concat(t, "\n"), "Занять", "Закрыть", 2)
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

----------------------------------------------------------------------
-- ФРАКЦИИ: наборы, отборы на лидера, временные лидерки
----------------------------------------------------------------------
-- {ключ, название, id для /templeader, тип}
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

----------------------------------------------------------------------
-- ОБЪЯВЛЕНИЯ, ПАМЯТКИ И ПРОВЕРКИ
----------------------------------------------------------------------
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
-- быстрые наборы должностей
local CHK_PRESETS = {
    { "Руководство", { "io", "zo", "po", "ks", "zks" } },
    { "Следящие", { "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
    { "ГА и ЗГА", { "ga", "zga" } },
    { "Главные следящие", { "gsg", "gsgh", "gsm" } },
    { "ЗГС", { "zgsg", "zgsgh", "zgsm" } },
    { "ПГС", { "pgsg", "pgsgh", "pgsm" } },
    { "Все", { "io", "zo", "po", "ks", "zks", "ga", "zga", "gsg", "gsgh", "gsm", "zgsg", "zgsgh", "zgsm", "pgsg", "pgsgh", "pgsm" } },
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
    local answer = (word == "1") and "цифру 1" or ("слово «" .. word .. "»")
    local tail = secs > 0 and (" Время: " .. math.floor(secs) .. " сек.") or ""
    local lines = { "/a Проверка активности администрации!" }
    if sel and #sel > 0 then
        -- строки собираем по длине в символах (сервер режет сообщение на 128 байтах)
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

-- конец проверки; announce - сообщить итог в /a
local function chkEnd(announce)
    if not CHK.active then fmsg("Проверка не запущена.") return end
    CHK.active = false
    CHK.token = CHK.token + 1
    if CHK.thread then pcall(function() CHK.thread:terminate() end) CHK.thread = nil end
    fmsg(string.format("Проверка закончена. Отметились: %d (список: /chkres).", #CHK.list))
    if announce then safeSend(string.format("/a Проверка активности завершена. Отметились: %d.", #CHK.list)) end
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
-- удаление админ-каров всегда с предупреждением в /a и таймером 15 с
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
        fmsg("Кодировка: " .. (enc8 and "библиотека encoding" or "запасная (encoding не найдена)"))
        fmsg("Окно /fh: " .. (g and (g.disabled and "отключено из-за ошибок" or g.init and "не запустилось" or "готово") or "недоступно (нет mimgui)"))
        fmsg("Уведомление о репорте: " .. (not cfg.reptoast and "выключено в настройках" or (g and g.off) and ("сломалось: " .. tostring(g.err)) or "включено") ..
            ". Репортов получено: " .. #reports)
    end)
    reg("reptest", function(p)
        local text = trim(p or "")
        if text == "" then text = "Тестовый репорт: проверка уведомления" end
        local shown = false
        pcall(function() if guiState and guiState.ready() then shown = guiState.reportToast({ name = "Test_Player", id = "7", text = text }) end end)
        fmsg(shown and "Тестовое уведомление запущено." or "Уведомление не показано. Подробности: /fhdiag")
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

----------------------------------------------------------------------
-- ГЛАВНОЕ МЕНЮ /fh
----------------------------------------------------------------------
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
    { "#", "Раздачи" },
    { "/gw слово | приз", "запустить раздачу (банк 500000, лвл 3, #9 15)" },
    { "/gwlast слово | приз", "финальный раунд, сам закроет раздачу" },
    { "/gwstop", "отменить раздачу" },
    { "#", "Репорты" },
    { "/reports", "последние 15 репортов, быстрый ответ" },
    { "/rpl", "обновить список репортов из /define" },
    { "/rr [ID] текст", "ответить игроку через /pm" },
    { "/reptest  /fhdiag", "проверка овального уведомления о репорте; диагностика кодировки и окна" },
    { "/fhgui [on|off]", "окно /fh или безопасный режим (диалоги и чат)" },
    { "/fhupd [install]", "проверка обновлений на GitHub; install - скачать и установить" },
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

----------------------------------------------------------------------
-- ОКНО MIMGUI: /fh -- меню слева, страницы справа
-- Если mimgui/шрифт с кириллицей недоступны, /fh откроет обычное диалоговое окно.
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
        imgui.TextColored(color or ACC, U(s))
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
            elseif q == "" or (r.l or (function() r.l = lower1251(r[1] .. " " .. r[2]) return r.l end)()):find(q, 1, true) then
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
        if imgui.Button(U("Обновить из /define") .. "##rpl", V2(fs * 12, fs * 1.8)) then post(function() DEF.refresh() end) end
        imgui.SameLine() hint("Список берётся из команды /define (диалог не показывается).")
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
                imgui.Spacing()
                imgui.PushItemWidth(-1) imgui.InputTextWithHint("##rpreason", U("Причина наказания (обязательно)"), B.modTxt, 160) imgui.PopItemWidth()
                for _, pa in ipairs({ { "Варн", "/warn" }, { "Мут", "/mute" }, { "Джайл", "/jail" }, { "Бан", "/ban" } }) do
                    if imgui.Button(U(pa[1]) .. "##rp" .. pa[2], V2(fs * 6, fs * 2)) then
                        local rtx = trim(getBuf(B.modTxt))
                        if rtx == "" then G.modMsg = "Укажите причину в поле выше."
                        else
                            local line = pa[2] .. " " .. r.id .. " " .. rtx
                            G.modMsg = "Отправлено: " .. line
                            post(function() safeSend(line) end)
                        end
                    end
                    imgui.SameLine()
                end
                imgui.NewLine()
                if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
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
        if UPD.latest and verNewer(UPD.latest, VERSION) then
            imgui.BeginChild("##updbanner", V2(0, fs * 3.2), true)
            imgui.TextColored(YEL, toUi("Доступно обновление v" .. UPD.latest .. " (у вас v" .. VERSION .. ")"))
            if UPD.notes ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.notes)) end
            if primary("Установить обновление##updinst", V2(fs * 14, fs * 1.6)) then post(UPD.install) end
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
        local names = selNames()
        local key = table.concat(names, "|") .. "#" .. word .. "#" .. secs
        if G.chkKey ~= key then G.chkKey, G.chkPreview = key, (chkLines(names, word, secs)) end
        for _, l in ipairs(G.chkPreview) do imgui.TextWrapped(U(l)) end
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

    pages[14] = { "ИИ", function()
        title("ИИ-помощник")
        hint("Спросите что угодно: правила, формулировки, ответ игроку. Ответ появится ниже.")
        imgui.InputTextMultiline("##aichat", B.aiChat, 600, V2(-1, fs * 4))
        local bw = V2(fs * 11, fs * 2)
        if primary("Спросить##aiask", bw) then
            local q = trim(getBuf(B.aiChat))
            if q == "" then G.aiMsg = "Напишите вопрос."
            elseif not AI.ready() then G.aiMsg = "Сначала заполните адрес и ключ API в Настройках."
            else
                G.aiMsg = "Думаю..."
                post(function()
                    AI.ask("Ты помощник администратора SA-MP сервера. Отвечай кратко, по-русски.", q, function(ok, text)
                        G.aiMsg = ok and tostring(text) or ("Ошибка: " .. tostring(text))
                    end)
                end)
            end
        end
        imgui.SameLine()
        if imgui.Button(U("Очистить") .. "##aiclr", bw) then ffi.copy(B.aiChat, "") G.aiMsg = nil end
        imgui.BeginChild("##aians", V2(0, fs * 8), true)
        imgui.TextWrapped(U(G.aiMsg or "Ответ появится здесь."))
        imgui.EndChild()
    end }

    pages[15] = { "Модерация", function()
        title("Модерация")
        hint("Укажите ID или ник и текст (причину). Кнопки отправляют команду сразу, как при вводе в чат.")
        imgui.Text(U("ID / ник")) imgui.SameLine()
        imgui.PushItemWidth(fs * 12) imgui.InputText("##modid", B.modId, 48) imgui.PopItemWidth()
        imgui.SameLine() imgui.Text(U("Текст")) imgui.SameLine()
        imgui.PushItemWidth(-1) imgui.InputText("##modtxt", B.modTxt, 160) imgui.PopItemWidth()
        local mid, mtx = trim(getBuf(B.modId)), trim(getBuf(B.modTxt))
        local bw = V2(fs * 9, fs * 2)
        local ACT = {
            { "Гетто", "/ghetto", false },
            { "Склад", "/warehouse", false },
            { "Цвет банды", "/gzcolor", "text" },
            { "Варн", "/warn", "idtext" },
            { "Анварн", "/unwarn", "id" },
            { "Мут", "/mute", "idtext" },
            { "Размут", "/unmute", "id" },
            { "Джайл", "/jail", "idtext" },
            { "Из джайла", "/unjail", "id" },
            { "Бан", "/ban", "idtext" },
            { "Разбан", "/unban", "id" },
            { "Статистика", "/getstats", "id" },
            { "Инвентарь", "/checkinv", "id" },
        }
        for i, a in ipairs(ACT) do
            if imgui.Button(U(a[1]) .. "##mod" .. i, bw) then
                local need = a[3]
                if (need == "id" or need == "idtext") and mid == "" then
                    G.modMsg = "Укажите ID или ник."
                elseif (need == "text" or need == "idtext") and mtx == "" then
                    G.modMsg = "Заполните поле «Текст»."
                else
                    local parts = { a[2] }
                    if need == "id" or need == "idtext" then parts[#parts + 1] = mid end
                    if need == "text" or need == "idtext" then parts[#parts + 1] = mtx end
                    local line = table.concat(parts, " ")
                    G.modMsg = "Отправлено: " .. line
                    post(function() safeSend(line) end)
                end
            end
            if i % 4 ~= 0 and i < #ACT then imgui.SameLine() end
        end
        imgui.Spacing()
        if G.modMsg then imgui.TextColored(GRAY, U(G.modMsg)) end
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
        if imgui.Checkbox(U("Сообщение в чат о новом репорте"), repBuf) then
            cfg.reptoast = repBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Checkbox(U("Проверять обновления при запуске"), updBuf) then
            cfg.autoupd = updBuf[0] and true or false
            post(saveCfg)
        end
        if imgui.Button(U("Проверить обновления сейчас") .. "##updnow", V2(fs * 14, fs * 2)) then post(function() UPD.check(false) end) end
        if UPD.status ~= "" then imgui.SameLine() imgui.TextColored(GRAY, toUi(UPD.status)) end
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
            imgui.TextColored(GRAY, U("by ByFilipp  ·  v" .. VERSION))
            imgui.Separator() imgui.Spacing()
            -- группы меню; настройки всегда в самом низу
            local groups = {
                { "ГЛАВНОЕ", { "Главная", "Репорты", "Проверка", "Мероприятия", "Раздачи" } },
                { "АДМИНИСТРИРОВАНИЕ", { "Занять", "Фракции", "Транспорт", "Памятки" } },
                { "МОДЕРАЦИЯ", { "Модерация" } },
                { "ИНСТРУМЕНТЫ", { "ИИ", "Биндер", "Шпаргалки", "Команды" } },
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
            st.WindowRounding, st.ChildRounding, st.FrameRounding, st.GrabRounding, st.ScrollbarRounding = 10, 8, 6, 6, 8
            st.WindowBorderSize, st.ChildBorderSize, st.FrameBorderSize = 1, 1, 0
            set("WindowBg", br, bg_, bb, cfg.alpha)
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

    imgui.OnInitialize(function()
        local ok, err = pcall(function()
            local io = imgui.GetIO()
            io.Fonts:AddFontFromFileTTF(fontPath, fs, nil, io.Fonts:GetGlyphRangesCyrillic())
            -- второй (большой) шрифт не создаём: лишний атлас шрифтов ронял игру на слабых ПК; крупный текст делаем масштабом
            applyStyle()
        end)
        if not ok then G.initFailed = true print("[FH] gui init error: " .. tostring(err)) end
    end)

    function G.reportToast() return false end

    function G.diag()
        return { toast = cfg.reptoast, off = G.noRepToast, err = G.repErr, disabled = G.disabled, init = G.initFailed }
    end

    imgui.OnFrame(function()
        local on = G.show[0] and not G.disabled and not G.initFailed and guiAllowed()
        G.mainOn = on and true or false
        GUARD.set(G.mainOn or G.toastOn == true)
        if not on then G.t0 = nil end
        return on
    end, function(self)
        self.HideCursor = false
        imgui.SetNextWindowSize(V2(fs * 50, fs * 30), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
        if imgui.Begin("FilippHelper##fh", G.show, imgui.WindowFlags.NoCollapse) then
            guarded(drawBody)
        end
        imgui.End()
    end)

    function G.ready() return not G.disabled and not G.initFailed and guiAllowed() end
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
    if not text:find("Репорт", 1, true) then return end

    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, body = clean:match("Репорт от ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not name then return end
    body = body:gsub("%s*|%s*Уже%s*%d+%s*репорт[^|]*$", "")

    table.insert(reports, 1, { name = name, id = id, text = body })
    if cfg.reptoast then
        fmsg("{FFFF00}Репорт от " .. name .. "[" .. id .. "]: {FFFFFF}" .. body)
    end
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
    reg("cb", function(p) if trim(p or "") ~= "" then safeSend("/warehouse " .. trim(p)) else fmsg("Укажите параметры: /cb [текст]") end end)
    reg("gc", function(p) if trim(p or "") ~= "" then safeSend("/gzcolor " .. trim(p)) else fmsg("Укажите параметры: /gc [цвет]") end end)
    reg("sprod", function(p)
        local a, b = (p or ""):match("(%d+)%s+(%d+)")
        if a then safeSend("/setbizprod " .. a .. " " .. b) else fmsg("Использование: /sprod [ID бизнеса] [число]") end
    end)
    reg("wn", function(p)
        p = trim(p or "")
        if p:match("^%d+%s+%S") then safeSend("/warn " .. p)
        else fmsg("Использование: /wn [ID] [причина]") end
    end)
    -- команды с ID: вставляют команду в строку чата (как у Бруно, но ID по умолчанию из /re)
    local function regId(cmd, sCmd, input)
        reg(cmd, function(p)
            local id = tgt(p)
            if not id then fmsg("Укажите ID: /" .. cmd .. " ID (или сначала /re ID)") return end
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
            if p ~= "" then safeSend("/" .. sCmd .. " " .. p) else fmsg("Использование: /" .. cmd .. " [ID или ник]") end
        end)
    end
    regArg("uwn", "unwarn") regArg("ujl", "unjail") regArg("um", "unmute") regArg("bn", "ban") regArg("ubn", "unban")
    -- таймер удаления и респавна транспорта
    reg("sc", function()
        if scThread then pcall(function() scThread:terminate() end) end
        scThread = lua_thread.create(function()
            safeSend("/a Внимание, через 15 секунд удаляю и респавню весь транспорт на сервере!")
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
            fmsg("Таймер респавна транспорта остановлен.")
        else fmsg("Таймер респавна транспорта не запущен.") end
    end)
end

local function registerCommands(reg)
    registerExtra(reg)
    registerPorted(reg)
    reg("fh", function()
        if guiState and guiState.ready() then guiState.toggle()
        else
            if not guiAllowed() and not GUARD.warned then
                GUARD.warned = true
                fmsg("Окно /fh отключено (безопасный режим или конфликт с другим imgui), открываю меню диалогами. Включить окно: /fhgui on")
            end
            uiMenu()
        end
    end)
    reg("fhgui", function(p)
        p = lower1251(trim(p or ""))
        if p == "on" then
            cfg.safe, cfg.force, GUARD.warned = false, true, false
            saveCfg()
            fmsg("Окно /fh включено. Если игра снова вылетит на окне, безопасный режим включится сам.")
        elseif p == "off" then
            cfg.safe = true
            saveCfg()
            fmsg("Безопасный режим: вместо окна /fh диалоги и чат. Вернуть окно: /fhgui on")
        else
            fmsg("Окно /fh: " .. (guiAllowed() and "включено" or "выключено (безопасный режим или конфликт imgui)") .. ". Команды: /fhgui on | off")
        end
    end)
    reg("reports", uiReports)
    reg("rpl", function() DEF.refresh() end)
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

    -- Защитные обёртки: обрезка длины, pcall -- команды и диалоги не должны ронять игру
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

    -- всё, что трогает чат и SAMP, - только когда игра подключена к серверу
    if sampGetGamestate then
        while true do
            local okG, gs = pcall(sampGetGamestate)
            if not okG or gs == 3 then break end
            wait(250)
        end
    end
    wait(1500)
    fmsg("{FFD700}FilippHelper v" .. VERSION .. " {FFFFFF}- загружен")
    if GUARD.notice then
        fmsg("{FF6666}Прошлый запуск закрылся на окне /fh. Включён безопасный режим: вместо окна диалоги и чат. Вернуть окно: /fhgui on")
    end
    fmsg("{A9A9A9}Автор и разработчик: {66CCFF}ByFilipp {A9A9A9}| при участии {66CCFF}Claude {A9A9A9}(Anthropic)")
    fmsg("{A9A9A9}Раздачи, репорты, мероприятия, проверка активности, транспорт, биндер и ИИ-ответы - в одном окне")
    fmsg("{A9A9A9}Окно управления: {FFFF00}/fh {A9A9A9}| все команды: {FFFF00}/fcmd {A9A9A9}| биндер: {FFFF00}/fbind")
    fmsg("{A9A9A9}Обновления: {FFFF00}/fhupd {A9A9A9}| диагностика: {FFFF00}/fhdiag {A9A9A9}| проверка уведомления: {FFFF00}/reptest")
    fmsg("{A9A9A9}Поддержка и вопросы: {FFFF00}@ByFilipp123 {A9A9A9}- приятной игры!")
    if cfg.autoupd then
        lua_thread.create(function()
            wait(15000)   -- не мешаем загрузке игры
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

function onScriptTerminate(scr, quitGame)
    local ok, me = pcall(thisScript)
    if ok and scr == me then GUARD.set(false) end
end
