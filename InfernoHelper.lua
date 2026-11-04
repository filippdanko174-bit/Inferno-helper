-- Inferno Helper v1 ByFilipp (Halloween Update) -- исправленная и оптимизированная версия.
-- Файл должен быть в кодировке Windows-1251 (cp1251), как и оригинал.
local okEv, ev = pcall(require, 'samp.events')
if not okEv then ev = require 'lib.samp.events' end

local currentTargetID = nil
local scThread = nil
local globalReportTexts = {}

local MAX_CHAT_LEN = 128   -- безопасная длина строки для sampSendChat (длиннее -- риск вылета клиента)
local SEND_GAP     = 1100  -- пауза между сообщениями (антифлуд сервера)

-- Состояние раздачи (всё в одном месте)
local giveaway = { active = false, last = false, word = "", prize = "", startedAt = 0 }

local postNames = {
    ["ИО"]       = "И.О",
    ["ЗО"]       = "Заместителя Основателя",
    ["ПО"]       = "Помощника Основателя",
    ["КС"]       = "Куратора Сервера",
    ["ЗКС"]      = "Заместителя Куратора Сервера",
    ["ГА"]       = "Главного Администратора",
    ["ЗГА"]      = "Заместителя ГА",
    ["ГС ГОСС"]  = "ГС GOSS",
    ["ГС ГЕТТО"] = "ГС GHETTO",
    ["ГС МАФИИ"] = "ГС MAFIA"
}

-- Файл уже в cp1251, перекодировка не нужна (оригинальная u8 просто копировала строку побайтно).
local function u8(str) return str end

-- @ENC-BEGIN (на ПК файл уже в cp1251, перекодировка не нужна)
local function toGame(s) return s end     -- строка скрипта -> игра
local function fromGame(s) return s end   -- игра -> строка скрипта
-- @ENC-END

----------------------------------------------------------------------
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
----------------------------------------------------------------------

-- Нижний регистр с учётом кириллицы cp1251 (string.lower кириллицу не трогает)
local LOWER_MAP = {}
for b = 192, 223 do LOWER_MAP[string.char(b)] = string.char(b + 32) end
LOWER_MAP[string.char(168)] = string.char(184) -- Ё -> ё
local function lower1251(s)
    return (s:lower():gsub("[\192-\223\168]", LOWER_MAP))
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function containsAny(s, list)
    for i = 1, #list do
        if s:find(list[i], 1, true) then return true end
    end
    return false
end

-- Безопасная отправка: обрезаем слишком длинные строки
local function safeSend(text)
    text = toGame(tostring(text or "")):gsub("%c", " ")
    if text == "" then return end
    if #text > MAX_CHAT_LEN then text = text:sub(1, MAX_CHAT_LEN) end
    local ok, err = pcall(sampSendChat, text)
    if not ok then print("[Inferno Helper] sampSendChat error: " .. tostring(err)) end
end

-- Отправка списка строк одним потоком с паузами. onDone вызывается после последней строки.
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
        if not ok then print("[Inferno Helper] sendSeq error: " .. tostring(err)) end
        if onDone then pcall(onDone) end
    end)
end

----------------------------------------------------------------------
-- РАЗДАЧА: разбор приза
----------------------------------------------------------------------
-- {номер статы, фиксированное количество или nil, корни слов...}. Порядок важен: срабатывает первое совпадение.
local PRIZE_RULES = {
    { 13, "1000000", "кунг", "kong", "kung" },
    { 14, "1000000", "кик", "kick" },
    { 12, "1000000", "бокс", "box", "стил" },
    { 2,  nil, "закон" },
    { 1,  nil, "уров", "лвл", "lvl" },
    { 3,  nil, "мат", "патрон", "желез" },
    { 4,  nil, "убий" },
    { 5,  nil, "номер", "тел", "sim" },
    { 6,  nil, "exp", "эксп" },
    { 8,  nil, "мобил", "сотов" },
    { 9,  nil, "нал" },
    { 10, nil, "аптеч" },
    { 11, nil, "член", "орг" },
    { 15, nil, "зависим" },
    { 16, nil, "нарко", "порох", "drug" },
    { 7,  nil, "банк", "ден", "руб" },
}

-- Количество из названия приза: "500000", "1.000.000", "1,000,000" -> без разделителей
local function parseAmount(prize)
    local num = prize:match("%d[%d%.,]*%d") or prize:match("%d+")
    if not num then return "100000" end
    num = num:gsub("[%.,]", "")
    return num
end

local function resolvePrize(prize)
    local low = lower1251(prize)
    for i = 1, #PRIZE_RULES do
        local rule = PRIZE_RULES[i]
        for k = 3, #rule do
            if low:find(rule[k], 1, true) then
                return rule[1], rule[2] or parseAmount(prize)
            end
        end
    end
    return 7, parseAmount(prize) -- по умолчанию банк
end

