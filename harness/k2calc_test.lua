-- REST-сервис k2calc_test: автоматический прогон тест-кейсов пакета pkg/k2calc
-- на тестовом счёте с виртуальной АБС.
--
-- Вход (request.input, JSON-строка или таблица):
--   {"all":true}                 - все активные кейсы из k2calc_test_case
--   {"case":"INC-1-PROD"}        - один кейс
--   {"tag":"regress"}            - активные кейсы с тегом (колонка tags, через запятую)
--   {"scenario":{...}}           - сценарий целиком в запросе (отладка)
--   {"fuzz":{...}}               - случайные сценарии с проверкой инвариантов (см. ниже)
--   "verbose":true               - трассировка шагов и для успешных кейсов
--
-- Выход: output.summary {total, passed, failed, current_total, current_matched}
--        output.results[]
--   passed          - кейс прошёл по expect (целевое поведение) и без нарушений инвариантов
--   matches_current - кейс совпал с expect_current (текущее поведение пакета, как в проде);
--                     инварианты здесь не учитываются
--
-- Сценарий (JSON):
--   acc_id, reqs[{id, debt, stat}]
--   balance, limit              - остаток и лимит виртуальной АБС на старте
--   acc {flagptpay, limit_nat}  - начальные поля k2acc
--   abs_raise_limit             - поднимает ли АБС лимит на сумму поступления
--                                 (по умолчанию false: так ведёт себя W4 в проде)
--   mzp_covered                 - true: добавить строку typ=1 начала месяца с большой суммой,
--                                 чтобы ограничение ПМ не срабатывало
--   seed_anl[]                  - строки аналитики «истории месяца» до сценария:
--                                 {typ, amount, f_o,f_b,f_c,l_o,l_b,l_c, is_finished, arcfl}
--   check50                     - false: отключить инвариант 50% по строке
--   steps[]                     - шаги (см. STEPS)
--   expect / expect_current     - {payments[], total_paid, released, abs_bal, abs_lim,
--                                  limit_nat, buckets{f_o,...}}
--
-- Fuzz: {"fuzz":{"acc_id":..,"req":..,"debt":1000000,"seed":1,"runs":10,"steps":12,
--                "typ4_share":0.1,"verbose":false}}
--   Генерирует случайные последовательности: поступления (часть приходит в АБС до обработки
--   предыдущих), обработка строго по очереди (FIFO), пересчёт лимита, оплаты, траты клиента.
--   Оракул: итог оплат = сумма долей банка (50% от typ=2, 100% от typ=4) + все инварианты.
--   Упавший прогон возвращает свой сценарий: его можно сохранить как обычный кейс.
--
-- Места, которые надо подогнать под вашу схему, помечены  -- [ADAPT]

output = {}

local EPS = 0.005
local MAX_ERR_LEN = 1500
local BUCKETS = { 'f_o', 'f_b', 'f_c', 'l_o', 'l_b', 'l_c' }

---------------------------------------------------------------
-- Утилиты
---------------------------------------------------------------
local function q1(sql, ...)
    local row, ers, ern = SqlQueryRow2(sql, ...)
    if ern ~= 0 then error((ers or '') .. ' | ' .. sql) end
    return row or {}
end

local function qn(sql, ...)
    local rows, ers, ern = SqlQueryRows(sql, ...)
    if ern ~= 0 then error((ers or '') .. ' | ' .. sql) end
    return rows or {}
end

local function ex(sql, ...)
    local ers, ern = SqlExec2(sql, ...)
    if ern ~= 0 then error((ers or '') .. ' | ' .. sql) end
end

local function ins(sql, ...)
    local id, ers, ern = SqlInsert(sql, ...)
    if ern ~= 0 then error((ers or '') .. ' | ' .. sql) end
    return id
end

local function n(v) return tonumber(v or 0) or 0 end
local function s(v) return tostring(v) end
local function r2(v) return math.floor(n(v) * 100 + 0.5) / 100 end
local function eq(a, b) return math.abs(n(a) - n(b)) < EPS end
local function cut(t)
    t = tostring(t or '')
    if #t > MAX_ERR_LEN then return string.sub(t, 1, MAX_ERR_LEN) .. '...' end
    return t
