-- FOOD-102. Генератор тестовых данных.
--
-- Распределение (BR-11.7) на один вызов insert_test_data(value):
--   value     : client, courier, product_category, restaurant;
--   value * 5 : address (value — под рестораны, value * 4 — под клиентов),
--               product, order, review, payment;
--   client_address, order_structure — сколько нужно для связности;
--   courier_pay — по каждому курьеру за последние 6 месяцев (BR-10.2, BR-10.7).
--
-- Процедуру можно вызывать многократно без очистки: каждый вызов добавляет
-- новую порцию данных и связывает между собой только строки этой порции,
-- поэтому выплаты курьеров прошлых вызовов не теряют согласованность.
--
-- Процедура не вызывает другие функции и процедуры схемы: courier_pay,
-- блюда и рейтинги заполняются прямыми INSERT/UPDATE. При этом на вставляемых
-- строках срабатывают триггеры таблиц: review_entity_check (проверка отзыва)
-- и payment_pay_status (order.pay_status по BR-8.7). Триггер rating_change
-- на время генерации пропускается: процедура ставит флаг транзакции
-- kalugin_food.skip_rating, а рейтинги этой порции считает одним UPDATE
-- в разделе 9 (samples, раздел 10).

set search_path to kalugin_food;

create or replace procedure insert_test_data(value integer)
language plpgsql
set search_path = kalugin_food, exts
as $$
declare
    -- справочники для правдоподобных строк
    c_streets    text[] := array['ул. Ленина', 'ул. Мира', 'ул. Гагарина', 'ул. Пушкина',
                                 'ул. Советская', 'ул. Садовая', 'ул. Лесная', 'ул. Школьная',
                                 'наб. Речная', 'ул. Молодёжная', 'пр. Победы', 'ул. Центральная'];
    c_surnames   text[] := array['Иванов', 'Петров', 'Сидоров', 'Смирнов', 'Кузнецов',
                                 'Попов', 'Соколов', 'Лебедев', 'Козлов', 'Новиков'];
    c_names      text[] := array['Иван', 'Пётр', 'Алексей', 'Дмитрий', 'Сергей',
                                 'Андрей', 'Михаил', 'Николай'];
    c_patronyms  text[] := array['Иванович', 'Петрович', 'Сергеевич', 'Алексеевич',
                                 'Дмитриевич', 'Андреевич'];
    c_categories text[] := array['Супы', 'Салаты', 'Пицца', 'Роллы', 'Бургеры', 'Десерты',
                                 'Напитки', 'Горячее', 'Закуски', 'Завтраки', 'Паста', 'Гриль'];
    c_rest_names text[] := array['Пельменная', 'Траттория', 'Суши-бар', 'Бургерная', 'Кофейня',
                                 'Чайхана', 'Блинная', 'Гриль-хаус', 'Пиццерия', 'Столовая'];
    c_dishes     text[] := array['Борщ', 'Солянка', 'Цезарь', 'Оливье', 'Маргарита', 'Пепперони',
                                 'Филадельфия', 'Калифорния', 'Чизбургер', 'Тирамису', 'Морс',
                                 'Плов', 'Шашлык', 'Карбонара', 'Сырники', 'Блины с мясом'];
    c_order_notes text[] := array['Позвонить за 10 минут', 'Без лука', 'Оставить у двери',
                                  'Домофон не работает', 'Нужны приборы', 'Без комментариев'];
    c_review_txt text[] := array['Очень вкусно', 'Привезли быстро', 'Всё остыло',
                                 'Порция маленькая', 'Отличный сервис', 'Буду заказывать ещё',
                                 'Курьер вежливый', 'Средне'];

    v_cat         uuid[] := '{}';
    v_cour        uuid[] := '{}';
    v_cour_start  timestamp[] := '{}';
    v_cour_end    timestamp[] := '{}';
    v_cour_fired  boolean[] := '{}';
    v_addr        uuid[] := '{}';
    v_rest        uuid[] := '{}';
    v_client      uuid[] := '{}';
    v_prod        uuid[] := '{}';
    v_prod_price  numeric[] := '{}';
    v_extra_addr  uuid[];          -- дополнительный (соседский) адрес клиента или NULL

    v_id          uuid;
    v_price       numeric;
    v_text        text;
    v_hire        date;
    v_dismiss     date;
    v_status_c    courier_status;
    v_active_st   courier_status[] := array_remove(enum_range(null::courier_status), 'уволен');
    v_rest_st     restaurant_status[] := enum_range(null::restaurant_status);
    v_order_all   order_status[] := enum_range(null::order_status);
    -- незавершённые: создан .. в_доставке; завершённые: доставлен .. отменён (порядок enum)
    v_order_open  order_status[] := enum_range(null::order_status, 'в_доставке'::order_status);
    v_order_done  order_status[] := enum_range('доставлен'::order_status, null::order_status);
    v_start_time  time;
    v_base        bigint;
    -- месяцы выплат: текущий и пять предыдущих (BR-10.7)
    v_pay_start   date := (date_trunc('month', current_date) - interval '5 months')::date;
    -- даты данных: последние 180 дней, но не раньше первого месяца выплат,
    -- чтобы у каждого доставленного заказа был месяц в courier_pay
    v_window_start date := greatest(v_pay_start, current_date - 180);

    -- заказ
    v_ci          integer;
    v_ri          integer;
    v_ki          integer;
    v_ai          integer;
    v_order_id    uuid;
    v_order_addr  uuid;
    v_order_ts    timestamp;
    v_deliv_ts    timestamp;
    v_order_st    order_status;
    v_items       integer[];
    v_swap        integer;
    v_qty         numeric[];
    v_amount      numeric;
    v_n_items     integer;
    v_pi          integer;
    v_entity_type review_entity_type;
    v_entity_id   uuid;

    -- выплаты
    v_coef        numeric;
    v_last_coef   numeric;
    v_rec         record;

    i             integer;
    j             integer;
