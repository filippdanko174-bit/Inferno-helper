-- FilippHelper (FH) 2.0 -- помощник администратора SA-MP. Автор: ByFilipp.
-- Написан заново по функционалу. Один мастер-файл: ПК (cp1251) и Android (UTF-8).
pcall(function() script_name("FilippHelper") script_author("ByFilipp") end)

local MOBILE = true   --@MOBILE
local VERSION = "2.0"
local UPDATE_FILE = "FilippHelper_Mobile.lua"   --@UPDFILE
local REPO_RAW = "https://raw.githubusercontent.com/filippdanko174-bit/Inferno-helper/main/"

local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

-- Всё состояние держим в одной таблице: меньше локальных переменных и upvalue (лимиты LuaJIT).
local FH = {
    cfg = { automp = false, reptoast = true, safe = false, force = false, accent = { 0.20, 0.55, 0.95 }, bg = { 0.07, 0.08, 0.10 }, alpha = 0.96,
            aiUrl = "", aiKey = "", aiModel = "", aiPrompt = "Ты помощник администратора SA-MP. Ответь игроку коротко и вежливо на русском." },
    reports = {}, templates = {}, notes = {}, binds = {},
    watched = nil,            -- ID из /re
    cmds = {},                -- имя -> функция(аргумент)
    ready = false,            -- true после входа на сервер
    queue = {}, qthread = nil,
    gw = { active = false }, chk = { active = false, list = {}, seen = {}, word = "1", token = 0 },
    ui = {},
}
local C = FH.cfg

----------------------------------------------------------------------
-- КОДИРОВКИ. Внутри скрипта: ПК - cp1251, Android - UTF-8.
-- toGame/fromGame: граница с игрой (cp1251). toUi/fromUi: граница с mimgui (UTF-8).
----------------------------------------------------------------------
local encOk, encoding = pcall(require, 'encoding')
local enc8
if encOk and encoding then encoding.default = 'CP1251' enc8 = encoding.UTF8 end

local function cpchr(cp)
    if cp < 0x80 then return string.char(cp) elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
local EXTRA = { [0x401] = 0xA8, [0x451] = 0xB8, [0x2116] = 0xB9, [0xAB] = 0xAB, [0xBB] = 0xBB, [0x2014] = 0x97, [0x2013] = 0x96, [0x2026] = 0x85,
    [0xB0] = 0xB0, [0xB1] = 0xB1, [0xB7] = 0xB7, [0x2022] = 0x95, [0x201C] = 0x93, [0x201D] = 0x94, [0x2018] = 0x91, [0x2019] = 0x92, [0xA0] = 0xA0 }
local B2U = {}
for cp = 0x410, 0x44F do B2U[cp - 0x410 + 0xC0] = cp end
for cp, b in pairs(EXTRA) do B2U[b] = cp end
local function u8to1251(s)
    return (s:gsub("[\192-\247][\128-\191]*", function(ch)
        local b1, b2, b3 = ch:byte(1, 3)
        local cp
        if b1 < 0xE0 then cp = (b1 - 0xC0) * 64 + (b2 - 0x80) elseif b1 < 0xF0 and b3 then cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80) end
        if not cp then return "?" end
        if cp >= 0x410 and cp <= 0x44F then return string.char(cp - 0x410 + 0xC0) end
        for c2, b in pairs(EXTRA) do if c2 == cp then return string.char(b) end end
        return "?"
    end))
end
local function c1251to8(s) return (s:gsub("[\128-\255]", function(c) return cpchr(B2U[c:byte()] or 0x3F) end)) end

local toGame, fromGame, toUi, fromUi
if MOBILE then
    toGame = function(s) if enc8 then return enc8:decode(s) end return u8to1251(s) end
    fromGame = function(s) if enc8 then return enc8:encode(s) end return c1251to8(s) end
    toUi, fromUi = function(s) return s end, function(s) return s end
else
    toGame, fromGame = function(s) return s end, function(s) return s end
    toUi = function(s) if enc8 then return enc8:encode(s) end return c1251to8(s) end
    fromUi = function(s) if enc8 then return enc8:decode(s) end return u8to1251(s) end
end

local LMAP = {}
for b = 192, 223 do LMAP[string.char(b)] = string.char(b + 32) end
LMAP[string.char(168)] = string.char(184)
local function lower(s)   -- нижний регистр с кириллицей (в кодировке скрипта)
    s = tostring(s or "")
    if MOBILE then return fromGame((toGame(s):lower():gsub("[\192-\223\168]", LMAP))) end
    return (s:lower():gsub("[\192-\223\168]", LMAP))
end
local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end
local function ulen(s) if MOBILE then return #s - select(2, s:gsub("[\128-\191]", "")) end return #s end

----------------------------------------------------------------------
-- ВЫВОД И ОТПРАВКА. Каждый вызов SAMP-функции защищён; из хуков мы ничего в игру не шлём.
----------------------------------------------------------------------
local function log(s) pcall(print, "[FH] " .. tostring(s)) end
local function chatAdd(text, color)
    if not FH.ready then return end
    text = toGame(tostring(text or ""))
    if #text > 140 then text = text:sub(1, 140) end
    pcall(sampAddChatMessage, text, color or -1)
end
local function fmsg(text) chatAdd("{66CCFF}[FH] {FFFFFF}" .. tostring(text), -1) end

