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
language plpgsql
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
$$;

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
language plpgsql
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
$$;

create trigger payment_pay_status_trg
    after insert or update or delete on payment
    for each row
    execute function payment_pay_status();

-- ---------------------------------------------------------------------------
-- FOOD-105. Пересчёт агрегированного рейтинга (BR-9.6, BR-9.7).
--   'блюдо'    -> product.rating    = AVG(review.rating) по отзывам на блюдо;
--   'ресторан' -> restaurant.rating = AVG(review.rating) по отзывам на ресторан;
--   'заказ'    -> агрегата нет, ничего не делаем.
-- При UPDATE пересчитываются и старая, и новая сущность (если ссылка
-- изменилась). Нет отзывов -> AVG даёт NULL. Триггер меняет только product
-- и restaurant, поэтому рекурсии по review нет.
-- Генератор insert_test_data не пересчитывает рейтинг на каждый отзыв:
-- на время генерации он ставит флаг транзакции kalugin_food.skip_rating = 'on'
-- и в конце считает рейтинги порции сам. Без ALTER TABLE ... DISABLE TRIGGER,
-- для которого нужно владение таблицей.
-- ---------------------------------------------------------------------------
create or replace function rating_change()
returns trigger
language plpgsql
set search_path = kalugin_food, exts
as $$
declare
    v_types review_entity_type[] := '{}';
    v_ids   uuid[] := '{}';
    k       integer;
begin
    -- missing_ok = true: если флаг ни разу не ставили, вернётся NULL
    if current_setting('kalugin_food.skip_rating', true) = 'on' then
        return null;
    end if;

    if tg_op in ('UPDATE', 'DELETE') then
        v_types := v_types || old.entity_type;
        v_ids   := v_ids   || old.entity_id;
    end if;

    if tg_op = 'INSERT'
       or (tg_op = 'UPDATE'
           and (new.entity_type, new.entity_id) is distinct from (old.entity_type, old.entity_id)) then
        v_types := v_types || new.entity_type;
        v_ids   := v_ids   || new.entity_id;
    end if;

    for k in 1 .. coalesce(array_length(v_ids, 1), 0) loop
        if v_types[k] = 'блюдо' then
            update product p
               set rating = (select round(avg(r.rating), 2)
                               from review r
                              where r.entity_type = 'блюдо'
                                and r.entity_id = v_ids[k])
             where p.product_id = v_ids[k];
        elsif v_types[k] = 'ресторан' then
            update restaurant rs
               set rating = (select round(avg(r.rating), 2)
                               from review r
                              where r.entity_type = 'ресторан'
                                and r.entity_id = v_ids[k])
             where rs.restaurant_id = v_ids[k];
        end if;
    end loop;

    return null;
end;
$$;

create trigger rating_change_trg
    after insert or update or delete on review
    for each row
    execute function rating_change();
