-- Триггеры целостности и агрегатов.

set search_path to kalugin_food;

-- ---------------------------------------------------------------------------
-- FOOD-101. Проверка полиморфной ссылки review.entity_id (BR-9.1, BR-9.2).
-- FK на «одну из трёх таблиц» в PostgreSQL невозможен, поэтому проверка
-- выполняется триггером:
--   'блюдо'    -> блюдо входит в состав этого заказа;
--   'ресторан' -> это ресторан этого заказа;
--   'заказ'    -> entity_id совпадает с order_id.
-- Принадлежность заказа клиенту обеспечивает FK review_order_client_fk.
-- ---------------------------------------------------------------------------
create or replace function review_entity_check()
returns trigger
set search_path = kalugin_food, exts
as $$
declare
    v_order_ts timestamp;
begin
    select o.order_timestamp
      into v_order_ts
      from "order" o
     where o.order_id = new.order_id;

    if not found then
        raise exception 'Отзыв: заказ % не существует', new.order_id;
    end if;

    if new.review_timestamp < v_order_ts then
        raise exception 'Отзыв: дата отзыва (%) раньше даты заказа (%)',
            new.review_timestamp, v_order_ts;
    end if;

    if new.entity_type = 'блюдо' then
        if not exists (select 1
                         from order_structure os
                        where os.order_id = new.order_id
                          and os.product_id = new.entity_id) then
            raise exception 'Отзыв: блюдо % отсутствует в заказе %',
                new.entity_id, new.order_id;
        end if;
    elsif new.entity_type = 'ресторан' then
        if not exists (select 1
                         from "order" o
                        where o.order_id = new.order_id
                          and o.restaurant_id = new.entity_id) then
            raise exception 'Отзыв: ресторан % не является рестораном заказа %',
                new.entity_id, new.order_id;
        end if;
    elsif new.entity_type = 'заказ' then
        if new.entity_id <> new.order_id then
            raise exception 'Отзыв на заказ: entity_id (%) должен совпадать с order_id (%)',
                new.entity_id, new.order_id;
        end if;
    end if;

    return new;
end;
$$ language plpgsql;

create trigger review_entity_check_trg
    before insert or update on review
    for each row
    execute function review_entity_check();

-- ---------------------------------------------------------------------------
-- FOOD-101. Агрегированный статус оплаты заказа (BR-8.7):
--   'оплачен' — есть успешная попытка;
--   'ошибка'  — попытки есть и все завершились ошибкой;
--   'ожидает' — иначе (есть попытки в обработке или попыток нет).
-- ---------------------------------------------------------------------------
create or replace function payment_pay_status()
returns trigger
set search_path = kalugin_food, exts
as $$
declare
    v_order_id uuid;
    v_status   order_pay_status;
begin
    foreach v_order_id in array
        case tg_op
            when 'INSERT' then array[new.order_id]
            when 'DELETE' then array[old.order_id]
            else array[old.order_id, new.order_id]
        end
    loop
        -- Версия строки заказа синхронизирует параллельные изменения оплат.
        update "order" set pay_status = pay_status where order_id = v_order_id;
        select case
                   when bool_or(p.status = 'успех') then 'оплачен'
                   when count(*) > 0 and bool_and(p.status = 'ошибка') then 'ошибка'
                   else 'ожидает'
               end::order_pay_status
          into v_status
          from payment p
         where p.order_id = v_order_id;

        -- строка заказа переписывается, только если статус действительно изменился
        update "order" o
           set pay_status = v_status
         where o.order_id = v_order_id
           and o.pay_status is distinct from v_status;
    end loop;

    return null;
end;
$$ language plpgsql;

create trigger payment_pay_status_trg
    after insert or update or delete on payment
    for each row
    execute function payment_pay_status();

-- BR-7.3. Состав заказа хранит только заказ, блюдо и количество.
-- Родительские изменения проверяются тем же правилом, что и новые позиции.
create or replace function order_restaurant_check() returns trigger
set search_path = kalugin_food, exts
as $$
declare
    order_ids uuid[];
    restaurant_ids uuid[];
    restaurant_key uuid;
