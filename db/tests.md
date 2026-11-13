# Протокол прогона проверок

Все проверки выполнены по `templates/tests.md` на **чистой базе, восстановленной из бэкапа**
(`db/foodexpress_kalugin.backup` → `pg_restore` → `db/schema/grants.sql`), под ролью `inspector`,
если не указано иное.

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `PostgreSQL 17.11 on x86_64-windows` |
| Дата проверки | 2026-11-12, повторно C, D, E.3/E.4, I и восстановление бэкапа — 2026-11-13 (после правок генератора) |
| Схема | `kalugin_food` |
| Роль-аудитор | `inspector` (пароль `NetoSQL2025`) |

### Порядок развёртывания

```bash
createdb foodexpress_restore
psql -d foodexpress_restore -c 'create schema exts; create extension "uuid-ossp" schema exts;'   # если exts ещё нет
pg_restore -d foodexpress_restore db/foodexpress_kalugin.backup
psql -d foodexpress_restore -f db/schema/grants.sql
psql -U inspector -d foodexpress_restore
```

Бэкап снят командой
`pg_dump -Fc -n kalugin_food --no-owner --no-privileges -f db/foodexpress_kalugin.backup <база>`:
без владельцев и прав, чтобы восстановление на чужом сервере не падало на отсутствующих ролях;
права выдаёт `grants.sql`. Бэкап содержит тестовые данные `insert_test_data(10)`.
Пересобран 2026-11-13 (`pg_dump` 17.11) из базы, собранной по исходникам `00`…`09` + `grants.sql` после правок генератора и `rating_change`; восстановление проверено: `pg_restore --exit-on-error` в чистую базу с `exts` + `uuid-ossp` → код 0, `grants.sql` дважды → код 0, в базе 50 заказов / 50 оплат / 60 выплат, затем под `inspector` пройдены C, D.8 (строгая), D.14, E.3/E.4, I.

Сборка схемы из исходников (вместо бэкапа): по порядку `db/schema/00_schema.sql` … `09_how_much_money.sql`, затем `grants.sql`.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: `pg_restore --exit-on-error` → код 0; `grants.sql` → код 0, повторный запуск `grants.sql` → код 0.
Вердикт: OK

### A.2. Переключение на inspector

Факт: `current_user` = `inspector`. Для роли задан `search_path = kalugin_food, exts, public`, поэтому `SET search_path` необязателен.
Вердикт: OK

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

Факт: `kalugin_food`.
Вердикт: OK

### B.2. Схема `exts` с `uuid-ossp`

Факт: `uuid-ossp`, схема `exts` (создана окружением, в скриптах проекта не пересоздаётся).
Вердикт: OK

### B.3. Все 12 исходных таблиц + N после нормализации

