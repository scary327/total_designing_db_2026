-- ВНИМАНИЕ: удаляет тестовые данные; выполнять только в отдельной тестовой БД.
\set ON_ERROR_STOP on
SET ROLE inspector;
SET search_path TO kalugin_food, exts;
CALL erase_test_data();
CALL erase_test_data();
CALL insert_test_data(10);
CALL insert_test_data(10);
DO $$
DECLARE t text; n bigint; bad bigint; r uuid; c uuid; before_n bigint; v_product uuid; old_rating numeric;
BEGIN
 FOREACH t IN ARRAY ARRAY['client','courier','restaurant','product_category'] LOOP
  EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
  IF n <> 20 THEN RAISE EXCEPTION '%: % instead of 20',t,n; END IF;
 END LOOP;
 FOREACH t IN ARRAY ARRAY['address','product','order','review','payment'] LOOP
  EXECUTE format('SELECT count(*) FROM %I', t) INTO n;
  IF n <> 100 THEN RAISE EXCEPTION '%: % instead of 100',t,n; END IF;
 END LOOP;
 SELECT count(*) INTO bad FROM "order" o WHERE o.order_amount<1000 OR o.total_amount<1000 OR o.total_amount<>o.order_amount+round(o.order_amount*0.1,2);
 IF bad>0 THEN RAISE EXCEPTION 'order amounts: %',bad; END IF;
 SELECT count(*) INTO n FROM (SELECT DISTINCT pay_status FROM "order") statuses;
 IF n <> 3 THEN RAISE EXCEPTION 'expected 3 payment statuses, got %',n; END IF;
 SELECT count(*) INTO bad FROM "order" o JOIN payment p ON p.order_id=o.order_id
 WHERE p.amount<>o.total_amount OR o.pay_status <> CASE p.status WHEN 'успех' THEN 'оплачен'::order_pay_status WHEN 'ошибка' THEN 'ошибка'::order_pay_status ELSE 'ожидает'::order_pay_status END OR (o.status='доставлен' AND p.status<>'успех');
 IF bad>0 THEN RAISE EXCEPTION 'inconsistent payments: %',bad; END IF;
 UPDATE "order" SET description=NULL WHERE order_id=(SELECT order_id FROM "order" LIMIT 1);
 UPDATE "order" SET description='' WHERE order_id=(SELECT order_id FROM "order" LIMIT 1);
 SELECT restaurant_id INTO r FROM restaurant LIMIT 1;
 SELECT product_category_id INTO c FROM product_category LIMIT 1;
 SELECT count(*) INTO before_n FROM product;
 CALL add_product(r,c,'Тестовое блюдо',100,'Описание');
 IF (SELECT count(*) FROM product)<>before_n+1 THEN RAISE EXCEPTION 'add product did not insert'; END IF;
 BEGIN CALL add_product(r,c,'Тест',-1,'Описание'); RAISE EXCEPTION 'negative price accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN CALL add_product('00000000-0000-0000-0000-000000000000'::uuid,c,'Тест',100,'Описание'); RAISE EXCEPTION 'invalid restaurant accepted'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 SELECT product_id INTO v_product FROM product WHERE rating IS NOT NULL LIMIT 1;
 IF v_product IS NULL THEN RAISE EXCEPTION 'no rated product for trigger test'; END IF;
 SELECT rating INTO old_rating FROM product WHERE product_id=v_product;
 UPDATE review SET rating=CASE WHEN rating=1 THEN 5 ELSE 1 END WHERE review_id=(SELECT review_id FROM review WHERE entity_type='блюдо' AND entity_id=v_product LIMIT 1);
 SELECT count(*) INTO bad FROM product p WHERE p.product_id=v_product AND p.rating IS DISTINCT FROM (SELECT round(avg(r.rating),2) FROM review r WHERE r.entity_type='блюдо' AND r.entity_id=v_product);
 IF bad>0 THEN RAISE EXCEPTION 'review rating update failed'; END IF;
 CALL courier_salary(); CALL courier_salary();
 IF (SELECT count(*) FROM get_statistic())<>(SELECT count(*) FROM restaurant) THEN RAISE EXCEPTION 'incorrect restaurant count'; END IF;
 RAISE NOTICE 'Functional checks passed';
END $$;
SELECT pay_status, count(*) FROM "order" GROUP BY pay_status ORDER BY pay_status;
