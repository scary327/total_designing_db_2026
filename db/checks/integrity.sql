-- Проверки целостности и отчётов; все изменения откатываются.
-- Выполнять в отдельной тестовой базе после установки схемы и grants.sql.
\set ON_ERROR_STOP on
BEGIN;
SET ROLE inspector;
SET search_path TO kalugin_food, exts;
CALL erase_test_data();
CALL insert_test_data(200);

DO $$
DECLARE
    v_product uuid;
    v_review uuid;
    v_restaurant uuid;
    v_month date;
    v_count integer;
    v_actual numeric;
BEGIN
    -- Найти блюдо, присутствующее хотя бы в трёх доставленных заказах.
    SELECT os.product_id INTO v_product
    FROM order_structure os JOIN "order" o USING (order_id)
    WHERE o.status = 'доставлен'
    GROUP BY os.product_id HAVING count(DISTINCT o.order_id) >= 3
    LIMIT 1;
    IF v_product IS NULL THEN RAISE EXCEPTION 'Нет блюда в трёх доставленных заказах'; END IF;

    DELETE FROM review WHERE entity_type = 'блюдо' AND entity_id = v_product;
    INSERT INTO review (client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
    SELECT ranked.client_id, localtimestamp, v_product, 'блюдо', ranked.order_id,
           'Проверка рейтинга', (ARRAY[3, 4, 5])[ranked.rn]
    FROM (
        SELECT o.order_id, o.client_id,
               row_number() OVER (ORDER BY o.order_id)::integer AS rn
        FROM "order" o JOIN order_structure os USING (order_id)
        WHERE o.status = 'доставлен' AND os.product_id = v_product
        ORDER BY o.order_id LIMIT 3
    ) ranked;
    SELECT rating INTO v_actual FROM product WHERE product_id = v_product;
    IF v_actual IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'Средний рейтинг: ожидалось 4, получено %', v_actual; END IF;
    DELETE FROM review WHERE entity_type='блюдо' AND entity_id=v_product AND rating=3;
    SELECT rating INTO v_actual FROM product WHERE product_id = v_product;
    IF v_actual IS DISTINCT FROM 4.5 THEN RAISE EXCEPTION 'После удаления: ожидалось 4.5, получено %', v_actual; END IF;

    -- Перенос отзыва требует пересчёта и исходного, и нового объекта.
    SELECT rv.review_id, o.restaurant_id INTO v_review, v_restaurant
    FROM review rv JOIN "order" o USING (order_id)
    WHERE rv.entity_type='блюдо' AND rv.entity_id=v_product
      AND NOT EXISTS (SELECT 1 FROM review other WHERE other.order_id=rv.order_id
                      AND other.entity_type='ресторан' AND other.entity_id=o.restaurant_id)
    LIMIT 1;
    IF v_review IS NULL THEN
        -- Освободить отзыв на ресторан в одном из соответствующих заказов.
        SELECT rv.review_id, o.restaurant_id INTO v_review, v_restaurant
        FROM review rv JOIN "order" o USING (order_id)
        WHERE rv.entity_type='блюдо' AND rv.entity_id=v_product LIMIT 1;
        DELETE FROM review WHERE order_id=(SELECT order_id FROM review WHERE review_id=v_review)
          AND entity_type='ресторан' AND entity_id=v_restaurant;
    END IF;
    UPDATE review SET entity_type='ресторан', entity_id=v_restaurant WHERE review_id=v_review;
    IF EXISTS (SELECT 1 FROM product p WHERE p.product_id=v_product AND p.rating IS DISTINCT FROM
       (SELECT round(avg(r.rating),2) FROM review r WHERE r.entity_type='блюдо' AND r.entity_id=v_product))
       OR EXISTS (SELECT 1 FROM restaurant rs WHERE rs.restaurant_id=v_restaurant AND rs.rating IS DISTINCT FROM
       (SELECT round(avg(r.rating),2) FROM review r WHERE r.entity_type='ресторан' AND r.entity_id=v_restaurant))
    THEN RAISE EXCEPTION 'Перенос отзыва не пересчитал оба рейтинга'; END IF;
    DELETE FROM review WHERE entity_type='блюдо' AND entity_id=v_product;
    IF (SELECT rating FROM product WHERE product_id=v_product) IS NOT NULL THEN
        RAISE EXCEPTION 'Рейтинг без отзывов должен быть NULL';
    END IF;

    -- Убрать доставки из промежуточного месяца и проверить отчёт с нулями.
    SELECT (min(date_trunc('month', order_timestamp)) + interval '1 month')::date INTO v_month
    FROM "order" WHERE status='доставлен';
    IF v_month >= (SELECT max(date_trunc('month', order_timestamp))::date FROM "order" WHERE status='доставлен') THEN
        RAISE EXCEPTION 'Недостаточно месяцев для теста пропуска';
    END IF;
    DELETE FROM "order" WHERE status='доставлен'
      AND order_timestamp >= v_month AND order_timestamp < v_month + interval '1 month';
    SELECT count(*) INTO v_count FROM how_much_money
      WHERE year_month=to_char(v_month,'YYYY-MM') AND sum_no_commission=0 AND commission=0;
    IF v_count <> 1 THEN RAISE EXCEPTION 'Месяц без доставок отсутствует в отчёте'; END IF;
    SELECT count(*) INTO v_count FROM how_much_money
      WHERE year_month=to_char(v_month + interval '1 month','YYYY-MM') AND prev_commission=0;
    IF v_count <> 1 THEN RAISE EXCEPTION 'Комиссия за пустой месяц потеряна'; END IF;
    RAISE NOTICE 'Проверки рейтинга и пустого месяца пройдены';
END $$;
ROLLBACK;
