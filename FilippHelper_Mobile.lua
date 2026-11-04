-- FilippHelper (FH) -- помощник администратора SA-MP для MoonLoader. Автор: ByFilipp.
-- Версия для MonetLoader (Android), файл в UTF-8.
local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

-- @ENC: MonetLoader -- файл в UTF-8, игра ждёт CP1251; перекодируем на границе
local encOk, encoding = pcall(require, 'encoding')
local enc8
if encOk and encoding then
    encoding.default = 'CP1251'
    enc8 = encoding.UTF8
end
local function toGame(s) if enc8 then return enc8:decode(s) end return s end
local function fromGame(s) if enc8 then return enc8:encode(s) end return s end

local VERSION = "1.0"
local MAX_CHAT_LEN = 128   -- безопасная длина строки для sampSendChat
local SEND_GAP = 1100      -- пауза между сообщениями (антифлуд сервера)
local MAX_REPORTS = 15

local watchedId = nil   -- ID игрока из /re
local reports = {}            -- последние репорты, новые в начале

----------------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
----------------------------------------------------------------------
local function lowerCyr(c)
    local b2 = c:byte(2)
    if c:byte(1) == 208 then
        if b2 == 129 then return "\209\145" end
        if b2 >= 144 and b2 <= 159 then return "\208" .. string.char(b2 + 32) end
        if b2 >= 160 and b2 <= 175 then return "\209" .. string.char(b2 - 32) end
    end
    return c
end
local function lower1251(s) return (s:lower():gsub("\208[\129\144-\175]", lowerCyr)) end

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function safeSend(text)
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
-- РЕПОРТЫ: журнал последних обращений и быстрый ответ
----------------------------------------------------------------------
local D_MENU, D_RLIST, D_RREPLY, D_GWSTART = 4120, 4121, 4122, 4123

local function replyTo(id, text)
    text = trim(text or "")
    if text == "" then return false end
    safeSend(string.format("/pm %s %s", id, text))
    return true
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

uiHandlers[D_RLIST] = function(button, list)
    if button == 0 then return end
    local r = reports[list + 1]
    if not r then return uiReports() end
    ui.replyId = r.id
    uiShow(D_RREPLY, "Ответ игроку " .. r.name .. "[" .. r.id .. "]",
        "Жалоба: " .. r.text .. "\n\nВведите ответ (уйдёт через /pm):", "Отправить", "Назад", 1)
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
-- МЕРОПРИЯТИЯ: готовые анонсы в /aad
----------------------------------------------------------------------
local D_EV, D_FR, D_FRACT, D_NOTES, D_NOTE, D_NOTEADD = 4140, 4141, 4142, 4144, 4145, 4146

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
    local id = (arg ~= nil and arg:match("^%d+$")) or watchedId
    local lines = { string.format("/aad [МП] Внимание, игроки! Скоро стартует мероприятие «%s».", e[2]) }
    for k = 3, #e do
        local line = e[k]
        if line:find("{id}", 1, true) then
            if not id then fmsg("Нужен ID ведущего: /ev " .. e[1] .. " ID") return end
            line = line:gsub("{id}", id)
        end
        lines[#lines + 1] = "/aad [МП] " .. line
    end
    sendSeq(lines, SEND_GAP)
end

local function uiEvents()
    local t = {}
    for i, e in ipairs(EVENTS) do t[i] = string.format("{FFFFFF}%s {A9A9A9}(/ev %s)", e[2], e[1]) end
    uiShow(D_EV, "FH | Мероприятия", table.concat(t, "\n"), "Объявить", "Закрыть", 2)
end

uiHandlers[D_EV] = function(button, list)
    if button == 0 then return end
    local e = EVENTS[list + 1]
    if e then announceEvent(e) end
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
        sampSetChatInputText("/mp ") sampSetChatInputEnabled(true)
    end)
end

local function tryoutO(f)
    sendSeq({
        "/o [Отбор] Идёт отбор на пост лидера: " .. f[2] .. ".",
        "/o [Отбор] Нужно: 13+, связь ВК, знание " .. RULES_BY_KIND[f[4]] .. ".",
        "/o [Отбор] Желающие - пишите /gomp.",
    }, 2500)
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
    { "jj", "jail", "idin" }, { "mm", "mute", "idin" }, { "ww", "warn", "idin" }, { "bb", "ban", "args" },
    { "uw", "unwarn", "args" }, { "uj", "unjail", "args" }, { "unm", "unmute", "args" }, { "ub", "unban", "args" },
    { "ib", "iban", "args" }, { "ip", "pgetip", "args" }, { "bip", "banip", "args" },
    { "ofl", "offleader", "args" }, { "mkl", "makeleader", "args" },
    { "fuel", "fuelcars", "none" }, { "gh", "ghetto", "none" }, { "gzc", "gzcolor", "args" },
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