Факт: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` — 12 таблиц, N = 0 (дополнительные таблицы для 3НФ не потребовались, см. `constraints.md`). `information_schema.tables` дополнительно показывает представление `how_much_money` (тип `VIEW`).
Вердикт: OK

### B.4. Все PK — `uuid`

Факт: пусто. Внешний идентификатор транзакции назван `transaction_ref` — это не UUID и не ключ нашей системы (см. `constraints.md`).
Вердикт: OK

### B.5. Enum-типы

Факт: 8 типов — `courier_status`, `order_pay_status`, `order_status`, `payment_status`, `payment_type`, `product_status`, `restaurant_status`, `review_entity_type`; значения совпадают с `constraints.md`.
Вердикт: OK

### B.6. FK-ограничения

Факт: 20 FK (все связи ERD + составные FK для BR-7.3, BR-7.4, BR-8.4, BR-9.2).
Вердикт: OK

### B.7. Пароль — MD5

Факт: `len = 32`, hex-строки (например `3706a9dbe90f7a243bc21cda903d7847`).
Вердикт: OK

### B.8. Негативные проверки ограничений (дополнительно, под `postgres`, в откатываемой транзакции)

Факт: 33 попытки нарушить бизнес-правила — все отклонены базой:
BR-1.4 (ручная запись комиссии), BR-1.8, BR-2.2 (логин, телефон), BR-2.3, BR-2.5, BR-3.3, BR-3.5, BR-4.2, BR-4.4, BR-5.3,
BR-6.3 (уволен без даты, увольнение раньше найма), BR-6.4, BR-7.3 (два варианта), BR-7.4, BR-7.12, BR-7.13, BR-7.15, BR-7.16,
BR-8.1, BR-8.3, BR-8.4, BR-9.1, BR-9.2 (чужой клиент, блюдо не из заказа, чужой ресторан), BR-9.4, BR-9.5, BR-10.3, BR-10.4, BR-11.3.
Вердикт: OK

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

Факт: `CALL erase_test_data();` — без ошибок.
Вердикт: OK

### C.2. Первый запуск

Факт: `CALL insert_test_data(10);` — без ошибок.
Вердикт: OK

### C.3. Распределение строк (BR-11.7)

Факт: address 50, client 10, courier 10, order 50, payment 50, product 50, product_category 10, restaurant 10, review 50.
Таблицы связей: client_address 41–45 (40 + соседские адреса), order_structure 94–113 (1–3 блюда в заказе), courier_pay 60 (10 курьеров × 6 месяцев).
Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

Факт: 10 ресторанных адресов, 50 всего → 40 клиентских.
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

Факт: 0 (дополнительно пустые строки запрещены CHECK `<> ''` в схеме).
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

Факт: 0.
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

Факт: 7–9 (первый курьер каждой порции всегда работает).
Вердикт: OK

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

Факт: строк, где `amount <> expected_amount`, — 0 (проверены все строки, а не первые 20). Также 0 доставленных заказов без записи `courier_pay` за их месяц.
Вердикт: OK

### C.9. Повторный вызов не ломает

Факт: 10 вызовов подряд без ошибок; данные **добавляются** (110 клиентов, 550 заказов, 660 выплат), C.8 после повторов — 0 расхождений. Повторно после правок генератора: второй вызов `insert_test_data(10)` → 100 заказов, 100 оплат, 120 выплат; строгая D.8 и D.14 — 0 нарушений. Решение задокументировано в `constraints.md`.
Вердикт: OK

### C.10. Дополнительно

Факт:
- все даты (заказы, доставки, отзывы, оплаты, найм и увольнение курьеров) — не раньше `current_date - 180` и не в будущем: 0 нарушений. Окно дат — `greatest(1-е число месяца пять месяцев назад, current_date - 180)`, поэтому каждый доставленный заказ попадает в один из 6 месяцев `courier_pay` (C.8: 0 заказов без выплаты за их месяц);
- заказ лежит в периоде работы курьера (не раньше найма, не позже увольнения): 0 нарушений;
- `order_amount = Σ(price × quantity)` по составу: 0 нарушений;
- `courier.coefficient` = коэффициент на следующий месяц по доставкам текущего месяца (для работающих): 0 нарушений;
- в теле процедуры нет `order by random()` (`regexp_count(prosrc, 'order by random')` = 0): адрес заказа берётся из массива адресов клиента по случайному индексу, состав заказа — перемешиванием массива индексов блюд ресторана;
- `rating_change` во время генерации не пересчитывает рейтинг: за `insert_test_data(10)` счётчик `pg_stat_user_tables.n_tup_upd` по `product` вырос ровно на 50 — это один итоговый `UPDATE` блюд порции, без обновлений из триггера на каждый отзыв. После `CALL` флаг `kalugin_food.skip_rating` снят (`off`) и в той же транзакции; рейтинги совпадают с AVG (D.14);
- граничный случай `insert_test_data(1)` — без ошибок;
- производительность: `value = 10` — 0,4–0,6 с на временном кластере (`100` — 3,8 с, `1000` — 37 с по замеру предыдущей версии).

Вердикт: OK

---

## D. Проверки бизнес-правил на сгенерированных данных

| Проверка | Ожидается | Факт | Вердикт |
|---|---|---|---|
| D.1 Все FK валидны | все 0 | все 0 (гарантируется FK) | OK |
| D.2 Минимальная сумма заказа (BR-1.8) | 0 | 0 | OK |
| D.3 Комиссия = 10% (BR-1.4) | 0 | 0 | OK |
| D.4 `total_amount = order_amount + commission` | 0 | 0 | OK |
| D.5 Доставка не раньше создания (BR-7.13) | 0 | 0 | OK |
| D.6 Адрес доставки принадлежит клиенту (BR-7.4) | 0 | 0 | OK |
| D.7 Блюда заказа из одного ресторана (BR-7.3) | 0 | 0 | OK |
| D.8 Ровно одна успешная оплата (BR-8.1) | пусто | пусто | OK |
| D.9 Сумма оплаты = `total_amount` (BR-8.4) | 0 | 0 | OK |
| D.10 Нет дублей `client_address` (BR-2.5) | пусто | пусто | OK |
| D.11 Нет дублей `order_structure` (BR-7.16) | пусто | пусто | OK |
| D.12 `work_end > work_start` (BR-4.4) | 0 | 0 | OK |
| D.13 `dismissal_date >= hire_date` (BR-6.3) | 0 | 0 | OK |
| D.14 Рейтинг блюд и ресторанов = AVG отзывов (BR-9.6) | совпадает | 0 расхождений по всем блюдам и ресторанам | OK |
| Доп. `pay_status` согласован с попытками оплаты (BR-8.7) | 0 | 0 | OK |

Примечание к D.8. Запрос из шаблона (`... FROM payment WHERE status = 'успех' GROUP BY order_id HAVING count(*) != 1`) не видит заказы **без** успешной оплаты: у них нет строк в выборке. Поэтому дополнительно выполнена строгая проверка «ровно одна» от таблицы заказов:

```sql
SELECT o.order_id, count(p.payment_id) AS success_cnt
FROM "order" o
LEFT JOIN payment p ON p.order_id = o.order_id AND p.status = 'успех'
GROUP BY o.order_id
HAVING count(p.payment_id) <> 1;
```

Факт: пусто (и после первого вызова, и после повторного). Генератор создаёт у каждого заказа одну попытку оплаты, и она успешная (предоплата — заказ в статусе `создан` тоже уже оплачен). Так одновременно выполняются BR-8.1 (ровно одна успешная), BR-11.7 (`payment = value × 5` — ровно по одной строке на заказ; дополнительные неуспешные попытки увеличили бы число строк сверх `value × 5`) и BR-8.7: у всех 50 заказов `pay_status = 'оплачен'`. Больше одной успешной попытки не даёт и частичный уникальный индекс `payment_one_success_uq`.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

PostgreSQL не допускает подзапросы в аргументах `CALL`
(`ERROR: cannot use subquery in CALL argument`), поэтому ID берутся заранее в переменные psql:

```sql
select restaurant_id as rid from restaurant limit 1 \gset
select product_category_id as cid from product_category limit 1 \gset

