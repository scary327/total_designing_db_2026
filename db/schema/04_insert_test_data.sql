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
-- и payment_pay_status (order.pay_status по BR-8.7). Рейтинг пересчитывается
-- построчным триггером rating_change; отдельного режима генерации у него нет.

set search_path to kalugin_food;

create or replace procedure insert_test_data(value integer)
set search_path = kalugin_food, exts
as $$
declare
    -- заказов в одном пакете; кратно 5, см. раздел 8
    c_chunk       constant integer = 50000;

    v_category_ids         uuid[] = '{}';
    v_client_ids      uuid[] = '{}';
    v_courier_ids        uuid[];
    v_courier_start  timestamp[];
    v_courier_end    timestamp[];
    v_courier_fired  boolean[];
    v_address_ids        uuid[];
    v_has_shared_address       boolean[];       -- у клиента i есть ещё и адрес соседа
    v_restaurant_ids        uuid[];
    v_restaurant_statuses restaurant_status[];
    v_active_restaurant_indexes    integer[];       -- номера активных ресторанов
    v_product_ids        uuid[];
    v_product_prices       integer[];
    v_product_statuses product_status[];
    v_order_ids         uuid[];          -- заказы текущего пакета

    v_active_st   courier_status[] = array_remove(enum_range(null::courier_status), 'уволен');
    v_rest_st     restaurant_status[] = enum_range(null::restaurant_status);
    v_prod_st     product_status[] = enum_range(null::product_status);
    v_order_all   order_status[] = enum_range(null::order_status);
    -- завершённые: доставлен .. отменён (порядок enum)
    v_order_done  order_status[] = enum_range('доставлен'::order_status, null::order_status);
    v_pay_types   payment_type[] = enum_range(null::payment_type);
    v_pay_statuses payment_status[] = enum_range(null::payment_status);
    v_rev_types   review_entity_type[] = enum_range(null::review_entity_type);

    -- месяцы выплат: текущий и пять предыдущих (BR-10.7)
    v_pay_start   date = (date_trunc('month', current_date) - interval '5 months')::date;
    -- даты данных: последние 180 дней, но не раньше первого месяца выплат,
    -- чтобы у каждого доставленного заказа был месяц в courier_pay
    v_window_start date = greatest(v_pay_start, current_date - 180);

    v_from        integer;
    v_cnt         integer;
    v_added       integer;
    v_try         integer;
