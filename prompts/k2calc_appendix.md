# Приложение к промпту k2calc_autotest_next_steps.md

Готовые наработки: диагностические запросы, выгрузка данных, эскизы исправлений.
Это **эскизы**: имена колонок, поведение функций платформы (`SqlQueryRow2` при пустой
выборке, `SqlInsert` и т.д.) и бизнес-правила нужно сверить со схемой и методологией
перед применением.

---

## A. Диагностические запросы по счёту

```sql
-- A1. Все строки аналитики по счёту
select * from k2anl_income where acc_id = :acc order by id;

-- A2. Не зарегистрировано ли одно поступление дважды
select log_id, count(*) from k2anl_income
 where acc_id = :acc and typ in (2,4)
 group by log_id having count(*) > 1;

-- A3. Платежи и из каких корзин они взяты
select p.id, p.created_at, pa.anl_id, pa.code, pa.amount
  from k2req_pay p join k2req_pay_anl pa on pa.pay_id = p.id
 where p.acc_id = :acc order by p.id, pa.id;

-- A4. Расхождение лимитов (Д5): сравнить с лимитом в АБС
select limit_nat from k2acc where id = :acc;

-- A5. Поступления, не дошедшие до аналитики (кандидаты на потерянные события)
--     имя колонки счёта в k2income_log сверить с DDL
select l.* from k2income_log l
 where l.acc_id = :acc
   and l.dequeue_time >= :dt_from
   and not exists (select 1 from k2anl_income i where i.log_id = l.id);

-- A6. Отладка упавших экземпляров
select * from bp_instance_debug where instance_id in (:instances);
```

Интерпретация:
- дубли в A2 → двойная регистрация поступления;
- списание в выписке АБС без записи в A3 → гонка Д4 с падением в `onPayment`;
- записи в A5 или `limit_nat` меньше лимита АБС → Д5 (зависший лимит).

---

## B. Выгрузка данных для стенда

### B1. Перечень

**Справочники (целиком):** `k2opertype`, `k2req_stat`, `k2cur`, `k2rate_type`, `k2rate`,
`k2system`, `k2acc_product`, `k2acc_lock_type`, параметр `k2mzp`.

**По счетам (фильтр `acc_id` и связанные `cli_id`, `req_id`):**

| Таблица | Фильтр |
|---|---|
| `k2acc` | `id in (:accs)` |
| `k2cli` | `id in (cli_id счетов)` |
| `k2req_acc` | `acc_id in (:accs)` |
| `k2req` | `id in (req_id из k2req_acc)` |
| `k2req_group` | `id in (group_id требований)` |
| `k2acc_lock` | `acc_id in (:accs)` |
| `k2anl_income` | `acc_id in (:accs)`, все строки, включая архивные |
| `k2req_pay` | `acc_id in (:accs)` |
| `k2req_pay_anl` | `pay_id in (id из k2req_pay)` |
| `k2income_log` | по счёту за период и по `log_id` из `k2anl_income` |
| `k2ignore` | по `acc_id`, `cli_id`, `bank_id` |
| `k2bankrupt` | по `cli_id` |

**Период:** минимум с 1-го числа месяца инцидента (`getStartBalAndDt`,
`getSumPaymentsFrom` считают с начала месяца), лучше с регистрации ПТ.

**Дополнительно:** выписка АБС за период с точным временем операций, остаток и лимит
на начало периода.

### B2. SQLcl → INSERT-скрипт

Один источник в каждом `FROM`, фильтры через `in`, тогда SQLcl подставит реальное имя
таблицы в INSERT.

```sql
-- запуск: sql user/pass@prod @export_inc.sql
set sqlformat insert
set feedback off
set termout off
define ACCS = '<id счетов через запятую>'
define DT_FROM = "date '2026-10-01'"

spool fixtures_inc.sql

select * from k2.k2opertype;
select * from k2.k2req_stat;
select * from k2.k2cur;
select * from k2.k2rate_type;
select * from k2.k2system;
select * from k2.k2rate;
select * from k2.k2acc_product;
select * from k2.k2acc_lock_type;

select * from k2.k2acc a where a.id in (&ACCS);
select * from k2.k2cli c where c.id in (select cli_id from k2.k2acc where id in (&ACCS));
select * from k2.k2req_acc ra where ra.acc_id in (&ACCS);
select * from k2.k2req r where r.id in (select req_id from k2.k2req_acc where acc_id in (&ACCS));
select * from k2.k2req_group g where g.id in (
  select r.group_id from k2.k2req r
   where r.id in (select req_id from k2.k2req_acc where acc_id in (&ACCS)));
select * from k2.k2acc_lock l where l.acc_id in (&ACCS);
select * from k2.k2anl_income i where i.acc_id in (&ACCS) and i.dt >= &DT_FROM;
select * from k2.k2req_pay p where p.acc_id in (&ACCS) and p.created_at >= &DT_FROM;
select * from k2.k2req_pay_anl pa where pa.pay_id in (
  select id from k2.k2req_pay where acc_id in (&ACCS) and created_at >= &DT_FROM);
select * from k2.k2income_log l where l.acc_id in (&ACCS) and l.dequeue_time >= &DT_FROM;
select * from k2.k2ignore i where i.acc_id in (&ACCS)
   or i.cli_id in (select cli_id from k2.k2acc where id in (&ACCS));
select * from k2.k2bankrupt b where b.cli_id in (select cli_id from k2.k2acc where id in (&ACCS));

spool off
```