end
local function hasStep(sc, op)
    for _, st in ipairs(sc.steps or {}) do
        if st.op == op then return true end
    end
    return false
end

---------------------------------------------------------------
-- Виртуальная АБС (K2VIRTUAL_ACC, связь со счётом K2 по code)
---------------------------------------------------------------
local VABS = {}

local ACC_BY_CODE = [[code = (select code from k2acc where id = ?)]]

function VABS.validate(acc_id)
    local row = q1([[select count(*) cnt from K2VIRTUAL_ACC v
                     join k2acc a on a.code = v.code where a.id = ?]], s(acc_id))
    if n(row.cnt) ~= 1 then
        error('Для счёта K2 id=' .. s(acc_id) .. ' ожидался один виртуальный счёт по code, найдено: ' .. s(row.cnt))
    end
end

function VABS.reset(acc_id, bal, lim)
    ex([[update K2VIRTUAL_ACC set balance = ?, lim = ? where ]] .. ACC_BY_CODE,
        s(r2(bal)), s(r2(lim)), s(acc_id))
end

function VABS.income(acc_id, amount, raise_limit)
    if raise_limit then
        ex([[update K2VIRTUAL_ACC set balance = balance + ?, lim = lim + ? where ]] .. ACC_BY_CODE,
            s(amount), s(amount), s(acc_id))
    else
        ex([[update K2VIRTUAL_ACC set balance = balance + ? where ]] .. ACC_BY_CODE,
            s(amount), s(acc_id))
    end
end

function VABS.debit(acc_id, amount)
    ex([[update K2VIRTUAL_ACC set balance = balance - ? where ]] .. ACC_BY_CODE,
        s(amount), s(acc_id))
end

function VABS.setLimit(acc_id, lim)
    ex([[update K2VIRTUAL_ACC set lim = ? where ]] .. ACC_BY_CODE, s(r2(lim)), s(acc_id))
end

function VABS.state(acc_id)
    local r = q1([[select balance, lim from K2VIRTUAL_ACC where ]] .. ACC_BY_CODE, s(acc_id))
    return { bal = r2(r.balance), lim = r2(r.lim) }
end

---------------------------------------------------------------
-- Записи K2, которые в проде создают другие процессы
---------------------------------------------------------------
local K2 = {}