----------------------------------------------------------------------
-- РАЗДАЧА: победитель и запуск раунда
----------------------------------------------------------------------
local function onGiveawayWinner(name, id)
    giveaway.active = false
    local isLast = giveaway.last
    giveaway.last = false

    local seconds = math.floor(os.clock() - giveaway.startedAt + 0.5)
    if seconds < 1 then seconds = 1 end
    local stat, amount = resolvePrize(giveaway.prize)

    local lines = {
        string.format("/aad РАЗДАЧА | Игрок %s забирает приз! Он успел за %d секунд(ы)!", name, seconds),
        string.format("/pm %s Вы выиграли! Ожидайте, выдам вам приз.", id),
        string.format("/setstat %s %d %s", id, stat, amount),
        string.format("/pm %s Приз успешно выдан! Приятной игры.", id),
    }
    if isLast then
        lines[#lines + 1] = "/aad РАЗДАЧА | На этом наша раздача официально завершена! Всем спасибо за участие."
        lines[#lines + 1] = "/aad РАЗДАЧА | С уважением, Команда / Администрация проекта Inferno Pride!"
    end
    sendSeq(lines, SEND_GAP, nil, SEND_GAP)
end

-- Разбор "[Фраза] - [Приз]"
local function parseGiveawayParam(param)
    param = param or ""
    local word, prize = param:match("^(.-)%s+%-%s+(.+)$") -- сначала дефис с пробелами ("кто-то - 100к")
    if not word then word, prize = param:match("^(.-)%s*%-%s*(.+)$") end
    if not word then return nil end
    word, prize = trim(word), trim(prize)
    if word == "" or prize == "" then return nil end
    return word, prize
end

local function startGiveaway(param, isLast)
    local word, prize = parseGiveawayParam(param)
    if not word then
        sampAddChatMessage(string.format("{1E90FF}[Inferno Helper] {FFFFFF}Использование: /%s [Фраза] - [Описание приза]", isLast and "razdlast" or "razd"), -1)
        return
    end
    giveaway.word      = lower1251(word)
    giveaway.prize     = prize
    giveaway.last      = isLast
    giveaway.startedAt = os.clock()
    giveaway.active   = true

    local lines
    if isLast then
        lines = {
            string.format("/aad РАЗДАЧА | ВНИМАНИЕ! Стартует ФИНАЛЬНЫЙ раунд раздачи! Приз: %s!", prize),
            string.format("/aad РАЗДАЧА | Кто первый напишет финальную фразу '%s' в репорт — заберёт последний приз!", word),
        }
        sampAddChatMessage("{1E90FF}[Inferno Helper] {FFFFFF}Финальный раунд раздачи запущен! Скрипт сам закроет сессию!", -1)
    else
        lines = {
            string.format("/aad РАЗДАЧА | Разыгрывается приз: %s!", prize),
            string.format("/aad РАЗДАЧА | Кто первый напишет кодовую фразу '%s' в репорт — заберёт приз!", word),
        }
        sampAddChatMessage(string.format("{1E90FF}[Inferno Helper] {FFFFFF}Раздача запущена! Ожидание слова: {FFFF00}%s {FFFFFF}| Приз: {FFFF00}%s", word, prize), -1)
    end
    sendSeq(lines, SEND_GAP)
end

----------------------------------------------------------------------
-- ОБРАБОТКА СООБЩЕНИЙ СЕРВЕРА
----------------------------------------------------------------------
local GIVEAWAY_IGNORE = {
    "ответьте на репорт", "работайте по жалобе", "отвечаем на репорт",
    "РАЗДАЧА |", "MP |", "OTBOR |", "NABOR |", "OPROS |",
}

local function onServerMessageImpl(color, text)
    if type(text) ~= "string" then return end
    text = fromGame(text)
    if text:find("Danil_Telekinezov", 1, true) and (text:find("авторизовался", 1, true) or text:find("админ", 1, true)) then
        sampAddChatMessage("{FF6600}[Inferno Helper] {9933FF}Помощник разработчика Danil_Telekinezov вступил на дежурство. Приятной работы!", -1)
    end

    -- Быстрый выход: всё дальше касается только строк "Репорт от ..."
    if not text:find("Репорт", 1, true) then return end

    local cleanText = text:gsub("{%x%x%x%x%x%x}", ""):gsub("%c", "")
    local rName, rId, rRaw = cleanText:match("Репорт от ([A-Za-z0-9_]+)%[(%d+)%]%s*:%s*(.+)")
    if not rName then return end

    local rText = rRaw:gsub("%s*|%s*Уже%s*%d+%s*репорт[^|]*$", "")
    local idNum = tonumber(rId)
    if idNum and idNum < 1000 then globalReportTexts[idNum] = rText end

    if not giveaway.active then return end
    if containsAny(cleanText, GIVEAWAY_IGNORE) then return end
    if rName == "Admin" or rName == "Utka_News" then return end

    if lower1251(trim(rText)) == giveaway.word then
        onGiveawayWinner(rName, rId)
    end
end

function ev.onServerMessage(color, text)
    -- Ошибка в обработчике не должна ронять скрипт/игру
    local ok, err = pcall(onServerMessageImpl, color, text)
    if not ok then print("[Inferno Helper] onServerMessage error: " .. tostring(err)) end
end

local function registerAllInfernoCommands()
    -- ОБЪЕДИНЕННЫЙ ФРАКЦИОННЫЙ БЛОК: НАБОРЫ, ОТБОРЫ ЧАТА /aad И ОТБОРЫ ЧАТА /o
    local function createNaborCmd(cmd, text)
        sampRegisterChatCommand(cmd, function()
            sendSeq({
                "/o NABOR | Минутку внимания! Прямо сейчас открыты наборы.",
                string.format("/o NABOR | Ждем ваши заявки на вступление в %s.", text),
                "/o NABOR | Желаете устроиться? Быстрее пишите в /rep +!",
                "/o NABOR | С уважением, Администрация Inferno Pride!",
            }, 2500)
        end)
    end

    createNaborCmd("nrm", "Русскую Мафию") createNaborCmd("nym", "Японскую Мафию") createNaborCmd("nim", "Итальянскую Мафию")
    createNaborCmd("npb", "Похоронное Бюро") createNaborCmd("nom", "Outlaws MC") createNaborCmd("nrf", "Rifa Gang")
    createNaborCmd("nbl", "Ballas Gang") createNaborCmd("naz", "Aztec Gang") createNaborCmd("ngv", "Grove Street")
    createNaborCmd("nvg", "LS Vagos") createNaborCmd("nap", "Армии ЛС") createNaborCmd("nbls", "Больницу ЛС")
    createNaborCmd("nmr", "Мэрию") createNaborCmd("nrc", "Радиоцентр") createNaborCmd("nsw", "S.W.A.T")
    createNaborCmd("ngov", "Правительство") createNaborCmd("nlspd", "LSPD") createNaborCmd("nfbi", "FBI")
    createNaborCmd("nrcpd", "RCPD") createNaborCmd("nvs", "Верховный суд")
    local function regOtbor(cmd, name, rule)
        sampRegisterChatCommand(cmd, function()
            sendSeq({
                "/aad OTBOR | Уважаемые игроки проекта, минуточку вашего внимания!",
                string.format("/aad OTBOR | Сейчас пройдет official отбор на пост Лидера: %s.", name),
                string.format("/aad OTBOR | Критерии: Возраст 13+ лет, наличие спец. связи ВК и знание %s.", rule),
                "/aad OTBOR | Желающие занять данный пост — ожидайте открытия телепорта!",
            }, SEND_GAP, function()
                sampSetChatInputText("/mp ") sampSetChatInputEnabled(true)
            end)
        end)
    end

    regOtbor("orm", "Русская мафия", "правил Бизваров") regOtbor("oym", "Японская мафия", "правил Бизваров") regOtbor("oim", "Итальянская мафия", "правил Бизваров")
    regOtbor("opb", "Похоронное бюро", "правил Бизваров") regOtbor("oom", "Outlaws MC", "правил Бизваров") regOtbor("orf", "Rifa Gang", "действующих правил Каптов")
    regOtbor("obl", "Southside Ballas", "действующих правил Каптов") regOtbor("oaz", "Varlos Los Aztecas", "действующих правил Каптов") regOtbor("ogv", "Grove Street", "действующих правил Каптов")
    regOtbor("ovg", "LS Vagos", "действующих правил Каптов") regOtbor("oap", "Армия ЛС", "общих правил для лидеров") regOtbor("obls", "Hospital ЛС", "общих правил для лидеров")
    regOtbor("omr", "Мэрия", "общих правил для лидеров") regOtbor("orc", "Радиоцентр", "общих правил для лидеров") regOtbor("osw", "S.W.A.T", "общих правил для лидеров")
    regOtbor("ogov", "Правительство", "общих правил для лидеров") regOtbor("olspd", "LSPD", "общих правил для лидеров") regOtbor("ofbi", "FBI", "общих правил для лидеров")
    regOtbor("orcpd", "RCPD", "общих правил для лидеров") regOtbor("ovs", "Верховный суд", "общих правил для лидеров")
    local function regOOtbor(cmd, name, rule)
        sampRegisterChatCommand(cmd, function()
            sendSeq({
                "/o OTBOR | Ув. игроки, минуточку вашего внимания!",
                string.format("/o OTBOR | Сейчас пройдет отбор на пост Лидера: %s!", name),
                string.format("/o OTBOR | Критерии: 13+ лет, связь ВК и знание %s!", rule),
                "/o OTBOR | Желающие занять данный пост — прописывайте: /gomp",
            }, 2500)
        end)
    end

    regOOtbor("oorm", "Русская мафия", "правил Бизваров") regOOtbor("ooym", "Японская мафия", "правил Бизваров") regOOtbor("ooim", "Итальянская мафия", "правил Бизваров")
    regOOtbor("oopb", "Похоронное бюро", "правил Бизваров") regOOtbor("ooom", "Outlaws MC", "правил Бизваров") regOOtbor("oorf", "Rifa Gang", "правил Каптов")
    regOOtbor("oobl", "Ballas Gang", "правил Каптов") regOOtbor("ooaz", "Aztec Gang", "правил Каптов") regOOtbor("oogv", "Grove Street", "правил Каптов")
    regOOtbor("oovg", "LS Vagos", "правил Каптов") regOOtbor("ooap", "Армия ЛС", "правил лидеров") regOOtbor("oobls", "Больница ЛС", "правил лидеров")
    regOOtbor("oomr", "Мэрия", "правил лидеров") regOOtbor("oorc", "Радиоцентр", "правил лидеров") regOOtbor("oosw", "S.W.A.T", "правил лидеров")
    regOOtbor("oogov", "Правительство", "правил лидеров") regOOtbor("oolspd", "LSPD", "правил лидеров") regOOtbor("oofbi", "FBI", "правил лидеров")
    regOOtbor("oorcpd", "RCPD", "правил лидеров") regOOtbor("oovs", "Верховный суд", "правил лидеров")
    local function regMp(cmd, line2, line3, line4)
        sampRegisterChatCommand(cmd, function()
            local lines = {
                "/aad MP | Уважаемые игроки проекта, минуточку вашего внимания!",
                "/aad MP | " .. line2,
                "/aad MP | " .. line3,
            }
            if line4 then lines[#lines + 1] = "/aad MP | " .. line4 end
            sendSeq(lines, SEND_GAP)
        end)
    end

    regMp("mpsv", "Прямо сейчас стартует мероприятие 'Светофор' на мосту!", "Суть: на команду 'Зелёный' бежим к финишу, на 'Красный' — стоим.", "Кто продолжит движение на красный цвет — выбывает. Победит первый на финише.")
    regMp("mppl", "Прямо сейчас стартует мероприятие 'Поливалка' на крыше!", "Суть: удержаться на крыше здания, пока админ поливает вас водой из БТР.", "Использовать оружие и мешать другим запрещено. Победит последний выживший!")
    regMp("mpdb", "Прямо сейчас стартует мероприятие 'Дерби'!", "Суть: садимся по машинам и начинаем жестко таранить и ДБшить оппонентов.", "Тот, чья машина уцелеет и кто останется последним на арене — победитель.")
    regMp("mppr", "Прямо сейчас стартует мероприятие 'Прятки'!", "Суть: хорошенько спрятаться на локации от ведущего администратора.", "По команде разрешено использовать маски (/mask) и анимации (/anim).")
    regMp("mppk", "Прямо сейчас стартует мероприятие 'Паркур'!", "Суть: Добраться до самого верха паркур-зоны быстрее всех остальных.", "Запрещено использовать оружие, мешать другим и юзать баги. Удачи!")
    regMp("mprr", "Прямо сейчас стартует мероприятие 'Русская Рулетка'!", "Суть проста: встать в строй, дождаться очереди и испытать удачу.", "Запрещено нарушать правила строя, использовать оружие и анимации.")
    regMp("mppv", "Прямо сейчас стартует экстремальное мероприятие 'Гонки от Ковша'!", "Суть: Игроки на квадриках должны уворачиваться от Гелика с ковшом в закрытой коробке.", "Использовать баги, чинить транспорт и юзать софты запрещено. Последний выживший выиграл!")
    regMp("mpms", "Прямо сейчас стартует мероприятие 'Мясорубка'!", "Суть: Бегаем по локации и уворачиваемся от ударов бензопилы администратора.", "Использовать оружие, броню и маски запрещено. Победит последний выживший!")
    regMp("mpdn", "Прямо сейчас стартует мероприятие 'Догонялки'!", "Суть: Admin бегает за игроками. Тот, кого админ ударит кулаком — выбывает.", "Убегать можно по всей локации. Использовать анимации и баги запрещено!")
    regMp("mpcg", "Прямо сейчас стартует увлекательное мероприятие 'Царь Горы'!", "Суть: Забраться на самый верх горы объектов и удержаться там кулаками.", "Использовать оружие и маски запрещено. Кто останется на вершине в конце — победил!")
    regMp("mppp", "Прямо сейчас стартует масштабное мероприятие 'Прыжки с Парашютом'!", "Суть: Всем выдаются парашюты. Ваша задача — приземлиться строго на админскую метку.", "Кто промахнется или разобьется — выбывает. Проявите точность приземления!")
    regMp("mpkd", "Прямо сейчас стартует мероприятие 'Король Дигла'!", "Суть: Всем выдается Deagle. Ваша задача — уничтожить всех соперников.", "Тот, кто останется последним живым на арене, заберет главный приз!")
    regMp("mpus", "Прямо сейчас стартует мероприятие 'Увернись от Султана'!", "Суть: Игроки встают в строй, а админ едет на авто. Нужно вовремя прыгнуть.", "Кто попадет под колеса или отлетит — выбывает. Проявите реакцию!")

    sampRegisterChatCommand("mpinf", function(arg)
        local targetId = nil
        if arg and arg:match("^%d+$") then targetId = arg
        elseif currentTargetID then targetId = currentTargetID end
        if targetId then
            lua_thread.create(function()
                safeSend(u8("/aad MP | Уважаемые игроки проекта, минуточку вашего внимания!")) wait(1100)
                safeSend(u8("/aad MP | Прямо сейчас стартует интерактивное мероприятие 'Догони Инфернус'!")) wait(1100)
                safeSend(string.format(u8("/aad MP | Задача: Найти на карте ЧЁРНЫЙ INFERNUS админа и передать 1 рубль через /pay %s 1."), targetId)) wait(1100)
                safeSend(u8("/aad MP | Использовать читы, ДБ и мешать другим игрокам запрещено. Кто первый передал — победил!"))
            end)
        else
            sampAddChatMessage(u8("{1E90FF}[Inferno Helper] {FFFFFF}Ошибка! Укажите ID админа: {FFFF00}/mpinf [ID]"), -1)
        end
    end)
    sampRegisterChatCommand("mppb", function()
        lua_thread.create(function()
            safeSend(u8("/aad MP | Уважаемые игроки проекта, минуточку вашего внимания!")) wait(1100)
            safeSend(u8("/aad MP | Прямо сейчас стартует командное мероприятие 'Пейнтбол'!")) wait(1100)
            safeSend(u8("/aad MP | Суть: Каждый сам за себя. Ваша задача — набрать как можно больше убийств.")) wait(1100)
            safeSend(u8("/aad MP | Победит тот человек, у которого в конце матча будет больше всего киллов!")) wait(1100)
            safeSend(u8("/aad MP | Телепорт открыт! Для автоматического участия прописывайте: /gomp"))
        end)
    end)

    sampRegisterChatCommand("mpks", function()
        lua_thread.create(function()
            safeSend(u8("/aad MP | Уважаемые игроки проекта, минуточку вашего внимания!")) wait(1100)
            safeSend(u8("/aad MP | Прямо сейчас стартует увлекательное мероприятие 'Круг Смерти'!")) wait(1100)
            safeSend(u8("/aad MP | Суть: Все участники встают в один большой круг и включают анимации.")) wait(1100)
            safeSend(u8("/aad MP | Admin выдает игроку Дигл с 1 патроном. Задача — выстрелить в оппонента.")) wait(1100)
            safeSend(u8("/aad MP | Кто готов рискнуть и забрать ценный приз — пишите быстрее: /gomp"))
        end)
    end)

    sampRegisterChatCommand("inf", function()
        lua_thread.create(function()
            safeSend(u8("/aad INFO | Уважаемые игроки, администрация сервера всегда на связи!")) wait(1100) 
            safeSend(u8("/aad INFO | Если вы столкнулись с нарушением правил или багом — пишите в /rep.")) wait(1100)
            safeSend(u8("/aad INFO | Пожалуйста, формулируйте свой вопрос или жалобу четко и ясно.")) wait(1100)
            safeSend(u8("/aad INFO | Оффтоп, флуд и оскорбления в репорт строго наказываются.")) wait(1100)
            safeSend(u8("/aad INFO | Желаем вам приятной игры и отличного настроения на Inferno Pride!"))
        end)
    end)
    sampRegisterChatCommand("razdintro", function()
        lua_thread.create(function()
            safeSend(u8("/aad РАЗДАЧА | Уважаемые игроки проекта, минуточку вашего внимания!")) wait(1100)
            safeSend(u8("/aad РАЗДАЧА | ПРЯМО СЕЙЧАС пройдет быстрая раздача призов! Готовим свои пальчики..."))
        end)
    end)

    sampRegisterChatCommand("razd", function(param) startGiveaway(param, false) end)

    sampRegisterChatCommand("razdlast", function(param) startGiveaway(param, true) end)
    sampRegisterChatCommand("sc", function()
        if scThread then pcall(function() scThread:terminate() end) end
        scThread = lua_thread.create(function()
            safeSend(u8("/a Внимание, через 15 секунд я удаляю и респавню весь транспорт на сервере!"))
            wait(15000) 
            safeSend("/dvall") wait(1500) 
            safeSend("/spawncars")
            scThread = nil
        end)
    end)

    sampRegisterChatCommand("scc", function()
        if scThread then
            pcall(function() scThread:terminate() end)
            scThread = nil
            sampAddChatMessage(u8("{1E90FF}[Inferno Helper] {FF3333}Экстренно! Таймер респавна успешно остановлен."), -1)
        else sampAddChatMessage(u8("{1E90FF}[Inferno Helper] {A9A9A9}Ошибка! Таймер спавна сейчас не запущен."), -1) end
    end)

    local function regSimpleCmd(cmd, sCmd)
        sampRegisterChatCommand(cmd, function(arg)
            if arg and arg ~= "" then safeSend(string.format("/%s %s", sCmd, arg))
            else sampAddChatMessage(u8("[Inferno Helper] Укажите параметры."), -1) end
        end)
    end
    regSimpleCmd("uwn", "unwarn") regSimpleCmd("ujl", "unjail") regSimpleCmd("um", "unmute")
    regSimpleCmd("bn", "ban") regSimpleCmd("ubn", "unban")
    local function regShortCmd(cmd, sCmd, hasParam)
        sampRegisterChatCommand(cmd, function(param)
            if hasParam and (not param or param == "") then sampAddChatMessage(u8("[Inferno Helper] Ошибка параметров!"), -1) return end
            if hasParam then safeSend(string.format("/%s %s", sCmd, param)) else safeSend("/" .. sCmd) end
        end)
    end
    regShortCmd("ib", "iban", true) regShortCmd("pg", "pgetip", true) regShortCmd("bi", "banip", true)
    regShortCmd("ol", "offleader", true) regShortCmd("mle", "makeleader", true)
    regShortCmd("fc", "fuelcars", false)

    sampRegisterChatCommand("gt", function() safeSend("/ghetto") end)
    sampRegisterChatCommand("gc", function(param) if param and param ~= "" then safeSend("/gzcolor " .. param) else sampAddChatMessage(u8("[Inferno Helper] Укажите параметры."), -1) end end)
    sampRegisterChatCommand("cb", function(param) if param and param ~= "" then safeSend("/warehouse " .. param) else sampAddChatMessage(u8("[Inferno Helper] Укажите параметры."), -1) end end)
    sampRegisterChatCommand("wh", function() safeSend("/warehouse") end)

    local function regInputCmd(cmd, sCmd)
        sampRegisterChatCommand(cmd, function(arg)
            if arg and arg:match("^%d+$") then sampSetChatInputText(string.format("/%s %s ", sCmd, arg)) sampSetChatInputEnabled(true)
            elseif currentTargetID then sampSetChatInputText(string.format("/%s %s ", sCmd, currentTargetID)) sampSetChatInputEnabled(true)
            else sampAddChatMessage(u8("[Inferno Helper] Ошибка параметров!"), -1) end
        end)
    end
    regInputCmd("jl", "jail") regInputCmd("mt", "mute")
    sampRegisterChatCommand("wn", function(param)
        if param and param ~= "" then safeSend(string.format("/warn %s", param))
        elseif currentTargetID then sampSetChatInputText(string.format("/warn %s ", currentTargetID)) sampSetChatInputEnabled(true)
        else sampAddChatMessage(u8("[Inferno Helper] Ошибка параметров!"), -1) end
    end)

    local function regReCmd(cmd, sCmd)
        sampRegisterChatCommand(cmd, function(arg)
            if arg and arg:match("^%d+$") then safeSend(string.format("/%s %s", sCmd, arg))
            elseif currentTargetID then safeSend(string.format("/%s %s", sCmd, currentTargetID))
            else sampAddChatMessage(u8("[Inferno Helper] Ошибка параметров!"), -1) end
        end)
    end
    regReCmd("as", "getstats") regReCmd("ci", "checkinv")

    sampRegisterChatCommand("sprod", function(param)
        local p1, p2 = string.match(param, "(%d+)%s+(%d+)")
        if p1 and p2 then safeSend(string.format("/setbizprod %s %s", p1, p2))
        else sampAddChatMessage(u8("[Inferno Helper] Ошибка параметров!"), -1) end
    end)

    sampRegisterChatCommand("a1", function()
        lua_thread.create(function()
            safeSend(u8("/a Внимание, важная проверка активности следящей администрации!")) wait(1100)
            safeSend(u8("/a Просьба всем Главным и Заместителям Главных Следящих поставить свой тег!")) wait(1100)
            safeSend(u8("/a Пожалуйста, отпишите в админ-чат строго цифру: 1"))
        end)
    end)
    -- Плавное чтение общих правил в обычный чат с КД 3.5 секунды
    sampRegisterChatCommand("pravila", function()
        local function s(txt) safeSend(u8(txt)) wait(3500) end
        lua_thread.create(function()
            s("Ваша ежедневная норма в будние дни составляет ровно 1 час.")
            s("Норма онлайна в выходные дни составляет 1 час 30 минут.")
            s("Если вы не будете отыгрывать данную норму — будете получать выговоры.")
            s("При получении 3/3 выговоров вас официально снимают с поста лидера с ЧСЛ.")
            s("Обязательный час пик в будние дни проходит строго с 17:00 до 20:00.")
            s("Обязательный час пик в выходные дни проходит строго с 16:00 до 19:00.")
            s("Если вы будете отсутствовать в пиковое время — вы также получаете выговоры.")
            s("По всем возникающим вопросам обращайтесь к следящим вашей структуры!")
        end)
    end)

    -- ХЭЛЛОУИНСКИЙ ОБНОВЛЕННЫЙ МОДУЛЬ ШПАРГАЛОК И БЫСТРЫХ ОТВЕТОВ СЛЕДЯЩИМ
    sampRegisterChatCommand("vopros", function(arg)
        if arg == "1" then 
            safeSend(u8("Что такое ЧП?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}Это Час Пик, обязательное время онлайна для лидеров фракций."), -1)
        elseif arg == "2" then 
            safeSend(u8("Какая норма онлайна у лидера в будни?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}Ваша норма онлайна в будние дни составляет ровно 1 час."), -1)
        elseif arg == "3" then 
            safeSend(u8("Какая норма онлайна у лидера в выходные?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}Ваша норма онлайна в выходные дни составляет 1 час 30 минут."), -1)
        elseif arg == "4" then 
            safeSend(u8("Что обязан делать лидер фракции?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}Лидер обязан активно следить за своей фракцией, форумом и составом."), -1)
        elseif arg == "5" then 
            safeSend(u8("Что такое блат?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}Блат — это когда лидер ставит человека на высокую должность на халяву (без отчетов/обзвона)."), -1)
        elseif arg == "6" then 
            safeSend(u8("Со скольки до скольки длится ЧП в будни?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}В будние дни обязательный час пик длится строго с 17:00 до 20:00."), -1)
        elseif arg == "7" then 
            safeSend(u8("Со скольки до скольки длится ЧП в выходные?"))
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] Подсказка: {FFFFFF}В выходные дни обязательный час пик длится строго с 16:00 до 19:00."), -1)
        else sampAddChatMessage(u8("{FF6600}[Inferno Helper] {FFFFFF}Использование: {FFFF00}/vopros [1-7]"), -1) end
    end)
    -- [АВТО-НАЗНАЧЕНИЕ ВРЕМЕННЫХ ЛИДЕРОК ДЛЯ СЛЕДЯЩИХ]
    local function fL(cmd, id) sampRegisterChatCommand(cmd, function() safeSend("/templeader " .. id) end) end
    fL("lspd", 1) fL("fbi", 2) fL("armia", 3) fL("mcls", 4) fL("ital", 5) fL("yapon", 6) fL("meria", 7)
    fL("ballas", 12) fL("vagos", 13) fL("russ", 14) fL("groove", 15) fL("smi", 16) fL("aztec", 17)
    fL("rifa", 18) fL("hitman", 23) fL("swat", 25) fL("pravo", 26) fL("rcpd", 27) fL("outlaw", 28) fL("syd", 29)

    sampRegisterChatCommand("fastlead", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | ВРЕМЕННЫЕ ЛИДЕРКИ ]\n\n{FFFFFF}Введи команду в чат для авто-выдачи лидерки себе:\n\n{9933FF}ГОС. СТРУКТУРЫ:\t\t\t\tМАФИИ И БАНДЫ:\n{FF6600}/lspd {FFFFFF}- Полиция ЛС (ID: 1)\t\t{FF6600}/ital {FFFFFF}- Итальянская Мафия (ID: 5)\n{FF6600}/fbi {FFFFFF}- ФБР (ID: 2)\t\t\t{FF6600}/yapon {FFFFFF}- Японская Мафия (ID: 6)\n{FF6600}/armia {FFFFFF}- Армия ЛС (ID: 3)\t\t{FF6600}/ballas {FFFFFF}- Ballas Gang (ID: 12)\n{FF6600}/mcls {FFFFFF}- Hospital ЛС (ID: 4)\t\t{FF6600}/vagos {FFFFFF}- Vagos Gang (ID: 13)\n{FF6600}/meria {FFFFFF}- Мэрия ЛС (ID: 7)\t\t{FF6600}/russ {FFFFFF}- Русская Мафия (ID: 14)\n{FF6600}/smi {FFFFFF}- Новостная сеть (ID: 16)\t{FF6600}/groove {FFFFFF}- Grove Street (ID: 15)\n{FF6600}/swat {FFFFFF}- S.W.A.T (ID: 25)\t\t{FF6600}/aztec {FFFFFF}- Aztec Gang (ID: 17)\n{FF6600}/pravo {FFFFFF}- Правительство (ID: 26)\t{FF6600}/rifa {FFFFFF}- Rifa Gang (ID: 18)\n{FF6600}/rcpd {FFFFFF}- RCPD Академия (ID: 27)\t{FF6600}/hitman {FFFFFF}- Похоронное Бюро (ID: 23)\n{FF6600}/syd {FFFFFF}-  Суд (ID: 29)\t{FF6600}/outlaw {FFFFFF}- Outlaws MC (ID: 28)\n\n{9933FF}Для возврата в меню следящего используйте: {FFFF00}/ldhelp")
        sampShowDialog(3220, u8("Inferno Helper | Быстрые Лидерки"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("voprmenu", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | ШПАРГАЛКИ ]\n\n{FFFFFF}Используй команду в чат: {FFFF00}/vopros [Номер вопроса]\n\n{9933FF}СПИСОК ДОСТУПНЫХ ОТВЕТОВ ЛИДЕРАМ:\n{FF6600}Вопрос №1 {FFFFFF}- Что такое ЧП?\n{FF6600}Вопрос №2 {FFFFFF}- Норма лидера в будни (1 час).\n{FF6600}Вопрос №3 {FFFFFF}- Норма лидера в выходные (1 час 30 минут).\n{FF6600}Вопрос №4 {FFFFFF}- Что обязан делать лидер фракции?\n{FF6600}Вопрос №5 {FFFFFF}- Что такое блат?\n{FF6600}Вопрос №6 {FFFFFF}- Время ЧП в будни (с 17:00 до 20:00).\n{FF6600}Вопрос №7 {FFFFFF}- Время ЧП в выходные (с 16:00 до 19:00).\n\n{9933FF}Для возврата в меню следящего используйте: {FFFF00}/ldhelp")
        sampShowDialog(3219, u8("Inferno Helper | Ответы Лидерам"), text, u8("Закрыть"), "", 0)
    end)
    -- [МОДУЛЬ СУПЕР-КОМПАКТНЫХ И ПОНЯТНЫХ ПРАВИЛ КАПТОВ /CAPTURE ДЛЯ СЛЕДЯЩИХ]
    sampRegisterChatCommand("captlist", function()
        local text = u8("{FF6600}INFERNO PRIDE | ШПАРГАЛКА ПО ПРАВИЛАМ КАПТОВ CAPTURE\n\n{33CC33}РАЗРЕШЕНО НА КАПТЕ\n{FFFFFF}• Слайды, полуслайды, +C, сбивы перекатов. Легкодоступные крыши в 2 прыжка или по лестнице.\n• Слив вне квадрата после 5 минут капта. Капт куском или обрезом. Автомобили для баррикад.\n\n{FF3333}ЗАПРЕЩЕНО НАКАЗАНИЕ 1 ИЗ 3 И СПАВН ИЛИ ДЖЕЙЛ ИЛИ ВАРН\n{FFFFFF}• Убийство или запрет на вход в квадрат до 5 минут. Нахождение на крыше выше 2 прыжков.\n• Заходить в интерьер в бою или СК в интерьере банды. Обстрел респавна соперника.\n• Использовать маску, бронежилет, аптечки или наркотики в бою. Вне боя сбивать анимации можно.\n• Находиться в чужом скине, если клист банды отличается от скина фракции.\n\n{FF3333}ТЯЖЕЛЫЕ НАРУШЕНИЯ ИГРОКА ИЛИ ВАРН\n{FFFFFF}• ДНК на капте или Джетпак или Дом на колёсах на территории квадрата. Наказание 1 из 3.\n• Антифраг. Суицид или релог или подстав под смерть от госников, чтобы не дать фраг врагу.\n• Отказ от предоставления опры следящей администрации или скрытие читов на откате. Наказание Варн и минус квадрат.\n• Багоюз Дабл Килл. Наказание 2 из 3. Намеренная стрельба по колесам транспорта врага.\n• Провокация на слив вне квадрата или намеренная провокация на СК у респавна. Наказание Джейл 10 минут.\n\n{FF9900}НАКАЗАНИЯ ДЛЯ ЛИДЕРОВ БАНД И МИНУС ТЕРРИТОРИИ\n{FFFFFF}• Участие в капте игроков от 1 до 3 рангов фракции. Помеха капту от третьей банды. Лидеру 1 из 3.\n• Капт респы любой банды. Наказание Выговор лидеру и отмена капта и минус 3 квадрата.\n• Полный игнор капта или неприезд состава на забив территории. Наказание 1 из 3 лидеру.\n\n{FF6600}Для возврата в меню следящего используйте command /ldhelp")
        sampShowDialog(3221, u8("Inferno Pride | Правила Каптов"), text, u8("Закрыть"), "", 0)
    end)

    -- [НОВЫЙ МОДУЛЬ ШПАРГАЛКИ ПО ПРАВИЛАМ БИЗВАРОВ /BIZWAR ДЛЯ СЛЕДЯЩИХ ЗА МАФИЯМИ]
    sampRegisterChatCommand("bizwarlist", function()
        local text = u8("{FF6600}INFERNO PRIDE | ШПАРГАЛКА ПО ПРАВИЛАМ СТРЕЛ BIZWAR\n\n{33CC33}ОБЩЕЕ ПОЛОЖЕНИЕ И ПРАВИЛА ЗАБИВА\n{FFFFFF}• Забивать стрелу может только Лидер или Заместитель. Забив от 30 минут до начала через ВК.\n• Время проведения стрел строго с 12:00 до 22:00 по московскому времени. Стрелы проводятся минимум 2х2.\n• Длительность стрелы составляет 10 минут. Обязана быть опра от Лидера и Зама при отсутствии следящих.\n• Каждое полученное мафией нарушение 3 из 3 означает, что фракция теряет ровно 1 бизнес.\n\n{FF3333}ЗАПРЕЩЕНО НА БИЗВАРЕ НАКАЗАНИЕ 1 ИЗ 3 ПРЕДУПРЕЖДЕНИЙ\n{FFFFFF}• Любые крыши или горы. Стрельба по машине во время въезда врага в квадрат. Тянуть время вне квадрата.\n• Катать в квадрате на машине более 10 секунд. Наказание 1 из 3 и Спавн.\n• Чужой скин фракции. Помощь посторонних лиц на стреле. Если помогли посторонние, мафии сразу выдается 3 из 3.\n• АФК более 30 секунд. Прилетать на вертолете или приезжать на личном транспорте. Не впускать мафию в квадрат.\n• Выходить из квадрата стрелы. Использовать маску. Использовать бронежилеты или оружие кроме Desert Eagle, M4, Shotgun, Rifle.\n• СпавнКилл, ДрайвБай, ТимКилл. Слив или стрельба вне квадрата. Полный игнор стрелы и следящих.\n• Антифраг. Прыжок с моста или горы, суицид, чтобы враг не получил заслуженный фраг.\n\n{33CC33}ТЯЖЕЛЫЕ НАРУШЕНИЯ НА СТРЕЛЕ\n{FFFFFF}• Использовать любые баги игры или стрельбы, сбивать любые анимации в бою. Наказание 2 из 3.\n• Стрелять с пассажирского сиденья автомобиля. Наказание 1 из 3 и Джейл 10 минут.\n• Проведение стрел вне времени до 12:00 или после 22:00. Наказание Остановка стрелы и Выговор лидеру.\n\n{FF6600}Для возврата в меню следящего используйте command /ldhelp")
        sampShowDialog(3222, u8("Inferno Pride | Правила Бизваров"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("ldhelp", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | ПАНЕЛЬ СЛЕДЯЩЕГО ]\n\n{9933FF}СПИСОК АКТИВНЫХ КОМАНД МОДУЛЯ:\n{FF6600}/pravila {FFFFFF}- Выдать полный свод правил лидерства в обычный чат.\n{FF6600}/voprmenu {FFFFFF}- Открыть список шпаргалок и быстрых ответов на частые вопросы.\n{FF6600}/fastlead {FFFFFF}- Панель моментальной выдачи временной лидерки фракций.\n{FF6600}/captlist {FFFFFF}- Открыть выжимку и шпаргалку по правилам каптов банды.\n{FF6600}/bizwarlist {FFFFFF}- Открыть выжимку и шпаргалку по правилам стрел мафии.\n\n{9933FF}Для вывода основного админ-меню используйте: {FFFF00}/helper")
        sampShowDialog(3218, u8("Inferno Helper | Панель Следящего"), text, u8("Закрыть"), "", 0)
    end)
    -- ПЕРЕДЕЛАHНАЯ СИНХРОННАЯ КОМАНДА АКЦИИ С АНГЛИЙСКИМ РЕПОРТОМ
    sampRegisterChatCommand("timeinfo", function()
        lua_thread.create(function()
            safeSend(u8("/aad INFO | Уважаемые игроки проекта, спешим вам напомнить!")) wait(1100)
            safeSend(u8("/aad INFO | Прямо сейчас у нас действует акция: отыграв время, вы получаете призы!")) wait(1100)
            safeSend(u8("/aad INFO | Каждый день вы можете получать награды до 5 раз, просто отыграв по 1 часу!")) wait(1100)
            safeSend(u8("/aad INFO | Чтобы проверить своё время и забрать приз, введите в чат строго: /rep time")) wait(1100)
            safeSend(u8("/aad INFO | С уважением, Руководство проекта и Команда Inferno Pride!"))
        end)
    end)

    sampRegisterChatCommand("opros", function(param)
        local postTag, adminName = string.match(param, "^([A-Za-zА-Яа-яЁё0-9_%s]+)%s+(.+)$")
        if not postNames[postTag] then
            for tag, _ in pairs(postNames) do
                if param:sub(1, #tag) == tag then
                    postTag = tag
                    adminName = param:sub(#tag + 2)
                    break
                end
            end
        end
        if postTag and adminName and postNames[postTag] then
            local fullPost = postNames[postTag]
            lua_thread.create(function()
                safeSend(string.format(u8("/aad OPROS | Уважаемые игроки сервера, минуту вашего внимания!"))) wait(1100)
                safeSend(string.format(u8("/aad OPROS | Как вы оцениваете работу %s %s? Пишите в /rep [1-5]"), fullPost, adminName))
            end)
        else
            sampAddChatMessage(u8("{FF6600}[Inferno Helper] {FFFFFF}Ошибка! Использование: {FFFF00}/opros [Должность] [Ник]"), -1)
        end
    end)

    sampRegisterChatCommand("helper", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | ГЛАВНОЕ МЕНЮ ]\n\n{9933FF}ИНФОРМАЦИОННЫЕ И МП МОДУЛИ:\n{FF6600}/about {FFFFFF}- Презентация софта и мануал.\n{FF6600}/uinfo {FFFFFF}- Журнал истории обновлений.\n{FF6600}/mphelp {FFFFFF}- Меню запуска МП, раздач и модулей опроса.\n\n{FF3333}РАЗДЕЛ ДЛЯ ЗГС / ГС НАПРАВЛЕНИЙ /9+ LVL/:\n{FF6600}/nmenu {FFFFFF}- Меню со списком команд авто-наборов.\n{FF6600}/omenu {FFFFFF}- Меню публикации админ-отборов в /mp.\n{FF6600}/ldhelp {FFFFFF}- Карманный журнал, лидерки и шпаргалки следящих.\n{FF6600}/hbinder {FFFFFF}- Окно биндера (свои команды), справка: /binder.\n\n{33CC33}ОБЩИЙ МОДЕРАТОРСКИЙ АРСЕНАЛ И НАКАЗАНИЯ:\n{FF6600}/amenu {FFFFFF}- Отдельное окно со всеми сокращениями команд наказаний.\n\n{9933FF}Разработчик софта: {FFFFFF}ByFilipp | {9933FF}Тех. поддержка ВК: {FFFFFF}@ByFilipp123")
        sampShowDialog(3210, u8("Inferno Helper | Панель Управления"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("amenu", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | АРСЕНАЛ ]\n\n{FF6600}/arep ID {FFFFFF}- Умный репорт: авто-ответ игроку + полный пуш сути жалобы в /a.\n{FF6600}/as ID_Админа {FFFFFF}- Просмотр подробной статистики модератора (/getstats).\n{FF6600}/ci ID_Админа {FFFFFF}- Дистанционная проверка инвентаря модератора (/checkinv).\n{FF6600}/fc {FFFFFF}- Полная заправка транспорта всего сервера (/fuelcars).\n{FF6600}/inf {FFFFFF}- Официальное государственное информирование игроков в чат (/aad).\n{FF6600}/timeinfo {FFFFFF}- Оповестить игроков об акции на призы за онлайн (/aad).\n\n{9933FF}[СОКРАЩЕНИЯ И УТИЛИТЫ НАКАЗАНИЙ]:\n{FFFFFF}• Выдача наказаний:\t{FF6600}/jl [ID] (jail), /mt [ID] (mute), /wn [ID/Парам] (warn), /bn [ID] (ban)\n{FFFFFF}• Снятие наказаний:\t{FF6600}/ujl [ID] (unjail), /um [ID] (unmute), /uwn [ID] (unwarn), /ubn [ID] (unban)\n{FFFFFF}• Системные блокировки:\t{FF6600}/ib [ID] (iban), /bi [ID] (banip), /pg [ID] (pgetip)\n{FFFFFF}• Transportные утилиты:\t{FF6600}/sc (Респавн авто через 15 сек), /scc (Остановка таймера)\n\n{FF6600}Для возврата в главное меню используйте: {FFFF00}/helper")
        sampShowDialog(3211, u8("Inferno Helper | Modoratorskiy Arsenal"), text, u8("Закрыть"), "", 0)
    end)
    sampRegisterChatCommand("mphelp", function()
        local text = u8("{FF6600}[ INFERNO HELPER | HALLOWEEN UPDATE | МЕРОПРИЯТИЯ ]\n\n{9933FF}СПИСОК ДОСТУПНЫХ МП:\n{FFFFFF}/mpsv - МП «Светофор»\n/mppl - МП «Поливалка»\n/mpdb - МП «Дерби»\n/mppr - МП «Прятки»\n/mpkd - МП «Король Дигла»\n/mpus - МП «Увернись от Султана»\n/mpinf [ID] - МП «Догони Инфернус»\n\n{FF6600}МОДУЛЬ ИНТЕРАКТИВНЫХ РАЗДАЧ ПРИЗОВ:\n{FF6600}/razdintro {FFFFFF}- Пре-анонс («Готовим свои пальчики»)\n{FF6600}/razd [Слово] - [Приз] {FFFFFF}- Обычный раунд раздачи в репорт\n{FF6600}/razdlast [Слово] - [Приз] {FFFFFF}- ФИНАЛЬНЫЙ раунд с авто-выдачей и авто-закрытием в /aad\n\n{33CC33}АДМИНИСТРАТИВНЫЕ ОПРОСЫ И ТЕСТЫ ОНЛАЙНА:\n{FF6600}/a1 {FFFFFF}- Быстрая проверка активности следящих в админ-чат /a")
        sampShowDialog(3212, u8("Inferno Pride | МП и Раздачи"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("gmenu", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | РУКОВОДСТВО ]\n\n{FF6600}/mle ID {FFFFFF}- Назначить лидера фракции (/makeleader).\n{FF6600}/ol [Ник] {FFFFFF}- Снятие лидера в оффлайне строго по никнейму (/offleader).\n{FF6600}/gt {FFFFFF}- Моментальный телепорт в центр Опасного Района (/ghetto).\n{FF6600}/gc ID {FFFFFF}- Быстро изменить цвет зоны контроля банды (/gzcolor).\n{FF6600}/sprod БИЗ ПР {FFFFFF}- Установить количество продуктов бизнесу (/setbizprod).\n{FFFF00}/cb ID_Фракции {FFFFFF}- Быстая проверка состояния склада (/warehouse).\n{FFFF00}/wh {FFFFFF}- Быстая проверка состояния склада фракции.\n\n{9933FF}?? [ДОПОЛНИТЕЛЬНЫЕ МОДУЛИ ОПОВЕЩЕНИЙ]:\n{FF6600}/nmenu {FFFFFF}- Текстовое меню со списком команд авто-наборов.\n{FF6600}/omenu {FFFFFF}- Текстовое меню публикации админ-отборов в /mp.\n\n{FF6600}Для вывода основного списка используйте: {FFFF00}/helper")
        sampShowDialog(3213, u8("Inferno Helper | Руководство"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("uinfo", function()
        local text = u8("{FF6600}[ INFERNO HELPER | HALLOWEEN UPDATE | ОБНОВЛЕНИЯ ]\n\n{33CC33}ВЕРСИЯ v1.0 | ОФИЦИАЛЬНЫЙ РЕЛИЗ\n{FFFFFF}• Первоначальный стабильный релиз скрипта для администрации сервера.\n• Создана базовая панель сокращений админ-команд (/jl, /mt, /wn, /bn).\n\n{33CC33}ВЕРСИЯ v1.1 | ПРОШЛОЕ ОБНОВЛЕНИЕ\n{FFFFFF}• Добавлен большой базовый пакет МП в модуль /mphelp.\n• Интегрирована полностью автоматическая система раздач.\n• Исправлены первые критические баги и зависания лаунчера.\n\n{33CC33}ВЕРСИЯ v1 ByFilipp | ТЕКУЩИЙ ГЛОБАЛЬНЫЙ РЕЛИЗ\n{FFFFFF}• Полностью переделали и оптимизировали автоответ на репорты /arep.\n• Успешно разработали и внедрили новую систему опросов игроков /opros.\n• Добавлен новый пакет МП, все списки выровнены строго в один абзац.\n• {33CC33}Внедрена революционная команда /razdlast с полным циклом авто-закрытия!\n\n{FF6600}С уважением к администрации Inferno Pride. Разработчик: ByFilipp!")
        sampShowDialog(3214, u8("Inferno Helper | Обновления"), text, u8("Закрыть"), "", 0)
    end)

    sampRegisterChatCommand("about", function()
        local text = u8("{FF6600}[ INFERNO HELPER v1 ByFilipp | HALLOWEEN UPDATE | ИНФО ]\n\n{FFFFFF}Административный ассистент разработан создателем {33CCFF}ByFilipp {FFFFFF}специально\nдля автоматизации рутины и облегчения работы следящей администрации сервера.\n\n{9933FF}ГЛАВНЫЕ НАПРАВЛЕНИЯ АССИСТЕНТА:\n{33CC33}• Система опросов {FFFFFF}- Двухстрочные голосования в /aad по оценке работы админов (/opros).\n{33CC33}• Автоматизация МП {FFFFFF}- Быстрый запуск, трансляция правил из ВК и интерактивные раздачи.\n{33CC33}• Контроль фракций {FFFFFF}- Экспресс-реклама наборов и критерии админ-отборов.\n{33CC33}• Admin-Арсенал {FFFFFF}- Сокращенные команды наказания, умный репорт и защита от лагов.\n\n{FF6600}Для вывода полного списка доступных команд введите: {FFFF00}/helper")
        sampShowDialog(3215, u8("Inferno Helper | Ознакомление"), text, u8("Закрыть"), "", 0)
    end)
    sampRegisterChatCommand("nmenu", function()
        local text = u8("{FF6600}[ INFERNO HELPER | HALLOWEEN UPDATE | НАБОРЫ ВО ФРАКЦИИ ]\n\n{FFFFFF}/nrm\t- Русская Мафия\t\t\t/nrf\t- Rifa Gang\n/nym\t- Японская Мафия\t\t\t/nbl\t- Ballas Gang\n/nim\t- Итальянская Мафия\t\t\t/naz\t- Aztec Gang\n/npb\t- Похоронное Бюро\t\t\t/ngv\t- Grove Street\n/nom\t- Клуб Outlaws MC\t\t\t/nvg\t- Vagos Gang\n/nap\t- Армия Лос-Сантос\t\t\t/ngov\t- Правительство\n/nlspd\t- Департамент LSPD\t\t\t/nfbi\t- Федеральное FBI\n/nrcpd\t- Департамент RCPD\t\t\t/nsw\t- Спец-отряд S.W.A.T\n/nmr\t- Городская Мэрия\t\t\t/nrc Caps - Радиоцентр ЛС\n/nbls     - Hospital Лос-Сантос\t\t/nvs\t- Верховный Суд\n\n{9933FF}Инструкция: Все праздничные бинды наборов автоматически улетают в общий чат /o!")
        sampShowDialog(3216, u8("Inferno Pride | Наборы во Фракции"), text, u8("Закрыть"), "", 0)
    end)
    sampRegisterChatCommand("omenu", function()
        local text = u8("{FF6600}[ INFERNO HELPER | HALLOWEEN UPDATE | АДМИН-ОТБОРЫ ]\n\n{9933FF}БИНДЫ В ЧАТ /aad:\t\t\t\t\tБИНДЫ В ОБЩИЙ ЧАТ /o:\n{FFFFFF}/orm\t- Русская Мафия\t\t\t/oorm\t- Русская Мафия\n/oym\t- Японская Мафия\t\t\t/ooym\t- Японская Мафия\n/oim\t- Итальянская Мафия\t\t\t/ooim\t- Итальянская Мафия\n/opb\t- Похоронное Бюро\t\t\t/oopb\t- Похоронное Бюро\n/oom\t- Outlaws MC\t\t\t\t/ooom\t- Outlaws MC\n/orf\t- Rifa Gang\t\t\t\t/oorf\t- Rifa Gang\n/obl\t- Ballas Gang\t\t\t\t/oobl\t- Ballas Gang\n/oaz\t- Aztec Gang\t\t\t\t/ooaz\t- Aztec Gang\n/ogv\t- Grove Gang\t\t\t\t/oogv\t- Grove Gang\n/ovg\t- Vagos Gang\t\t\t\t/oovg\t- Vagos Gang\n/oap\t- Армия Лос-Сантос\t\t\t/ooap\t- Армия ЛС\n/obls     - Hospital ЛС\t\t\t\t/oobls     - Hospital ЛС\n/omr\t- Городская Мэрия\t\t\t/oomr\t- Городская Мэрия\n/orc\t- Радиоцентр ЛС\t\t\t\t/oorc\t- Радиоцентр ЛС\n/olspd\t- Департамент LSPD\t\t\t/oolspd\t- Департамент LSPD\n/ofbi\t- Федеральное FBI\t\t\t/oofbi\t- Федеральное FBI\n/orcpd\t- Департамент RCPD\t\t\t/oorcpd\t- Департамент RCPD\n/osw\t- Спец-отряд S.W.A.T\t\t\t/oosw\t- Спец-отряд S.W.A.T\n/ogov     - Правительство\t\t\t\t/oogov     - Правительство\n/ovs\t- Верховный Суд\t\t\t\t/oovs\t- Верховный Суд")
        sampShowDialog(3217, u8("Inferno Helper | Отборы на Лидерство"), text, u8("Закрыть"), "", 0)
    end)
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
    sampAddChatMessage("{FF6600}[Binder] {FFFFFF}" .. text, -1)
end

local function bindPath()
    if not bindFile then
        local dir = getWorkingDirectory() .. "/config"
        pcall(createDirectory, dir)
        bindFile = dir .. "/InfernoBinder.txt"
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
    local param = (arg ~= "") and arg or (currentTargetID or "")
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
    if not ok then print("[Inferno Helper] binder load error: " .. tostring(err)) end
end

local function bindHelp()
    sampShowDialog(3223, "Inferno Helper | Биндер",
        "{FF6600}[ СВОЙ БИНДЕР ]\n\n{33CC33}/hbinder {FFFFFF}- отдельное окно биндера (создание и правка без команд).\n\n" ..
        "{FFFFFF}Создаёт свои команды: набрали {FFFF00}/имя{FFFFFF} -- отправились все строки бинда по очереди.\n\n" ..
        "{FF6600}/bnd add имя текст {FFFFFF}- создать бинд / добавить строку.\n" ..
        "{FFFFFF}  Несколько строк сразу разделяйте {FFFF00};;{FFFFFF}, например:\n" ..
        "{FFFF00}  /bnd add hi /aad Привет! ;; /aad Как дела?\n" ..
        "{FF6600}/bnd rm имя N {FFFFFF}- удалить строку N.\n" ..
        "{FF6600}/bnd del имя {FFFFFF}- удалить бинд целиком.\n" ..
        "{FF6600}/bnd delay имя мс {FFFFFF}- пауза между строками (300-10000, по умолчанию 1100).\n" ..
        "{FF6600}/bnd show имя {FFFFFF}- показать строки бинда.\n" ..
        "{FF6600}/bnd list {FFFFFF}- список всех биндов.\n\n" ..
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
-- ОТДЕЛЬНОЕ ОКНО БИНДЕРА: /hbinder (на диалогах SA-MP, работает без imgui)
----------------------------------------------------------------------
local D_MAIN, D_NAME, D_ADD, D_BIND, D_LINES, D_DELAY, D_CONF, D_SHOW = 3230, 3231, 3232, 3233, 3234, 3235, 3236, 3237
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
    uiShow(D_MAIN, "Inferno Helper | Биндер", table.concat(t, "\n"), "Выбрать", "Закрыть", 2)
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
local function binderTick()
    local id = ui.open
    if id and sampHasDialogRespond(id) then
        ui.open = nil
        local button, list, input = sampGetDialogResponse(id)
        input = fromGame(input or "")
        local h = uiHandlers[id]
        local ok, err = true, nil
        if h then ok, err = pcall(h, button, list, input or "") end
        if not ok then print("[Inferno Helper] binder UI error: " .. tostring(err)) end
    end
end

local function setupBinder(builtin, reg)
    bindBuiltin, bindReg = builtin, reg
    builtin.bnd, builtin.binder, builtin.hbinder = true, true, true
    loadBinds()

    reg("binder", bindHelp)
    reg("hbinder", uiMain)
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

function main()
    if isSampLoaded and not isSampLoaded() then return end
    if isSampfuncsLoaded and not isSampfuncsLoaded() then return end
    while isSampAvailable and not isSampAvailable() do wait(100) end

    -- Защитные обёртки: обрезка длины, pcall -- ни одна команда/диалог не должны ронять игру
    local rawAdd, rawDialog, rawReg = sampAddChatMessage, sampShowDialog, sampRegisterChatCommand
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
    local rawInput = sampSetChatInputText
    sampSetChatInputText = function(t) pcall(rawInput, toGame(tostring(t or ""))) end
    local function guardedReg(name, fn)
        return rawReg(name, function(arg)
            local ok, err = pcall(fn, type(arg) == "string" and fromGame(arg) or "")
            if not ok then
                print("[Inferno Helper] command /" .. name .. " error: " .. tostring(err))
                sampAddChatMessage("{FF3333}[Inferno Helper] {FFFFFF}Ошибка в команде /" .. name .. ", подробности в moonloader.log", -1)
            end
        end)
    end
    sampRegisterChatCommand = guardedReg

    -- ПРАЗДНИЧНЫЙ СТАРТ ПРИ ВХОДЕ В ИГРУ В ИНТЕРФЕЙСЕ ЧАТА
    sampAddChatMessage(u8("{FF6600}[Inferno Helper] {9933FF}Административный ассистент успешно инициализирован. {FF3333}[HALLOWEEN UPDATE]"), -1)
    sampAddChatMessage(u8("{FF6600}[Inferno Helper] {FFFFFF}Разработчик софта: {FF6600}ByFilipp{FFFFFF}."), -1)
    sampAddChatMessage(u8("{FF6600}[Inferno Helper] {FFFFFF}Пропишите {FFFF00}/helper {FFFFFF}для панели управления или {FFFF00}/ldhelp {FFFFFF}для следящих."), -1)

    sampRegisterChatCommand("arep", function(id)
        if id and id:match("^%d+$") then
            local targetIdNum = tonumber(id)
            local reportSender = "ID " .. id
            if sampIsPlayerConnected(targetIdNum) then
                local targetName = sampGetPlayerNickname(targetIdNum)
                if targetName then reportSender = targetName .. "[" .. id .. "]" end
            end
            local reason = globalReportTexts[targetIdNum] or "Жалоба (текст не пойман сервером, чекните /report)"
            lua_thread.create(function()
                safeSend(string.format("/pm %s " .. u8("Здравствуйте, передам вашу жалобу!"), id)) wait(1050) 
                safeSend(u8("/a Уважаемая администрация, отвечаем на репорт!")) wait(1050) 
                safeSend(string.format(u8("/a %s | Жалоба: %s"), reportSender, u8(reason)))
            end)
        else sampAddChatMessage(u8("{FF6600}[Inferno Helper] {FFFFFF}Ошибка! Использование: {FFFF00}/arep [ID]"), -1) end
    end)

    -- запоминаем имена встроенных команд, чтобы бинды их не перекрывали
    local builtin = { arep = true }
    sampRegisterChatCommand = function(n, f) builtin[n] = true return guardedReg(n, f) end
    local okReg, errReg = pcall(registerAllInfernoCommands)
    if not okReg then print("[Inferno Helper] register error: " .. tostring(errReg)) end
    sampRegisterChatCommand = guardedReg
    local okB, errB = pcall(setupBinder, builtin, guardedReg)
    if not okB then print("[Inferno Helper] binder setup error: " .. tostring(errB)) end

    while true do
        wait(100)
        local okT, errT = pcall(binderTick)
        if not okT then print("[Inferno Helper] tick error: " .. tostring(errT)) end
    end
end

function ev.onSendCommand(command)
    if type(command) ~= "string" then return end
    local id = command:match("^/re%s+(%d+)")
    if id then currentTargetID = id
    elseif command:match("^/re%s+off") or command:match("^/reoff") then currentTargetID = nil end
end