begin
    if value is null or value < 1 then
        raise exception 'insert_test_data: value должно быть положительным, передано %', value;
    end if;

    -- -----------------------------------------------------------------------
    -- 1. Категории блюд (value). Название уникально (BR-5.7): совпавшие
    --    с уже существующими пропускаются и довставляются новыми.
    -- -----------------------------------------------------------------------
    v_try = 0;
    while cardinality(v_category_ids) < value loop
        v_try = v_try + 1;
        if v_try > 1000 then
            raise exception 'insert_test_data: не удалось подобрать % уникальных названий категорий',
                value - cardinality(v_category_ids);
        end if;

        with ins as (
            insert into product_category (product_category_id, product_category_name)
            select exts.uuid_generate_v4(),
                   (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                      from generate_series(1, g.len))
              from (select 1 + floor(random() * 100)::int as len
                      from generate_series(1, value - cardinality(v_category_ids))) as g
            on conflict (product_category_name) do nothing
            returning product_category_id
        )
        select v_category_ids || coalesce(array_agg(product_category_id), '{}')
          into v_category_ids
          from ins;
    end loop;

    -- -----------------------------------------------------------------------
    -- 2. Курьеры (value). Фамилия, имя и отчество генерируются отдельно,
    --    каждое — случайное слово от 1 до 50 букв с заглавной. Все даты — внутри окна v_window_start .. сегодня:
    --    не старше 180 дней и не раньше 1-го числа месяца пять месяцев назад.
    --    Выплаты генерируются за все месяцы этого окна, поэтому каждый
    --    доставленный заказ попадает в месяц, по которому есть запись courier_pay.
    --    Первый курьер всегда работает и нанят в начале окна (BR-6.6).
    --    Около 20% остальных — уволены, с датой увольнения не раньше даты
    --    найма (BR-6.3). Период работы курьера (найм .. увольнение или
    --    сейчас) запоминается в массивах — в нём лежат его заказы.
    -- -----------------------------------------------------------------------
    with ins as (
        insert into courier (courier_id, last_name, first_name, middle_name, phone_number, status,
                             hire_date, dismissal_date, coefficient)
        select exts.uuid_generate_v4(),
               -- заглавная А..Я и строчные буквы; initcap не годится: при
               -- локали C он не меняет регистр кириллицы
               chr(1040 + floor(random() * 32)::int)
                   || coalesce((select string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  from generate_series(2, c.last_name_length)), '')
               , chr(1040 + floor(random() * 32)::int)
                   || coalesce((select string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  from generate_series(2, c.first_name_length)), '')
               , chr(1040 + floor(random() * 32)::int)
                   || coalesce((select string_agg(chr(1072 + floor(random() * 32)::int), '')
                                  from generate_series(2, c.middle_name_length)), ''),
               '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
               case when c.fired then 'уволен'::courier_status
                    else v_active_st[1 + floor(random() * cardinality(v_active_st))::int]
               end,
               c.hire,
               case when c.fired
                    then c.hire + floor(random() * (current_date - c.hire + 1))::int
               end,
               0.1
          from (select case when g.i = 1 then v_window_start
                            else v_window_start
                                 + floor(random() * (current_date - v_window_start + 1))::int
                       end                               as hire,
                       g.i > 1 and random() < 0.2        as fired,
                       1 + floor(random() * 50)::int     as last_name_length,
                       1 + floor(random() * 50)::int     as first_name_length,
                       1 + floor(random() * 50)::int     as middle_name_length
                  from generate_series(1, value) as g(i)) as c
        returning courier_id, hire_date, dismissal_date
    )
    select array_agg(courier_id),
           array_agg(hire_date::timestamp),
           array_agg(case
                         when dismissal_date is null then localtimestamp
                         else least(dismissal_date + interval '23 hours 59 minutes', localtimestamp)
                     end),
           array_agg(dismissal_date is not null)
      into v_courier_ids, v_courier_start, v_courier_end, v_courier_fired
      from ins;

    -- -----------------------------------------------------------------------
    -- 3. Адреса (value * 5): первые value — под рестораны, остальные — клиентам.
    --    Улица — 1..150 букв; дом — 1..10 символов: номер и буквы (обрезаются
    --    по длине, поэтому дом всегда начинается с цифры); квартира/офис
    --    необязательна (BR-3.2), иначе 1..10 символов так же, как дом.
    -- -----------------------------------------------------------------------
    with ins as (
        insert into address (address_id, street, house_number, apartment_office)
        select exts.uuid_generate_v4(),
               (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                  from generate_series(1, a.len_street)),
               left((1 + floor(random() * 300))::int::text
                    || (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                          from generate_series(1, a.len_house)),
                    a.len_house),
               case when not a.no_apartment then
                   left((1 + floor(random() * 500))::int::text
                        || (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                              from generate_series(1, a.len_apartment)),
                        a.len_apartment)
               end
          from (select 1 + floor(random() * 150)::int as len_street,
                       1 + floor(random() * 10)::int  as len_house,
                       random() < 0.3                 as no_apartment,
                       1 + floor(random() * 10)::int  as len_apartment
                  from generate_series(1, value * 5)) as a
        returning address_id
    )
    select array_agg(address_id) into v_address_ids from ins;

    -- -----------------------------------------------------------------------
    -- 4. Рестораны (value): у ресторана i адрес v_address_ids[i] (BR-3.3).
    --    Первый ресторан всегда активен — на активные рестораны оформляются
    --    незавершённые заказы. Время закрытия позже открытия (BR-4.4):
    --    открытие 06:00..11:59, работа 8..12 часов, закрытие не позже 23:59.
    --    Название — 1..100 букв, описание — 1..200. ИНН, ОГРН и счёт —
    --    отдельные цифровые строки; реквизиты синтетические, без проверки
    --    контрольных сумм.
    -- -----------------------------------------------------------------------
    select array_agg(r.id order by r.i),
           array_agg(r.status order by r.i),
           array_agg(r.i order by r.i) filter (where r.status = 'активен')
      into v_restaurant_ids, v_restaurant_statuses, v_active_restaurant_indexes
      from (select g.i,
                   exts.uuid_generate_v4() as id,
                   case when g.i = 1 or random() < 0.8 then 'активен'::restaurant_status
                        else v_rest_st[1 + floor(random() * cardinality(v_rest_st))::int]
                   end as status
              from generate_series(1, value) as g(i)) as r;

    insert into restaurant (restaurant_id, restaurant_name, address_id, description,
                            work_start, work_end, inn, ogrn, bank_account, rating, status)
    select v_restaurant_ids[r.i],
           (select string_agg(chr(1072 + floor(random() * 32)::int), '')
              from generate_series(1, r.len_name)),
           v_address_ids[r.i],
           (select string_agg(chr(1072 + floor(random() * 32)::int), '')
              from generate_series(1, r.len_description)),
           r.work_start,
           r.work_start + (8 + floor(random() * 5))::int * interval '1 hour',
           lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
           lpad(floor(random() * 10000000000000)::bigint::text, 13, '0'),
           lpad(floor(random() * 10000000000)::bigint::text, 10, '0')
               || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
           null,
           v_restaurant_statuses[r.i]
      from (select g.i,
                   time '06:00' + floor(random() * 360)::int * interval '1 minute' as work_start,
                   1 + floor(random() * 100)::int as len_name,
                   1 + floor(random() * 200)::int as len_description
              from generate_series(1, value) as g(i)) as r;

    -- -----------------------------------------------------------------------
    -- 5. Клиенты (value). Логин (1..50 букв) и телефон уникальны (BR-2.2):
    --    строки с совпавшим логином или телефоном пропускаются и
    --    довставляются заново. Пароль — md5 (BR-2.3).
    -- -----------------------------------------------------------------------
    v_try = 0;
    while cardinality(v_client_ids) < value loop
        v_try = v_try + 1;
        if v_try > 1000 then
            raise exception 'insert_test_data: не удалось подобрать % уникальных логинов и телефонов',
                value - cardinality(v_client_ids);
        end if;

        with ins as (
            insert into client (client_id, login, password, phone_number)
            select exts.uuid_generate_v4(),
                   (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                      from generate_series(1, c.len)),
                   md5(random()::text),
                   '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0')
              from (select 1 + floor(random() * 50)::int as len
                      from generate_series(1, value - cardinality(v_client_ids))) as c
            on conflict do nothing
            returning client_id
        )
        select v_client_ids || coalesce(array_agg(client_id), '{}')
          into v_client_ids
          from ins;
    end loop;

    -- -----------------------------------------------------------------------
    -- 6. Адреса клиентов (BR-2.4, BR-2.5): у клиента i четыре своих адреса
    --    v_address_ids[value + i + value * k], k = 0..3; около 20% клиентов
    --    дополнительно пользуются первым адресом соседа (клиента i % value + 1),
    --    который у клиента i ещё не привязан. Дубли пары исключает PK.
    -- -----------------------------------------------------------------------
    insert into client_address (client_id, address_id)
    select v_client_ids[1 + (g.i - 1) % value], v_address_ids[value + g.i]
      from generate_series(1, value * 4) as g(i);

    select array_agg(value > 1 and random() < 0.2 order by g.i)
      into v_has_shared_address
      from generate_series(1, value) as g(i);

    insert into client_address (client_id, address_id)
    select v_client_ids[g.i], v_address_ids[value + 1 + g.i % value]
      from generate_series(1, value) as g(i)
     where v_has_shared_address[g.i];

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
    select array_agg(p.id order by p.j),
           array_agg(p.price order by p.j),
           array_agg(p.status order by p.j)
      into v_product_ids, v_product_prices, v_product_statuses
      from (select g.j,
                   exts.uuid_generate_v4() as id,
                   ((10 + floor(random() * 141)) * 10)::int as price,
                   case when g.j <= value or random() < 0.8 then 'доступно'::product_status
                        else v_prod_st[1 + floor(random() * cardinality(v_prod_st))::int]
                   end as status
              from generate_series(1, value * 5) as g(j)) as p;

    insert into product (product_id, product_name, product_category_id, price,
                         restaurant_id, photo_url, rating, status, description)
    select v_product_ids[p.j],
           (select string_agg(chr(1072 + floor(random() * 32)::int), '')
              from generate_series(1, p.len_name)),
           v_category_ids[1 + floor(random() * value)::int],
           v_product_prices[p.j],
           v_restaurant_ids[1 + (p.j - 1) % value],
           case when random() < 0.3 then null
                else 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg'
           end,
           null,
           v_product_statuses[p.j],
           (select string_agg(chr(1072 + floor(random() * 32)::int), '')
              from generate_series(1, p.len_description))
      from (select g.j,
                   1 + ((g.j - 1) / value) * 20 + floor(random() * 20)::int as len_name,
                   1 + floor(random() * 200)::int as len_description
              from generate_series(1, value * 5) as g(j)) as p;

    -- -----------------------------------------------------------------------
    -- 8. Заказы (value * 5) с составом, оплатой и отзывами — пакетами по
    --    c_chunk заказов. Номер заказа i; заказы с i % 5 in (1, 2) — всегда
    --    доставлены (40% каждого пакета), чтобы отзывов хватило (8.3).
    -- -----------------------------------------------------------------------
    for v_from in 1 .. value * 5 by c_chunk loop

        -- 8.1. Заказы и состав одним оператором.
        --   base_orders  — клиент, курьер, статус: у уволенного курьера заказы только
        --          завершённые;
        --   order_parameters — ресторан (для незавершённых — только активный), номер
        --          адреса клиента (BR-7.4: k = 0..3 — свои, 4 — соседский),
        --          время заказа в периоде работы курьера (незавершённые —
        --          за последние 2 часа), параметры состава;
        --   order_items — 1..3 разных блюда ресторана заказа (BR-7.3, BR-7.16):
        --          позиция t берёт блюдо k = (first_offset + t * product_step) % 5; product_step = 1..4
        --          взаимно прост с 5, поэтому k не повторяются — без
        --          перемешивания и без запросов к таблицам. У незавершённого
        --          заказа first_offset = 0 (первое блюдо — всегда доступное k = 0),
        --          недоступные блюда в него не попадают;
        --   calculated_amounts — сумма Σ(цена × количество) и цена первого блюда.
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
        with base_orders as materialized (
            select c.i, c.client_index, c.courier_index,
                   exts.uuid_generate_v4() as order_id,
                   case
                       when c.i % 5 in (1, 2) then 'доставлен'::order_status
                       when v_courier_fired[c.courier_index] then
                           case when random() < 0.85 then 'доставлен'::order_status
                                else v_order_done[1 + floor(random() * cardinality(v_order_done))::int]
                           end
                       when random() < 0.6 then 'доставлен'::order_status
                       else v_order_all[1 + floor(random() * cardinality(v_order_all))::int]
                   end as status
              from (select g.i,
                           1 + floor(random() * value)::int as client_index,
                           1 + floor(random() * value)::int as courier_index
                      from generate_series(v_from, least(v_from + c_chunk - 1, value * 5)) as g(i)) as c
        ),
        order_parameters as materialized (
            select o.*,
                   o.status < 'доставлен' as is_open,
                   case when o.status < 'доставлен'
                        then v_active_restaurant_indexes[1 + floor(random() * cardinality(v_active_restaurant_indexes))::int]
                        else 1 + floor(random() * value)::int
                   end as restaurant_index,
                   floor(random() * (4 + v_has_shared_address[o.client_index]::int))::int as address_offset,
                   1 + floor(random() * 3)::int as item_count,
                   case when o.status < 'доставлен' then 0 else floor(random() * 5)::int end as first_offset,
                   1 + floor(random() * 4)::int as product_step,
                   date_trunc('second',
                       case when o.status < 'доставлен'
                            then greatest(v_courier_start[o.courier_index],
                                          localtimestamp - random() * interval '2 hours')
                            else v_courier_start[o.courier_index]
                                 + random() * (v_courier_end[o.courier_index] - v_courier_start[o.courier_index])
                       end) as order_ts,
                   1 + floor(random() * 200)::int as len_description
              from base_orders as o
        ),
        order_items as materialized (
            select o.order_id, o.restaurant_index, position.item_index,
                   o.restaurant_index + value * ((o.first_offset + position.item_index * o.product_step) % 5) as product_index,
                   1 + floor(random() * 3)::int as quantity
              from order_parameters as o
             cross join generate_series(0, 2) as position(item_index)
             where position.item_index < o.item_count
               and (position.item_index = 0
                    or not o.is_open
                    or v_product_statuses[o.restaurant_index + value * ((o.first_offset + position.item_index * o.product_step) % 5)] = 'доступно')
        ),
        calculated_amounts as materialized (
            select s.order_id, s.first_price,
                   greatest(0, ceil((1000 - s.amount) / nullif(s.first_price, 0)))::int as add_qty,
                   s.amount
              from (select i.order_id,
                           sum(v_product_prices[i.product_index] * i.quantity)::numeric        as amount,
                           min(v_product_prices[i.product_index]) filter (where i.item_index = 0)  as first_price
                      from order_items as i
                     group by i.order_id) as s
        ),
        created_orders as (
            insert into "order" (order_id, courier_id, client_id, address_id, restaurant_id,
                                 order_timestamp, delivery_timestamp, order_amount,
                                 status, pay_status, description)
            select o.order_id,
                   v_courier_ids[o.courier_index],
                   v_client_ids[o.client_index],
                   case when o.address_offset = 4 then v_address_ids[value + 1 + o.client_index % value]
                        else v_address_ids[value + o.client_index + value * o.address_offset]
                   end,
                   v_restaurant_ids[o.restaurant_index],
                   o.order_ts,
                   -- время доставки только у доставленных (BR-7.12), не раньше создания (BR-7.13)
                   case when o.status = 'доставлен'
                        then least(o.order_ts + (20 + floor(random() * 100))::int * interval '1 minute',
                                   date_trunc('second', localtimestamp))
                   end,
                   a.amount + a.add_qty * a.first_price,
                   o.status,
                   'ожидает',
                   (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                      from generate_series(1, o.len_description))
              from order_parameters as o
              join calculated_amounts as a on a.order_id = o.order_id
            returning order_id
        ),
        created_items as (
            insert into order_structure (order_id, product_id, quantity)
            select i.order_id,
                   v_product_ids[i.product_index],
                   i.quantity + case when i.item_index = 0 then a.add_qty else 0 end
              from order_items as i
              join created_orders as created on created.order_id = i.order_id
              join calculated_amounts as a on a.order_id = i.order_id
        )
        select array_agg(order_id) into v_order_ids from created_orders;

        -- 8.2. Одна попытка на заказ (BR-11.7), сумма = total_amount (BR-8.4).
        --      Доставленные заказы оплачены; для остальных случайно выбираем
        --      любой статус попытки. Незавершённые и отменённые
        --      заказы могут ещё не иметь успешной оплаты. Агрегат заказа
        --      автоматически пересчитывает payment_pay_status (BR-8.7).
        --      Идентификатор транзакции — 64 hex-символа из двух md5; при
        --      совпадении с существующим попытка пропускается и довставляется.
        v_cnt = 0;
        v_try = 0;
        while v_cnt < cardinality(v_order_ids) loop
            v_try = v_try + 1;
            if v_try > 100 then
                raise exception 'insert_test_data: не удалось подобрать уникальные идентификаторы транзакций';
            end if;

            insert into payment (payment_id, order_id, payment_type, amount, transaction_ref,
                                 transaction_timestamp, status)
            select exts.uuid_generate_v4(),
                   o.order_id,
                   v_pay_types[1 + floor(random() * cardinality(v_pay_types))::int],
                   o.total_amount,
                   md5(random()::text) || md5(random()::text),
                   least(o.order_timestamp + (1 + floor(random() * 10))::int * interval '1 minute',
                         date_trunc('second', localtimestamp)),
                   case when o.status = 'доставлен' then 'успех'::payment_status
                        else v_pay_statuses[1 + floor(random() * cardinality(v_pay_statuses))::int]
                   end
              from unnest(v_order_ids) as u(order_id)
              join "order" as o on o.order_id = u.order_id
             where v_try = 1
                or not exists (select 1 from payment p where p.order_id = o.order_id)
            on conflict (transaction_ref) do nothing;

            get diagnostics v_added = row_count;
            v_cnt = v_cnt + v_added;
        end loop;

        -- 8.3. Отзывы — только на доставленные заказы, столько же, сколько
        --      заказов в пакете (value * 5 в сумме). Кандидаты: сам заказ,
        --      ресторан заказа и каждое блюдо состава (BR-9.1, BR-9.2), не
        --      больше одного отзыва на объект в заказе (BR-9.5). Сначала
        --      каждый доставленный заказ получает отзыв случайного типа
        --      (enum_range), затем недостающее количество добирается вторыми
        --      отзывами на другие объекты тех же заказов. Доставлено не
        --      меньше 40% пакета, у каждого не меньше трёх объектов, поэтому
        --      кандидатов всегда больше, чем нужно отзывов.
        insert into review (review_id, client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, photo_url, rating)
        select exts.uuid_generate_v4(),
               c.client_id,
               least(c.delivery_timestamp + (1 + floor(random() * 48))::int * interval '1 hour',
                     date_trunc('second', localtimestamp)),
               c.entity_id,
               c.entity_type,
               c.order_id,
               (select string_agg(chr(1072 + floor(random() * 32)::int), '')
                  from generate_series(1, c.len_description)),
               case when random() < 0.5 then null
                    else 'https://cdn.foodexpress.ru/review/' || md5(random()::text) || '.jpg'
               end,
               1 + floor(random() * 5)::int
          from (select x.*,
                       row_number() over (partition by x.order_id
                                          order by x.entity_type <> x.first_type, x.rnd) as rn,
                       1 + floor(random() * 200)::int as len_description
                  from (select o.order_id, o.client_id, o.delivery_timestamp, o.first_type,
                               e.entity_type, e.entity_id, random() as rnd
                          from (select oo.*,
                                       v_rev_types[1 + floor(random() * cardinality(v_rev_types))::int]
                                           as first_type
                                  from unnest(v_order_ids) as u(order_id)
                                  join "order" as oo on oo.order_id = u.order_id
                                 where oo.status = 'доставлен') as o
                         cross join lateral (
                                   select 'заказ'::review_entity_type, o.order_id
                                   union all
                                   select 'ресторан'::review_entity_type, o.restaurant_id
                                   union all
                                   select 'блюдо'::review_entity_type, os.product_id
                                     from order_structure as os
                                    where os.order_id = o.order_id
                               ) as e(entity_type, entity_id)
                       ) as x
               ) as c
         order by c.rn, c.rnd
         limit cardinality(v_order_ids);

        get diagnostics v_added = row_count;
        if v_added <> cardinality(v_order_ids) then
            raise exception 'insert_test_data: отзывов % вместо %', v_added, cardinality(v_order_ids);
        end if;
    end loop;

    -- -----------------------------------------------------------------------
    -- 9. Выплаты курьерам за последние 6 месяцев (BR-10.2, BR-10.7) —
    --     по каждому курьеру порции и каждому месяцу, даже без доставок.
    --     cnt и comm — число и сумма комиссий доставленных заказов курьера
    --     за месяц (по дате заказа). Коэффициент месяца: в первом месяце
    --     начальный 0.1 (BR-6.5), дальше — по числу доставок предыдущего
    --     месяца (lag). Выплата = коэффициент месяца × сумма комиссий.
    --     courier.coefficient — коэффициент на следующий месяц по доставкам
    --     текущего; уволенным он не назначается (BR-10.6), у них остаётся
    --     коэффициент текущего месяца.
    -- -----------------------------------------------------------------------
    with delivered as (
        select o.courier_id,
               date_trunc('month', o.order_timestamp) as mon,
               count(*)          as cnt,
               sum(o.commission) as comm
          from unnest(v_courier_ids) as u(courier_id)
          join "order" as o on o.courier_id = u.courier_id
         where o.status = 'доставлен'
         group by o.courier_id, date_trunc('month', o.order_timestamp)
    ),
    grid as (
        select u.courier_id, u.fired, m.mon,
               coalesce(d.cnt, 0)  as cnt,
               coalesce(d.comm, 0) as comm,
               lag(coalesce(d.cnt, 0)) over (partition by u.courier_id order by m.mon) as prev_cnt
          from unnest(v_courier_ids, v_courier_fired) as u(courier_id, fired)
         cross join generate_series(v_pay_start::timestamp,
                                    date_trunc('month', current_date),
                                    interval '1 month') as m(mon)
          left join delivered as d on d.courier_id = u.courier_id and d.mon = m.mon
    ),
    pay as (
        select g.*,
               case
                   when g.prev_cnt is null then 0.1
                   when g.prev_cnt > 500 then 0.5
                   when g.prev_cnt > 250 then 0.3
                   when g.prev_cnt > 150 then 0.2
                   else 0.1
               end as coef_used,
               case
                   when g.cnt > 500 then 0.5
                   when g.cnt > 250 then 0.3
                   when g.cnt > 150 then 0.2
                   else 0.1
               end as coef_next
          from grid as g
    ),
    ins_pay as (
        insert into courier_pay (year, month, courier_id, amount, coefficient_used)
        select extract(year from p.mon)::int,
               extract(month from p.mon)::int,
               p.courier_id,
               round(p.coef_used * p.comm, 2),
               p.coef_used
          from pay as p
    )
    update courier c
       set coefficient = case when p.fired then p.coef_used else p.coef_next end
      from pay as p
     where p.mon = date_trunc('month', current_date)
       and c.courier_id = p.courier_id;
end;
$$ language plpgsql;
