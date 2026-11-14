-- Триггеры целостности и агрегатов.

SET search_path TO kalugin_food;

-- ---------------------------------------------------------------------------
-- FOOD-101. Проверка полиморфной ссылки review.entity_id (BR-9.1, BR-9.2).
-- FK на «одну из трёх таблиц» в PostgreSQL невозможен, поэтому проверка
-- выполняется триггером:
--   'блюдо'    -> блюдо входит в состав этого заказа;
--   'ресторан' -> это ресторан этого заказа;
--   'заказ'    -> entity_id совпадает с order_id.
-- Принадлежность заказа клиенту обеспечивает FK review_order_client_fk.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION review_entity_check()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
DECLARE
    v_order_ts timestamp;
BEGIN
    SELECT o.order_timestamp
      INTO v_order_ts
      FROM "order" o
     WHERE o.order_id = new.order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Отзыв: заказ % не существует', new.order_id;
    END IF;

    IF new.review_timestamp < v_order_ts THEN
        RAISE EXCEPTION 'Отзыв: дата отзыва (%) раньше даты заказа (%)',
            new.review_timestamp, v_order_ts;
    END IF;

    IF new.entity_type = 'блюдо' THEN
        IF NOT EXISTS (SELECT 1
                         FROM order_structure os
                        WHERE os.order_id = new.order_id
                          AND os.product_id = new.entity_id) THEN
            RAISE EXCEPTION 'Отзыв: блюдо % отсутствует в заказе %',
                new.entity_id, new.order_id;
        END IF;
    ELSIF new.entity_type = 'ресторан' THEN
        IF NOT EXISTS (SELECT 1
                         FROM "order" o
                        WHERE o.order_id = new.order_id
                          AND o.restaurant_id = new.entity_id) THEN
            RAISE EXCEPTION 'Отзыв: ресторан % не является рестораном заказа %',
                new.entity_id, new.order_id;
        END IF;
    ELSIF new.entity_type = 'заказ' THEN
        IF new.entity_id <> new.order_id THEN
            RAISE EXCEPTION 'Отзыв на заказ: entity_id (%) должен совпадать с order_id (%)',
                new.entity_id, new.order_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER review_entity_check_trg
    BEFORE INSERT OR UPDATE ON review
    FOR EACH ROW
    EXECUTE FUNCTION review_entity_check();

-- ---------------------------------------------------------------------------
-- FOOD-101. Агрегированный статус оплаты заказа (BR-8.7):
--   'оплачен' — есть успешная попытка;
--   'ошибка'  — попытки есть и все завершились ошибкой;
--   'ожидает' — иначе (есть попытки в обработке или попыток нет).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION payment_pay_status()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
DECLARE
    v_order_id UUID;
    v_status   order_pay_status;
BEGIN
    FOREACH v_order_id IN array
        CASE tg_op
            WHEN 'INSERT' THEN array[new.order_id]
            WHEN 'DELETE' THEN array[old.order_id]
            ELSE array[old.order_id, new.order_id]
        END
    LOOP
        SELECT CASE
                   WHEN bool_or(p.status = 'успех') THEN 'оплачен'
                   WHEN count(*) > 0 AND bool_and(p.status = 'ошибка') THEN 'ошибка'
                   ELSE 'ожидает'
               END::order_pay_status
          INTO v_status
          FROM payment p
         WHERE p.order_id = v_order_id;

        -- строка заказа переписывается, только если статус действительно изменился
        UPDATE "order" o
           SET pay_status = v_status
         WHERE o.order_id = v_order_id
           AND o.pay_status IS DISTINCT FROM v_status;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER payment_pay_status_trg
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW
    EXECUTE FUNCTION payment_pay_status();

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
CREATE OR REPLACE FUNCTION rating_change()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
DECLARE
    v_types review_entity_type[] := '{}';
    v_ids   UUID[] := '{}';
    k       integer;
BEGIN
    -- missing_ok = true: если флаг ни разу не ставили, вернётся NULL
    IF current_setting('kalugin_food.skip_rating', TRUE) = 'on' THEN
        RETURN NULL;
    END IF;

    -- OLD нужно пересчитать при DELETE и UPDATE (в том числе при изменении
    -- только rating); NEW — при INSERT или переносе отзыва к другому объекту.
    -- При неизменной ссылке один пересчёт уже учитывает новое значение rating.
    IF tg_op IN ('UPDATE', 'DELETE') THEN
        v_types := v_types || old.entity_type;
        v_ids   := v_ids   || old.entity_id;
    END IF;

    IF tg_op = 'INSERT'
       OR (tg_op = 'UPDATE'
           AND (new.entity_type, new.entity_id) IS DISTINCT FROM (old.entity_type, old.entity_id)) THEN
        v_types := v_types || new.entity_type;
        v_ids   := v_ids   || new.entity_id;
    END IF;

    FOR k IN 1 .. coalesce(array_length(v_ids, 1), 0) LOOP
        IF v_types[k] = 'блюдо' THEN
            UPDATE product p
               SET rating = (SELECT round(avg(r.rating), 2)
                               FROM review r
                              WHERE r.entity_type = 'блюдо'
                                AND r.entity_id = v_ids[k])
             WHERE p.product_id = v_ids[k];
        ELSIF v_types[k] = 'ресторан' THEN
            UPDATE restaurant rs
               SET rating = (SELECT round(avg(r.rating), 2)
                               FROM review r
                              WHERE r.entity_type = 'ресторан'
                                AND r.entity_id = v_ids[k])
             WHERE rs.restaurant_id = v_ids[k];
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

CREATE TRIGGER rating_change_trg
    AFTER INSERT OR UPDATE OR DELETE ON review
    FOR EACH ROW
    EXECUTE FUNCTION rating_change();
