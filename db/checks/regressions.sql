-- Проверки бизнес-ограничений в откатываемой транзакции; только тестовая БД.
\set ON_ERROR_STOP on
begin;
set role inspector;
set search_path to kalugin_food, exts;
call erase_test_data();
call insert_test_data(20);

do $$
declare
    order_key uuid;
    product_key uuid;
    foreign_product uuid;
    foreign_restaurant uuid;
    review_key uuid;
    payment_key uuid;
    name_key uuid;
    unpaid_order uuid;
begin
    if exists (select 1 from information_schema.columns
               where table_schema='kalugin_food' and table_name='order_structure'
                 and column_name='restaurant_id') then
        raise exception 'Redundant restaurant in order_structure';
    end if;
    select s.order_id, s.product_id into order_key, product_key
    from order_structure s limit 1;
    select p.product_id, p.restaurant_id into foreign_product, foreign_restaurant
    from product p join "order" o on o.order_id=order_key
    where p.restaurant_id<>o.restaurant_id limit 1;
    if foreign_product is null then raise exception 'Missing second restaurant'; end if;

    begin
        insert into order_structure values (order_key, foreign_product, 1);
        raise exception 'Mixed restaurants accepted';
    exception when check_violation then null; end;
    begin
        update "order" set restaurant_id=foreign_restaurant where order_id=order_key;
        raise exception 'Order restaurant change accepted';
    exception when check_violation then null; end;
    begin
        update product set restaurant_id=foreign_restaurant where product_id=product_key;
        raise exception 'Product restaurant change accepted';
    exception when check_violation then null; end;

    select r.review_id,r.entity_id into review_key,product_key
    from review r where entity_type='блюдо' limit 1;
    if review_key is null then raise exception 'Missing product review'; end if;
    perform set_config('kalugin_food.skip_rating','on',true);
    update review set rating=case when rating=1 then 5 else 1 end where review_id=review_key;
    if exists (select 1 from product p where p.product_id=product_key
       and p.rating is distinct from (select round(avg(r.rating),2) from review r
                                     where r.entity_type='блюдо' and r.entity_id=product_key)) then
        raise exception 'Rating update bypassed';
    end if;
    -- Массовый оператор также пересчитывает каждый затронутый объект.
    update review set rating=case when rating=5 then 1 else rating+1 end;
    if exists (select 1 from product p where p.rating is distinct from
        (select round(avg(r.rating),2) from review r where r.entity_type='блюдо' and r.entity_id=p.product_id))
       or exists (select 1 from restaurant rs where rs.rating is distinct from
        (select round(avg(r.rating),2) from review r where r.entity_type='ресторан' and r.entity_id=rs.restaurant_id)) then
        raise exception 'Bulk rating update failed';
    end if;

    select p.payment_id,p.order_id into payment_key,order_key
    from payment p join "order" o using(order_id)
    where o.status='доставлен' and p.status='успех' limit 1;
    if payment_key is null then raise exception 'Missing paid delivered order'; end if;
    begin
        update payment set status='ошибка' where payment_id=payment_key;
        set constraints all immediate;
        raise exception 'Delivered order without payment accepted';
    exception when check_violation then null; end;
    begin
        delete from payment where payment_id=payment_key;
        set constraints all immediate;
        raise exception 'Successful payment deletion accepted';
    exception when check_violation then null; end;
    begin
        insert into payment(order_id,payment_type,amount,transaction_ref,transaction_timestamp,status)
        select order_id,payment_type,amount,md5(random()::text),transaction_timestamp,'успех'
        from payment where payment_id=payment_key;
        raise exception 'Duplicate successful payment accepted';
    exception when unique_violation then null; end;
    insert into "order"(courier_id,client_id,address_id,restaurant_id,order_amount,status)
    select courier_id,client_id,address_id,restaurant_id,order_amount,'создан'
    from "order" where order_id=order_key returning order_id into unpaid_order;
    begin
        update "order" set status='доставлен', delivery_timestamp=localtimestamp
        where order_id=unpaid_order;
        set constraints all immediate;
        raise exception 'Unpaid order marked delivered';
    exception when check_violation then null; end;
    delete from "order" where order_id=unpaid_order;
    update payment set status='ошибка' where payment_id=payment_key;
    insert into payment(order_id,payment_type,amount,transaction_ref,transaction_timestamp,status)
    select order_id,payment_type,amount,md5(random()::text),transaction_timestamp,'успех'
    from payment where payment_id=payment_key;
    set constraints all immediate;
    set constraints all deferred;

    -- Столбцы принимают граничную длину; формула генератора использует 1..50.
    select courier_id into name_key from courier limit 1;
    update courier set last_name=repeat('а',50), first_name='а', middle_name=repeat('б',50)
    where courier_id=name_key;
    if (select length(last_name) from courier where courier_id=name_key)<>50 then
        raise exception 'Name length boundary failed';
    end if;
    raise notice 'Regression checks passed';
end;
$$;
set constraints all immediate;
rollback;
