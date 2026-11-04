-- Тест-кейсы для REST-сервиса k2calc_test
--
-- Тестовый счёт стенда: 48350886, ПТ: 48337041 (control50percent = 1, part_pay = 1).
-- Если у вас другие id, замените их во всём файле.
--
-- expect          - целевое поведение по бизнес-правилам (пакет пока может не проходить)
-- expect_current  - текущее поведение пакета; задано только там, где цепочка проверена
--                   вручную по коду пакета
--
-- Допущения бизнес-правил (подтвердить у методолога):
--   * банку 50% от каждого обычного перевода (typ=2) отдельно, 100% от typ=4 (snd_attr='0');
--   * остаток на момент регистрации ПТ и прежние клиентские деньги (f_c) в базу 50% не входят;
--   * округление доли банка round2.

-- Таблица (если ещё не создана)
-- create table k2calc_test_case (
--     code       varchar2(50) primary key,
--     title      varchar2(400),
--     scenario   clob not null,
--     is_active  number(1) default 1 not null,
--     tags       varchar2(200)
-- );
-- Если таблица уже есть:
-- alter table k2calc_test_case add tags varchar2(200);

delete from k2calc_test_case where code in (
  'INC-1-SEQ', 'INC-1-RACE', 'INC-2',
  'INC-1-PROD', 'INC-1-CLEAN-SEQ', 'INC-1-CLEAN-BEFORE',
  'REG-ONE', 'REG-TWO-SEQ', 'REG-STALE-FC', 'REG-STALE-FC-TWO-BEFORE',
  'REG-TYP4', 'REG-TYP4-MIX', 'REG-MZP', 'REG-PARTIAL-DEBT',
  'REG-FIVE-SEQ', 'REG-FIVE-BEFORE', 'REG-CLIENT-SPEND');

---------------------------------------------------------------------------
-- INC-1: воспроизведение прода (проверено по bp_instances и коду пакета)
--
-- Устаревшая клиентская доля 09.09 (100 550,40) лежит в аналитике, деньги клиент
-- потратил, остаток 0,80. Оба перевода пришли в АБС до обработки первого.
-- Получение лимита для W4 возвращает limit_nat, поэтому lockedIncomes = 0, и второй
-- перевод «растворяется» в старой f_c. В базу 50% попадает f_c (Д1): 50 276 / 2 = 25 138.
---------------------------------------------------------------------------
insert into k2calc_test_case (code, title, tags, scenario) values ('INC-1-PROD',
'INC-1 как в проде: устаревшая f_c + два перевода до обработки',
'inc,current',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "balance": 0.80, "limit": 0,
  "acc": { "flagptpay": 0, "limit_nat": 0 },
  "mzp_covered": true,
  "seed_anl": [ { "typ": 2, "amount": 100550.40, "f_c": 100550.40, "is_finished": 1 } ],
  "steps": [
    { "op": "abs_income", "name": "I1", "amount": 29327.20 },
    { "op": "abs_income", "name": "I2", "amount": 20948.00 },
    { "op": "on_income", "income": "I1" }, { "op": "update_limit" },
    { "op": "on_income", "income": "I2" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect":         { "payments": [ 14663.60, 10474.00 ], "released": 25138.40, "buckets": { "f_b": 0 } },
  "expect_current": { "payments": [ 25138.00, 10474.00 ], "released": 14664.00 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('INC-1-CLEAN-SEQ',
'Остаток 0,80 на регистрации ПТ, переводы обрабатываются и оплачиваются по одному',
'inc,regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "balance": 0.80, "limit": 0,
  "mzp_covered": true,
  "steps": [
    { "op": "register_pt" },
    { "op": "abs_income", "name": "I1", "amount": 29327.20 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "name": "I2", "amount": 20948.00 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 14663.60, 10474.00 ], "released": 25138.40, "buckets": { "f_b": 0 } }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('INC-1-CLEAN-BEFORE',
'Два перевода приходят до обработки первого, без устаревшей f_c',
'inc,regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "balance": 0, "limit": 0,
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "name": "I1", "amount": 29327.20 },
    { "op": "abs_income", "name": "I2", "amount": 20948.00 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 14663.60, 10474.00 ], "released": 25137.60, "buckets": { "f_b": 0 } }
}~');

---------------------------------------------------------------------------
-- Регресс: базовые сценарии
---------------------------------------------------------------------------
insert into k2calc_test_case (code, title, tags, scenario) values ('REG-ONE',
'Одно поступление 10 000: банку 5 000',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 5000 ], "released": 5000, "abs_lim": 0, "buckets": { "f_b": 0, "f_c": 5000 } }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-TWO-SEQ',
'Два поступления по одному с оплатой после каждого',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "amount": 6000 }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 5000, 3000 ], "released": 8000, "abs_lim": 0 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-STALE-FC',
'Устаревшая f_c 50 000 (клиент потратил), одно поступление',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "balance": 0, "mzp_covered": true,
  "seed_anl": [ { "typ": 2, "amount": 50000, "f_c": 50000, "is_finished": 1 } ],
  "steps": [
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 5000 ], "released": 5000 }
}~');