call add_product(
    p_restaurant_id       => :'rid',
    p_product_category_id => :'cid',
    p_name                => 'Тестовое блюдо',
    p_price               => 250,
    p_rating              => 4.5,
    p_status              => 'доступно',
    p_description         => 'Описание'
    -- p_photo_url => '...' (необязательно)
);
```

Сигнатура: `add_product(p_restaurant_id, p_product_category_id, p_name, p_price, p_description, p_status default 'доступно', p_rating default null, p_photo_url default null)`.

Факт: `before = 50`, `after = 51`, NOTICE с ID нового блюда.
Вердикт: OK

### E.2. `add_product` — ошибки

Факт (каждый вызов падает, количество блюд не меняется):
- несуществующий ресторан → `add_product: ресторан с id 00000000-0000-0000-0000-000000000000 не существует`;
- несуществующая категория → `add_product: категория блюд с id … не существует`;
- цена −5 → `add_product: цена должна быть неотрицательной (BR-5.3), передано -5`;
- рейтинг 7 → `add_product: рейтинг должен быть от 0 до 5 (BR-5.4), передано 7`;
- статус `продано` → `add_product: недопустимый статус блюда "продано", допустимо: {доступно,нет_в_наличии,архив} (BR-5.5)`;
- пустое название → `add_product: название блюда обязательно (BR-5.2)`.

Вердикт: OK

### E.3 / E.4. `rating_change`

**Почему запрос из `templates/tests.md` дословно не выполняется.** Шаблон вставляет отзыв с клиентом `(SELECT client_id FROM client LIMIT 1)`, заказом `(SELECT order_id FROM "order" LIMIT 1)` и любым блюдом с рейтингом. Эти три значения между собой не связаны, а схема такие отзывы запрещает:
- BR-9.2 — отзыв оставляет только клиент этого заказа: составной FK `review_order_client_fk` `(order_id, client_id) → "order"(order_id, client_id)` отклоняет чужого клиента;
- BR-9.1/BR-9.2 — отзыв на блюдо только из состава этого заказа: триггер `review_entity_check` (BEFORE INSERT) отклоняет блюдо, которого нет в `order_structure` заказа.

Факт для дословного запроса: `ERROR: Отзыв: блюдо … отсутствует в заказе …` (`review_entity_check`, срабатывает раньше проверки FK). Это ожидаемое поведение, а не ошибка `rating_change`. Поэтому сценарий построен от данных: **блюдо → заказы, в которых оно есть → клиент каждого заказа**. Отзыв на одно блюдо в рамках заказа допускается один (BR-9.5, `review_entity_uq`), поэтому для отзывов 3, 4, 5 нужны три разных заказа с этим блюдом. Всё выполняется в откатываемой транзакции, под `inspector`:

```sql
BEGIN;

