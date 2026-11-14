-- ТОЛЬКО для отдельной тестовой БД: удаляет и повторно создаёт данные.
-- Проверки по templates/tests.md; E.2–E.4 выполняются в smoke.sql и integrity.sql.
-- Для вызова E.1 идентификаторы передаются через \gset.
\set ON_ERROR_STOP on
SET jit=off;
\echo CHECK A.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SET ROLE inspector;
SET search_path TO kalugin_food, exts;
SELECT current_user;

RESET ROLE;
\echo CHECK B.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';

RESET ROLE;
\echo CHECK B.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';

RESET ROLE;
\echo CHECK B.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'kalugin_food'
ORDER BY table_name;

RESET ROLE;
\echo CHECK B.4.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'kalugin_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';

RESET ROLE;
\echo CHECK B.5.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'kalugin_food'
GROUP BY t.typname
ORDER BY t.typname;

RESET ROLE;
\echo CHECK B.6.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'kalugin_food'::regnamespace
ORDER BY tbl, conname;

RESET ROLE;
\echo CHECK B.7.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT length(password) AS len, password
FROM client LIMIT 5;

RESET ROLE;
\echo CHECK C.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL erase_test_data();

RESET ROLE;
\echo CHECK C.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL insert_test_data(10);

RESET ROLE;
\echo CHECK C.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
ORDER BY tbl;

RESET ROLE;
\echo CHECK C.4.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;

RESET ROLE;
\echo CHECK C.5.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
-- и аналогично для других varchar-полей с NOT NULL

RESET ROLE;
\echo CHECK C.6.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
-- и аналогично для других NOT NULL полей

RESET ROLE;
\echo CHECK C.7.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM courier WHERE status != 'уволен';

RESET ROLE;
\echo CHECK C.8.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM "order" o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp
LIMIT 20;

RESET ROLE;
\echo CHECK C.9.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;

RESET ROLE;
\echo CHECK D.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT 'order_structure → order' AS fk, count(*) AS orphans
FROM order_structure os
LEFT JOIN "order" o ON os.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_structure → product', count(*)
FROM order_structure os
LEFT JOIN product p ON os.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'payment → order', count(*)
FROM payment pmt
LEFT JOIN "order" o ON pmt.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'review → order', count(*)
FROM review r
LEFT JOIN "order" o ON r.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'courier_pay → courier', count(*)
FROM courier_pay cp
LEFT JOIN courier c ON cp.courier_id = c.courier_id
WHERE c.courier_id IS NULL
UNION ALL
SELECT 'client_address → client', count(*)
FROM client_address ca
LEFT JOIN client c ON ca.client_id = c.client_id
WHERE c.client_id IS NULL
UNION ALL
SELECT 'client_address → address', count(*)
FROM client_address ca
LEFT JOIN address a ON ca.address_id = a.address_id
WHERE a.address_id IS NULL;

RESET ROLE;
\echo CHECK D.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order" WHERE total_amount < 1000;

RESET ROLE;
\echo CHECK D.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;

RESET ROLE;
\echo CHECK D.4.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;

RESET ROLE;
\echo CHECK D.5.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;

RESET ROLE;
\echo CHECK D.6.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;

RESET ROLE;
\echo CHECK D.7.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;

RESET ROLE;
\echo CHECK D.8.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT order_id, count(*) AS cnt
FROM payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;

RESET ROLE;
\echo CHECK D.9.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;

RESET ROLE;
\echo CHECK D.10.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;

RESET ROLE;
\echo CHECK D.11.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;

RESET ROLE;
\echo CHECK D.12.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM restaurant WHERE work_end <= work_start;

RESET ROLE;
\echo CHECK D.13.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;

RESET ROLE;
\echo CHECK D.14.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
-- product.rating = AVG(review.rating) по отзывам на блюдо
SELECT p.product_id, p.rating,
       (SELECT round(avg(r.rating), 2) FROM review r
        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id) AS expected
FROM product p
WHERE p.rating IS NOT NULL
LIMIT 20;

RESET ROLE;
\echo CHECK E.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT (SELECT restaurant_id FROM restaurant LIMIT 1) AS test_restaurant, (SELECT product_category_id FROM product_category LIMIT 1) AS test_category \gset
SELECT count(*) AS before FROM product;

CALL add_product(
    p_restaurant_id => :'test_restaurant'::uuid,
    p_product_category_id => :'test_category'::uuid,
    p_name => 'Тестовое блюдо',
    p_price => 250,
    p_rating => 4.5,
    p_status => 'доступно',
    p_description => 'Описание'
    -- + photo_url если есть
);

SELECT count(*) AS after FROM product;

RESET ROLE;
\echo CHECK E.5.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT * FROM get_statistic();

RESET ROLE;
\echo CHECK E.6.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
-- До
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;

CALL courier_salary();

-- После
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;
SELECT year, month, courier_id, amount, coefficient_used
FROM courier_pay
ORDER BY year DESC, month DESC, courier_id
LIMIT 20;

RESET ROLE;
\echo CHECK E.7.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);

RESET ROLE;
\echo CHECK F.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'kalugin_food'
  AND table_name = 'how_much_money'
ORDER BY ordinal_position;

RESET ROLE;
\echo CHECK F.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT * FROM how_much_money ORDER BY year_month;

RESET ROLE;
\echo CHECK F.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;

RESET ROLE;
\echo CHECK F.4.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission_diff,
       courier_pay,
       net_profit
FROM how_much_money
ORDER BY year_month
LIMIT 10;

RESET ROLE;
\echo CHECK G.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT
    nspname AS schema_name,
    has_schema_privilege('inspector', nspname, 'USAGE')  AS usage,
    has_schema_privilege('inspector', nspname, 'CREATE') AS create
FROM pg_namespace
WHERE nspname = 'kalugin_food';

RESET ROLE;
\echo CHECK G.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'kalugin_food'
GROUP BY table_name;

RESET ROLE;
\echo CHECK G.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'kalugin_food';
RESET ROLE;

RESET ROLE;
\echo CHECK G.4.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'kalugin_food';
RESET ROLE;

RESET ROLE;
\echo CHECK G.5.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
SET ROLE inspector;
SET search_path TO kalugin_food, exts;

CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT * FROM get_statistic();
SELECT * FROM how_much_money LIMIT 5;

RESET ROLE;

RESET ROLE;
\echo CHECK H.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS cnt,
       (SELECT coalesce(sum(commission), 0) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS commission_sum
FROM courier c;

RESET ROLE;
\echo CHECK H.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
EXPLAIN ANALYZE
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;

RESET ROLE;
\echo CHECK H.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
EXPLAIN ANALYZE SELECT * FROM get_statistic();

RESET ROLE;
\echo CHECK I.1.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL erase_test_data();

SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay;

RESET ROLE;
\echo CHECK I.2.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL erase_test_data();

RESET ROLE;
\echo CHECK I.3.
SET ROLE inspector; SET search_path TO kalugin_food, exts;
CALL insert_test_data(10);
SELECT count(*) FROM "order";

RESET ROLE;