-- Механизм INC-1 в общем виде. expect_current выведен по коду пакета:
-- I1: Δ=16000-50000 → f_c 16000; пересчёт Δ=-10000 → f_c 6000; база 6000+10000 → 8000.
-- I2: старая f_c 6000 → 0; база 6000 → 3000. Клиенту 16000-11000 = 5000.
insert into k2calc_test_case (code, title, tags, scenario) values ('REG-STALE-FC-TWO-BEFORE',
'Устаревшая f_c + два поступления до обработки (механизм INC-1)',
'regress,current',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "balance": 0, "mzp_covered": true,
  "acc": { "flagptpay": 0, "limit_nat": 0 },
  "seed_anl": [ { "typ": 2, "amount": 50000, "f_c": 50000, "is_finished": 1 } ],
  "steps": [
    { "op": "abs_income", "name": "I1", "amount": 10000 },
    { "op": "abs_income", "name": "I2", "amount": 6000 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect":         { "payments": [ 5000, 3000 ], "released": 8000 },
  "expect_current": { "payments": [ 8000, 3000 ], "released": 5000 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-TYP4',
'Поступление typ=4 (snd_attr=0): банку 100%',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000, "snd_attr": "0" },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "total_paid": 10000, "released": 0 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-TYP4-MIX',
'typ=4 8 000 и обычное 10 000 до обработки: 100% только с typ=4',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 8000, "snd_attr": "0" },
    { "op": "abs_income", "amount": 10000 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "total_paid": 13000, "released": 5000 }
}~');

-- Требует k2mzp > 20 000 и чтобы k2acc_getbal_at_virtual не возвращал большой остаток.
insert into k2calc_test_case (code, title, tags, scenario) values ('REG-MZP',
'ПМ не покрыт: поступление 10 000 целиком клиенту',
'regress,mzp',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "steps": [
    { "op": "abs_income", "amount": 10000 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "total_paid": 0, "released": 10000, "abs_lim": 0 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-PARTIAL-DEBT',
'Долг 3 000 меньше 50%: списать 3 000, остальное клиенту',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 3000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 3000 ], "released": 7000, "abs_lim": 0 }
}~');

---------------------------------------------------------------------------
-- Шаблон INC-2: пять поступлений. Реальную хронологию INC-2 подставить после
-- разбора (в т.ч. ответ АБС «Exists waiting document» на установку лимита).
---------------------------------------------------------------------------
insert into k2calc_test_case (code, title, tags, scenario) values ('REG-FIVE-SEQ',
'Пять поступлений по 10 000, обработка и оплата после каждого',
'regress,inc2',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" }, { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" }, { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" }, { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" }, { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" }, { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "total_paid": 25000, "released": 25000, "abs_lim": 0 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-FIVE-BEFORE',
'Пять поступлений по 10 000 приходят до обработки, обработка строго по очереди',
'regress,inc2',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 }, { "op": "abs_income", "amount": 10000 },
    { "op": "abs_income", "amount": 10000 }, { "op": "abs_income", "amount": 10000 },
    { "op": "abs_income", "amount": 10000 },
    { "op": "on_income" }, { "op": "update_limit" }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "on_income" }, { "op": "update_limit" }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "pay" }, { "op": "pay" }, { "op": "pay" }, { "op": "pay" },
    { "op": "update_limit" }
  ],
  "expect": { "total_paid": 25000, "released": 25000, "abs_lim": 0 }
}~');

insert into k2calc_test_case (code, title, tags, scenario) values ('REG-CLIENT-SPEND',
'Клиент тратит свою долю между поступлениями',
'regress',
q'~{
  "acc_id": 48350886,
  "reqs": [ { "id": 48337041, "debt": 1000000, "stat": "actual" } ],
  "mzp_covered": true,
  "steps": [
    { "op": "abs_income", "amount": 10000 }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" },
    { "op": "abs_spend", "amount": 5000 },
    { "op": "abs_income", "amount": 4000 }, { "op": "on_income" }, { "op": "update_limit" },
    { "op": "pay" }, { "op": "update_limit" }
  ],
  "expect": { "payments": [ 5000, 2000 ], "released": 2000, "abs_lim": 0 }
}~');

commit;