-- событие поступления (onIncomeEvent читает snd_attr по log_id).
-- Тестовые записи получают отрицательный src_ref_id: по нему они чистятся в resetState.
function K2.incomeLog(acc_id, amount, snd_attr)
    local account = q1([[select system_id from k2acc where id = ?]], s(acc_id))
    assert(account.system_id ~= nil, 'Missing k2acc.system_id for acc_id=' .. s(acc_id))
    local ref = q1([[select to_char(nvl(min(src_ref_id), 0) - 1) src_ref_id
                      from k2income_log where acc_id = ?
                       and src_ref_id between -4503599627370495 and -1
                       and src_ref_id = trunc(src_ref_id)]], s(acc_id))
    assert(ref.src_ref_id ~= nil, 'Missing generated src_ref_id')
    ins([[insert into k2income_log
            (acc_id, system_id, income_sum, snd_attr, dequeue_time, src_ref_id)
          values (?, ?, ?, ?, sysdate, ?)]],
        s(acc_id), s(account.system_id), s(amount), s(snd_attr), s(ref.src_ref_id))
    -- id читаем обратно: SqlInsert на этой таблице может вернуть не тот id
    local rows = qn([[select id from k2income_log where acc_id = ? and src_ref_id = ?]],
        s(acc_id), s(ref.src_ref_id))
    if #rows ~= 1 then
        error('Income insert readback failed: acc_id=' .. s(acc_id) ..
            ', src_ref_id=' .. s(ref.src_ref_id) .. ', rows=' .. s(#rows))
    end
    return rows[1].id
end

-- запись о списании (её id уходит в onPayment -> k2req_pay_anl)
function K2.payRecord(req_id, acc_id, amount)
    local account = q1([[select system_id from k2acc where id = ?]], s(acc_id))
    return ins([[insert into k2req_pay (req_id, acc_id, system_id, amount, created_at)
                 values (?, ?, ?, ?, sysdate)]],
        s(req_id), s(acc_id), s(account.system_id), s(amount))
end

function K2.validateReq(acc_id, req_id)
    local row = q1([[select count(*) cnt from k2req_acc ra
                     join k2req r on r.id = ra.req_id
                     join k2req_group g on g.id = r.group_id
                    where ra.acc_id = ? and ra.req_id = ?]], s(acc_id), s(req_id))
    if n(row.cnt) == 0 then
        error('Scenario req_id=' .. s(req_id) .. ' is not linked to test acc_id=' .. s(acc_id) ..
            ' with a debt group; check IDs in reqs and steps')
    end
end

function K2.setDebt(req_id, debt)
    ex([[update k2req_group set debt = ?
          where id = (select group_id from k2req where id = ?)]], s(debt), s(req_id))
end

-- строка аналитики «истории месяца». dt: начало текущего месяца + idx секунд,
-- чтобы getStartBalAndDt / getSumIncomesFrom видели её в текущем месяце.
function K2.seedAnl(acc_id, row, idx)
    ins([[insert into k2anl_income (
            acc_id, dt, arcfl, typ, log_id,
            f_o, f_b, f_c, l_o, l_b, l_c, amount, is_finished)
          values (?, trunc(sysdate, 'MM') + ? / 86400, ?, ?, null,
                  ?, ?, ?, ?, ?, ?, ?, ?)]],
        s(acc_id), s(idx), s(row.arcfl or 0), s(row.typ or 2),
        s(n(row.f_o)), s(n(row.f_b)), s(n(row.f_c)),
        s(n(row.l_o)), s(n(row.l_b)), s(n(row.l_c)),
        s(n(row.amount)), s(row.is_finished or 0))
end

---------------------------------------------------------------
-- Сброс состояния тестового счёта перед кейсом
---------------------------------------------------------------
local function resetState(sc)
    local acc = s(sc.acc_id)
    VABS.validate(acc)

    local reqIds = {}
    for _, req in ipairs(sc.reqs or {}) do reqIds[s(req.id)] = true end
    for _, step in ipairs(sc.steps or {}) do
        if step.req ~= nil then reqIds[s(step.req)] = true end
    end
    for req_id in pairs(reqIds) do K2.validateReq(acc, req_id) end

    ex([[delete from k2req_pay_anl where pay_id in (select id from k2req_pay where acc_id = ?)]], acc)
    ex([[delete from k2req_pay where acc_id = ?]], acc)
    ex([[delete from k2anl_income where acc_id = ?]], acc)
    -- тестовые события поступлений (в т.ч. не дошедшие до аналитики)
    ex([[delete from k2income_log where acc_id = ? and src_ref_id < 0]], acc)

    local a = sc.acc or {}
    ex([[update k2acc set limit_nat = ?, flagptpay = ?, last_pt_pay_date = null where id = ?]],
        s(n(a.limit_nat)), s(n(a.flagptpay)), acc)

    -- Если в сценарии есть register_pt, долг выставляется в этом шаге
    -- (в проде beforePtRegister вызывается до регистрации ПТ, иначе hasAccPt=true и
    -- остаток на момент регистрации не фиксируется).
    local debtNow = not hasStep(sc, 'register_pt')
    for _, r in ipairs(sc.reqs or {}) do
        K2.setDebt(r.id, debtNow and r.debt or 0)
        if r.stat then
            ex([[update k2req set stat_id = (select id from k2req_stat where code = ?)
                  where id = ?]], s(r.stat), s(r.id))
        end
    end

    local idx = 0
    if sc.mzp_covered then
        -- typ=1 начала месяца: getStartBalAndDt берёт его как остаток на начало,
        -- ограничение ПМ не срабатывает. Корзины пустые, на суммы аналитики не влияет.
        K2.seedAnl(acc, { typ = 1, amount = 100000000, is_finished = 1 }, idx)
    end
    for _, row in ipairs(sc.seed_anl or {}) do
        idx = idx + 1
        K2.seedAnl(acc, row, idx)
    end

    VABS.reset(acc, sc.balance or 0, sc.limit or 0)
end

---------------------------------------------------------------
-- Снимок состояния
---------------------------------------------------------------
local function snapshot(acc)
    local a = q1([[select nvl(sum(f_o),0) f_o, nvl(sum(f_b),0) f_b, nvl(sum(f_c),0) f_c,
                          nvl(sum(l_o),0) l_o, nvl(sum(l_b),0) l_b, nvl(sum(l_c),0) l_c
                     from k2anl_income where acc_id = ? and arcfl = 0]], acc)
    local k = q1([[select limit_nat, flagptpay from k2acc where id = ?]], acc)
    local v = VABS.state(acc)
    local snap = {
        limit_nat = r2(k.limit_nat), flagptpay = k.flagptpay,
        abs_bal = v.bal, abs_lim = v.lim,
        released = r2(math.max(0, v.bal - v.lim)),
    }
    local total = 0
    for _, b in ipairs(BUCKETS) do
        snap[b] = r2(a[b])
        total = total + snap[b]
    end
    snap.anl_total = r2(total)
    return snap
end

local function pendingSum(ctx)
    local t = 0
    for _, name in ipairs(ctx.pending) do t = t + ctx.incomes[name].amount end
    return r2(t)
end

---------------------------------------------------------------
-- Шаги сценария
--   register_pt                      beforePtRegister, затем долг ПТ из reqs
--   abs_income {name, amount, snd_attr, raise_limit}
--                                    поступление в АБС + запись k2income_log
--   on_income {income}               onIncomeEvent по ранее пришедшему поступлению
--   update_limit                     пересчёт и установка лимита
--   calc_pay {flow, req}             расчёт суммы к списанию
--   abs_debit {flow}                 списание в АБС
--   on_payment {flow}                разноска в K2 (onPayment)
--   pay {req}                        calc_pay + abs_debit + on_payment
--   abs_spend {amount | frac}        клиент тратит деньги, K2 об этом не знает
--                                    (frac: доля от доступного клиенту без необработанных
--                                    поступлений)
---------------------------------------------------------------
local STEPS = {}

STEPS.register_pt = function(api, sc, ctx, st)
    api.beforePtRegister(s(sc.acc_id))
    for _, r in ipairs(sc.reqs or {}) do K2.setDebt(r.id, r.debt) end
end

STEPS.abs_income = function(api, sc, ctx, st)
    local amount = r2(st.amount)
    ctx.nIncome = ctx.nIncome + 1
    local name = st.name or ('I' .. ctx.nIncome)
    local raise = sc.abs_raise_limit == true
    if st.raise_limit ~= nil then raise = st.raise_limit end
    VABS.income(sc.acc_id, amount, raise)
    local snd = st.snd_attr or '1'
    local log_id = K2.incomeLog(sc.acc_id, amount, snd)
    ctx.incomes[name] = { amount = amount, log_id = log_id, typ = (snd == '0') and 4 or 2 }
    table.insert(ctx.pending, name)
    ctx.last = { income = name, amount = amount, log_id = log_id }
end

STEPS.on_income = function(api, sc, ctx, st)
    local name = st.income or ctx.pending[1]
    local inc = ctx.incomes[name]
    if not inc then error('нет поступления ' .. tostring(name)) end
    for i, p in ipairs(ctx.pending) do
        if p == name then table.remove(ctx.pending, i) break end
    end
    local ok, err = xpcall(function()
        api.onIncomeEvent(s(sc.acc_id), inc.amount, inc.log_id)
    end, function(message) return debug.traceback(tostring(message), 2) end)
    ctx.last = { income = name, amount = inc.amount, log_id = inc.log_id }
    if not ok then error(err) end
end

STEPS.update_limit = function(api, sc, ctx, st)
    local acc = s(sc.acc_id)
    if api.setAccLimLockMonintoring then
        api.updateLimit(acc)
    else
        -- [ADAPT] setAccLimLockMonintoring в pkg/k2calc не объявлена. Эмуляция:
        -- лимит в виртуальной АБС и limit_nat в K2 выставляются одинаково.
        -- Заменить на реальный путь (процесс k2acc_set_limit_virtual или пакет,
        -- где определена setAccLimLockMonintoring), когда он будет известен.
        local lim = r2(api.getLimitAmount(acc))
        VABS.setLimit(acc, lim)
        ex([[update k2acc set limit_nat = ? where id = ?]], s(lim), acc)
    end
    ctx.last = { abs_lim = VABS.state(acc).lim }
end

STEPS.calc_pay = function(api, sc, ctx, st)
    local flow = st.flow or 'A'
    local req = st.req or (sc.reqs and sc.reqs[1] and sc.reqs[1].id)
    local amount = api.getAvailablePayAmount2(s(req), s(sc.acc_id))
    ctx.flows[flow] = { req = s(req), amount = r2(amount) }
    ctx.last = { flow = flow, amount = r2(amount), req = s(req) }
end

STEPS.abs_debit = function(api, sc, ctx, st)
    local f = ctx.flows[st.flow or 'A']
    if not f then error('нет расчёта для потока ' .. tostring(st.flow)) end
    if f.amount > 0 then
        VABS.debit(sc.acc_id, f.amount)
        ctx.debitTotal = r2(ctx.debitTotal + f.amount)
    end
end

STEPS.on_payment = function(api, sc, ctx, st)
    local f = ctx.flows[st.flow or 'A']
    if not f then error('нет расчёта для потока ' .. tostring(st.flow)) end
    if f.amount <= 0 then return end
    local pay_id = K2.payRecord(f.req, sc.acc_id, f.amount)
    api.onPayment(f.req, s(sc.acc_id), f.amount, pay_id)
    ex([[update k2req_group set debt = debt - ?
          where id = (select group_id from k2req where id = ?)]], s(f.amount), f.req)
    table.insert(ctx.payments, f.amount)
    ctx.last = { pay_id = pay_id, amount = f.amount }
end

STEPS.pay = function(api, sc, ctx, st)
    local st2 = { req = st.req, flow = '_seq' }
    STEPS.calc_pay(api, sc, ctx, st2)
    STEPS.abs_debit(api, sc, ctx, st2)
    STEPS.on_payment(api, sc, ctx, st2)
    ctx.last = { amount = ctx.flows['_seq'].amount }
end

STEPS.abs_spend = function(api, sc, ctx, st)
    local v = VABS.state(sc.acc_id)
    local available = r2(math.max(0, v.bal - v.lim - pendingSum(ctx)))
    local amount = st.amount and r2(st.amount) or r2(available * n(st.frac))
    if amount > available + EPS then
        error('abs_spend: клиент не может потратить ' .. s(amount) .. ', доступно ' .. s(available))
    end
    if amount > 0 then VABS.debit(sc.acc_id, amount) end
    ctx.spent = r2(ctx.spent + amount)
    ctx.last = { amount = amount, available = available }
end

---------------------------------------------------------------
-- Инварианты (после каждого шага). op - текущий шаг.
---------------------------------------------------------------
local function checkInvariants(acc, sc, ctx, op, snap)
    local v = {}

    local r = q1([[select count(*) cnt from k2anl_income
                    where acc_id = ? and least(f_o, f_b, f_c, l_o, l_b, l_c) < 0]], acc)
    if n(r.cnt) > 0 then table.insert(v, 'отрицательная корзина в k2anl_income') end

    r = q1([[select count(*) cnt from (
               select log_id from k2anl_income
                where acc_id = ? and typ in (2,4) and log_id is not null
                group by log_id having count(*) > 1)]], acc)
    if n(r.cnt) > 0 then table.insert(v, 'поступление зарегистрировано дважды (дубль log_id)') end

    if sc.check50 ~= false then
        -- банку с обычного поступления не больше 50%: и уже списанное, и отложенное в f_b/l_b
        local rows = qn([[select i.id, i.amount, i.f_b, i.l_b,
                                 (select nvl(sum(pa.amount),0) from k2req_pay_anl pa
                                   where pa.anl_id = i.id and pa.code in ('f_b','l_b')) paid
                            from k2anl_income i
                           where i.acc_id = ? and i.typ = 2 and i.log_id is not null]], acc)
        for _, row in ipairs(rows) do
            local bank = n(row.paid) + n(row.f_b) + n(row.l_b)
            if bank > r2(n(row.amount) * 0.5) + EPS then
                table.insert(v, 'доля банка с поступления ' .. s(row.amount) .. ' (anl_id=' ..
                    s(row.id) .. ') = ' .. s(r2(bank)) .. ' > 50%')
            end
        end
    end

    r = q1([[select nvl((select sum(amount) from k2req_pay where acc_id = ?),0) p,
                    nvl((select sum(pa.amount) from k2req_pay_anl pa
                          join k2req_pay p on p.id = pa.pay_id where p.acc_id = ?),0) pa
               from dual]], acc, acc)
    if not eq(r.p, r.pa) then
        table.insert(v, 'сумма k2req_pay (' .. s(r2(r.p)) .. ') <> разноска k2req_pay_anl (' ..
            s(r2(r.pa)) .. ')')
    end
    if not eq(ctx.debitTotal, r.p) then
        table.insert(v, 'списано в АБС ' .. s(ctx.debitTotal) .. ', а в k2req_pay ' .. s(r2(r.p)))
    end

    if op == 'update_limit' then
        -- после пересчёта аналитика должна совпадать с остатком АБС за вычетом
        -- ещё не обработанных поступлений; иначе необработанное поступление
        -- «растворилось» в старых корзинах (механизм INC-1)
        local pend = pendingSum(ctx)
        local diff = r2(snap.abs_bal - pend - snap.anl_total)
        if math.abs(diff) > EPS then
            table.insert(v, 'аналитика ' .. s(snap.anl_total) .. ' не сходится с остатком АБС ' ..
                s(snap.abs_bal) .. ' минус необработанные ' .. s(pend) .. ' (разница ' .. s(diff) .. ')')
        end

        local bankHeld = r2(snap.f_b + snap.l_o + snap.l_b + snap.l_c)
        if snap.abs_lim + EPS < bankHeld then
            table.insert(v, 'лимит АБС ' .. s(snap.abs_lim) ..
                ' меньше доли банка и арестованного ' .. s(bankHeld))
        end
        if snap.f_b < EPS and pend < EPS and snap.abs_lim > snap.abs_bal - snap.f_c + EPS then
            table.insert(v, 'нечего списывать, но лимит АБС ' .. s(snap.abs_lim) ..
                ' блокирует защищённую долю клиента f_c=' .. s(snap.f_c))
        end
    end
    return v
end

---------------------------------------------------------------
-- Проверка ожиданий
---------------------------------------------------------------
local function checkExpect(exp, ctx, final)
    local fails = {}
    local function fail(m) table.insert(fails, m) end
    if exp == nil then return fails end

    if exp.total_paid ~= nil then
        local t = 0
        for _, p in ipairs(ctx.payments) do t = t + p end
        local tol = exp.total_tolerance or EPS
        if math.abs(t - n(exp.total_paid)) > tol then
            fail('total_paid: ожидалось ' .. s(exp.total_paid) .. ', факт ' .. s(r2(t)))
        end
    end
    if exp.payments ~= nil then
        local okList = #exp.payments == #ctx.payments
        for i, p in ipairs(exp.payments) do
            if not eq(p, ctx.payments[i]) then okList = false end
        end
        if not okList then
            fail('payments: ожидалось ' .. JsonToString(exp.payments) ..
                ', факт ' .. JsonToString(ctx.payments))
        end
    end
    for k, val in pairs(exp.buckets or {}) do
        if not eq(final[k], val) then
            fail('корзина ' .. k .. ': ожидалось ' .. s(val) .. ', факт ' .. s(final[k]))
        end
    end
    for _, k in ipairs({ 'released', 'abs_lim', 'abs_bal', 'limit_nat' }) do
        if exp[k] ~= nil and not eq(final[k], exp[k]) then
            fail(k .. ': ожидалось ' .. s(exp[k]) .. ', факт ' .. s(final[k]))
        end
    end
    return fails
end

---------------------------------------------------------------
-- Прогон одного кейса
---------------------------------------------------------------
local k2calc = dbrequire('pkg/k2calc')

local function runCase(code, sc, verbose)
    local res = { code = code, title = sc.title, passed = false,
                  errors = {}, violations = {}, expect_fails = {}, trace = {} }
    local acc = s(sc.acc_id)
    local ctx = { incomes = {}, pending = {}, flows = {}, payments = {},
                  nIncome = 0, debitTotal = 0, spent = 0 }
    local seen = {}

    local ok, err = pcall(resetState, sc)
    if not ok then
        table.insert(res.errors, 'сброс состояния: ' .. cut(err))
        return res
    end

    local api = k2calc.getApi()

    for i, st in ipairs(sc.steps or {}) do
        local fn = STEPS[st.op]
        if fn then
            ok, err = pcall(fn, api, sc, ctx, st)
        else
            ok, err = false, 'неизвестный шаг: ' .. tostring(st.op)
        end

        local entry = { i = i, op = st.op, ok = ok, info = ctx.last }
        ctx.last = nil
        if not ok then
            entry.error = cut(err)
            table.insert(res.errors, 'шаг ' .. i .. ' ' .. tostring(st.op) .. ': ' .. cut(err))
        end

        local okS, snap = pcall(snapshot, acc)
        if okS then
            entry.snap = snap
            local okI, viol = pcall(checkInvariants, acc, sc, ctx, st.op, snap)
            if okI then
                for _, m in ipairs(viol) do
                    if not seen[m] then   -- нарушение показываем на шаге, где оно появилось
                        seen[m] = true
                        table.insert(res.violations, 'шаг ' .. i .. ' ' .. tostring(st.op) .. ': ' .. m)
                    end
                end
            else
                table.insert(res.errors, 'инварианты после шага ' .. i .. ': ' .. cut(viol))
            end
        else
            entry.snap = 'снимок недоступен: ' .. cut(snap)
        end
        table.insert(res.trace, entry)
    end

    local okF, final = pcall(snapshot, acc)
    if okF then
        res.final = final
        res.expect_fails = checkExpect(sc.expect, ctx, final)
        if sc.expect_current then
            res.current_fails = checkExpect(sc.expect_current, ctx, final)
        end
    else
        table.insert(res.errors, 'итоговый снимок: ' .. cut(final))
    end
    res.payments = ctx.payments

    local errorsOk = (#res.errors == 0) or (sc.expect and sc.expect.allow_errors)
    res.passed = errorsOk and #res.violations == 0 and #res.expect_fails == 0 and okF
    if sc.expect_current then
        local curErrorsOk = (#res.errors == 0) or sc.expect_current.allow_errors
        res.matches_current = curErrorsOk and okF and #res.current_fails == 0
    end
    if res.passed and not verbose then res.trace = nil end
    return res
end

---------------------------------------------------------------
-- Fuzz: генерация сценария
---------------------------------------------------------------
local function genScenario(f, runIdx)
    local seed = n(f.seed) + runIdx
    math.randomseed(seed)
    local nSteps = n(f.steps) > 0 and n(f.steps) or 12
    local typ4 = f.typ4_share ~= nil and n(f.typ4_share) or 0.1
    local steps, shares, nInc, pending = {}, 0, 0, 0

    local function income()
        nInc = nInc + 1
        local amount = r2(math.random(100000, 5000000) / 100)
        local snd = (math.random() < typ4) and '0' or '1'
        shares = shares + ((snd == '0') and amount or r2(amount * 0.5))
        table.insert(steps, { op = 'abs_income', name = 'I' .. nInc, amount = amount, snd_attr = snd })
        pending = pending + 1
    end
    local function process()
        table.insert(steps, { op = 'on_income' })            -- FIFO: первый необработанный
        table.insert(steps, { op = 'update_limit' })
        pending = pending - 1
    end
    local function pay()
        table.insert(steps, { op = 'pay' })
        table.insert(steps, { op = 'update_limit' })
    end

    for _ = 1, nSteps do
        local x = math.random()
        if x < 0.35 or (pending == 0 and x < 0.6) then
            income()
        elseif pending > 0 and x < 0.7 then
            process()
        elseif x < 0.9 then
            pay()
        else
            table.insert(steps, { op = 'abs_spend', frac = r2(math.random(10, 100) / 100) })
        end
    end
    while pending > 0 do process() end
    for _ = 1, math.max(3, nInc) do pay() end

    return {
        code = 'FUZZ-' .. s(seed),
        title = 'fuzz seed=' .. s(seed),
        acc_id = f.acc_id,
        reqs = { { id = f.req, debt = f.debt or 100000000, stat = 'actual' } },
        balance = 0, limit = 0, mzp_covered = true,
        steps = steps,
        expect = { total_paid = r2(shares), total_tolerance = 0.01 * math.max(1, nInc) },
    }
end

---------------------------------------------------------------
-- Точка входа
---------------------------------------------------------------
local function parseInput()
    local payload = request and request.input
    if payload == nil or payload == '' then
        error('REST request.input is empty: pass case, tag, scenario, fuzz or all=true')
    end
    if type(payload) == 'table' then return payload end
    return StringToJson(payload)
end

local function loadCases(req)
    local cases = {}
    if req.scenario then
        table.insert(cases, { code = req.scenario.code or 'adhoc', sc = req.scenario })
    elseif req.fuzz then
        local runs = n(req.fuzz.runs) > 0 and n(req.fuzz.runs) or 10
        for i = 0, runs - 1 do
            local sc = genScenario(req.fuzz, i)
            table.insert(cases, { code = sc.code, sc = sc, fuzz = true })
        end
    else
        local rows
        if req.case then
            rows = qn([[select code, scenario from k2calc_test_case where code = ?]], s(req.case))
        elseif req.tag then
            rows = qn([[select code, scenario from k2calc_test_case
                         where is_active = 1
                           and ',' || replace(tags, ' ', '') || ',' like '%,' || ? || ',%'
                         order by code]], s(req.tag))
        else
            rows = qn([[select code, scenario from k2calc_test_case
                         where is_active = 1 order by code]])
        end
        for _, row in ipairs(rows) do
            local okJ, sc = pcall(StringToJson, row.scenario)
            table.insert(cases, { code = row.code, sc = okJ and sc or nil,
                                  parse_error = (not okJ) and cut(sc) or nil })
        end
    end
    return cases
end

local okMain, errMain = pcall(function()
    local req = parseInput()
    if type(req) ~= 'table' then error('REST input must be a JSON object') end
    if not (req.scenario or req.case or req.tag or req.fuzz or req.all == true) then
        error('REST input must specify case, tag, scenario, fuzz or all=true')
    end
    output.request = { case = req.case, tag = req.tag, all = req.all == true,
                       fuzz = req.fuzz ~= nil, verbose = req.verbose == true }

    local cases = loadCases(req)
    local results, passed, curTotal, curMatched = {}, 0, 0, 0
    for _, c in ipairs(cases) do
        local r
        if c.parse_error then
            r = { code = c.code, passed = false, errors = { 'ошибка JSON сценария: ' .. c.parse_error } }
        else
            local okC, rr = pcall(runCase, c.code, c.sc, req.verbose)
            r = okC and rr or { code = c.code, passed = false, errors = { 'падение раннера: ' .. cut(rr) } }
            if c.fuzz and not r.passed then r.scenario = c.sc end   -- чтобы сохранить как кейс
        end
        if r.passed then passed = passed + 1 end
        if r.matches_current ~= nil then
            curTotal = curTotal + 1
            if r.matches_current then curMatched = curMatched + 1 end
        end
        table.insert(results, r)
    end

    output.summary = { total = #cases, passed = passed, failed = #cases - passed,
                       current_total = curTotal, current_matched = curMatched }
    output.results = results
end)

if not okMain then
    output.last_error = cut(errMain)
end
