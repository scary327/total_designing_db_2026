-- FOOD-102. Генератор тестовых данных.
--
-- value — число записей в справочниках, в крупных таблицах value × 5;
-- 1 млн строк = value 200000.
--
-- Распределение (BR-11.7) на один вызов insert_test_data(value):
--   value     : client, courier, product_category, restaurant;
--   value * 5 : address (value — под рестораны, value * 4 — под клиентов),
--               product, order, review, payment;
--   client_address, order_structure — сколько нужно для связности;
--   courier_pay — по каждому курьеру за последние 6 месяцев (BR-10.2, BR-10.7).
--
-- Весь вызов — одна транзакция: массивы идентификаторов порции держатся
-- в памяти процедуры, а каждый идентификатор — отдельный вызов
-- exts.uuid_generate_v4() (около 29 × value вызовов).
--
-- Процедуру можно вызывать многократно без очистки: каждый вызов добавляет
-- новую порцию данных и связывает между собой только строки этой порции,
-- поэтому выплаты курьеров прошлых вызовов не теряют согласованность.
-- Уникальные поля (название категории, логин и телефон клиента,
-- идентификатор транзакции) вставляются с on conflict do nothing, недостающие
-- строки довставляются, пока их не станет ровно столько, сколько нужно.
--
-- Все вставки пакетные (insert ... select ... from generate_series), без
-- построчных циклов. Строки порции связываются по номеру: идентификаторы
-- курьеров, клиентов, адресов, ресторанов и блюд собираются в массивы,
-- элемент берётся по случайному индексу — без запросов вида
-- «случайная строка таблицы». exts.uuid_generate_v4() вызывается только для
-- идентификаторов (BR-11.1). Заказы с составом, оплатами и отзывами
-- генерируются пакетами по c_chunk заказов, чтобы объём одного оператора
-- (и очередь проверок FK в памяти) не рос вместе с value.
--
-- Случайная строка — буквы а..я без префиксов и словарей:
--   (select string_agg(chr(1072 + floor(random() * 32)::int), '')
--      from generate_series(1, <длина>))
-- Код 1072 — Unicode буквы «а»; 32 кода дают «а»…«я» без «ё».
-- Длина — столбец внешнего запроса, поэтому подзапрос коррелированный и
-- выполняется для каждой строки заново. Для varchar(N) длина случайная
-- от 1 до N, для text — от 1 до 200.
--
-- Процедура не вызывает другие функции и процедуры схемы: courier_pay,
-- блюда и рейтинги заполняются прямыми INSERT/UPDATE. При этом на вставляемых
-- строках срабатывают триггеры таблиц: review_entity_check (проверка отзыва)
-- и payment_pay_status (order.pay_status по BR-8.7). Триггер rating_change
-- на время генерации пропускается: процедура ставит флаг транзакции
-- kalugin_food.skip_rating, а рейтинги этой порции считает одним UPDATE
-- в разделе 9 (samples, раздел 10).

SET search_path TO kalugin_food;

CREATE OR REPLACE PROCEDURE insert_test_data(value integer)
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
DECLARE
    -- заказов в одном пакете; кратно 5, см. раздел 8
    c_chunk       constant integer := 50000;

    v_cat         UUID[] := '{}';
    v_client      UUID[] := '{}';
    v_cour        UUID[];
    v_cour_start  timestamp[];
    v_cour_end    timestamp[];
    v_cour_fired  boolean[];
    v_addr        UUID[];
    v_extra       boolean[];       -- у клиента i есть ещё и адрес соседа
    v_rest        UUID[];
    v_rest_status restaurant_status[];
    v_rest_act    integer[];       -- номера активных ресторанов
    v_prod        UUID[];
    v_price       integer[];
    v_prod_status product_status[];
    v_ord         UUID[];          -- заказы текущего пакета

    v_active_st   courier_status[] := array_remove(enum_range(NULL::courier_status), 'уволен');
    v_rest_st     restaurant_status[] := enum_range(NULL::restaurant_status);
    v_prod_st     product_status[] := enum_range(NULL::product_status);
    v_order_all   order_status[] := enum_range(NULL::order_status);
    -- завершённые: доставлен .. отменён (порядок enum)
    v_order_done  order_status[] := enum_range('доставлен'::order_status, NULL::order_status);
    v_pay_types   payment_type[] := enum_range(NULL::payment_type);
    v_pay_statuses payment_status[] := enum_range(NULL::payment_status);
    v_rev_types   review_entity_type[] := enum_range(NULL::review_entity_type);

    -- месяцы выплат: текущий и пять предыдущих (BR-10.7)
    v_pay_start   date := (date_trunc('month', CURRENT_DATE) - interval '5 months')::date;
    -- даты данных: последние 180 дней, но не раньше первого месяца выплат,
    -- чтобы у каждого доставленного заказа был месяц в courier_pay
    v_window_start date := greatest(v_pay_start, CURRENT_DATE - 180);

    v_from        integer;
    v_cnt         integer;
    v_added       integer;
    v_try         integer;