local vrThread
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
    byKey("nab", recruit) byKey("otb", tryoutAad) byKey("otbo", tryoutO) byKey("lead", tempLeader)
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

    reg("ar", function(p)
        local id = p:match("^(%d+)") or watchedId
        if not id then fmsg("Использование: /ar ID") return end
        local text
        for _, r in ipairs(reports) do if r.id == id then text = r.text break end end
        local name = "ID " .. id
        for _, r in ipairs(reports) do if r.id == id then name = r.name .. "[" .. id .. "]" break end end
        sendSeq({
            string.format("/pm %s Здравствуйте, ваша жалоба принята, передаю её администрации.", id),
            "/a Коллеги, отвечаем на репорт!",
            string.format("/a %s | Жалоба: %s", name, text or "текст не найден, смотрите /report"),
        }, SEND_GAP)
    end)

    reg("vr", function()
        if vrThread then fmsg("Таймер уже идёт (остановить: /vrstop).") return end
        vrThread = lua_thread.create(function()
            pcall(function()
                safeSend("/a Через 15 секунд весь транспорт на сервере будет удалён и возвращён на места!")
                wait(15000)
                safeSend("/dvall") wait(1500)
                safeSend("/spawncars")
            end)
            vrThread = nil
        end)
    end)
    reg("vrstop", function()
        if vrThread then
            pcall(function() vrThread:terminate() end)
            vrThread = nil
            fmsg("Таймер респавна остановлен.")
        else fmsg("Таймер не запущен.") end
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
      "{66CCFF}/ev ключ {FFFFFF}- сразу объявить (например /ev svet). Для «infern»: /ev infern ID\n\n" ..
      "{A9A9A9}Ключи: svet poliv derbi pryat parkur rulet kovsh myaso dogon car parash digl sultan paint krug infern" },
    { "Фракции",
      "{66CCFF}/fr {FFFFFF}- окно фракций: набор, отбор, временная лидерка\n" ..
      "{66CCFF}/nab ключ {FFFFFF}- набор в /o\n" ..
      "{66CCFF}/otb ключ {FFFFFF}- отбор на лидера в /aad (потом откроется ввод /mp)\n" ..
      "{66CCFF}/otbo ключ {FFFFFF}- отбор на лидера в /o\n" ..
      "{66CCFF}/lead ключ {FFFFFF}- взять временную лидерку (/templeader)\n\n" ..
      "{A9A9A9}Ключи: rus jap ita fun out rif bal azt gro vag arm hos mer rad swt gov lsp fbi rcp sud" },
    { "Наказания",
      "{FFFFFF}Вставляют команду с ID в строку ввода: {66CCFF}/jj /mm /ww {A9A9A9}(jail, mute, warn)\n" ..
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
local MENU_ROWS = {
    { "#", "Раздачи" },
    { "/gw слово | приз", "запустить раздачу (банк 500000, лвл 3, #9 15)" },
    { "/gwlast слово | приз", "финальный раунд, сам закроет раздачу" },
    { "/gwstop", "отменить раздачу" },
    { "#", "Репорты" },
    { "/reports", "последние 15 репортов, быстрый ответ" },
    { "/rr [ID] текст", "ответить игроку через /pm" },
    { "/ar ID", "ответ + текст жалобы в /a" },
    { "#", "Мероприятия и опросы" },
    { "/ev [ключ] [ID]", "анонс МП в /aad (список: /ev)" },
    { "/poll должность ник", "опрос об оценке работы админа" },
    { "#", "Фракции" },
    { "/fr", "окно: набор, отбор, лидерка" },
    { "/nab /otb /otbo /lead ключ", "набор /o, отбор /aad, отбор /o, лидерка" },
    { "#", "Наказания" },
    { "/jj /mm /ww [ID]", "jail, mute, warn - вставят команду в ввод" },
    { "/bb /uw /uj /unm /ub", "ban, unwarn, unjail, unmute, unban" },
    { "/ib /ip /bip /ofl /mkl", "iban, pgetip, banip, offleader, makeleader" },
    { "/gs /inv [ID]", "getstats, checkinv (ID или из /re)" },
    { "/fuel /gh /wh /gzc /bp", "fuelcars, ghetto, warehouse, gzcolor, setbizprod" },
    { "#", "Прочее" },
    { "/vr  /vrstop", "респавн транспорта через 15 сек / отмена" },
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
-- ОБРАБОТКА СООБЩЕНИЙ СЕРВЕРА
----------------------------------------------------------------------
local function onServerMessageImpl(color, text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
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

function ev.onServerMessage(color, text)
    local ok, err = pcall(onServerMessageImpl, color, text)
    if not ok then print("[FH] onServerMessage error: " .. tostring(err)) end
end

function ev.onSendCommand(command)
    if type(command) ~= "string" then return end
    local id = command:match("^/re%s+(%d+)")
    if id then watchedId = id
    elseif command:match("^/re%s+off") or command:match("^/reoff") then watchedId = nil end
end

----------------------------------------------------------------------
-- ЗАПУСК
----------------------------------------------------------------------
local function registerCommands(reg)
    registerExtra(reg)
    reg("fh", uiMenu)
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

    fmsg("Загружен. Меню: {FFFF00}/fh")

    while true do
        wait(100)
        local okT, errT = pcall(uiTick)
        if not okT then print("[FH] tick error: " .. tostring(errT)) end
    end
end