begin
    if tg_table_name = 'order_structure' then
        select array_agg(distinct order_id) into order_ids from new_rows;
    elseif tg_table_name = 'order' then
        select array_agg(n.order_id), array_agg(o.restaurant_id) || array_agg(n.restaurant_id)
        into order_ids, restaurant_ids
        from new_rows n join old_rows o using (order_id)
        where n.restaurant_id is distinct from o.restaurant_id;
    else
        select array_agg(s.order_id), array_agg(o.restaurant_id) || array_agg(n.restaurant_id)
        into order_ids, restaurant_ids
        from new_rows n join old_rows o using (product_id)
        left join order_structure s using (product_id)
        where n.restaurant_id is distinct from o.restaurant_id;
    end if;

    if order_ids is null then return null; end if;
    select coalesce(restaurant_ids, '{}') || coalesce(array_agg(o.restaurant_id), '{}')
           || coalesce(array_agg(p.restaurant_id), '{}')
    into restaurant_ids
    from "order" o join order_structure s using (order_id)
    join product p using (product_id)
    where o.order_id = any(order_ids);

    -- Обновление общей строки создаёт новую версию: изменения ресторана
    -- и состава сериализуются и при repeatable read, а не только при read committed.
    for restaurant_key in
        select distinct id from unnest(restaurant_ids) as ids(id) order by id
    loop
        update restaurant set rating = rating where restaurant_id = restaurant_key;
    end loop;

    -- Позиция могла быть зафиксирована, пока смена ресторана ждала блокировку.
    -- Поэтому для блюда читаем затронутые заказы заново после синхронизации.
    if tg_table_name = 'product' then
        select array_agg(s.order_id) into order_ids
        from order_structure s join new_rows n using (product_id);
    end if;

    if exists (
        select 1 from order_structure s join "order" o using (order_id)
        join product p using (product_id)
        where s.order_id = any(order_ids) and p.restaurant_id <> o.restaurant_id
    ) then
        raise exception 'Блюда заказа должны принадлежать ресторану заказа'
            using errcode = '23514', constraint = 'order_restaurant_match';
    end if;
    return null;
end;
$$ language plpgsql;

create trigger order_structure_insert_check
    after insert on order_structure referencing new table as new_rows
    for each statement execute function order_restaurant_check();
create trigger order_structure_update_check
    after update on order_structure referencing old table as old_rows new table as new_rows
    for each statement execute function order_restaurant_check();
create trigger order_restaurant_update_check
    after update on "order" referencing old table as old_rows new table as new_rows
    for each statement execute function order_restaurant_check();
create trigger product_restaurant_update_check
    after update on product referencing old table as old_rows new table as new_rows
    for each statement execute function order_restaurant_check();

-- FOOD-105. Пересчёт среднего после изменения отзыва.
-- При переносе отзыва пересчитываются старый и новый объекты.
create or replace function rating_change() returns trigger
set search_path = kalugin_food, exts
as $$
declare
    entity_types review_entity_type[] = '{}';
    entity_ids uuid[] = '{}';
    i integer;
begin
    if tg_op in ('UPDATE', 'DELETE') then
        entity_types = entity_types || old.entity_type;
        entity_ids = entity_ids || old.entity_id;
    end if;
    if tg_op = 'INSERT' or (tg_op = 'UPDATE' and
       (new.entity_type, new.entity_id) is distinct from (old.entity_type, old.entity_id)) then
        entity_types = entity_types || new.entity_type;
        entity_ids = entity_ids || new.entity_id;
    end if;
    for i in 1 .. coalesce(array_length(entity_ids, 1), 0) loop
        -- Блокировка до чтения отзывов синхронизирует пересчёт одного объекта.
        if entity_types[i] = 'блюдо' then
            perform 1 from product where product_id = entity_ids[i] for update;
            update product p set rating = (
                select round(avg(r.rating), 2) from review r
                where r.entity_type = 'блюдо' and r.entity_id = entity_ids[i])
            where p.product_id = entity_ids[i];
        elseif entity_types[i] = 'ресторан' then
            perform 1 from restaurant where restaurant_id = entity_ids[i] for update;
            update restaurant rs set rating = (
                select round(avg(r.rating), 2) from review r
                where r.entity_type = 'ресторан' and r.entity_id = entity_ids[i])
            where rs.restaurant_id = entity_ids[i];
        end if;
    end loop;
    return null;
end;
$$ language plpgsql;

create trigger rating_change_trg
    after insert or update or delete on review
    for each row execute function rating_change();

-- Доставленный заказ проверяется в конце транзакции: оплата может быть
-- вставлена после заказа или заменена другой успешной попыткой до COMMIT.
create or replace function delivered_payment_check() returns trigger
set search_path = kalugin_food, exts
as $$
declare
    order_keys uuid[];
    order_key uuid;
    current_status order_status;
begin
    if tg_op = 'INSERT' then order_keys = array[new.order_id];
    elseif tg_op = 'DELETE' then order_keys = array[old.order_id];
    else order_keys = array[old.order_id, new.order_id];
    end if;
    for order_key in select distinct id from unnest(order_keys) ids(id) order by id loop
        select status into current_status from "order" where order_id = order_key for update;
        if found and current_status = 'доставлен' and not exists (
            select 1 from payment where order_id = order_key and status = 'успех'
        ) then
            raise exception 'Доставленный заказ % должен иметь успешную оплату', order_key
                using errcode = '23514', constraint = 'delivered_order_payment';
        end if;
    end loop;
    return null;
end;
$$ language plpgsql;

create constraint trigger delivered_order_payment_check
    after insert or update of status on "order"
    deferrable initially deferred for each row execute function delivered_payment_check();
create constraint trigger delivered_payment_change_check
    after insert or update or delete on payment
    deferrable initially deferred for each row execute function delivered_payment_check();