DDL при необходимости:
```sql
select dbms_metadata.get_ddl('TABLE', table_name, 'K2') from all_tables
 where owner = 'K2' and table_name in ('K2ACC','K2ANL_INCOME','K2REQ_PAY',
   'K2REQ_PAY_ANL','K2INCOME_LOG' /* ... */);
```

### B3. Перед загрузкой на стенд

- **Маскирование** (согласовать с ИБ): в `k2cli` заменить ФИО, ИИН, контакты.
  У ИИН сохранить длину 12 и **5-ю цифру**: по ней `ignoreLivingWage` определяет тип
  клиента. Суммы, даты, id не маскировать.
- **Конфликт id:** отдельная схема под кейсы или согласованный сдвиг id во всех
  таблицах; последовательности поднять выше загруженных id.
- **Порядок загрузки:** справочники → `k2cli` → `k2acc` → `k2req_group` → `k2req` →
  `k2req_acc` → `k2acc_lock` → `k2income_log` → `k2anl_income` → `k2req_pay` →
  `k2req_pay_anl` → `k2ignore`/`k2bankrupt`.
- **Режимы:** «снимок после» — загрузить всё и выполнить запросы раздела A;
  «проигрывание» — загрузить состояние на момент до первого инцидентного поступления
  (строки с `dt`/`created_at` раньше него), выставить остаток и лимит виртуальной АБС
  на тот же момент и подавать события по выписке в том же порядке.

---

## C. Исправления харнесса

### C1. Порядок регистрации ПТ

```lua
-- resetState: долг обнулять, а не выставлять
for _, r in ipairs(sc.reqs or {}) do
    ex([[update k2req_group set debt = 0
          where id = (select group_id from k2req where id = ?)]], s(r.id))
    -- статус как раньше
end

STEPS.register_pt = function(api, sc, ctx, st)
    api.beforePtRegister(s(sc.acc_id))       -- фиксирует остаток typ=1
    for _, r in ipairs(sc.reqs or {}) do     -- затем «регистрируется» ПТ
        ex([[update k2req_group set debt = ?
              where id = (select group_id from k2req where id = ?)]], s(r.debt), s(r.id))
    end
end
```

### C2. Инварианты на лимит и сверку остатка

Добавить в `checkInvariants`; лимитные проверки выполнять только после шага
`update_limit` (передать `st.op` в функцию).

```lua
if op == 'update_limit' then
    local bankHeld = snap.f_b + snap.l_o + snap.l_b + snap.l_c
    if snap.abs_lim + EPS < bankHeld then
        table.insert(v, 'лимит АБС ' .. s(snap.abs_lim) ..
            ' меньше доли банка и арестованного ' .. s(r2(bankHeld)))
    end
    if snap.abs_lim > snap.abs_bal - snap.f_c + EPS then
        table.insert(v, 'лимит АБС ' .. s(snap.abs_lim) ..
            ' блокирует защищённую долю клиента f_c=' .. s(snap.f_c))
    end
end
local diff = r2(snap.abs_bal - anlTotal)
if math.abs(diff) > EPS then
    table.insert(v, 'остаток АБС не разложен по корзинам, разница ' .. s(diff))
end
```

### C3. Ожидания двух видов

В сценарии держать `expect` (правильно по бизнес-правилам) и `expect_current`
(текущее поведение пакета). В отчёте выводить оба результата. Пока пакет не исправлен,
ожидаемо: `expect_current` проходит, `expect` падает.

---

## D. Эскизы исправлений пакета

### D1. Построчное деление при регистрации поступления (Д1, Д2, Д3)

Вызывать в `onIncomeEvent` после `addAnlIncome`, под той же блокировкой счёта.