begin
    if value is null or value < 1 then
        raise exception 'insert_test_data: value должно быть положительным, передано %', value;
    end if;

    -- rating_change не пересчитывает рейтинг на каждый отзыв генератора:
    -- флаг действует до конца транзакции (is_local = true) и снимается
    -- перед итоговым пересчётом в разделе 9.
    perform set_config('kalugin_food.skip_rating', 'on', true);

    -- -----------------------------------------------------------------------
    -- 1. Категории блюд (value). Название уникально (BR-5.7).
    -- -----------------------------------------------------------------------
    select count(*) into v_base from product_category;
    for i in 1..value loop
        loop
            v_text := c_categories[1 + floor(random() * cardinality(c_categories))::int]
                      || ' №' || (v_base + i)::text;
            exit when not exists (select 1 from product_category
                                   where product_category_name = v_text);
            v_base := v_base + value;
        end loop;
        insert into product_category (product_category_id, product_category_name)
        values (exts.uuid_generate_v4(), v_text)
        returning product_category_id into v_id;
        v_cat := v_cat || v_id;
    end loop;

    -- -----------------------------------------------------------------------
    -- 2. Курьеры (value). Все даты — внутри окна v_window_start .. сегодня:
    --    не старше 180 дней и не раньше 1-го числа месяца пять месяцев назад.
    --    Выплаты генерируются за все месяцы этого окна, поэтому каждый
    --    доставленный заказ попадает в месяц, по которому есть запись courier_pay.
    --    Первый курьер всегда работает и нанят в начале окна (BR-6.6).
    --    Около 20% остальных — уволены, с датой увольнения не раньше даты
    --    найма (BR-6.3).
    -- -----------------------------------------------------------------------
    for i in 1..value loop
        if i = 1 then
            v_hire := v_window_start;
        else
            v_hire := v_window_start + floor(random() * (current_date - v_window_start + 1))::int;
        end if;

        if i > 1 and random() < 0.2 then
            v_status_c := 'уволен';
            v_dismiss := v_hire + floor(random() * (current_date - v_hire + 1))::int;
        else
            v_status_c := v_active_st[1 + floor(random() * cardinality(v_active_st))::int];
            v_dismiss := null;
        end if;

        insert into courier (courier_id, fio, phone_number, status,
                             hire_date, dismissal_date, coefficient)
        values (exts.uuid_generate_v4(),
                c_surnames[1 + floor(random() * cardinality(c_surnames))::int] || ' '
                    || c_names[1 + floor(random() * cardinality(c_names))::int] || ' '
                    || c_patronyms[1 + floor(random() * cardinality(c_patronyms))::int],
                '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0'),
                v_status_c, v_hire, v_dismiss, 0.1)
        returning courier_id into v_id;

        v_cour       := v_cour || v_id;
        v_cour_start := v_cour_start || v_hire::timestamp;
        v_cour_end   := v_cour_end || case
                            when v_dismiss is null then localtimestamp
                            else least(v_dismiss + interval '23 hours 59 minutes', localtimestamp)
                        end;
        v_cour_fired := v_cour_fired || (v_dismiss is not null);
    end loop;

    -- -----------------------------------------------------------------------
    -- 3. Адреса (value * 5): первые value — под рестораны, остальные — клиентам.
    --    Квартира/офис необязательна (BR-3.2).
    -- -----------------------------------------------------------------------
    for i in 1..value * 5 loop
        insert into address (address_id, street, house_number, apartment_office)
        values (exts.uuid_generate_v4(),
                c_streets[1 + floor(random() * cardinality(c_streets))::int],
                (1 + floor(random() * 150))::int::text
                    || case when random() < 0.15 then 'А' else '' end,
                case
                    when random() < 0.3 then null
                    when i <= value then 'оф. ' || (1 + floor(random() * 50))::int
                    else (1 + floor(random() * 300))::int::text
                end)
        returning address_id into v_id;
        v_addr := v_addr || v_id;
    end loop;

    -- -----------------------------------------------------------------------
    -- 4. Рестораны (value): у каждого свой адрес из первых value (BR-3.3).
    --    Время закрытия позже открытия (BR-4.4): открытие 06:00..11:59,
    --    работа 8..12 часов, поэтому закрытие не позже 23:59.
    -- -----------------------------------------------------------------------
    select count(*) into v_base from restaurant;
    for i in 1..value loop
        v_start_time := time '06:00' + floor(random() * 360)::int * interval '1 minute';
        insert into restaurant (restaurant_id, restaurant_name, address_id, description,
                                work_start, work_end, company_details, rating, status)
        values (exts.uuid_generate_v4(),
                c_rest_names[1 + floor(random() * cardinality(c_rest_names))::int]
                    || ' «' || c_surnames[1 + floor(random() * cardinality(c_surnames))::int] || '»'
                    || ' №' || (v_base + i)::text,
                v_addr[i],
                'Доставка домашней кухни, ресторан-партнёр FoodExpress',
                v_start_time,
                v_start_time + (8 + floor(random() * 5))::int * interval '1 hour',
                'ИНН ' || lpad(floor(random() * 1e10)::bigint::text, 10, '0')
                    || ', ОГРН ' || lpad(floor(random() * 1e13)::bigint::text, 13, '0')
                    || ', р/с 40702810' || lpad(floor(random() * 1e12)::bigint::text, 12, '0'),
                null,
                case when random() < 0.9 then 'активен'::restaurant_status
                     else v_rest_st[1 + floor(random() * cardinality(v_rest_st))::int]
                end)
        returning restaurant_id into v_id;
        v_rest := v_rest || v_id;
    end loop;

    -- -----------------------------------------------------------------------
    -- 5. Клиенты (value). Логин и телефон уникальны (BR-2.2),
    --    пароль — md5 (BR-2.3).
    -- -----------------------------------------------------------------------
    select count(*) into v_base from client;
    for i in 1..value loop
        loop
            v_text := '+79' || lpad(floor(random() * 1000000000)::bigint::text, 9, '0');
            exit when not exists (select 1 from client where phone_number = v_text);
        end loop;
        insert into client (client_id, login, password, phone_number)
        values (exts.uuid_generate_v4(),
                'user_' || left(md5(random()::text), 6) || '_' || (v_base + i)::text,
                md5(random()::text),
                v_text)
        returning client_id into v_id;
        v_client := v_client || v_id;
    end loop;

    -- -----------------------------------------------------------------------
    -- 6. Адреса клиентов (BR-2.4, BR-2.5): клиентские адреса раздаются по
    --    кругу (у каждого клиента 4 адреса), часть клиентов дополнительно
    --    пользуется адресом соседа. Дубли пары исключает PK.
    --    Адреса клиента i: v_addr[value + i + value * k], k = 0..3,
    --    и v_extra_addr[i], если он есть, — из них выбирается адрес заказа.
    -- -----------------------------------------------------------------------
    for i in 1..value * 4 loop
        insert into client_address (client_id, address_id)
        values (v_client[1 + (i - 1) % value], v_addr[value + i]);
    end loop;

    v_extra_addr := array_fill(null::uuid, array[value]);
    if value > 1 then
        for i in 1..value loop
            if random() < 0.2 then
                -- адрес соседа (клиента i % value + 1) у клиента i ещё не привязан
                insert into client_address (client_id, address_id)
                values (v_client[i], v_addr[value + 1 + (i % value)]);
                v_extra_addr[i] := v_addr[value + 1 + (i % value)];
            end if;
        end loop;
    end if;

    -- -----------------------------------------------------------------------
    -- 7. Блюда (value * 5): блюдо j принадлежит ресторану ((j - 1) % value) + 1,
    --    так у каждого ресторана ровно 5 блюд. Цена 100..1500 (BR-5.3).
    -- -----------------------------------------------------------------------
    for j in 1..value * 5 loop
        insert into product (product_id, product_name, product_category_id, price,
                             restaurant_id, photo_url, rating, status, description)
        values (exts.uuid_generate_v4(),
                c_dishes[1 + floor(random() * cardinality(c_dishes))::int],
                v_cat[1 + floor(random() * value)::int],
                (10 + floor(random() * 141)) * 10,
                v_rest[1 + (j - 1) % value],
                case when random() < 0.3 then null
                     else 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' end,
                null,
                case when random() < 0.8 then 'доступно'::product_status
                     else (enum_range(null::product_status))
                          [1 + floor(random() * cardinality(enum_range(null::product_status)))::int]
                end,
                'Фирменное блюдо, вес ' || (200 + floor(random() * 300))::int || ' г')
        returning product_id, price into v_id, v_price;
        v_prod := v_prod || v_id;
        v_prod_price := v_prod_price || v_price;
    end loop;

    -- -----------------------------------------------------------------------
    -- 8. Заказы (value * 5) с составом, оплатой и отзывом.
    -- -----------------------------------------------------------------------
    for i in 1..value * 5 loop
        v_ci := 1 + floor(random() * value)::int;
        v_ri := 1 + floor(random() * value)::int;
        v_ki := 1 + floor(random() * value)::int;

        -- адрес доставки — один из адресов клиента (BR-7.4), по случайному
        -- индексу из массива адресов, без запроса к client_address
        v_ai := floor(random() * (4 + (v_extra_addr[v_ci] is not null)::int))::int;
        v_order_addr := case
                            when v_ai = 4 then v_extra_addr[v_ci]
                            else v_addr[value + v_ci + value * v_ai]
                        end;

        -- статус: у уволенного курьера заказы только завершённые
        if v_cour_fired[v_ki] then
            v_order_st := case
                              when random() < 0.85 then 'доставлен'::order_status
                              else v_order_done[1 + floor(random() * cardinality(v_order_done))::int]
                          end;
        elsif random() < 0.7 then
            v_order_st := 'доставлен';
        else
            v_order_st := v_order_all[1 + floor(random() * cardinality(v_order_all))::int];
        end if;

        -- время заказа — в период работы курьера (не раньше найма и не позже увольнения),
        -- незавершённые заказы — за последние 2 часа
        if v_order_st = any (v_order_open) then
            v_order_ts := greatest(v_cour_start[v_ki],
                                   localtimestamp - random() * interval '2 hours');
        else
            v_order_ts := v_cour_start[v_ki]
                          + random() * (v_cour_end[v_ki] - v_cour_start[v_ki]);
        end if;
        v_order_ts := date_trunc('second', v_order_ts);

        -- время доставки только у доставленных (BR-7.12), не раньше создания (BR-7.13)
        if v_order_st = 'доставлен' then
            v_deliv_ts := least(v_order_ts + (20 + floor(random() * 100))::int * interval '1 minute',
                                date_trunc('second', localtimestamp));
        else
            v_deliv_ts := null;
        end if;

        -- состав: 1..3 разных блюда ресторана заказа (BR-7.3, BR-7.16).
        -- Индексы 5 блюд ресторана перемешиваются в массиве (Фишер — Йетс),
        -- берутся первые v_n_items — без повторов и без запросов к таблицам.
        v_n_items := 1 + floor(random() * 3)::int;
        v_items := array[v_ri, v_ri + value, v_ri + value * 2, v_ri + value * 3, v_ri + value * 4];
        for j in reverse 5..2 loop
            v_ai := 1 + floor(random() * j)::int;
            v_swap := v_items[j];
            v_items[j] := v_items[v_ai];
            v_items[v_ai] := v_swap;
        end loop;
        v_items := v_items[1:v_n_items];

        v_qty := '{}';
        v_amount := 0;
        for j in 1..v_n_items loop
            v_qty := v_qty || (1 + floor(random() * 3))::numeric;
            v_amount := v_amount + v_prod_price[v_items[j]] * v_qty[j];
        end loop;

        -- общая сумма не меньше 1000 (BR-1.8): докладываем количество первого блюда
        while round(v_amount * 1.10, 2) < 1000 loop
            v_qty[1] := v_qty[1] + 1;
            v_amount := v_amount + v_prod_price[v_items[1]];
        end loop;

        insert into "order" (order_id, courier_id, client_id, address_id, restaurant_id,
                             order_timestamp, delivery_timestamp, order_amount,
                             status, pay_status, description)
        values (exts.uuid_generate_v4(), v_cour[v_ki], v_client[v_ci], v_order_addr, v_rest[v_ri],
                v_order_ts, v_deliv_ts, v_amount,
                v_order_st, 'ожидает',
                c_order_notes[1 + floor(random() * cardinality(c_order_notes))::int])
        returning order_id into v_order_id;

        for j in 1..v_n_items loop
            insert into order_structure (order_id, product_id, restaurant_id, quantity)
            values (v_order_id, v_prod[v_items[j]], v_rest[v_ri], v_qty[j]);
        end loop;

        -- оплата: одна попытка на заказ, и она успешная — у каждого заказа
        -- ровно одна успешная оплата (BR-8.1), а строк payment ровно
        -- value * 5 (BR-11.7). Сумма = total_amount (BR-8.4).
        -- Предоплата: заказ в любом статусе (и 'создан') уже оплачен.
        -- order.pay_status = 'оплачен' выставляет триггер payment_pay_status (BR-8.7).
        insert into payment (payment_id, order_id, payment_type, amount, transaction_ref,
                             transaction_timestamp, status)
        select exts.uuid_generate_v4(), o.order_id,
               (enum_range(null::payment_type))
                   [1 + floor(random() * cardinality(enum_range(null::payment_type)))::int],
               o.total_amount,
               'TX-' || replace(exts.uuid_generate_v4()::text, '-', ''),
               least(o.order_timestamp + (1 + floor(random() * 10))::int * interval '1 minute',
                     date_trunc('second', localtimestamp)),
               'успех'::payment_status
          from "order" o
         where o.order_id = v_order_id;

        -- отзыв: на блюдо из этого заказа, ресторан заказа или сам заказ (BR-9.1, BR-9.2)
        v_entity_type := (enum_range(null::review_entity_type))
                         [1 + floor(random() * cardinality(enum_range(null::review_entity_type)))::int];
        v_entity_id := case v_entity_type
                           when 'блюдо'    then v_prod[v_items[1 + floor(random() * v_n_items)::int]]
                           when 'ресторан' then v_rest[v_ri]
                           else v_order_id
                       end;

        insert into review (review_id, client_id, review_timestamp, entity_id, entity_type,
                            order_id, description, photo_url, rating)
        values (exts.uuid_generate_v4(), v_client[v_ci],
                least(coalesce(v_deliv_ts, v_order_ts)
                          + (1 + floor(random() * 48))::int * interval '1 hour',
                      greatest(v_order_ts, date_trunc('second', localtimestamp))),
                v_entity_id, v_entity_type, v_order_id,
                c_review_txt[1 + floor(random() * cardinality(c_review_txt))::int],
                case when random() < 0.5 then null
                     else 'https://cdn.foodexpress.ru/review/' || md5(random()::text) || '.jpg' end,
                1 + floor(random() * 5)::int);
    end loop;

    -- -----------------------------------------------------------------------
    -- 9. Рейтинги блюд и ресторанов этой порции = среднее по отзывам,
    --    NULL если отзывов нет (BR-9.6, BR-9.7). Считаются здесь одним
    --    UPDATE, а не триггером rating_change на каждый отзыв. Флаг пропуска
    --    снимается, чтобы дальнейшие изменения отзывов в этой же транзакции
    --    снова пересчитывали рейтинг.
    -- -----------------------------------------------------------------------
    perform set_config('kalugin_food.skip_rating', 'off', true);

    update product p
       set rating = (select round(avg(r.rating), 2)
                       from review r
                      where r.entity_type = 'блюдо'
                        and r.entity_id = p.product_id)
     where p.product_id = any (v_prod);

    update restaurant rs
       set rating = (select round(avg(r.rating), 2)
                       from review r
                      where r.entity_type = 'ресторан'
                        and r.entity_id = rs.restaurant_id)
     where rs.restaurant_id = any (v_rest);

    -- -----------------------------------------------------------------------
    -- 10. Выплаты курьерам за последние 6 месяцев (BR-10.2, BR-10.7).
    --     Идём от старого месяца к текущему: в первом месяце действует
    --     начальный коэффициент 0.1 (BR-6.5); выплата = коэффициент месяца ×
    --     сумма комиссий доставленных заказов курьера за месяц (по дате заказа);
    --     коэффициент следующего месяца — по числу доставок.
    --     После текущего месяца courier.coefficient = коэффициент на следующий
    --     месяц; уволенным он не назначается (BR-10.6).
    -- -----------------------------------------------------------------------
    for i in 1..value loop
        v_coef := 0.1;
        v_last_coef := 0.1;

        for v_rec in
            select m.mon,
                   count(o.order_id)              as cnt,
                   coalesce(sum(o.commission), 0) as commission_sum
              from generate_series(v_pay_start::timestamp,
                                   date_trunc('month', current_date),
                                   interval '1 month') as m(mon)
              left join "order" o
                     on o.courier_id = v_cour[i]
                    and o.status = 'доставлен'
                    and o.order_timestamp >= m.mon
                    and o.order_timestamp <  m.mon + interval '1 month'
             group by m.mon
             order by m.mon
        loop
            insert into courier_pay (year, month, courier_id, amount, coefficient_used)
            values (extract(year from v_rec.mon)::int,
                    extract(month from v_rec.mon)::int,
                    v_cour[i],
                    round(v_coef * v_rec.commission_sum, 2),
                    v_coef);

            v_last_coef := v_coef;
            v_coef := case
                          when v_rec.cnt > 500 then 0.5
                          when v_rec.cnt > 250 then 0.3
                          when v_rec.cnt > 150 then 0.2
                          else 0.1
                      end;
        end loop;

        update courier
           set coefficient = case when v_cour_fired[i] then v_last_coef else v_coef end
         where courier_id = v_cour[i];
    end loop;
end;
$$;