BEGIN
    IF value IS NULL OR value < 1 THEN
        RAISE EXCEPTION 'insert_test_data: value должно быть положительным, передано %', value;
    END IF;

    -- rating_change не пересчитывает рейтинг на каждый отзыв генератора:
    -- флаг действует до конца транзакции (is_local = true) и снимается
    -- перед итоговым пересчётом в разделе 9.
    PERFORM set_config('kalugin_food.skip_rating', 'on', TRUE);

    -- -----------------------------------------------------------------------
    -- 1. Категории блюд (value). Название уникально (BR-5.7): совпавшие
    --    с уже существующими пропускаются и довставляются новыми.
    -- -----------------------------------------------------------------------
    v_try := 0;
    WHILE cardinality(v_cat) < value LOOP
        v_try := v_try + 1;
        IF v_try > 1000 THEN
            RAISE EXCEPTION 'insert_test_data: не удалось подобрать % уникальных названий категорий',
                value - cardinality(v_cat);
        END IF;

        WITH ins AS (
            INSERT INTO product_category (product_category_id, product_category_name)
            SELECT exts.uuid_generate_v4(),
                   (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                      FROM generate_series(1, g.len))
              FROM (SELECT 1 + floor(random() * 100)::int AS LEN
                      FROM generate_series(1, value - cardinality(v_cat))) AS g
            ON CONFLICT (product_category_name) DO NOTHING
            RETURNING product_category_id
        )
        SELECT v_cat || coalesce(array_agg(product_category_id), '{}')
          INTO v_cat
          FROM ins;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 2. Курьеры (value). Фамилия, имя и отчество генерируются отдельно,
    --    каждое — случайное слово от 1 до 49 букв с заглавной. Все даты — внутри окна v_window_start .. сегодня:
    --    не старше 180 дней и не раньше 1-го числа месяца пять месяцев назад.
    --    Выплаты генерируются за все месяцы этого окна, поэтому каждый
    --    доставленный заказ попадает в месяц, по которому есть запись courier_pay.
    --    Первый курьер всегда работает и нанят в начале окна (BR-6.6).
    --    Около 20% остальных — уволены, с датой увольнения не раньше даты
    --    найма (BR-6.3). Период работы курьера (найм .. увольнение или
    --    сейчас) запоминается в массивах — в нём лежат его заказы.
    -- -----------------------------------------------------------------------
    WITH ins AS (
        INSERT INTO courier (courier_id, last_name, first_name, middle_name, phone_number, status,
                             hire_date, dismissal_date, coefficient)
        SELECT exts.uuid_generate_v4(),
               -- заглавная А..Я и строчные буквы; initcap не годится: при
               -- локали C он не меняет регистр кириллицы
               chr(1040 + floor(random() * 32)::int)
                   || coalesce((SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  FROM generate_series(2, c.len1)), '')
               , chr(1040 + floor(random() * 32)::int)
                   || coalesce((SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  FROM generate_series(2, c.len2)), '')
               , chr(1040 + floor(random() * 32)::int)
                   || coalesce((SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  FROM generate_series(2, c.len3)), ''),
               '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
               CASE WHEN c.fired THEN 'уволен'::courier_status
                    ELSE v_active_st[1 + floor(random() * cardinality(v_active_st))::int]
               END,
               c.hire,
               CASE WHEN c.fired
                    THEN c.hire + floor(random() * (CURRENT_DATE - c.hire + 1))::int
               END,
               0.1
          FROM (SELECT CASE WHEN g.i = 1 THEN v_window_start
                            ELSE v_window_start
                                 + floor(random() * (CURRENT_DATE - v_window_start + 1))::int
                       END                               AS hire,
                       g.i > 1 AND random() < 0.2        AS fired,
                       1 + floor(random() * 49)::int     AS len1,
                       1 + floor(random() * 49)::int     AS len2,
                       1 + floor(random() * 49)::int     AS len3
                  FROM generate_series(1, value) AS g(i)) AS c
        RETURNING courier_id, hire_date, dismissal_date
    )
    SELECT array_agg(courier_id),
           array_agg(hire_date::timestamp),
           array_agg(CASE
                         WHEN dismissal_date IS NULL THEN LOCALTIMESTAMP
                         ELSE least(dismissal_date + interval '23 hours 59 minutes', LOCALTIMESTAMP)
                     END),
           array_agg(dismissal_date IS NOT NULL)
      INTO v_cour, v_cour_start, v_cour_end, v_cour_fired
      FROM ins;

    -- -----------------------------------------------------------------------
    -- 3. Адреса (value * 5): первые value — под рестораны, остальные — клиентам.
    --    Улица — 1..150 букв; дом — 1..10 символов: номер и буквы (обрезаются
    --    по длине, поэтому дом всегда начинается с цифры); квартира/офис
    --    необязательна (BR-3.2), иначе 1..10 символов так же, как дом.
    -- -----------------------------------------------------------------------
    WITH ins AS (
        INSERT INTO address (address_id, street, house_number, apartment_office)
        SELECT exts.uuid_generate_v4(),
               (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                  FROM generate_series(1, a.len_street)),
               left((1 + floor(random() * 300))::int::text
                    || (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                          FROM generate_series(1, a.len_house)),
                    a.len_house),
               CASE WHEN NOT a.no_apartment THEN
                   left((1 + floor(random() * 500))::int::text
                        || (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                              FROM generate_series(1, a.len_apartment)),
                        a.len_apartment)
               END
          FROM (SELECT 1 + floor(random() * 150)::int AS len_street,
                       1 + floor(random() * 10)::int  AS len_house,
                       random() < 0.3                 AS no_apartment,
                       1 + floor(random() * 10)::int  AS len_apartment
                  FROM generate_series(1, value * 5)) AS a
        RETURNING address_id
    )
    SELECT array_agg(address_id) INTO v_addr FROM ins;

    -- -----------------------------------------------------------------------
    -- 4. Рестораны (value): у ресторана i адрес v_addr[i] (BR-3.3).
    --    Первый ресторан всегда активен — на активные рестораны оформляются
    --    незавершённые заказы. Время закрытия позже открытия (BR-4.4):
    --    открытие 06:00..11:59, работа 8..12 часов, закрытие не позже 23:59.
    --    Название — 1..100 букв, описание и реквизиты — 1..200: BR-4.5
    --    описывает содержание реквизитов, но не формат, поэтому шаблона
    --    «ИНН …» нет.
    -- -----------------------------------------------------------------------
    SELECT array_agg(r.id ORDER BY r.i),
           array_agg(r.status ORDER BY r.i),
           array_agg(r.i ORDER BY r.i) filter (WHERE r.status = 'активен')
      INTO v_rest, v_rest_status, v_rest_act
      FROM (SELECT g.i,
                   exts.uuid_generate_v4() AS id,
                   CASE WHEN g.i = 1 OR random() < 0.8 THEN 'активен'::restaurant_status
                        ELSE v_rest_st[1 + floor(random() * cardinality(v_rest_st))::int]
                   END AS status
              FROM generate_series(1, value) AS g(i)) AS r;

    INSERT INTO restaurant (restaurant_id, restaurant_name, address_id, description,
                            work_start, work_end, inn, ogrn, bank_account, rating, status)
    SELECT v_rest[r.i],
           (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
              FROM generate_series(1, r.len_name)),
           v_addr[r.i],
           (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
              FROM generate_series(1, r.len_description)),
           r.work_start,
           r.work_start + (8 + floor(random() * 5))::int * interval '1 hour',
           lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
           lpad(floor(random() * 10000000000000)::bigint::text, 13, '0'),
           lpad(floor(random() * 10000000000)::bigint::text, 10, '0')
               || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
           NULL,
           v_rest_status[r.i]
      FROM (SELECT g.i,
                   TIME '06:00' + floor(random() * 360)::int * interval '1 minute' AS work_start,
                   1 + floor(random() * 100)::int AS len_name,
                   1 + floor(random() * 200)::int AS len_description
              FROM generate_series(1, value) AS g(i)) AS r;

    -- -----------------------------------------------------------------------
    -- 5. Клиенты (value). Логин (1..50 букв) и телефон уникальны (BR-2.2):
    --    строки с совпавшим логином или телефоном пропускаются и
    --    довставляются заново. Пароль — md5 (BR-2.3).
    -- -----------------------------------------------------------------------
    v_try := 0;
    WHILE cardinality(v_client) < value LOOP
        v_try := v_try + 1;
        IF v_try > 1000 THEN
            RAISE EXCEPTION 'insert_test_data: не удалось подобрать % уникальных логинов и телефонов',
                value - cardinality(v_client);
        END IF;

        WITH ins AS (
            INSERT INTO client (client_id, login, password, phone_number)
            SELECT exts.uuid_generate_v4(),
                   (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                      FROM generate_series(1, c.len)),
                   md5(random()::text),
                   '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0')
              FROM (SELECT 1 + floor(random() * 50)::int AS LEN
                      FROM generate_series(1, value - cardinality(v_client))) AS c
            ON CONFLICT DO NOTHING
            RETURNING client_id
        )
        SELECT v_client || coalesce(array_agg(client_id), '{}')
          INTO v_client
          FROM ins;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 6. Адреса клиентов (BR-2.4, BR-2.5): у клиента i четыре своих адреса
    --    v_addr[value + i + value * k], k = 0..3; около 20% клиентов
    --    дополнительно пользуются первым адресом соседа (клиента i % value + 1),
    --    который у клиента i ещё не привязан. Дубли пары исключает PK.
    -- -----------------------------------------------------------------------
    INSERT INTO client_address (client_id, address_id)
    SELECT v_client[1 + (g.i - 1) % value], v_addr[value + g.i]
      FROM generate_series(1, value * 4) AS g(i);

    SELECT array_agg(value > 1 AND random() < 0.2 ORDER BY g.i)
      INTO v_extra
      FROM generate_series(1, value) AS g(i);

    INSERT INTO client_address (client_id, address_id)
    SELECT v_client[g.i], v_addr[value + 1 + g.i % value]
      FROM generate_series(1, value) AS g(i)
     WHERE v_extra[g.i];

    -- -----------------------------------------------------------------------
    -- 7. Блюда (value * 5): блюдо j принадлежит ресторану ((j - 1) % value) + 1,
    --    так у каждого ресторана ровно 5 блюд: j = r + value * k, k = 0..4.
    --    Цена 100..1500 (BR-5.3), не нулевая — на ней держится добавка до
    --    минимальной суммы заказа (раздел 8). Блюдо k = 0 всегда доступно —
    --    с него начинается незавершённый заказ.
    --    Название блюда k — 20k + 1 .. 20k + 20 букв: у пяти блюд ресторана
    --    разная длина названия, значит, и названия разные, а вместе длины
    --    покрывают весь диапазон 1..100. Описание — 1..200 букв.
    -- -----------------------------------------------------------------------
    SELECT array_agg(p.id ORDER BY p.j),
           array_agg(p.price ORDER BY p.j),
           array_agg(p.status ORDER BY p.j)
      INTO v_prod, v_price, v_prod_status
      FROM (SELECT g.j,
                   exts.uuid_generate_v4() AS id,
                   ((10 + floor(random() * 141)) * 10)::int AS price,
                   CASE WHEN g.j <= value OR random() < 0.8 THEN 'доступно'::product_status
                        ELSE v_prod_st[1 + floor(random() * cardinality(v_prod_st))::int]
                   END AS status
              FROM generate_series(1, value * 5) AS g(j)) AS p;

    INSERT INTO product (product_id, product_name, product_category_id, price,
                         restaurant_id, photo_url, rating, status, description)
    SELECT v_prod[p.j],
           (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
              FROM generate_series(1, p.len_name)),
           v_cat[1 + floor(random() * value)::int],
           v_price[p.j],
           v_rest[1 + (p.j - 1) % value],
           CASE WHEN random() < 0.3 THEN NULL
                ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg'
           END,
           NULL,
           v_prod_status[p.j],
           (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
              FROM generate_series(1, p.len_description))
      FROM (SELECT g.j,
                   1 + ((g.j - 1) / value) * 20 + floor(random() * 20)::int AS len_name,
                   1 + floor(random() * 200)::int AS len_description
              FROM generate_series(1, value * 5) AS g(j)) AS p;

    -- -----------------------------------------------------------------------
    -- 8. Заказы (value * 5) с составом, оплатой и отзывами — пакетами по
    --    c_chunk заказов. Номер заказа i; заказы с i % 5 in (1, 2) — всегда
    --    доставлены (40% каждого пакета), чтобы отзывов хватило (8.3).
    -- -----------------------------------------------------------------------
    FOR v_from IN 1 .. value * 5 BY c_chunk LOOP

        -- 8.1. Заказы и состав одним оператором.
        --   base_orders  — клиент, курьер, статус: у уволенного курьера заказы только
        --          завершённые;
        --   order_parameters — ресторан (для незавершённых — только активный), номер
        --          адреса клиента (BR-7.4: k = 0..3 — свои, 4 — соседский),
        --          время заказа в периоде работы курьера (незавершённые —
        --          за последние 2 часа), параметры состава;
        --   order_items — 1..3 разных блюда ресторана заказа (BR-7.3, BR-7.16):
        --          позиция t берёт блюдо k = (first_offset + t * step) % 5; step = 1..4
        --          взаимно прост с 5, поэтому k не повторяются — без
        --          перемешивания и без запросов к таблицам. У незавершённого
        --          заказа first_offset = 0 (первое блюдо — всегда доступное k = 0),
        --          недоступные блюда в него не попадают;
        --   order_amounts — сумма Σ(цена × количество) и цена первого блюда.
        --          Общая сумма не меньше 1000 (BR-1.8): при сумме блюд
        --          от 1000 общая сумма = сумма + 10% ≥ 1100. Недостающее
        --          добирается количеством первого блюда по замкнутой формуле
        --          ceil((1000 - сумма) / цена), без цикла. Цена блюда
        --          генератора не меньше 100; при нулевой цене nullif даёт
        --          NULL, добавка 0, и заказ отклонит CHECK order_total_min_chk,
        --          а не бесконечный цикл.
        --   order_amount = Σ по составу с учётом добавки (BR-7.10).
        --   Начальный статус оплаты — ожидание; триггер payment_pay_status
        --   обновит его после добавления сгенерированной попытки оплаты.
        WITH base_orders AS MATERIALIZED (
            SELECT c.i, c.client_index, c.courier_index,
                   exts.uuid_generate_v4() AS order_id,
                   CASE
                       WHEN c.i % 5 IN (1, 2) THEN 'доставлен'::order_status
                       WHEN v_cour_fired[c.courier_index] THEN
                           CASE WHEN random() < 0.85 THEN 'доставлен'::order_status
                                ELSE v_order_done[1 + floor(random() * cardinality(v_order_done))::int]
                           END
                       WHEN random() < 0.6 THEN 'доставлен'::order_status
                       ELSE v_order_all[1 + floor(random() * cardinality(v_order_all))::int]
                   END AS status
              FROM (SELECT g.i,
                           1 + floor(random() * value)::int AS client_index,
                           1 + floor(random() * value)::int AS courier_index
                      FROM generate_series(v_from, least(v_from + c_chunk - 1, value * 5)) AS g(i)) AS c
        ),
        order_parameters AS MATERIALIZED (
            SELECT o.*,
                   o.status < 'доставлен' AS is_open,
                   CASE WHEN o.status < 'доставлен'
                        THEN v_rest_act[1 + floor(random() * cardinality(v_rest_act))::int]
                        ELSE 1 + floor(random() * value)::int
                   END AS restaurant_index,
                   floor(random() * (4 + v_extra[o.client_index]::int))::int AS addr_i,
                   1 + floor(random() * 3)::int AS n_items,
                   CASE WHEN o.status < 'доставлен' THEN 0 ELSE floor(random() * 5)::int END AS first_offset,
                   1 + floor(random() * 4)::int AS step,
                   date_trunc('second',
                       CASE WHEN o.status < 'доставлен'
                            THEN greatest(v_cour_start[o.courier_index],
                                          LOCALTIMESTAMP - random() * interval '2 hours')
                            ELSE v_cour_start[o.courier_index]
                                 + random() * (v_cour_end[o.courier_index] - v_cour_start[o.courier_index])
                       END) AS order_ts,
                   1 + floor(random() * 200)::int AS len_description
              FROM base_orders AS o
        ),
        order_items AS MATERIALIZED (
            SELECT o.order_id, o.restaurant_index, position.item_index,
                   o.restaurant_index + value * ((o.first_offset + position.item_index * o.step) % 5) AS product_index,
                   1 + floor(random() * 3)::int AS qty
              FROM order_parameters AS o
             CROSS JOIN generate_series(0, 2) AS position(item_index)
             WHERE position.item_index < o.n_items
               AND (position.item_index = 0
                    OR NOT o.is_open
                    OR v_prod_status[o.restaurant_index + value * ((o.first_offset + position.item_index * o.step) % 5)] = 'доступно')
        ),
        order_amounts AS MATERIALIZED (
            SELECT s.order_id, s.first_price,
                   greatest(0, ceil((1000 - s.amount) / nullif(s.first_price, 0)))::int AS add_qty,
                   s.amount
              FROM (SELECT i.order_id,
                           sum(v_price[i.product_index] * i.qty)::numeric        AS amount,
                           min(v_price[i.product_index]) filter (WHERE i.item_index = 0)  AS first_price
                      FROM order_items AS i
                     GROUP BY i.order_id) AS s
        ),
        ins_order AS (
            INSERT INTO "order" (order_id, courier_id, client_id, address_id, restaurant_id,
                                 order_timestamp, delivery_timestamp, order_amount,
                                 status, pay_status, description)
            SELECT o.order_id,
                   v_cour[o.courier_index],
                   v_client[o.client_index],
                   CASE WHEN o.addr_i = 4 THEN v_addr[value + 1 + o.client_index % value]
                        ELSE v_addr[value + o.client_index + value * o.addr_i]
                   END,
                   v_rest[o.restaurant_index],
                   o.order_ts,
                   -- время доставки только у доставленных (BR-7.12), не раньше создания (BR-7.13)
                   CASE WHEN o.status = 'доставлен'
                        THEN least(o.order_ts + (20 + floor(random() * 100))::int * interval '1 minute',
                                   date_trunc('second', LOCALTIMESTAMP))
                   END,
                   a.amount + a.add_qty * a.first_price,
                   o.status,
                   'ожидает',
                   (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                      FROM generate_series(1, o.len_description))
              FROM order_parameters AS o
              JOIN order_amounts AS a ON a.order_id = o.order_id
            RETURNING order_id
        ),
        ins_structure AS (
            INSERT INTO order_structure (order_id, product_id, restaurant_id, quantity)
            SELECT i.order_id,
                   v_prod[i.product_index],
                   v_rest[i.restaurant_index],
                   i.qty + CASE WHEN i.item_index = 0 THEN a.add_qty ELSE 0 END
              FROM order_items AS i
              JOIN order_amounts AS a ON a.order_id = i.order_id
        )
        SELECT array_agg(order_id) INTO v_ord FROM ins_order;

        -- 8.2. Одна попытка на заказ (BR-11.7), сумма = total_amount (BR-8.4).
        --      Доставленные заказы оплачены; для остальных случайно выбираем
        --      любой статус попытки. Незавершённые и отменённые
        --      заказы могут ещё не иметь успешной оплаты. Агрегат заказа
        --      автоматически пересчитывает payment_pay_status (BR-8.7).
        --      Идентификатор транзакции — 64 hex-символа из двух md5; при
        --      совпадении с существующим попытка пропускается и довставляется.
        v_cnt := 0;
        v_try := 0;
        WHILE v_cnt < cardinality(v_ord) LOOP
            v_try := v_try + 1;
            IF v_try > 100 THEN
                RAISE EXCEPTION 'insert_test_data: не удалось подобрать уникальные идентификаторы транзакций';
            END IF;

            INSERT INTO payment (payment_id, order_id, payment_type, amount, transaction_ref,
                                 transaction_timestamp, status)
            SELECT exts.uuid_generate_v4(),
                   o.order_id,
                   v_pay_types[1 + floor(random() * cardinality(v_pay_types))::int],
                   o.total_amount,
                   md5(random()::text) || md5(random()::text),
                   least(o.order_timestamp + (1 + floor(random() * 10))::int * interval '1 minute',
                         date_trunc('second', LOCALTIMESTAMP)),
                   CASE WHEN o.status = 'доставлен' THEN 'успех'::payment_status
                        ELSE v_pay_statuses[1 + floor(random() * cardinality(v_pay_statuses))::int]
                   END
              FROM unnest(v_ord) AS u(order_id)
              JOIN "order" AS o ON o.order_id = u.order_id
             WHERE v_try = 1
                OR NOT EXISTS (SELECT 1 FROM payment p WHERE p.order_id = o.order_id)
            ON CONFLICT (transaction_ref) DO NOTHING;

            GET DIAGNOSTICS v_added = ROW_COUNT;
            v_cnt := v_cnt + v_added;
        END LOOP;

        -- 8.3. Отзывы — только на доставленные заказы, столько же, сколько
        --      заказов в пакете (value * 5 в сумме). Кандидаты: сам заказ,
        --      ресторан заказа и каждое блюдо состава (BR-9.1, BR-9.2), не
        --      больше одного отзыва на объект в заказе (BR-9.5). Сначала
        --      каждый доставленный заказ получает отзыв случайного типа
        --      (enum_range), затем недостающее количество добирается вторыми
        --      отзывами на другие объекты тех же заказов. Доставлено не
        --      меньше 40% пакета, у каждого не меньше трёх объектов, поэтому
        --      кандидатов всегда больше, чем нужно отзывов.
        INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, photo_url, rating)
        SELECT exts.uuid_generate_v4(),
               c.client_id,
               least(c.delivery_timestamp + (1 + floor(random() * 48))::int * interval '1 hour',
                     date_trunc('second', LOCALTIMESTAMP)),
               c.entity_id,
               c.entity_type,
               c.order_id,
               (SELECT string_agg(chr(1072 + floor(random() * 32)::int), '')
                  FROM generate_series(1, c.len_description)),
               CASE WHEN random() < 0.5 THEN NULL
                    ELSE 'https://cdn.foodexpress.ru/review/' || md5(random()::text) || '.jpg'
               END,
               1 + floor(random() * 5)::int
          FROM (SELECT x.*,
                       row_number() OVER (PARTITION BY x.order_id
                                          ORDER BY x.entity_type <> x.first_type, x.rnd) AS rn,
                       1 + floor(random() * 200)::int AS len_description
                  FROM (SELECT o.order_id, o.client_id, o.delivery_timestamp, o.first_type,
                               e.entity_type, e.entity_id, random() AS rnd
                          FROM (SELECT oo.*,
                                       v_rev_types[1 + floor(random() * cardinality(v_rev_types))::int]
                                           AS first_type
                                  FROM unnest(v_ord) AS u(order_id)
                                  JOIN "order" AS oo ON oo.order_id = u.order_id
                                 WHERE oo.status = 'доставлен') AS o
                         CROSS JOIN LATERAL (
                                   SELECT 'заказ'::review_entity_type, o.order_id
                                   UNION ALL
                                   SELECT 'ресторан'::review_entity_type, o.restaurant_id
                                   UNION ALL
                                   SELECT 'блюдо'::review_entity_type, os.product_id
                                     FROM order_structure AS os
                                    WHERE os.order_id = o.order_id
                               ) AS e(entity_type, entity_id)
                       ) AS x
               ) AS c
         ORDER BY c.rn, c.rnd
         LIMIT cardinality(v_ord);

        GET DIAGNOSTICS v_added = ROW_COUNT;
        IF v_added <> cardinality(v_ord) THEN
            RAISE EXCEPTION 'insert_test_data: отзывов % вместо %', v_added, cardinality(v_ord);
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 9. Рейтинги блюд и ресторанов этой порции = среднее по отзывам,
    --    NULL если отзывов нет (BR-9.6, BR-9.7). Считаются здесь одним
    --    UPDATE на таблицу, а не триггером rating_change на каждый отзыв.
    --    Отзывы порции ссылаются только на блюда и рестораны порции, у
    --    которых до этого рейтинга не было, — блюда без отзывов остаются NULL.
    --    Флаг пропуска снимается, чтобы дальнейшие изменения отзывов в этой
    --    же транзакции снова пересчитывали рейтинг.
    -- -----------------------------------------------------------------------
    PERFORM set_config('kalugin_food.skip_rating', 'off', TRUE);

    UPDATE product p
       SET rating = r.avg_rating
      FROM (SELECT rv.entity_id, round(avg(rv.rating), 2) AS avg_rating
              FROM review rv
              JOIN unnest(v_prod) AS u(product_id) ON u.product_id = rv.entity_id
             WHERE rv.entity_type = 'блюдо'
             GROUP BY rv.entity_id) AS r
     WHERE p.product_id = r.entity_id;

    UPDATE restaurant rs
       SET rating = r.avg_rating
      FROM (SELECT rv.entity_id, round(avg(rv.rating), 2) AS avg_rating
              FROM review rv
              JOIN unnest(v_rest) AS u(restaurant_id) ON u.restaurant_id = rv.entity_id
             WHERE rv.entity_type = 'ресторан'
             GROUP BY rv.entity_id) AS r
     WHERE rs.restaurant_id = r.entity_id;

    -- -----------------------------------------------------------------------
    -- 10. Выплаты курьерам за последние 6 месяцев (BR-10.2, BR-10.7) —
    --     по каждому курьеру порции и каждому месяцу, даже без доставок.
    --     cnt и comm — число и сумма комиссий доставленных заказов курьера
    --     за месяц (по дате заказа). Коэффициент месяца: в первом месяце
    --     начальный 0.1 (BR-6.5), дальше — по числу доставок предыдущего
    --     месяца (lag). Выплата = коэффициент месяца × сумма комиссий.
    --     courier.coefficient — коэффициент на следующий месяц по доставкам
    --     текущего; уволенным он не назначается (BR-10.6), у них остаётся
    --     коэффициент текущего месяца.
    -- -----------------------------------------------------------------------
    WITH delivered AS (
        SELECT o.courier_id,
               date_trunc('month', o.order_timestamp) AS mon,
               count(*)          AS cnt,
               sum(o.commission) AS comm
          FROM unnest(v_cour) AS u(courier_id)
          JOIN "order" AS o ON o.courier_id = u.courier_id
         WHERE o.status = 'доставлен'
         GROUP BY o.courier_id, date_trunc('month', o.order_timestamp)
    ),
    grid AS (
        SELECT u.courier_id, u.fired, m.mon,
               coalesce(d.cnt, 0)  AS cnt,
               coalesce(d.comm, 0) AS comm,
               lag(coalesce(d.cnt, 0)) OVER (PARTITION BY u.courier_id ORDER BY m.mon) AS prev_cnt
          FROM unnest(v_cour, v_cour_fired) AS u(courier_id, fired)
         CROSS JOIN generate_series(v_pay_start::timestamp,
                                    date_trunc('month', CURRENT_DATE),
                                    interval '1 month') AS m(mon)
          LEFT JOIN delivered AS d ON d.courier_id = u.courier_id AND d.mon = m.mon
    ),
    pay AS (
        SELECT g.*,
               CASE
                   WHEN g.prev_cnt IS NULL THEN 0.1
                   WHEN g.prev_cnt > 500 THEN 0.5
                   WHEN g.prev_cnt > 250 THEN 0.3
                   WHEN g.prev_cnt > 150 THEN 0.2
                   ELSE 0.1
               END AS coef_used,
               CASE
                   WHEN g.cnt > 500 THEN 0.5
                   WHEN g.cnt > 250 THEN 0.3
                   WHEN g.cnt > 150 THEN 0.2
                   ELSE 0.1
               END AS coef_next
          FROM grid AS g
    ),
    ins_pay AS (
        INSERT INTO courier_pay (YEAR, MONTH, courier_id, amount, coefficient_used)
        SELECT extract(YEAR FROM p.mon)::int,
               extract(MONTH FROM p.mon)::int,
               p.courier_id,
               round(p.coef_used * p.comm, 2),
               p.coef_used
          FROM pay AS p
    )
    UPDATE courier c
       SET coefficient = CASE WHEN p.fired THEN p.coef_used ELSE p.coef_next END
      FROM pay AS p
     WHERE p.mon = date_trunc('month', CURRENT_DATE)
       AND c.courier_id = p.courier_id;
END;
$$;