-- блюдо, которое входит минимум в три заказа
SELECT os.product_id AS pid
FROM order_structure os
GROUP BY os.product_id
HAVING count(*) >= 3
ORDER BY count(*) DESC, os.product_id
LIMIT 1 \gset

-- чистый старт: убираем имеющиеся отзывы на это блюдо
DELETE FROM review WHERE entity_type = 'блюдо' AND entity_id = :'pid';
SELECT rating FROM product WHERE product_id = :'pid';                -- NULL

-- E.3: три заказа с этим блюдом -> клиент каждого заказа -> отзывы 3, 4, 5
INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type,
                    order_id, description, rating)
SELECT exts.uuid_generate_v4(), o.client_id, localtimestamp, :'pid', 'блюдо',
       o.order_id, 'Тестовый отзыв', v.rating
FROM (SELECT o.order_id, o.client_id,
             row_number() OVER (ORDER BY o.order_timestamp, o.order_id) AS rn
      FROM "order" o
      JOIN order_structure os ON os.order_id = o.order_id
      WHERE os.product_id = :'pid') o
JOIN (VALUES (1, 3), (2, 4), (3, 5)) AS v(rn, rating) ON v.rn = o.rn;

SELECT rating FROM product WHERE product_id = :'pid';                -- 4.00

-- E.4: удаление и изменение отзывов
DELETE FROM review WHERE entity_type = 'блюдо' AND entity_id = :'pid' AND rating = 3;
SELECT rating FROM product WHERE product_id = :'pid';                -- 4.50

UPDATE review SET rating = 1
WHERE entity_type = 'блюдо' AND entity_id = :'pid' AND rating = 4;
SELECT rating FROM product WHERE product_id = :'pid';                -- 3.00

DELETE FROM review WHERE entity_type = 'блюдо' AND entity_id = :'pid';
SELECT rating FROM product WHERE product_id = :'pid';                -- NULL