```lua
function api.splitFreeIncomes(anl, isIgnore50)
    local rows, ers, ern = SqlQueryRows([[
        select id, typ, f_o from k2anl_income
         where acc_id = ? and arcfl = 0 and f_o > 0
         order by id]], tostring(anl.acc_id))
    if ern ~= 0 then error(ers .. debug.traceback()) end

    local afterLW = nil
    if not isIgnore50 then
        afterLW = math.max(0, api.getAmountAfterLivingWage(anl))
    end

    for _, row in ipairs(rows) do
        local fo  = tonumber(row.f_o)
        local typ = tonumber(row.typ)
        local fb
        if typ == 4 then
            fb = fo                          -- 100% только для ЭТОЙ строки
        elseif typ == 2 then
            fb = api.round2(fo * 0.5)        -- 50% от конкретного перевода
        else
            fb = 0                           -- typ 1/3: согласовать с методологией
        end
        if afterLW then
            fb = math.min(fb, afterLW)
            afterLW = afterLW - fb
        end
        local fc = api.round2(fo - fb)
        local ers2, ern2 = SqlExec2([[
            update k2anl_income
               set f_o = 0, f_b = f_b + ?, f_c = f_c + ?
             where id = ?]], fb, fc, row.id)
        if ern2 ~= 0 then error(ers2 .. debug.traceback()) end
        anl.f_o = api.round2(anl.f_o - fo)
        anl.f_b = api.round2(anl.f_b + fb)
        anl.f_c = api.round2(anl.f_c + fc)
    end
end
```

Открытые вопросы методологии: делится ли остаток на момент регистрации ПТ (`typ=1`) и
«прочие» (`typ=3`) 50/50; округление полукопейки (`round2` или `roundDown2`).

### D2. Расчёт суммы без изменения данных

Ветка «PM» в `getAvailablePayAmountAnl` после переноса деления:

```lua
local amountAvaiable = anl.f_b            -- без moveAnls, без f_c в базе
if amountAvaiable <= 0 then return 0 end
return api.convertAvailablePayAmount(req_id, acc_id, reqDebt, amountAvaiable)
```

Блок `if anl.f_o > 0 then ... moveAnls ... end` убрать. Признак `typ` брать из строки,
а не из `getAggAnl`. В `onPayment` проверку `anl.typ==4` убрать: банковская доля
`typ=4` уже целиком лежит в `f_b`, списывать из `f_b`.

### D3. Идемпотентность поступления (Д5)

```sql
create unique index k2anl_income_log_uq on k2anl_income
  (case when typ in (2,4) then log_id end);
```

В начале `onIncomeEvent`:
```lua
local dup = SqlQueryRow2([[select count(*) cnt from k2anl_income
                            where log_id = ? and typ in (2,4)]], tostring(log_id))
if tonumber(dup.cnt or 0) > 0 then return end
```

### D4. Резервирование суммы платежа (Д4)

На шаге расчёта, под блокировкой счёта, переносить рассчитанную сумму из `f_b` в
резерв: запись `k2req_pay_anl` со статусом `pending` или отдельная колонка `r_b` в
`k2anl_income`. `onPayment` после успешного списания в АБС подтверждает резерв; при
отказе АБС резерв возвращается в `f_b`. Второй поток уже не видит ту же банковскую
долю. Минимальный вариант без резерва: держать блокировку `k2acc` на всём пути
«расчёт → списание → onPayment» (хуже по пропускной способности).

### D5. Необработанные поступления и сверка (Д5)

- `lockedIncomes` считать по записям `k2income_log` без строки в `k2anl_income`
  (запрос A5), а не через `accLim − limit_nat`.
- Для зависших счетов: найти такие записи, повторно выполнить `onIncomeEvent` (с D3
  это безопасно), затем `updateLimit`.
- Регулярная сверка `limit_nat` с лимитом АБС с алертом при расхождении.

### D6. Блокировка и подпроцессы (Д6)

Проверить, в какой сессии выполняются `k2acc_getbal_sys` и `k2acc_get_lim_sys`. Если в
отдельной и они обращаются к строке `k2acc`, получать баланс и лимит **до**
`for update` и передавать внутрь, либо обрабатывать события одного счёта строго
последовательно.

### D7. Мелкие исправления

- `hasAnyAnl`: `(typ<>2 or typ<>4)` → `typ not in (2,4)`.
- Удалить второе объявление `getAvailablePayAmount` (оно перекрывает первое и теряет
  fallback `getStandingOrdPayment`) или явно оставить одно нужное.
- `found`, `errText`, `errNum`, `typp` объявить `local`.
- В `onIncomeEvent` проверять ошибку `update k2acc set cldepositarrested`.
- `getAnlIncomeBankPart` не ограничивать сумму банковской долей первой строки.
- `getAccBal`: `if errNum==0 and found and found.cldepositarrested ~= nil then`.
- `syncAnl`: убрать необъявленные глобальные `systm`, `prdct`.

---

## E. Порядок внедрения

1. Разовая сверка зависших счетов (D5) и идемпотентность (D3).
2. Построчное деление и read-only расчёт (D1, D2) вместе с резервированием (D4): без
   резервирования построчное деление не защищает от двойного списания.
3. Блокировки (D6) и мелкие исправления (D7).

После каждого шага прогонять все кейсы автотеста.
