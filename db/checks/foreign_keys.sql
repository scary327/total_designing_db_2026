\set ON_ERROR_STOP on
BEGIN;
SET ROLE inspector;
SET search_path TO kalugin_food, exts;
CALL erase_test_data();
CALL insert_test_data(10);
DO $$
DECLARE
 o_id uuid; c_id uuid; a_id uuid; r_id uuid; p_id uuid; cat_id uuid; k_id uuid;
 n_default integer; n_cascade integer;
BEGIN
 SELECT count(*) FILTER (WHERE confdeltype = 'a'), count(*) FILTER (WHERE confdeltype = 'c')
 INTO n_default, n_cascade FROM pg_constraint
 WHERE contype = 'f' AND connamespace = 'kalugin_food'::regnamespace;
 IF n_default <> 12 OR n_cascade <> 8 THEN RAISE EXCEPTION 'Unexpected foreign key actions: %, %', n_default, n_cascade; END IF;
 SELECT o.order_id, o.client_id, o.address_id, o.restaurant_id, o.courier_id, s.product_id, p.product_category_id
 INTO o_id, c_id, a_id, r_id, k_id, p_id, cat_id
 FROM "order" o JOIN order_structure s ON s.order_id = o.order_id JOIN product p ON p.product_id = s.product_id LIMIT 1;
 IF o_id IS NULL OR k_id IS NULL OR NOT EXISTS (SELECT FROM payment WHERE order_id = o_id) THEN RAISE EXCEPTION 'Missing test data'; END IF;
 BEGIN DELETE FROM client WHERE client_id=c_id; RAISE EXCEPTION 'Client deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM address WHERE address_id=a_id; RAISE EXCEPTION 'Address deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM client_address WHERE client_id=c_id AND address_id=a_id; RAISE EXCEPTION 'Client address deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM restaurant WHERE restaurant_id=r_id; RAISE EXCEPTION 'Restaurant deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM courier WHERE courier_id=k_id; RAISE EXCEPTION 'Courier deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM product WHERE product_id=p_id; RAISE EXCEPTION 'Product deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM product_category WHERE product_category_id=cat_id; RAISE EXCEPTION 'Category deletion was allowed'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
 DELETE FROM "order" WHERE order_id=o_id;
 IF EXISTS (SELECT FROM order_structure WHERE order_id=o_id) OR EXISTS (SELECT FROM payment WHERE order_id=o_id) OR EXISTS (SELECT FROM review WHERE order_id=o_id) THEN RAISE EXCEPTION 'Dependent order rows remain'; END IF;
 IF NOT EXISTS (SELECT FROM client WHERE client_id=c_id) OR NOT EXISTS (SELECT FROM product WHERE product_id=p_id) THEN RAISE EXCEPTION 'Unrelated rows deleted'; END IF;
 RAISE NOTICE 'Foreign key checks passed';
END $$;
ROLLBACK;