ROLLBACK;
```

Факт (на базе из сборки и на базе, восстановленной из бэкапа):
- до отзывов `product.rating = NULL`;
- после трёх отзывов 3, 4, 5 — `4.00`;
- после удаления отзыва с рейтингом 3 — `4.50`;
- после UPDATE рейтинга оставшегося отзыва 4 → 1 — `3.00`;
- после удаления всех — `NULL`.

Дополнительно (прогон 2026-11-12): UPDATE отзыва с `блюдо` на `ресторан` — рейтинг блюда стал `NULL`, рейтинг ресторана пересчитан (`2.00` = ожидаемое среднее); отзыв на `заказ` вставляется без ошибок и ничего не пересчитывает.

Вердикт: OK

### E.5. `get_statistic()`

Факт: колонки `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`; 10 строк = 10 ресторанов; `best_user` — логин клиента.
Сверка с независимым расчётом «в лоб»: расхождений по суммам и средним — 0; выбранное блюдо имеет максимальное суммарное количество — 0 расхождений; выбранный клиент имеет максимум доставленных заказов — 0 расхождений; `NULL` при наличии заказов — 0; `total_amount < avg_amount` — 0.
Ресторан без доставленных заказов выводится с `total_amount = 0`, `avg_amount = 0`, `best_product_name` и `best_user` — `NULL`.
Вердикт: OK

### E.6. `courier_salary()`

Факт: записи за текущий месяц есть у всех курьеров, работавших в этом месяце (10); у уволенных коэффициент не изменился (0 изменений); суммы согласованы с C.8 (0 расхождений).
Проверка порогов BR-10.2 (в откатываемой транзакции, коэффициент текущего месяца 0.3): 162 доставки → новый коэффициент 0.2, 260 → 0.3, 511 → 0.5; зарплата посчитана по коэффициенту текущего месяца 0.3.
Вердикт: OK

### E.7. `courier_salary()` — повторный вызов

Факт: количество записей за текущий месяц не изменилось (10 → 10). При повторном вызове `coefficient_used` и сумма остались прежними — коэффициент текущего месяца берётся из уже существующей записи, а не из `courier.coefficient` (там после первого вызова — коэффициент следующего месяца).
Вердикт: OK

---

## F. Представление `how_much_money`

### F.1. Колонки

Факт: `year_month` text, `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` — numeric.
Вердикт: OK

### F.2. Месяцы покрыты

Факт: месяцы от первого до последнего месяца с доставленными заказами подряд, без пропусков (серия строится рекурсивным CTE).
Вердикт: OK

### F.3. Месяцы без заказов присутствуют (BR-11.9)

Факт: в одном из прогонов генератор сам дал месяц без доставок (`2026-07`) — строка есть с нулями, `net_profit = 0`. Дополнительно в откатываемой транзакции удалены доставленные заказы второго месяца — месяц остался в отчёте с нулевыми суммами, `prev_commission` следующего месяца = 0.
Вердикт: OK

### F.4. Корректность сумм

Факт: строк, где `commission <> sum_with_commission - sum_no_commission`, — 0; `commission_diff ≠ commission - prev_commission` — 0 (для первого месяца оба `NULL`); `net_profit ≠ commission - courier_pay` — 0; `year_month` в формате `YYYY-MM` — все строки.
Вердикт: OK

---

## G. Права `inspector`

| Проверка | Ожидается | Факт | Вердикт |
|---|---|---|---|
| G.1 Права на схему | `true`, `true` | `kalugin_food`: usage `t`, create `t`; `exts`, `information_schema`, `pg_catalog`: usage `t` | OK |
| G.2 Права на таблицы | DML на каждой | `SELECT, INSERT, UPDATE, DELETE, TRUNCATE` на всех 12 таблицах и на представлении | OK |
| G.3 `information_schema` читается | 12 + N | 13 = 12 таблиц + представление `how_much_money` | OK |
| G.4 `pg_catalog` читается | 12 + N | 12 (`pg_tables` не показывает представления) | OK |
| G.5 Процедуры и функции под `inspector` | без `permission denied` | `erase_test_data`, `insert_test_data(10)`, `courier_salary`, `get_statistic`, `how_much_money`, `add_product`, триггеры — без ошибок | OK |

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. Паттерн «избыточные подзапросы»

Факт: 2 SubPlan, каждый выполняется 10 раз (`loops=10`) с отдельным сканом `"order"`; Execution Time 0,117 мс на 10 курьерах. Число сканов растёт линейно с числом курьеров.

### H.2. Паттерн «один JOIN»

Факт: один `Hash Right Join`, один `Seq Scan on "order"`, `HashAggregate`; Execution Time 0,136 мс. На 10 строках время сопоставимо с H.1, но сканов `"order"` — 1 вместо 20.

### H.3. `get_statistic`

`EXPLAIN ANALYZE SELECT * FROM get_statistic()` показывает только `Function Scan` (1,6 мс). План тела функции снят через `auto_explain` (`log_nested_statements = on`):
- `"order"` читается **один раз** (`CTE delivered`, MATERIALIZED, Bitmap Index Scan по `order_status_ts_idx`), дальше переиспользуется через `CTE Scan`;
- `client`, `order_structure`, `restaurant` — по одному скану, `product` — индексный доступ; все соединения — `Hash Join` / `Hash Left Join`;
- нет `SubPlan`, `LATERAL`, `WindowAgg`: «лучшее» блюдо и клиент выбираются агрегатом `(array_agg(... order by ... desc, random()))[1]`.

Вердикт: OK

---

## I. Очистка и повторная генерация

| Проверка | Ожидается | Факт | Вердикт |
|---|---|---|---|
| I.1 `erase_test_data` очищает всё | все 0 | 0 во всех 12 таблицах | OK |
| I.2 Повторный `erase_test_data` | без ошибок | без ошибок | OK |
| I.3 `insert_test_data` после очистки | 50 заказов | 50 | OK |