local MAX_LEN, GAP = 128, 1100
local function rawSend(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" or not FH.ready then return end
    if #text > MAX_LEN then text = text:sub(1, MAX_LEN) end
    local ok, err = pcall(sampSendChat, text)
    if not ok then log("send error: " .. tostring(err)) end
end

-- Единая очередь исходящих: один рабочий поток, строки идут строго по порядку с паузой.
-- item = { text } | { fn = функция } | { wait = мс }
local function pump()
    if FH.qthread then return end
    FH.qthread = lua_thread.create(function()
        while #FH.queue > 0 do
            local it = table.remove(FH.queue, 1)
            -- пауза считается от предыдущей отправки (антифлуд сервера)
            local need = (FH.lastGap or 0) - (os.clock() - (FH.lastSend or -1000)) * 1000
            if need > 0 then wait(math.floor(need)) end
            local ok, err = pcall(function()
                if it.fn then it.fn() elseif it.text then rawSend(it.text) end
            end)
            if not ok then log("queue error: " .. tostring(err)) end
            FH.lastSend, FH.lastGap = os.clock(), it.wait or GAP
        end
        FH.qthread = nil
    end)
end
local function say(text, gap) FH.queue[#FH.queue + 1] = { text = text, wait = gap } pump() end
local function sayAll(lines, gap, after)
    for i, l in ipairs(lines) do say(l, gap) end
    if after then FH.queue[#FH.queue + 1] = { fn = after, wait = 50 } pump() end
end
local function sayNow(text) rawSend(text) end   -- одиночная команда, минуя очередь
local function stopQueue() FH.queue = {} end

local function setInput(text)
    if not FH.ready then return end
    pcall(sampSetChatInputText, toGame(text))
    pcall(sampSetChatInputEnabled, true)
end

----------------------------------------------------------------------
-- КОНФИГ И ФАЙЛЫ (config/FilippHelper_*.txt)
----------------------------------------------------------------------
local function cfgDir()
    local d = getWorkingDirectory() .. "/config"
    pcall(createDirectory, d)
    return d
end
local function readLines(name)
    local out = {}
    local f = io.open(cfgDir() .. "/" .. name, "rb")
    if not f then return out end
    for l in f:lines() do out[#out + 1] = (l:gsub("\r$", "")) end
    f:close()
    return out
end
local function writeLines(name, lines)
    local ok = pcall(function()
        local f = assert(io.open(cfgDir() .. "/" .. name, "wb"))
        for _, l in ipairs(lines) do f:write(l, "\r\n") end
        f:close()
    end)
    return ok
end

local NUMK = { alpha = true }
local function saveCfg()
    local L = { "automp=" .. (C.automp and "1" or "0"), "reptoast=" .. (C.reptoast and "1" or "0"), "safe=" .. (C.safe and "1" or "0"),
        "force=" .. (C.force and "1" or "0"), "alpha=" .. C.alpha,
        "accent=" .. table.concat(C.accent, ","), "bg=" .. table.concat(C.bg, ","),
        "aiUrl=" .. C.aiUrl, "aiKey=" .. C.aiKey, "aiModel=" .. C.aiModel, "aiPrompt=" .. C.aiPrompt:gsub("[\r\n]", " ") }
    writeLines("FilippHelper_settings.txt", L)
end
local function loadCfg()
    for _, l in ipairs(readLines("FilippHelper_settings.txt")) do
        local k, v = l:match("^([%w_]+)=(.*)$")
        if k then
            if k == "automp" or k == "reptoast" or k == "safe" or k == "force" then C[k] = (v == "1")
            elseif k == "alpha" then C.alpha = math.max(0.3, math.min(1, tonumber(v) or 0.96))
            elseif k == "accent" or k == "bg" then
                local a, b, c = v:match("([%d%.]+),([%d%.]+),([%d%.]+)")
                if a then C[k] = { tonumber(a), tonumber(b), tonumber(c) } end
            elseif k:sub(1, 2) == "ai" and C[k] ~= nil then C[k] = v end
        end
    end
end

-- ТЕКСТЫ ПАМЯТОК И ДОЛЖНОСТИ
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
local VOPROS = {
    { "Что такое ЧП?", "ЧП - час пик, обязательное время онлайна лидеров." },
    { "Какая норма онлайна у лидера в будни?", "В будни норма - 1 час." },
    { "Какая норма онлайна у лидера в выходные?", "В выходные норма - 1 час 30 минут." },
    { "Что обязан делать лидер фракции?", "Следить за фракцией, форумом и составом." },
    { "Что такое блат?", "Блат - выдача высокой должности без отчётов и обзвона." },
    { "Со скольки до скольки ЧП в будни?", "В будни ЧП с 17:00 до 20:00." },
    { "Со скольки до скольки ЧП в выходные?", "В выходные ЧП с 16:00 до 19:00." },
}
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


----------------------------------------------------------------------
-- ДИАЛОГИ (свои окна SA-MP): показать и дождаться ответа опросом в потоке
----------------------------------------------------------------------
local DLG_BASE, dlgSeq = 4200, 0
local function dialog(title, text, b1, b2, style, cb)
    if not FH.ready then return end
    dlgSeq = dlgSeq % 40 + 1
    local id = DLG_BASE + dlgSeq
    local ok = pcall(sampShowDialog, id, toGame(title), toGame(text:sub(1, 3500)), toGame(b1 or "OK"), toGame(b2 or ""), style or 0)
    if not ok or not cb then return end
    lua_thread.create(function()
        local t0 = os.clock()
        while os.clock() - t0 < 120 do
            wait(100)
            local has, done = pcall(sampHasDialogRespond, id)
            if has and done then
                local ok2, btn, list, input = pcall(sampGetDialogResponse, id)
                if ok2 then
                    local ok3, err = pcall(cb, btn, list, fromGame(input or ""))
                    if not ok3 then log("dialog cb: " .. tostring(err)) end
                end
                return
            end
        end
    end)
end
-- меню-список: items = { {название, функция}, ... }
local function menu(title, items, b1)
    local t = {}
    for i, it in ipairs(items) do t[i] = it[1] end
    dialog(title, table.concat(t, "\n"), b1 or "Выбрать", "Закрыть", 2, function(btn, list)
        if btn == 1 and items[list + 1] and items[list + 1][2] then items[list + 1][2]() end
    end)
end
local function ask(title, text, cb)   -- окно с вводом
    dialog(title, text, "OK", "Отмена", 1, function(btn, _, input) if btn == 1 then cb(trim(input)) end end)
end
local function info(title, text) dialog(title, text, "Закрыть", "", 0) end

----------------------------------------------------------------------
-- РЕПОРТЫ, ШАБЛОНЫ, ОТВЕТЫ
----------------------------------------------------------------------
local MAX_REPORTS = 15
local DEFAULT_TPL = {
    "Здравствуйте! Ваша жалоба принята, разбираемся.", "Передано на рассмотрение старшей администрации.",
    "Уточните, пожалуйста: ID нарушителя и что произошло.", "Нарушений не обнаружено.",
    "Игрок наказан, спасибо за обращение!", "С таким вопросом обратитесь на форум проекта.", "Приятной игры на нашем сервере!",
}
local function saveTpl() local L = {} for _, t in ipairs(FH.templates) do L[#L + 1] = "> " .. t end writeLines("FilippHelper_templates.txt", L) end
local function loadTpl()
    for _, l in ipairs(readLines("FilippHelper_templates.txt")) do
        if l:sub(1, 2) == "> " and #FH.templates < 30 then FH.templates[#FH.templates + 1] = l:sub(3, 202) end
    end
    if #FH.templates == 0 then for i, t in ipairs(DEFAULT_TPL) do FH.templates[i] = t end end
end

local function reply(id, text)
    text = trim(text)
    if not id or text == "" then return false end
    say(string.format("/pm %s %s", id, text))
    return true
end
local function reportById(id) for _, r in ipairs(FH.reports) do if r.id == id then return r end end end
local function targetId(p) return trim(p):match("^(%d+)") or FH.watched or (FH.reports[1] and FH.reports[1].id) end

local function addReport(name, id, text)
    table.insert(FH.reports, 1, { name = name, id = id, text = text })
    while #FH.reports > MAX_REPORTS do table.remove(FH.reports) end
end

-- список репортов из ответа /define
local DEF = { waiting = false, t0 = 0 }
local function defineParse(text)
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("{%x%x%x%x%x%x}", ""):gsub("[\t\r]", " ")
        local name, id, body = line:match("([A-Za-z][A-Za-z0-9_%.]*)%[(%d+)%]%s*[:%-%)]*%s*(.*)")
        if not name then name, id, body = line:match("([A-Za-z][A-Za-z0-9_%.]*)%s*%((%d+)%)%s*[:%-]*%s*(.*)") end
        if name and #list < MAX_REPORTS then list[#list + 1] = { name = name, id = id, text = trim(body) } end
    end
    return list
end
local function defineRefresh()
    if DEF.waiting then return end
    DEF.waiting, DEF.t0 = true, os.clock()
    say("/define")
    lua_thread.create(function()
        wait(5000)
        if DEF.waiting then DEF.waiting = false fmsg("/define не ответил (нет доступа или другой формат).") end
    end)
end

local function showReports()
    if #FH.reports == 0 then fmsg("Репортов пока нет.") return end
    local items = {}
    for i, r in ipairs(FH.reports) do
        items[i] = { string.format("{FFFF00}%s[%s] {FFFFFF}%s", r.name, r.id, r.text), function()
            ask("Ответ " .. r.name .. "[" .. r.id .. "]", "Текст ответа игроку:", function(t) if t ~= "" then reply(r.id, t) end end)
        end }
    end
    menu("FH | Репорты (клик - быстрый ответ)", items, "Ответить")
end

local function cmdAr(p)
    local id = trim(p):match("^(%d+)") or FH.watched
    if not id then fmsg("Использование: /ar ID") return end
    local r = reportById(id)
    sayAll({
        string.format("/pm %s Здравствуйте, ваша жалоба принята, передаю её администрации.", id),
        "/a Коллеги, отвечаем на репорт!",
        string.format("/a %s | Жалоба: %s", r and (r.name .. "[" .. id .. "]") or ("ID " .. id), r and r.text or "текст не найден, смотрите /report"),
    })
end

----------------------------------------------------------------------
-- РАЗДАЧА ПРИЗОВ: победитель - первый репорт с кодовым словом
----------------------------------------------------------------------
local GW_TAG = "[Раздача]"
local GW_IGNORE = { Admin = true, Utka_News = true }
local PRIZES = {   -- { номер статы, названия... }
    { 7, "bank", "банк", "деньги", "money", "руб" }, { 1, "lvl", "лвл", "уровень", "level" }, { 3, "mat", "мат" }, { 6, "exp", "опыт" },
    { 2, "закон" }, { 5, "sim", "сим", "номер" }, { 12, "box", "бокс" }, { 13, "kung", "кунг" }, { 14, "kick", "кик" },
}
local function parsePrize(spec)
    local word, rest = lower(spec):match("^(%S+)%s*(.*)$")
    if not word then return nil end
    local stat = tonumber(word:match("^#(%d+)$"))
    if not stat then
        for _, t in ipairs(PRIZES) do
            for k = 2, #t do if word:find(t[k], 1, true) == 1 then stat = t[1] break end end
            if stat then break end
        end
    end
    local num = rest:match("^%d[%d%.,]*%d") or rest:match("^%d+")
    if not stat or not num then return nil end
    return stat, (num:gsub("[%.,]", ""))
end
local function gwFinish(name, id)
    local g = FH.gw
    g.active = false
    local sec = math.max(1, math.floor(os.clock() - g.t0 + 0.5))
    local L = { string.format("/aad %s Победитель - %s! Время: %d сек.", GW_TAG, name, sec) }
    if g.stat then
        L[#L + 1] = string.format("/pm %s Поздравляю, вы первый! Приз сейчас будет выдан.", id)
        L[#L + 1] = string.format("/setstat %s %d %s", id, g.stat, g.amount)
        L[#L + 1] = string.format("/pm %s Приз выдан, приятной игры!", id)
    else
        FH.defer(function() fmsg(string.format("{FFFF00}Выдайте приз вручную: %s [%s] -> %s", name, id, g.prize)) end)
        L[#L + 1] = string.format("/pm %s Поздравляю, вы первый! Приз выдам в ближайшее время.", id)
    end
    if g.last then L[#L + 1] = "/aad " .. GW_TAG .. " Раздача завершена, спасибо всем за участие!" end
    sayAll(L)
end
local function gwStart(p, last)
    local word, prize = p:match("^(.-)%s*|%s*(.+)$")
    word, prize = trim(word), trim(prize)
    if word == "" or prize == "" then fmsg("Использование: /" .. (last and "gwlast" or "gw") .. " слово | приз  (например: /gw котик | банк 500000)") return end
    local g = FH.gw
    g.word, g.prize, g.last, g.t0, g.active = lower(word), prize, last, os.clock(), true
    g.stat, g.amount = parsePrize(prize)
    sayAll({ string.format("/aad %s %sПриз: %s", GW_TAG, last and "ФИНАЛ! " or "", prize),
             string.format("/aad %s Кто первым отправит в /rep слово «%s» - тот победил!", GW_TAG, word) })
    if g.stat then fmsg(string.format("Раздача запущена. Слово: {FFFF00}%s{FFFFFF}. Приз выдастся сам (стата %d, кол-во %s).", word, g.stat, g.amount))
    else fmsg(string.format("Раздача запущена. Слово: {FFFF00}%s{FFFFFF}. Тип приза не распознан - выдавать придётся вручную.", word)) end
end
local function gwIntro(p)
    local L = { "/aad [Раздача] Внимание, игроки! Сейчас пройдёт быстрая раздача призов.", "/aad [Раздача] Приготовьтесь писать кодовое слово в чат!" }
    if trim(p) ~= "" then L[#L + 1] = "/aad [Раздача] Приз: " .. trim(p) .. "." end
    sayAll(L)
end

----------------------------------------------------------------------
-- АВТО-/mp (по умолчанию выключено): после анонса вводит /mp и жмёт первую строку списка
----------------------------------------------------------------------
local AM = { armed = false, t0 = 0 }
local function armMp(force)
    if not force and not C.automp then return end
    AM.armed, AM.t0 = true, os.clock()
    say("/mp", 50)
end
local function afterAnnounce()   -- что делать в конце анонса МП/отбора
    if C.automp then armMp() else setInput("/mp ") end
end

----------------------------------------------------------------------
-- МЕРОПРИЯТИЯ
----------------------------------------------------------------------
-- { ключ, название, строки правил... }; {id} подставляется для интерактивных МП
local EVENTS = {
    { "svet", "Светофор", "Бежим к финишу на «Зелёный» и замираем на «Красный».", "Кто двинулся на красный - вылетает. Побеждает первый у финиша." },
    { "poliv", "Поливалка", "Нужно удержаться на крыше, пока вас поливают из БТР.", "Оружие и толчки запрещены. Побеждает последний оставшийся." },
    { "derbi", "Дерби", "Садимся в машины и таранитесь на арене.", "Побеждает тот, чья машина осталась на ходу последней." },
    { "pryat", "Прятки", "Прячьтесь от ведущего где угодно на локации.", "По команде можно пользоваться масками и анимациями. Кто найден - выбывает." },
    { "parkur", "Паркур", "Кто быстрее всех доберётся до вершины паркур-зоны?", "Без оружия, помех другим и багов." },
    { "rulet", "Русская рулетка", "Встаём в строй и по очереди пытаем удачу.", "Строй не нарушать, оружие и анимации не использовать." },
    { "kovsh", "Гонки от Ковша", "Игроки на квадроциклах уворачиваются от Гелика с ковшом.", "Баги, ремонт машин и стороннюю помощь использовать нельзя." },
    { "myaso", "Мясорубка", "Бегаем по локации и уходим от бензопилы ведущего.", "Без оружия, брони и масок. Побеждает последний выживший." },
    { "dogon", "Догонялки", "Ведущий гонится за игроками.", "Кого ударили кулаком - тот выбыл. Анимации и баги запрещены." },
    { "car", "Царь горы", "Заберитесь на вершину горы из объектов и держитесь.", "Только кулаки, без оружия и масок. Побеждает тот, кто остался на вершине." },
    { "parash", "Прыжки с парашютом", "Все получают парашюты и приземляются на метку ведущего.", "Промазал или разбился - выбываешь. Побеждает самый точный." },
    { "digl", "Король Дигла", "Каждому выдаётся Deagle.", "Нужно убрать всех соперников. Побеждает последний живой." },
    { "sultan", "Увернись от Султана", "Игроки в строю, ведущий едет на машине.", "Кого задели - тот выбыл. Нужно вовремя уворачиваться." },
    { "paint", "Пейнтбол", "Каждый сам за себя, считаются убийства.", "Побеждает тот, у кого в конце больше фрагментов." },
    { "krug", "Круг Смерти", "Игроки встают кругом, ведущий выдаёт Deagle с одним патроном.", "Задача - выстрелить в оппонента." },
    { "infern", "Догони Инфернус", "Найдите на карте ЧЁРНЫЙ INFERNUS ведущего и передайте ему 1 рубль: /pay {id} 1.", "Читы и помехи запрещены." },
}
local function eventByKey(k) k = lower(k) for _, e in ipairs(EVENTS) do if e[1] == k then return e end end end
local function announceEvent(e, arg)
    arg = trim(arg)
    local needId = false
    for k = 3, #e do if e[k]:find("{id}", 1, true) then needId = true end end
    local id, prize = nil, arg
    if needId then
        local a, b = arg:match("^(%d+)%s*(.*)$")
        if a then id, prize = a, b else id, prize = FH.watched, arg end
        if not id then fmsg("Нужен ID ведущего: /ev " .. e[1] .. " ID [приз]") return end
    end
    local L = { string.format("/aad [МП] Внимание, игроки! Скоро стартует мероприятие «%s».", e[2]) }
    for k = 3, #e do L[#L + 1] = "/aad [МП] " .. e[k]:gsub("{id}", id or "") end
    if trim(prize) ~= "" then L[#L + 1] = "/aad [МП] Приз победителю: " .. trim(prize) .. "." end
    L[#L + 1] = "/aad [МП] Участие свободное для всех. Ждите открытия телепорта."
    L[#L + 1] = "/aad [МП] Нарушители правил МП будут удалены без права на приз."
    sayAll(L, GAP, afterAnnounce)
end
local function eventsMenu()
    local items = {}
    for i, e in ipairs(EVENTS) do
        items[i] = { string.format("{FFFFFF}%s {A9A9A9}(/ev %s)", e[2], e[1]), function()
            ask("Приз для МП «" .. e[2] .. "»", e[1] == "infern" and "ID ведущего, затем приз (пример: 55 5кк)" or "Приз (можно пусто). Пример: 5кк",
                function(t) announceEvent(e, t) end)
        end }
    end
    menu("FH | Мероприятия", items, "Объявить")
end

----------------------------------------------------------------------
-- ФРАКЦИИ: набор, отборы на лидера, временная лидерка
----------------------------------------------------------------------
local FRACTIONS = {   -- { ключ, название, id для /templeader, тип }
    { "rus", "Русская мафия", 14, "mafia" }, { "jap", "Японская мафия", 6, "mafia" }, { "ita", "Итальянская мафия", 5, "mafia" },
    { "fun", "Похоронное бюро", 23, "mafia" }, { "out", "Outlaws MC", 28, "mafia" },
    { "rif", "Rifa Gang", 18, "gang" }, { "bal", "Ballas Gang", 12, "gang" }, { "azt", "Aztec Gang", 17, "gang" },
    { "gro", "Grove Street", 15, "gang" }, { "vag", "LS Vagos", 13, "gang" },
    { "arm", "Армия ЛС", 3, "gov" }, { "hos", "Больница ЛС", 4, "gov" }, { "mer", "Мэрия", 7, "gov" },
    { "rad", "Радиоцентр", 16, "gov" }, { "swt", "S.W.A.T", 25, "gov" }, { "gov", "Правительство", 26, "gov" },
    { "lsp", "LSPD", 1, "gov" }, { "fbi", "FBI", 2, "gov" }, { "rcp", "RCPD", 27, "gov" }, { "sud", "Верховный суд", 29, "gov" },
}
local RULES_KIND = { mafia = "правил бизваров", gang = "правил каптов", gov = "общих правил лидеров" }
local function fractionByKey(k) k = lower(k) for _, f in ipairs(FRACTIONS) do if f[1] == k then return f end end end

local function recruit(f)
    sayAll({ "/o [Набор] Внимание! Открыт набор в «" .. f[2] .. "».", "/o [Набор] Подайте заявку через /rep +." }, 2500)
end
local function tryoutAad(f)
    sayAll({ "/aad [Отбор] Внимание! Проходит отбор на пост лидера: " .. f[2] .. ".",
             "/aad [Отбор] Требования: возраст 13+, связь ВК, знание " .. RULES_KIND[f[4]] .. ".",
             "/aad [Отбор] Ждите открытия телепорта." }, GAP, afterAnnounce)
end
local function tryoutO(f)
    sayAll({ "/o [Отбор] Идёт отбор на пост лидера: " .. f[2] .. ".",
             "/o [Отбор] Нужно: 13+, связь ВК, знание " .. RULES_KIND[f[4]] .. ".",
             "/o [Отбор] Желающие - пишите /gomp." }, 2500, afterAnnounce)
end
local function tempLeader(f) say("/templeader " .. f[3]) end
local function fractionMenu()
    local items = {}
    for i, f in ipairs(FRACTIONS) do
        items[i] = { string.format("{FFFFFF}%s {A9A9A9}(%s)", f[2], f[1]), function()
            menu(f[2], {
                { "Набор (в общий чат /o)", function() recruit(f) end },
                { "Отбор на лидера (/aad)", function() tryoutAad(f) end },
                { "Отбор на лидера (общий чат /o)", function() tryoutO(f) end },
                { "Взять временную лидерку себе", function() tempLeader(f) end },
            })
        end }
    end
    menu("FH | Фракции", items)
end

----------------------------------------------------------------------
-- ЗАНЯТЬ ЗАДАЧУ: "z ..." несколько раз в /a
----------------------------------------------------------------------
local CLAIMS = { { "ao", "aad otbor" }, { "oo", "o otbor" }, { "am", "aad mp" }, { "ar", "aad razdacha" }, { "sp", "spawn" }, { "on", "o nabor" } }
local function claim(text, count)
    text = trim(text)
    if text == "" then return end
    count = math.max(1, math.min(5, tonumber(count) or 3))
    local L = {}
    for i = 1, count do L[i] = "/a z " .. text end
    sayAll(L)
end
local function claimMenu()
    local items = {}
    for i, c in ipairs(CLAIMS) do items[i] = { string.format("{FFFF00}z %s {A9A9A9}(/z %s)", c[2], c[1]), function() claim(c[2]) end } end
    menu("FH | Занять", items, "Занять")
end

----------------------------------------------------------------------
-- КОМАНДЫ-СОКРАЩЕНИЯ (режимы: args - нужны параметры; idin - вставить "/cmd ID " в строку ввода;
-- idopt - ID из аргумента или /re; optargs - параметры необязательны; none - без них)
----------------------------------------------------------------------
local ALIASES = {
    { "jj", "jail", "idin" }, { "mut", "mute", "idin" }, { "ww", "warn", "idin" }, { "bb", "ban", "args" },
    { "uw", "unwarn", "args" }, { "uj", "unjail", "args" }, { "unm", "unmute", "args" }, { "ub", "unban", "args" },
    { "ib", "iban", "args" }, { "ip", "pgetip", "args" }, { "bip", "banip", "args" }, { "ofl", "offleader", "args" }, { "mkl", "makeleader", "args" },
    { "fuel", "fuelcars", "none" }, { "fc", "fuelcars", "none" }, { "spc", "spawncars", "none" }, { "gh", "ghetto", "none" },
    { "gt", "ghetto", "none" }, { "gzc", "gzcolor", "args" }, { "gc", "gzcolor", "args" }, { "wh", "warehouse", "optargs" },
    { "cb", "warehouse", "args" }, { "gs", "getstats", "idopt" }, { "inv", "checkinv", "idopt" }, { "bp", "setbizprod", "args" },
}
local function aliasFn(short, full, mode)
    return function(p)
        p = trim(p)
        if mode == "none" then say("/" .. full) return end
        if mode == "optargs" then say(p == "" and ("/" .. full) or ("/" .. full .. " " .. p)) return end
        if mode == "idin" or mode == "idopt" then
            local id = p:match("^(%d+)") or FH.watched
            if not id then fmsg("Укажите ID: /" .. short .. " ID") return end
            if mode == "idin" then setInput(string.format("/%s %s ", full, id)) else say(string.format("/%s %s", full, id)) end
            return
        end
        if p == "" then fmsg("Укажите параметры: /" .. short .. " ...") return end
        say("/" .. full .. " " .. p)
    end
end

----------------------------------------------------------------------
-- МОДЕРАЦИЯ ПО /re-ЦЕЛИ: /wn /sc /scc /jl /mt /uwn /ujl /um /bn /ubn /as /ci /sprod
----------------------------------------------------------------------
local function tgt(p) p = trim(p) if p ~= "" then return p end return FH.watched end
local MOD_PORT = {   -- { имя, серверная команда } - цель в начале, остальное - причина/параметры
    { "wn", "warn" }, { "jl", "jail" }, { "mt", "mute" }, { "bn", "ban" }, { "uwn", "unwarn" }, { "ujl", "unjail" }, { "um", "unmute" },
    { "ubn", "unban" }, { "as", "aspawn" }, { "ci", "clearinv" },
}
local function modFn(short, full)
    return function(p)
        p = trim(p)
        local id, rest = p:match("^(%d+)%s*(.*)$")
        if not id then id, rest = FH.watched, p end
        if not id then fmsg("Укажите ID: /" .. short .. " ID [причина] (или откройте /re ID)") return end
        if rest ~= "" then say(string.format("/%s %s %s", full, id, rest)) else setInput(string.format("/%s %s ", full, id)) end
    end
end

----------------------------------------------------------------------
-- ШПАРГАЛКИ (свои заметки)
----------------------------------------------------------------------
local function saveNotes()
    local L = {}
    for _, n in ipairs(FH.notes) do
        L[#L + 1] = "[" .. n.title .. "]"
        for _, l in ipairs(n.lines) do L[#L + 1] = "> " .. l end
    end
    return writeLines("FilippHelper_notes.txt", L)
end
local function loadNotes()
    local cur
    for _, l in ipairs(readLines("FilippHelper_notes.txt")) do
        local t = l:match("^%[(.+)%]$")
        if t then
            if #FH.notes < 40 then cur = { title = t:sub(1, 40), lines = {} } FH.notes[#FH.notes + 1] = cur else cur = nil end
        elseif cur and l:sub(1, 2) == "> " and #cur.lines < 30 then cur.lines[#cur.lines + 1] = l:sub(3) end
    end
end
local function findNote(title)
    title = lower(trim(title))
    for i, n in ipairs(FH.notes) do if lower(n.title) == title then return n, i end end
end
local function noteAdd(title, text)
    title = trim(title:gsub("[%[%]]", ""))
    if title == "" or ulen(title) > 40 then return "Название: до 40 символов." end
    local n = findNote(title)
    local fresh = not n
    if fresh then
        if #FH.notes >= 40 then return "Лимит заметок: 40" end
        n = { title = title, lines = {} }
    end
    local added = 0
    for piece in (text .. ";;"):gmatch("(.-);;") do
        piece = trim(piece)
        if piece ~= "" and #n.lines < 30 then n.lines[#n.lines + 1] = piece added = added + 1 end
    end
    if added == 0 then return "Пустой текст, ничего не добавлено." end
    if fresh then FH.notes[#FH.notes + 1] = n end
    saveNotes()
    return string.format("Заметка «%s»: добавлено строк %d (всего %d).", n.title, added, #n.lines)
end
local function noteShow(n) info(n.title, table.concat(n.lines, "\n")) end
local function notesMenu()
    local items = { { "{33CC33}[+] Новая заметка", function()
        ask("Новая заметка", "Формат: название | текст. Строки через ;;", function(t)
            local ti, tx = t:match("^(.-)%s*|%s*(.+)$")
            if ti then fmsg(noteAdd(ti, tx)) else fmsg("Формат: название | текст") end
        end)
    end } }
    for _, n in ipairs(FH.notes) do items[#items + 1] = { string.format("{FFFFFF}%s {A9A9A9}- строк: %d", n.title, #n.lines), function() noteShow(n) end } end
    menu("FH | Шпаргалки", items, "Открыть")
end
local function cmdNote(p)
    local sub, rest = trim(p):match("^(%S+)%s*(.*)$")
    if sub == "add" then
        local ti, tx = rest:match("^(.-)%s*|%s*(.+)$")
        if not ti then fmsg("Использование: /note add название | текст") return end
        fmsg(noteAdd(ti, tx))
    elseif sub == "del" then
        local n, i = findNote(rest)
        if not n then fmsg("Заметка не найдена.") return end
        table.remove(FH.notes, i) saveNotes() fmsg("Заметка удалена.")
    elseif sub == "show" then
        local n = findNote(rest)
        if n then noteShow(n) else fmsg("Заметка не найдена.") end
    else notesMenu() end
end

----------------------------------------------------------------------
-- ПРОВЕРКА АКТИВНОСТИ В /a
----------------------------------------------------------------------
local CHK = FH.chk
local function roleNames(keys)
    local out = {}
    for _, k in ipairs(keys) do for _, r in ipairs(ROLES) do if r[1] == k then out[#out + 1] = r[3] end end end
    return out
end
local function chkLines(sel, word, secs)
    word = trim(word) if word == "" then word = "1" end
    secs = tonumber(secs) or 0
    local answer = (word == "1") and "цифру 1" or ("слово «" .. word .. "»")
    local tail = secs > 0 and (" Время: " .. math.floor(secs) .. " сек.") or ""
    local L = { "/a Проверка активности администрации!" }
    if sel and #sel > 0 then
        local cur, used, first = {}, 0, true
        local function flush(last)
            if #cur == 0 then return end
            L[#L + 1] = "/a " .. (first and "Отзываются: " or "") .. table.concat(cur, ", ") .. (last and "." or ",")
            first, cur, used = false, {}, 0
        end
        for _, name in ipairs(sel) do
            if #cur > 0 and used + 2 + ulen(name) > 95 then flush(false) end
            used = used + (#cur > 0 and 2 or 0) + ulen(name)
            cur[#cur + 1] = name
        end
        flush(true)
        L[#L + 1] = "/a Поставьте свой тег и напишите в /a " .. answer .. "." .. tail
    else
        L[#L + 1] = "/a Главные и заместители главных следящих - поставьте свой тег."
        L[#L + 1] = "/a Подтвердите присутствие: напишите в /a " .. answer .. "." .. tail
    end
    return L, word, secs
end
local function chkText()
    local t = { string.format("{FFFFFF}Отметились: {33CC33}%d", #CHK.list), "{A9A9A9}Ответ: " .. CHK.word .. (CHK.active and "   (проверка идёт)" or "   (проверка закончена)"), "" }
    if #CHK.list == 0 then t[#t + 1] = "{A9A9A9}Пока никто не ответил." end
    for i, e in ipairs(CHK.list) do t[#t + 1] = string.format("{FFFFFF}%d. %s{A9A9A9}%s  - через %d сек.", i, e.name, e.id and ("[" .. e.id .. "]") or "", e.sec) end
    return table.concat(t, "\n")
end
local function chkShow() info("FH | Итог проверки активности", chkText()) end
local function chkEnd(announce)
    if not CHK.active then fmsg("Проверка не запущена.") return end
    CHK.active, CHK.token = false, CHK.token + 1
    fmsg(string.format("Проверка закончена. Отметились: %d (список: /chkres).", #CHK.list))
    if announce then say(string.format("/a Проверка активности завершена. Отметились: %d.", #CHK.list)) end
end
local function chkCollect(text)
    if not CHK.active then return end
    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, msg = clean:match("([%w_%.]+)%[(%d+)%]%s*:%s*(.-)%s*$")
    if not name then name, msg = clean:match("([%w_%.]+)%s*:%s*(.-)%s*$") end
    if not name or lower(msg) ~= lower(CHK.word) or CHK.seen[name] then return end
    CHK.seen[name] = true
    CHK.list[#CHK.list + 1] = { name = name, id = id, sec = math.floor(os.clock() - CHK.t0) }
end
local function chkStart(sel, opts)
    opts = opts or {}
    local L, word, secs = chkLines(sel, opts.word, opts.seconds)
    CHK.active, CHK.list, CHK.seen, CHK.word = false, {}, {}, word
    CHK.token = CHK.token + 1
    local my = CHK.token
    sayAll(L, GAP, function()
        if CHK.token ~= my then return end
        CHK.active, CHK.t0 = true, os.clock()
        if secs > 0 then
            lua_thread.create(function()
                wait(secs * 1000)
                if CHK.token == my and CHK.active then pcall(function() chkEnd(false) chkShow() end) end
            end)
        end
    end)
end
local function roleByToken(tok)
    tok = lower(tok):gsub("[%s,]", "")
    for _, r in ipairs(ROLES) do if r[1] == tok or lower(r[2]):gsub("%s", "") == tok then return r[3] end end
end
local function chkArgs(p)   -- /a1 [должности] [t=секунд] [w=слово]
    p = trim(p)
    if p == "" then chkStart(nil) return end
    local sel, bad, opts = {}, {}, {}
    for tok in p:gmatch("[^%s,]+") do
        local secs, word = tok:match("^t=(%d+)$"), tok:match("^w=(.+)$")
        if secs then opts.seconds = tonumber(secs) elseif word then opts.word = word
        else local r = roleByToken(tok) if r then sel[#sel + 1] = r else bad[#bad + 1] = tok end end
    end
    if #bad > 0 then
        local keys = {}
        for _, r in ipairs(ROLES) do keys[#keys + 1] = r[1] end
        fmsg("Не знаю: " .. table.concat(bad, ", ") .. ". Ключи: " .. table.concat(keys, " ") .. " | t=60 w=слово")
        return
    end
    chkStart(sel, opts)
end
local function chkMenu()
    local items = { { "{33CC33}Общая проверка (без должностей)", function() chkStart(nil) end } }
    for _, pr in ipairs(CHK_PRESETS) do items[#items + 1] = { "{66CCFF}Набор: {FFFFFF}" .. pr[1], function() chkStart(roleNames(pr[2])) end } end
    for _, r in ipairs(ROLES) do items[#items + 1] = { "{FFFFFF}" .. r[2], function() chkStart({ r[3] }) end } end
    menu("FH | Проверка активности", items, "Проверить")
end

----------------------------------------------------------------------
-- ОБЪЯВЛЕНИЯ, ПАМЯТКИ, ТРАНСПОРТ, ОПРОС
----------------------------------------------------------------------
local function sayRules()
    sayAll({ "Норма онлайна лидера: в будни 1 час, в выходные 1 час 30 минут.", "Не отыграли норму - получаете выговор.",
        "3/3 выговоров - снятие с поста лидера и ЧСЛ.", "Час пик в будни: с 17:00 до 20:00.", "Час пик в выходные: с 16:00 до 19:00.",
        "Отсутствие в час пик тоже карается выговором.", "Вопросы - к следящим вашей структуры." }, 3500)
end
local function sayInfo()
    sayAll({ "/aad [INFO] Уважаемые игроки, администрация всегда на связи!", "/aad [INFO] Нашли баг или нарушение - пишите в /rep.",
        "/aad [INFO] Формулируйте вопрос или жалобу коротко и понятно.", "/aad [INFO] За флуд, оффтоп и оскорбления в репорте выдаётся наказание.",
        "/aad [INFO] Приятной игры!" })
end
local function sayTimeInfo()
    sayAll({ "/aad [INFO] Игроки, напоминаем об акции за онлайн!", "/aad [INFO] Отыграйте час на сервере и получите приз.",
        "/aad [INFO] Награду можно получать до 5 раз в день.", "/aad [INFO] Проверить время и забрать приз: /rep time",
        "/aad [INFO] С уважением, администрация проекта." })
end
local function showRules(kind) local r = RULES_TEXT[kind] if r then info(r[1], r[2]) end end
local function askVopros(p)
    local n = tonumber(trim(p):match("^%d+"))
    local v = n and VOPROS[n]
    if not v then fmsg("Использование: /vopros 1-" .. #VOPROS .. " (вопрос лидеру в чат, ответ покажу вам).") return end
    say(v[1]) fmsg("Ответ: " .. v[2])
end
local function cmdPoll(p)
    local who = trim(p)
    if who == "" then fmsg("Использование: /poll должность и ник (например: /poll ГА Ivan_Ivanov)") return end
    sayAll({ "/aad [Опрос] Игроки, уделите минуту!", "/aad [Опрос] Оцените работу: " .. who .. ". Отправьте в /rep цифру от 1 до 5." })
end

-- удаление админ-каров: всегда предупреждение в /a и таймер 15 секунд
local VR = { token = 0, active = false }
local function dvTimer(spawn)
    if VR.active then fmsg("Таймер уже идёт (остановить: /vrstop).") return end
    VR.active, VR.token = true, VR.token + 1
    local my = VR.token
    say("/a Через 15 секунд админ-транспорт будет удалён" .. (spawn and " и весь транспорт сервера возвращён на места." or "."))
    lua_thread.create(function()
        wait(15000 + GAP)
        if VR.token ~= my then return end
        VR.active = false
        say("/dvall")
        if spawn then say("/spawncars") end
    end)
end
local function vrStop()
    if VR.active then VR.active, VR.token = false, VR.token + 1 fmsg("Таймер респавна остановлен.") else fmsg("Таймер не запущен.") end
end

----------------------------------------------------------------------
-- БИНДЕР: свои команды /имя; строка с "/" уходит командой, остальное в чат; {id}, {arg}
----------------------------------------------------------------------
local BIND = { max = 40, maxLines = 15 }
local function saveBinds()
    local L = {}
    for _, b in ipairs(FH.binds) do
        L[#L + 1] = "[" .. b.name .. "|" .. b.delay .. "]"
        for _, l in ipairs(b.lines) do L[#L + 1] = "> " .. l end
    end
    return writeLines("FilippHelper_binds.txt", L)
end
local function bindByName(n) n = lower(n) for i, b in ipairs(FH.binds) do if b.name == n then return b, i end end end
local function runBind(b, arg)
    arg = trim(arg)
    local id = arg:match("^(%d+)") or FH.watched or ""
    local L = {}
    for i, l in ipairs(b.lines) do
        l = l:gsub("{id}", id):gsub("{arg}", arg)
        local first = l:match("^/(%S+)")
        if first and bindByName(first) then fmsg("Бинд не может вызывать другой бинд (защита от циклов).")
        else L[#L + 1] = l end
    end
    sayAll(L, b.delay)
end
local registerCmd   -- определена в main-блоке
local function registerBind(b)
    registerCmd(b.name, function(p) local cur = bindByName(b.name) if cur then runBind(cur, p) end end, true)
end
local function loadBinds()
    local cur
    for _, l in ipairs(readLines("FilippHelper_binds.txt")) do
        local n, d = l:match("^%[([%w_]+)|(%d+)%]$")
        if n then
            if #FH.binds < BIND.max then cur = { name = lower(n), delay = math.max(300, math.min(10000, tonumber(d))), lines = {} } FH.binds[#FH.binds + 1] = cur else cur = nil end
        elseif cur and l:sub(1, 2) == "> " and #cur.lines < BIND.maxLines then cur.lines[#cur.lines + 1] = l:sub(3) end
    end
end
local function cmdBnd(p)
    local sub, rest = trim(p):match("^(%S+)%s*(.*)$")
    if sub == "add" then
        local name, text = rest:match("^([%w_]+)%s+(.+)$")
        if not name then fmsg("Использование: /bnd add имя текст (несколько строк через ;;)") return end
        name = lower(name)
        if FH.cmds[name] then fmsg("Имя /" .. name .. " занято командой хелпера.") return end
        local b = bindByName(name)
        local fresh = not b
        if fresh then
            if #FH.binds >= BIND.max then fmsg("Лимит биндов: " .. BIND.max) return end
            b = { name = name, delay = 1100, lines = {} }
        end
        local added = 0
        for piece in (text .. ";;"):gmatch("(.-);;") do
            piece = trim(piece)
            if piece ~= "" and #b.lines < BIND.maxLines then b.lines[#b.lines + 1] = piece added = added + 1 end
        end
        if added == 0 then fmsg("Пустой текст.") return end
        if fresh then FH.binds[#FH.binds + 1] = b registerBind(b) end
        saveBinds()
        fmsg(string.format("Бинд /%s: добавлено строк %d (всего %d).", name, added, #b.lines))
    elseif sub == "rm" then
        local name, n = rest:match("^([%w_]+)%s+(%d+)$")
        local b = name and bindByName(name)
        if b and b.lines[tonumber(n)] then table.remove(b.lines, tonumber(n)) saveBinds() fmsg("Строка удалена.") else fmsg("Использование: /bnd rm имя N") end
    elseif sub == "del" then
        local b, i = bindByName(rest)
        if b then table.remove(FH.binds, i) saveBinds() fmsg("Бинд удалён.") else fmsg("Бинд не найден.") end
    elseif sub == "delay" then
        local name, ms = rest:match("^([%w_]+)%s+(%d+)$")
        local b = name and bindByName(name)
        if b then b.delay = math.max(300, math.min(10000, tonumber(ms))) saveBinds() fmsg("Пауза: " .. b.delay .. " мс.") else fmsg("Использование: /bnd delay имя мс (300-10000)") end
    elseif sub == "show" then
        local b = bindByName(rest)
        if not b then fmsg("Бинд не найден.") return end
        info("/" .. b.name .. " (пауза " .. b.delay .. " мс)", table.concat(b.lines, "\n"))
    else
        local names = {}
        for _, b in ipairs(FH.binds) do names[#names + 1] = "/" .. b.name end
        fmsg("Бинды: " .. (#names > 0 and table.concat(names, " ") or "нет") .. ". Справка: /binder")
    end
end
local function binderHelp()
    info("FH | Биндер", "{66CCFF}/bnd add имя текст{FFFFFF} - создать бинд (строки через ;;)\n{66CCFF}/bnd rm имя N{FFFFFF} - удалить строку\n" ..
        "{66CCFF}/bnd del имя{FFFFFF} - удалить бинд\n{66CCFF}/bnd delay имя мс{FFFFFF} - пауза между строками (300-10000)\n" ..
        "{66CCFF}/bnd show имя{FFFFFF}, {66CCFF}/bnd list{FFFFFF} - просмотр\n\nСтрока с / уходит командой, остальное - в чат.\nПодстановки: {id} - ID из аргумента или /re, {arg} - весь аргумент.")
end

----------------------------------------------------------------------
-- HTTP (для ИИ и обновления): effil+requests в отдельном потоке, запасной вариант ssl.https
----------------------------------------------------------------------
local function httpRequest(method, url, headers, body, cb)   -- cb(ok, code, text)
    local okE, effil = pcall(require, 'effil')
    local okR = pcall(require, 'requests')
    if okE and okR then
        local ok, th = pcall(function()
            return effil.thread(function(m, u, h, b)
                local rq = require 'requests'
                local okq, resp = pcall(rq.request, { method = m, url = u, headers = h, data = b })
                if not okq then return false, tostring(resp) end
                return true, resp.status_code, resp.text
            end)(method, url, headers or {}, body)
        end)
        if ok then
            lua_thread.create(function()
                local t0 = os.clock()
                while os.clock() - t0 < 60 do
                    local st = th:status()
                    if st == "completed" then
                        local okr, a, b2, c = pcall(function() return th:get() end)
                        if okr and a then cb(true, b2, c) else cb(false, 0, tostring(okr and b2 or a)) end
                        return
                    elseif st == "failed" or st == "canceled" then cb(false, 0, "поток завершился с ошибкой") return end
                    wait(100)
                end
                pcall(function() th:cancel() end)
                cb(false, 0, "таймаут")
            end)
            return
        end
    end
    local okS, https = pcall(require, 'ssl.https')
    local okL, ltn12 = pcall(require, 'ltn12')
    if okS and okL then
        local chunks = {}
        local okq, code = pcall(https.request, { url = url, method = method, headers = headers, source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(chunks) })
        local text = table.concat(chunks)
        if okq and code then cb(true, tonumber(code) or 0, text) else cb(false, 0, tostring(code)) end
        return
    end
    cb(false, 0, "нет effil/requests и ssl.https")
end

local function jsonStr(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end
local function jsonField(text, key)   -- первая строка-значение поля "key" с раскодированием
    local s = text:match('"' .. key .. '"%s*:%s*"(.-[^\\])"') or text:match('"' .. key .. '"%s*:%s*"()"') and ""
    if not s then return nil end
    s = s:gsub("\\u(%x%x%x%x)", function(h) return cpchr(tonumber(h, 16)) end):gsub("\\(.)", { n = "\n", r = "", t = " ", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })
    return s
end

local AI = { busy = false }
local function aiAsk(question, cb)   -- cb(ok, text)
    if AI.busy then cb(false, "Запрос уже идёт.") return end
    if C.aiUrl == "" or C.aiKey == "" or C.aiModel == "" then cb(false, "Заполните адрес, ключ и модель (Настройки -> ИИ или /aiset).") return end
    AI.busy = true
    local body = string.format('{"model":%s,"messages":[{"role":"system","content":%s},{"role":"user","content":%s}],"max_tokens":300}',
        jsonStr(C.aiModel), jsonStr(toUi(C.aiPrompt)), jsonStr(toUi(question)))
    httpRequest("POST", C.aiUrl, { ["Content-Type"] = "application/json", Authorization = "Bearer " .. C.aiKey }, body, function(ok, code, text)
        AI.busy = false
        if not ok then cb(false, "Ошибка запроса: " .. tostring(text)) return end
        local ans = jsonField(text or "", "content")
        if ans and ans ~= "" then cb(true, fromUi(ans)) else cb(false, "Ответ сервиса (код " .. tostring(code) .. "): " .. fromUi((jsonField(text or "", "message") or tostring(text)):sub(1, 120))) end
    end)
end
local function aiReportDraft(r, cb) aiAsk("Репорт игрока " .. r.name .. ": " .. r.text .. "\nНапиши короткий вежливый ответ.", cb) end
local function cmdAi(p)
    local r = reportById(trim(p):match("^(%d+)") or "") or FH.reports[1]
    if not r then fmsg("Нет репортов для ответа.") return end
    fmsg("ИИ думает над репортом " .. r.name .. "[" .. r.id .. "]...")
    aiReportDraft(r, function(ok, text)
        if ok then setInput("/rr " .. r.id .. " " .. text) else fmsg("ИИ: " .. text) end
    end)
end
local function cmdAiSet(p)
    local k, v = trim(p):match("^(%S+)%s+(.+)$")
    local map = { url = "aiUrl", key = "aiKey", model = "aiModel", prompt = "aiPrompt" }
    if k and map[k] then C[map[k]] = v saveCfg() fmsg("ИИ: " .. k .. " сохранён.") else fmsg("Использование: /aiset url|key|model|prompt значение") end
end
local function aiDiag()
    local function has(n) return (pcall(require, n)) and "есть" or "нет" end
    fmsg("effil: " .. has("effil") .. ", requests: " .. has("requests") .. ", ssl.https: " .. has("ssl.https") .. ", ltn12: " .. has("ltn12"))
    fmsg("Адрес: " .. (C.aiUrl ~= "" and "задан" or "не задан") .. ", ключ: " .. (C.aiKey ~= "" and "задан" or "не задан") .. ", модель: " .. (C.aiModel ~= "" and C.aiModel or "не задана"))
end

----------------------------------------------------------------------
-- ОБНОВЛЕНИЕ из репозитория
----------------------------------------------------------------------
local UPD = { latest = nil, text = nil }
local function verNum(v) local a, b = tostring(v):match("(%d+)%.?(%d*)") return (tonumber(a) or 0) * 1000 + (tonumber(b) or 0) end
local function updCheck(manual)
    httpRequest("GET", REPO_RAW .. "version.txt", {}, nil, function(ok, code, text)
        if not ok or code ~= 200 then if manual then fmsg("Не удалось проверить обновление.") end return end
        local v = trim((text or ""):match("^[^\r\n]*"))
        UPD.latest = v
        if verNum(v) > verNum(VERSION) then fmsg("Вышла версия " .. v .. " (у вас " .. VERSION .. "). Установить: /fhupd install")
        elseif manual then fmsg("Установлена последняя версия (" .. VERSION .. ").") end
    end)
end
local function updInstall()
    fmsg("Скачиваю обновление...")
    httpRequest("GET", REPO_RAW .. UPDATE_FILE, {}, nil, function(ok, code, text)
        if not ok or code ~= 200 or #text < 20000 or not text:find("FilippHelper", 1, true) then fmsg("Обновление не скачано (код " .. tostring(code) .. ").") return end
        local path = thisScript().path
        local f = io.open(path .. ".new", "wb")
        if not f then fmsg("Нет доступа на запись.") return end
        f:write(text) f:close()
        os.remove(path .. ".bak") os.rename(path, path .. ".bak")
        if os.rename(path .. ".new", path) then fmsg("Обновлено. Перезагрузите скрипты (Ctrl+R).")
        else os.rename(path .. ".bak", path) fmsg("Не удалось заменить файл, оставлена текущая версия.") end
    end)
end
local function cmdUpd(p) if trim(p) == "install" then updInstall() else updCheck(true) end end

----------------------------------------------------------------------
-- ПРИЧИНА НАКАЗАНИЯ: если сервер показывает список/поле причины, подбираем по нашему тексту
----------------------------------------------------------------------
local PUN = { pending = nil }
local function punNote(cmd)
    local kind, reason = cmd:match("^/(%a+)%s+%S+%s+(.+)$")
    if kind == "mute" or kind == "jail" or kind == "warn" or kind == "ban" then
        reason = reason:gsub("^%d+%s+", "")   -- число после ID (минуты/дни) - не часть причины
        PUN.pending = { reason = reason, t = os.clock() }
    end
end
local function dlgReply(id, btn, list, input)   -- ответ из потока; диалог скрыт нами, поэтому активность не проверяем
    lua_thread.create(function() wait(150) pcall(sampSendDialogResponse, id, btn, list, toGame(input or "")) end)
end
local function punHandle(id, style, text)
    local p = PUN.pending
    if not p then return false end
    if os.clock() - p.t > 12 then PUN.pending = nil return false end
    if style == 1 then PUN.pending = nil dlgReply(id, 1, 0, p.reason) return true end
    if style ~= 2 and style ~= 4 then return false end
    local words = {}
    for w in lower(p.reason):gmatch("[^%s%.,!%?%-%(%)%[%]:;\"']+") do if ulen(w) >= 6 then words[#words + 1] = w end end
    if #words == 0 then return false end
    local best, score, idx, i = nil, 0, -1, 0
    for line in (fromGame(text):gsub("{%x%x%x%x%x%x}", "") .. "\n"):gmatch("([^\n]*)\n") do
        local low, s = lower(line), 0
        for _, w in ipairs(words) do if low:find(w, 1, true) then s = s + 1 end end
        if s > score then best, score, idx = line, s, i end
        i = i + 1
    end
    if not best then return false end
    PUN.pending = nil
    dlgReply(id, 1, idx, "")
    FH.defer(function() fmsg("Причина выбрана: " .. trim(best)) end)
    return true
end

----------------------------------------------------------------------
-- ХУКИ SAMP. Только разбор текста и запись в таблицы; вывод в игру откладывается в главный цикл.
----------------------------------------------------------------------
FH.deferred = {}
function FH.defer(fn) FH.deferred[#FH.deferred + 1] = fn end

local function onMessage(text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
    chkCollect(text)
    if not text:find("Репорт", 1, true) then return end
    local clean = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local name, id, body = clean:match("Репорт от ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not name then return end
    body = body:gsub("%s*|%s*Уже%s*%d+%s*репорт[^|]*$", "")
    addReport(name, id, body)
    if C.reptoast then FH.defer(function() fmsg("{FFFF00}Репорт от " .. name .. "[" .. id .. "]: {FFFFFF}" .. body) end) end
    local g = FH.gw
    if g.active and not GW_IGNORE[name] and not clean:find(GW_TAG, 1, true) and lower(trim(body)) == g.word then gwFinish(name, id) end
end
function ev.onServerMessage(color, text) local ok, err = pcall(onMessage, text) if not ok then log("onServerMessage: " .. tostring(err)) end end

function ev.onSendCommand(cmd)
    pcall(function()
        if type(cmd) ~= "string" then return end
        cmd = fromGame(cmd)
        punNote(cmd)
        if cmd:match("^/define") and not DEF.waiting then DEF.user = os.clock() end
        local id = cmd:match("^/re%s+(%d+)")
        if id then FH.watched = id elseif cmd:match("^/re%s+off") or cmd:match("^/reoff") then FH.watched = nil end
    end)
end

local function onDialog(id, style, title, text)
    if PUN.pending and punHandle(id, style, text) then return false end
    local ours = DEF.waiting and os.clock() - DEF.t0 < 6
    if ours or (DEF.user and os.clock() - DEF.user < 3) then
        DEF.user = nil
        local list = defineParse(fromGame(tostring(text or "")))
        DEF.waiting = false
        if #list > 0 then
            for i = #FH.reports, 1, -1 do FH.reports[i] = nil end
            for _, r in ipairs(list) do FH.reports[#FH.reports + 1] = r end
            FH.defer(function() fmsg("Список репортов обновлён из /define: " .. #list .. ".") end)
        else
            pcall(function() local f = io.open(cfgDir() .. "/FilippHelper_define.txt", "wb") if f then f:write(tostring(title), "\n", tostring(text)) f:close() end end)
            FH.defer(function() fmsg("Не удалось разобрать /define. Формат записан в config/FilippHelper_define.txt.") end)
        end
        if ours then dlgReply(id, 0, -1, "") return false end
    end
    if AM.armed then
        if os.clock() - AM.t0 > 6 then AM.armed = false
        elseif style == 2 or style == 4 or style == 5 then
            AM.armed = false
            -- нажимаем первую строку позже и только если диалог ещё открыт
            lua_thread.create(function()
                wait(300)
                local a1, act = pcall(sampIsDialogActive)
                local a2, cur = pcall(sampGetCurrentDialogId)
                if a1 and act and a2 and cur == id then pcall(sampSendDialogResponse, id, 1, 0, "") end
            end)
        end
    end
end
function ev.onShowDialog(id, style, title, b1, b2, text)
    local ok, res = pcall(onDialog, id, style, title, text)
    if not ok then log("onShowDialog: " .. tostring(res)) return end
    if res == false then return false end
end

----------------------------------------------------------------------
-- РЕГИСТРАЦИЯ КОМАНД
----------------------------------------------------------------------
function registerCmd(name, fn, quiet)
    if not quiet then FH.cmds[name] = fn end
    local ok, err = pcall(sampRegisterChatCommand, name, function(arg)
        local ok2, e2 = pcall(fn, fromGame(type(arg) == "string" and arg or ""))
        if not ok2 then log("/" .. name .. ": " .. tostring(e2)) FH.defer(function() fmsg("{FF3333}Ошибка в /" .. name .. ", см. moonloader.log") end) end
    end)
    if not ok then log("register " .. name .. ": " .. tostring(err)) end
end

-- страницы справки по командам
local HELP = {
    { "Раздачи", "/gw слово | приз - раздача (приз: банк 500000, лвл 3, #9 15)\n/gwlast слово | приз - финальная\n/gwstop - отмена\n/razdintro [приз] - анонс раздачи" },
    { "Репорты", "/reports - последние 15, быстрый ответ\n/rr [ID] текст - ответ\n/ar ID - ответ + жалоба в /a\n/tpl, /rt [ID] N - шаблоны\n/rpl - список из /define\n/ai [ID] - ИИ-черновик ответа" },
    { "МП и фракции", "/ev [ключ] [ID] [приз] - анонс МП (список: /ev)\n/fr - меню фракций\n/nab, /otb, /otbo, /tlead ключ\n/z ключ - занять задачу\n/mpa - нажать /mp вручную\n/fhset automp on|off" },
    { "Проверки и памятки", "/a1, /chk [должности] [t=сек] [w=слово]\n/chkres, /chkend\n/pravila, /inf, /timeinfo, /captlist, /bizwarlist, /vopros 1-7\n/poll должность ник" },
    { "Транспорт", "/spc, /fc, /dva, /dvs, /vr (с предупреждением и таймером 15 с), /vrstop" },
    { "Наказания", "/jj /mut /ww /bb /uw /uj /unm /ub /ib /ip /bip /ofl /mkl /gzc /gs /inv /bp /wh /gh\n/wn /jl /mt /bn /uwn /ujl /um /ubn /as /ci - цель по умолчанию из /re" },
    { "Прочее", "/fh - окно, /fcmd - эта справка, /fhgui on|off, /fhupd [install], /fhdiag, /aidiag, /aiset\n/notes, /note add|del|show, /bnd, /binder, /fbind" },
}
local function helpMenu()
    local items = {}
    for i, h in ipairs(HELP) do items[i] = { h[1], function() info("FH | " .. h[1], h[2]) end } end
    menu("FH | Команды", items, "Открыть")
end
FH.helpMenu = helpMenu

local function registerAll1()
    local function reg(n, f) registerCmd(n, f) end
    reg("fcmd", helpMenu)
    reg("reports", showReports)
    reg("rpl", defineRefresh)
    reg("rr", function(p)
        local id, text = trim(p):match("^(%d+)%s+(.+)$")
        if not id then id, text = FH.watched or (FH.reports[1] and FH.reports[1].id), trim(p) end
        if not id or trim(text) == "" then fmsg("Использование: /rr [ID] текст") return end
        reply(id, text)
    end)
    reg("ar", cmdAr)
    reg("tpl", function(p)
        local sub, rest = trim(p):match("^(%S+)%s*(.*)$")
        if sub == "add" and trim(rest) ~= "" and #FH.templates < 30 then FH.templates[#FH.templates + 1] = trim(rest):sub(1, 200) saveTpl() fmsg("Шаблон добавлен.")
        elseif sub == "del" and FH.templates[tonumber(rest)] then table.remove(FH.templates, tonumber(rest)) saveTpl() fmsg("Шаблон удалён.")
        else
            fmsg("Шаблоны (отправить: /rt [ID] N; добавить: /tpl add текст; удалить: /tpl del N):")
            for i, t in ipairs(FH.templates) do chatAdd(string.format("{FFFF00}%d. {FFFFFF}%s", i, t)) end
        end
    end)
    reg("rt", function(p)
        local id, n = trim(p):match("^(%d+)%s+(%d+)$")
        if not id then n, id = trim(p):match("^(%d+)$"), FH.watched end
        local t = FH.templates[tonumber(n or 0)]
        if not id or not t then fmsg("Использование: /rt [ID] номер_шаблона (список: /tpl)") return end
        reply(id, t)
    end)
    reg("gw", function(p) gwStart(p, false) end)
    reg("gwlast", function(p) gwStart(p, true) end)
    reg("gwstop", function() if FH.gw.active then FH.gw.active = false fmsg("Раздача отменена.") else fmsg("Раздача не запущена.") end end)
    reg("razdintro", gwIntro)
    reg("ev", function(p)
        local key, arg = trim(p):match("^(%S+)%s*(.*)$")
        local e = key and eventByKey(key)
        if e then announceEvent(e, arg) elseif key then fmsg("Нет такого МП: " .. key .. ". Список: /ev") else eventsMenu() end
    end)
    reg("fr", fractionMenu)
    for cmd, fn in pairs({ nab = recruit, otb = tryoutAad, otbo = tryoutO, tlead = tempLeader }) do
        reg(cmd, function(p) local f = fractionByKey(trim(p)) if f then fn(f) else fmsg("Укажите фракцию: /" .. cmd .. " ключ (ключи: /fr)") end end)
    end
    reg("z", function(p)
        local key, rest = trim(p):match("^(%S+)%s*(.*)$")
        if not key then claimMenu() return end
        for _, c in ipairs(CLAIMS) do if c[1] == lower(key) then claim(c[2], rest) return end end
        claim(p)
    end)
    reg("mpa", function() armMp(true) end)
    reg("fhset", function(p)
        local k, v = trim(p):match("^(%S+)%s+(%S+)$")
        if k == "automp" and (v == "on" or v == "off") then C.automp = (v == "on") saveCfg() fmsg("Авто-/mp: " .. (C.automp and "включено" or "выключено"))
        else fmsg("Использование: /fhset automp on|off (сейчас: " .. (C.automp and "on" or "off") .. ")") end
    end)
end
local function registerAll2()
    local function reg(n, f) registerCmd(n, f) end
    reg("a1", chkArgs) reg("chk", function(p) if trim(p) == "" then chkMenu() else chkArgs(p) end end)
    reg("chkres", chkShow) reg("chkend", function() chkEnd(true) end)
    reg("pravila", sayRules) reg("inf", sayInfo) reg("timeinfo", sayTimeInfo)
    reg("captlist", function() showRules("capt") end) reg("bizwarlist", function() showRules("biz") end)
    reg("vopros", askVopros) reg("poll", cmdPoll)
    reg("dva", function() dvTimer(false) end) reg("dvs", function() dvTimer(true) end) reg("vr", function() dvTimer(true) end) reg("vrstop", vrStop)
    for _, a in ipairs(ALIASES) do reg(a[1], aliasFn(a[1], a[2], a[3])) end
    for _, m in ipairs(MOD_PORT) do reg(m[1], modFn(m[1], m[2])) end
    reg("sc", function(p) local id = tgt(p) if id then say("/spectate " .. id) else fmsg("Укажите ID: /sc ID") end end)
    reg("scc", function() say("/spectateoff") end)
    reg("sprod", function(p)
        local a, b = trim(p):match("(%d+)%s+(%d+)")
        if a then say("/setbizprod " .. a .. " " .. b) else fmsg("Использование: /sprod [ID бизнеса] [число]") end
    end)
    reg("note", cmdNote) reg("notes", notesMenu)
    reg("bnd", cmdBnd) reg("binder", binderHelp)
    reg("ai", cmdAi) reg("aiset", cmdAiSet) reg("aidiag", aiDiag)
    reg("fhupd", cmdUpd)
    reg("fhdiag", function()
        fmsg("Версия " .. VERSION .. (MOBILE and " (Android)" or " (ПК)") .. ", кодировка: " .. (enc8 and "encoding" or "запасная"))
        fmsg("Окно /fh: " .. (FH.gui and (FH.gui.state() or "готово") or "недоступно") .. ". Репортов: " .. #FH.reports .. ". Авто-/mp: " .. (C.automp and "вкл" or "выкл"))
    end)
end
local function registerAll() registerAll1() registerAll2() end

----------------------------------------------------------------------
-- ОКНО /fh (mimgui). Только простые виджеты: без рисования поверх, без своих шрифтов-атласов, без анимаций.
-- Действия кнопок не выполняются внутри кадра: они откладываются в главный цикл (FH.defer).
----------------------------------------------------------------------
local GUARD_FILE = "FilippHelper.gui"   -- маркер: пока окно открыто, файл существует; если игра упала - при запуске включится безопасный режим
local guardOn = false
local function guardSet(on)
    if on == guardOn then return end
    guardOn = on
    pcall(function()
        local p = cfgDir() .. "/" .. GUARD_FILE
        if on then local f = io.open(p, "wb") if f then f:write("1") f:close() end else os.remove(p) end
    end)
end
local function guardCheck()
    local f = io.open(cfgDir() .. "/" .. GUARD_FILE, "rb")
    if f then
        f:close() os.remove(cfgDir() .. "/" .. GUARD_FILE)
        C.safe = true saveCfg()
        FH.crashNotice = true
    end
end
local function guiAllowed()
    if C.safe then return false end
    if C.force then return true end
    return not (package.loaded and package.loaded["imgui"])   -- старая библиотека imgui в одной игре с mimgui конфликтует
end

local X = {
    CHK = CHK,
    CHK_PRESETS = CHK_PRESETS,
    EVENTS = EVENTS,
    FRACTIONS = FRACTIONS,
    HELP = HELP,
    UPD = UPD,
    VOPROS = VOPROS,
    VR = VR,
    aiAsk = aiAsk,
    aiDiag = aiDiag,
    aiReportDraft = aiReportDraft,
    announceEvent = announceEvent,
    askVopros = askVopros,
    binderHelp = binderHelp,
    chkEnd = chkEnd,
    chkMenu = chkMenu,
    chkShow = chkShow,
    chkStart = chkStart,
    claimMenu = claimMenu,
    cmdAr = cmdAr,
    cmdBnd = cmdBnd,
    cmdPoll = cmdPoll,
    defineRefresh = defineRefresh,
    eventsMenu = eventsMenu,
    fractionMenu = fractionMenu,
    gwIntro = gwIntro,
    helpMenu = helpMenu,
    noteAdd = noteAdd,
    noteShow = noteShow,
    notesMenu = notesMenu,
    recruit = recruit,
    reply = reply,
    roleNames = roleNames,
    saveCfg = saveCfg,
    saveNotes = saveNotes,
    say = say,
    sayInfo = sayInfo,
    sayRules = sayRules,
    sayTimeInfo = sayTimeInfo,
    setInput = setInput,
    showReports = showReports,
    showRules = showRules,
    tempLeader = tempLeader,
    tryoutAad = tryoutAad,
    tryoutO = tryoutO,
    updCheck = updCheck,
    updInstall = updInstall,
}

local function buildGui()
    local okI, imgui = pcall(require, 'mimgui')
    if not okI or type(imgui) ~= "table" then return nil end
    local okF, ffi = pcall(require, 'ffi')
    if not okF then return nil end
    if not MOBILE and not enc8 then return nil end   -- для окна на ПК нужна перекодировка в UTF-8

    local sw, sh = 1280, 720
    pcall(function() sw, sh = getScreenResolution() end)
    local fs = math.max(14, math.min(26, math.floor(sh / 55)))
    local fontPath
    local cand = {}
    local okD, dir = pcall(getFolderPath, 0x14)
    if okD and type(dir) == "string" then for _, n in ipairs({ "arial.ttf", "segoeui.ttf", "tahoma.ttf" }) do cand[#cand + 1] = dir .. "\\" .. n end end
    for _, p in ipairs({ "/system/fonts/Roboto-Regular.ttf", "/system/fonts/NotoSans-Regular.ttf", "/system/fonts/DroidSans.ttf" }) do cand[#cand + 1] = p end
    for _, p in ipairs(cand) do local f = io.open(p, "rb") if f then f:close() fontPath = p break end end
    if not fontPath then return nil end

    local G = { show = imgui.new.bool(false), page = 1, errs = 0, dead = false, initFailed = false }
    local V2, V4 = imgui.ImVec2, imgui.ImVec4
    local ACC, GRAY, YEL = V4(C.accent[1], C.accent[2], C.accent[3], 1), V4(0.62, 0.65, 0.70, 1), V4(1, 0.85, 0.35, 1)

    local function nb(n) return imgui.new.char[n]() end
    local B = { gwWord = nb(64), gwPrize = nb(96), reply = nb(400), evArg = nb(96), bindName = nb(24), bindText = nb(256), noteTitle = nb(48), noteText = nb(256),
        chkWord = nb(24), chkSecs = nb(8), modId = nb(48), modTxt = nb(160), aiQ = nb(300), aiUrl = nb(200), aiKey = nb(200), aiModel = nb(64), aiPrompt = nb(500), poll = nb(64) }
    local accBuf = imgui.new.float[3](C.accent[1], C.accent[2], C.accent[3])
    local bgBuf = imgui.new.float[3](C.bg[1], C.bg[2], C.bg[3])
    local alphaBuf = imgui.new.float(C.alpha)
    local autoBuf, toastBuf = imgui.new.bool(C.automp), imgui.new.bool(C.reptoast)
    local function get(b) return trim(fromUi(ffi.string(b))) end
    local function put(b, s) ffi.copy(b, toUi(tostring(s or ""))) end
    local function clear(b) ffi.fill(b, ffi.sizeof(b), 0) end
    local sel = { report = 0 }
    local aiAnswer = ""

    local ucache, ucount = {}, 0
    local function U(s)
        local c = ucache[s]
        if not c then
            if ucount > 800 then ucache, ucount = {}, 0 end
            c = toUi(s) ucache[s] = c ucount = ucount + 1
        end
        return c
    end
    -- вызов действия вне кадра отрисовки
    local function act(fn) FH.defer(function() local ok, e = pcall(fn) if not ok then log("gui action: " .. tostring(e)) end end) end
    local function btn(label, fn, w)
        if imgui.Button(U(label) .. "##" .. label, w and V2(w, 0) or V2(0, 0)) then act(fn) end
    end
    local n = 0
    local function row(label, fn)   -- кнопки в ряд по 3
        n = n + 1
        if (n - 1) % 3 ~= 0 then imgui.SameLine() end
        btn(label, fn, fs * 10)
    end
    local function newRows() n = 0 end
    local function head(s) imgui.TextColored(ACC, U(s)) imgui.Separator() end
    local function input(label, b, w) imgui.PushItemWidth(w or fs * 18) imgui.InputText("##" .. label, b, 256) imgui.PopItemWidth() imgui.SameLine() imgui.Text(U(label)) end
    local function cmd(name, arg) return function() local f = FH.cmds[name] if f then f(arg or "") end end end

    local pages = {}
    pages[#pages + 1] = { "Главная", function()
        head("FilippHelper " .. VERSION .. " by ByFilipp")
        imgui.Text(U("ID из /re: " .. tostring(FH.watched or "нет") .. "   Репортов: " .. #FH.reports .. "   Авто-/mp: " .. (C.automp and "вкл" or "выкл")))
        imgui.Spacing()
        newRows()
        row("Репорты в чат", X.showReports) row("Обновить из /define", X.defineRefresh) row("Мероприятия", X.eventsMenu)
        row("Фракции", X.fractionMenu) row("Проверка активности", X.chkMenu) row("Занять задачу", X.claimMenu)
        row("Все команды", X.helpMenu) row("Шпаргалки", X.notesMenu) row("Справка по биндеру", X.binderHelp)
    end }
    pages[#pages + 1] = { "Репорты", function()
        head("Репорты")
        if #FH.reports == 0 then imgui.TextColored(GRAY, U("Репортов пока нет. Кнопка ниже берёт список из /define.")) end
        for i, r in ipairs(FH.reports) do
            if imgui.Selectable(U(string.format("%s[%s]: %s", r.name, r.id, r.text)) .. "##r" .. i, sel.report == i) then sel.report = i end
        end
        imgui.Spacing()
        newRows()
        row("Обновить из /define", X.defineRefresh)
        local r = FH.reports[sel.report]
        if r then
            input("Ответ", B.reply, fs * 26)
            newRows()
            row("Отправить", function() X.reply(r.id, get(B.reply)) end)
            row("Жалоба в /a (/ar)", function() X.cmdAr(r.id) end)
            row("ИИ ответ", function()
                X.aiReportDraft(r, function(ok, text) if ok then FH.defer(function() put(B.reply, text) end) else FH.defer(function() fmsg("ИИ: " .. text) end) end end)
            end)
            imgui.Text(U("Шаблоны:"))
            for i, t in ipairs(FH.templates) do if imgui.Selectable(U(i .. ". " .. t) .. "##t" .. i, false) then put(B.reply, t) end end
        end
    end }
    pages[#pages + 1] = { "Раздача", function()
        head("Раздача призов")
        input("Слово", B.gwWord) input("Приз (банк 500000, лвл 3, #9 15)", B.gwPrize)
        newRows()
        row("Запустить", function() FH.cmds.gw(get(B.gwWord) .. " | " .. get(B.gwPrize)) end)
        row("Финал", function() FH.cmds.gwlast(get(B.gwWord) .. " | " .. get(B.gwPrize)) end)
        row("Отмена", cmd("gwstop")) row("Анонс раздачи", function() X.gwIntro(get(B.gwPrize)) end)
        imgui.Spacing()
        imgui.TextColored(GRAY, U(FH.gw.active and ("Идёт раздача, слово: " .. tostring(FH.gw.word)) or "Раздача не запущена."))
    end }
    pages[#pages + 1] = { "Мероприятия", function()
        head("Мероприятия")
        input("Приз (для «Догони Инфернус»: ID ведущего и приз)", B.evArg, fs * 18)
        newRows()
        for _, e in ipairs(X.EVENTS) do row(e[2], function() X.announceEvent(e, get(B.evArg)) end) end
    end }
    pages[#pages + 1] = { "Фракции", function()
        head("Фракции: набор / отбор / лидерка")
        for i, f in ipairs(X.FRACTIONS) do
            imgui.Text(U(f[2])) imgui.SameLine(fs * 14)
            btn("Набор##" .. i, function() X.recruit(f) end) imgui.SameLine()
            btn("Отбор /aad##" .. i, function() X.tryoutAad(f) end) imgui.SameLine()
            btn("Отбор /o##" .. i, function() X.tryoutO(f) end) imgui.SameLine()
            btn("Лидерка##" .. i, function() X.tempLeader(f) end)
        end
    end }
    pages[#pages + 1] = { "Проверка", function()
        head("Проверка активности в /a")
        input("Слово ответа (по умолч. 1)", B.chkWord, fs * 8) input("Время, сек (0 - без таймера)", B.chkSecs, fs * 6)
        local function opts() return { word = get(B.chkWord), seconds = tonumber(get(B.chkSecs)) } end
        newRows()
        row("Общая проверка", function() X.chkStart(nil, opts()) end)
        for _, pr in ipairs(X.CHK_PRESETS) do row(pr[1], function() X.chkStart(X.roleNames(pr[2]), opts()) end) end
        row("Итог", X.chkShow) row("Завершить", function() X.chkEnd(true) end)
        imgui.Spacing()
        imgui.TextColored(GRAY, U(X.CHK.active and string.format("Идёт проверка. Отметились: %d", #X.CHK.list) or "Проверка не запущена."))
    end }
    pages[#pages + 1] = { "Памятки", function()
        head("Объявления и памятки")
        newRows()
        row("Нормы онлайна (/pravila)", X.sayRules) row("Инфо игрокам (/inf)", X.sayInfo) row("Акция за онлайн", X.sayTimeInfo)
        row("Правила каптов", function() X.showRules("capt") end) row("Правила бизваров", function() X.showRules("biz") end)
        imgui.Spacing() imgui.Text(U("Частые вопросы лидеру:"))
        newRows()
        for i, v in ipairs(X.VOPROS) do row(i .. ". " .. v[1], function() X.askVopros(tostring(i)) end) end
        imgui.Spacing()
        input("Опрос: должность и ник", B.poll, fs * 18)
        newRows() row("Запустить опрос", function() X.cmdPoll(get(B.poll)) end)
    end }
    pages[#pages + 1] = { "Транспорт", function()
        head("Транспорт")
        newRows()
        row("Спавн каров (/spc)", cmd("spc")) row("Заправка (/fc)", cmd("fc"))
        row("Удалить админ-кары (15 с)", cmd("dva")) row("Удалить и спавн (15 с)", cmd("dvs")) row("Стоп таймера", cmd("vrstop"))
        imgui.TextColored(GRAY, U(X.VR.active and "Таймер идёт." or "Удаление всегда с предупреждением в /a."))
    end }
    pages[#pages + 1] = { "Модерация", function()
        head("Модерация: ID или ник")
        input("ID или ник", B.modId, fs * 12) input("Причина", B.modTxt, fs * 20)
        local function t() local id = get(B.modId) if id == "" then id = FH.watched or "" end return id end
        newRows()
        local function srv(c, withReason) return function()
            local id = t()
            if id == "" then fmsg("Укажите ID или ник.") return end
            local r = get(B.modTxt)
            if withReason and r ~= "" then X.say("/" .. c .. " " .. id .. " " .. r) else X.setInput("/" .. c .. " " .. id .. " ") end
        end end
        for _, m in ipairs({ { "Варн", "warn" }, { "Мут", "mute" }, { "Джайл", "jail" }, { "Бан", "ban" }, { "Снять варн", "unwarn" }, { "Размут", "unmute" },
            { "Выпустить", "unjail" }, { "Разбан", "unban" } }) do row(m[1], srv(m[2], true)) end
        for _, m in ipairs({ { "Статистика", "getstats" }, { "Инвентарь", "checkinv" }, { "Следить", "spectate" }, { "Спавн игрока", "aspawn" } }) do row(m[1], srv(m[2], false)) end
        row("Гетто (/ghetto)", cmd("gh")) row("Склад (/warehouse)", cmd("wh"))
    end }
    pages[#pages + 1] = { "ИИ", function()
        head("ИИ-помощник")
        input("Вопрос", B.aiQ, fs * 26)
        newRows()
        row("Спросить", function()
            local q = get(B.aiQ)
            if q == "" then return end
            X.aiAsk(q, function(ok, text) FH.defer(function() aiAnswer = ok and text or ("Ошибка: " .. text) end) end)
        end)
        row("Очистить", function() aiAnswer = "" clear(B.aiQ) end)
        imgui.Spacing()
        imgui.PushTextWrapPos(0) imgui.TextWrapped(U(aiAnswer ~= "" and aiAnswer or "Ответ появится здесь.")) imgui.PopTextWrapPos()
    end }
    pages[#pages + 1] = { "Биндер", function()
        head("Биндер")
        input("Имя (команда /имя)", B.bindName, fs * 10) input("Текст (строки через ;;)", B.bindText, fs * 26)
        newRows() row("Создать / добавить", function() X.cmdBnd("add " .. get(B.bindName) .. " " .. get(B.bindText)) end)
        imgui.Spacing()
        for i, b in ipairs(FH.binds) do
            imgui.Text(U("/" .. b.name .. " - строк: " .. #b.lines)) imgui.SameLine()
            btn("Показать##b" .. i, function() X.cmdBnd("show " .. b.name) end) imgui.SameLine()
            btn("Удалить##b" .. i, function() X.cmdBnd("del " .. b.name) end)
        end
    end }
    pages[#pages + 1] = { "Шпаргалки", function()
        head("Шпаргалки")
        input("Название", B.noteTitle, fs * 12) input("Текст (строки через ;;)", B.noteText, fs * 26)
        newRows() row("Сохранить", function() fmsg(X.noteAdd(get(B.noteTitle), get(B.noteText))) end)
        imgui.Spacing()
        for i, nt in ipairs(FH.notes) do
            imgui.Text(U(nt.title .. " (" .. #nt.lines .. ")")) imgui.SameLine()
            btn("Открыть##n" .. i, function() X.noteShow(nt) end) imgui.SameLine()
            btn("Удалить##n" .. i, function() table.remove(FH.notes, i) X.saveNotes() end)
        end
    end }
    pages[#pages + 1] = { "Настройки", function()
        head("Настройки")
        if imgui.Checkbox(U("Авто-/mp после анонса МП и отбора") .. "##am", autoBuf) then C.automp = autoBuf[0] and true or false act(X.saveCfg) end
        if imgui.Checkbox(U("Сообщение в чат о новом репорте") .. "##rt", toastBuf) then C.reptoast = toastBuf[0] and true or false act(X.saveCfg) end
        if imgui.ColorEdit3(U("Цвет акцента") .. "##acc", accBuf) then C.accent = { accBuf[0], accBuf[1], accBuf[2] } act(X.saveCfg) end
        if imgui.ColorEdit3(U("Цвет фона") .. "##bg", bgBuf) then C.bg = { bgBuf[0], bgBuf[1], bgBuf[2] } act(X.saveCfg) end
        if imgui.SliderFloat(U("Прозрачность") .. "##al", alphaBuf, 0.3, 1.0) then C.alpha = alphaBuf[0] act(X.saveCfg) end
        imgui.Spacing() head("ИИ (OpenAI-совместимый API)")
        input("Адрес", B.aiUrl) input("Ключ", B.aiKey) input("Модель", B.aiModel) input("Системный промпт", B.aiPrompt, fs * 26)
        newRows()
        row("Сохранить ИИ", function() C.aiUrl, C.aiKey, C.aiModel, C.aiPrompt = get(B.aiUrl), get(B.aiKey), get(B.aiModel), get(B.aiPrompt) X.saveCfg() fmsg("ИИ: настройки сохранены.") end)
        row("Проверить доступность", X.aiDiag)
        imgui.Spacing() head("Обновление")
        newRows() row("Проверить", function() X.updCheck(true) end) row("Установить", X.updInstall)
        imgui.TextColored(GRAY, U("Версия " .. VERSION .. (X.UPD.latest and (", в репозитории: " .. X.UPD.latest) or "")))
    end }
    pages[#pages + 1] = { "Команды", function()
        head("Все команды")
        for _, h in ipairs(X.HELP) do
            imgui.TextColored(YEL, U(h[1]))
            imgui.PushTextWrapPos(0) imgui.TextWrapped(U(h[2])) imgui.PopTextWrapPos()
            imgui.Spacing()
        end
    end }
    local function loadAi() put(B.aiUrl, C.aiUrl) put(B.aiKey, C.aiKey) put(B.aiModel, C.aiModel) put(B.aiPrompt, C.aiPrompt) end
    loadAi()

    local function style()
        local st = imgui.GetStyle()
        local c, Col = st.Colors, imgui.Col
        local function set(k, r, g, b, a) c[Col[k]] = V4(r, g, b, a or 1) end
        local ar, ag, ab, br, bg, bb = C.accent[1], C.accent[2], C.accent[3], C.bg[1], C.bg[2], C.bg[3]
        local function up(v, d) return math.max(0, math.min(1, v + d)) end
        st.WindowPadding, st.FramePadding, st.ItemSpacing = V2(10, 10), V2(8, 6), V2(8, 8)
        st.WindowRounding, st.ChildRounding, st.FrameRounding = 8, 6, 5
        set("WindowBg", br, bg, bb, C.alpha) set("ChildBg", up(br, 0.03), up(bg, 0.03), up(bb, 0.04))
        set("Text", 0.92, 0.93, 0.95) set("FrameBg", up(br, 0.07), up(bg, 0.08), up(bb, 0.10))
        set("Button", up(br, 0.10), up(bg, 0.11), up(bb, 0.15)) set("ButtonHovered", ar * 0.85, ag * 0.85, ab * 0.85) set("ButtonActive", ar * 0.7, ag * 0.7, ab * 0.7)
        set("Header", ar * 0.75, ag * 0.75, ab * 0.75, 0.6) set("HeaderHovered", ar, ag, ab, 0.7) set("HeaderActive", ar, ag, ab)
        set("CheckMark", ar, ag, ab) set("SliderGrab", ar, ag, ab)
    end

    imgui.OnInitialize(function()
        local ok, err = pcall(function()
            local io = imgui.GetIO()
            io.Fonts:AddFontFromFileTTF(fontPath, fs, nil, io.Fonts:GetGlyphRangesCyrillic())
            style()
        end)
        if not ok then G.initFailed = true log("gui init: " .. tostring(err)) end
    end)

    imgui.OnFrame(function()
        local on = G.show[0] and not G.dead and not G.initFailed and guiAllowed()
        G.on = on and true or false
        guardSet(G.on)
        return on
    end, function(self)
        self.HideCursor = false
        imgui.SetNextWindowSize(V2(fs * 50, fs * 30), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
        if imgui.Begin("FilippHelper##fh", G.show, imgui.WindowFlags.NoCollapse) then
            local ok, err = pcall(function()
                if imgui.BeginChild("##nav", V2(fs * 11, 0), true) then
                    for i, p in ipairs(pages) do
                        if imgui.Selectable(U(p[1]) .. "##p" .. i, G.page == i) then G.page = i end
                    end
                end
                imgui.EndChild()
                imgui.SameLine()
                if imgui.BeginChild("##content", V2(0, 0), true) then pages[G.page][2]() end
                imgui.EndChild()
            end)
            if ok then G.errs = 0 else
                G.errs = G.errs + 1
                log("gui: " .. tostring(err))
                if G.errs >= 3 then G.dead = true G.show[0] = false end
            end
        end
        imgui.End()
    end)

    function G.ready() return not G.dead and not G.initFailed and guiAllowed() end
    function G.toggle() G.show[0] = not G.show[0] end
    function G.open(name)
        for i, p in ipairs(pages) do if p[1] == name then G.page = i end end
        G.show[0] = true
    end
    function G.state() if G.dead then return "отключено из-за ошибок" elseif G.initFailed then return "не запустилось" elseif not guiAllowed() then return "безопасный режим (/fhgui on)" end end
    return G
end

----------------------------------------------------------------------
-- ЗАПУСК
----------------------------------------------------------------------
loadCfg()
pcall(guardCheck)
do
    local ok, g = pcall(buildGui)
    if ok then FH.gui = g else log("gui build: " .. tostring(g)) end
end

local function guiReady() return FH.gui and FH.gui.ready() end

local function registerUi()
    registerCmd("fh", function() if guiReady() then FH.gui.toggle() else helpMenu() end end)
    registerCmd("fbind", function() if guiReady() then FH.gui.open("Биндер") else binderHelp() end end)
    registerCmd("fhgui", function(p)
        p = trim(p)
        if p == "off" then C.safe = true saveCfg() if FH.gui then FH.gui.show[0] = false end fmsg("Окно выключено, /fh покажет диалоги.")
        elseif p == "on" then C.safe, C.force = false, true saveCfg() fmsg("Окно включено (в том числе при старом imgui). Откройте /fh.")
        else fmsg("Использование: /fhgui on|off. Сейчас: " .. (guiReady() and "окно доступно" or "диалоги")) end
    end)
    registerCmd("reptest", function(p) addReport("Test_Player", "7", trim(p) ~= "" and trim(p) or "Тестовый репорт") fmsg("{FFFF00}Репорт от Test_Player[7]: {FFFFFF}тест") end)
end

function main()
    if isSampLoaded and not isSampLoaded() then return end
    if isSampfuncsLoaded and not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    -- ждём полного входа на сервер: до этого нельзя вызывать почти ничего из SAMP
    while true do
        local ok, st = pcall(sampGetGamestate)
        if ok and st == 3 then break end
        wait(500)
    end
    wait(2500)
    FH.ready = true

    local ok, err = pcall(function()
        loadTpl() loadNotes() loadBinds()
        registerAll() registerUi()
        for _, b in ipairs(FH.binds) do registerBind(b) end
    end)
    if not ok then log("init: " .. tostring(err)) end

    fmsg("FilippHelper " .. VERSION .. " by ByFilipp. Меню: {FFFF00}/fh{FFFFFF}, команды: {FFFF00}/fcmd{FFFFFF}.")
    if FH.crashNotice then fmsg("{FFCC00}Прошлый раз игра закрылась при открытом окне - оно отключено. Вернуть: /fhgui on") end
    if not guiReady() and not FH.crashNotice then fmsg("Окно /fh недоступно (нет mimgui, шрифта или найден старый imgui) - /fh откроет диалог.") end

    local t0 = os.clock()
    local checked = false
    while true do
        wait(50)
        if #FH.deferred > 0 then
            local list = FH.deferred
            FH.deferred = {}
            for _, fn in ipairs(list) do local ok2, e = pcall(fn) if not ok2 then log("defer: " .. tostring(e)) end end
        end
        if not checked and os.clock() - t0 > 15 then checked = true updCheck(false) end
    end
end
