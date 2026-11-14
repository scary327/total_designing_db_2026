-- Только отдельная тестовая БД; все изменения откатываются.
\set ON_ERROR_STOP on
begin;
set role inspector;
set search_path to kalugin_food, exts;
call erase_test_data();
call insert_test_data(10);
create temporary table salary_cases on commit drop as
select i, exts.uuid_generate_v4() as courier_id,
       (array[0,150,151,250,251,500,501,1])[i] as deliveries,
       (array[0.1,0.1,0.2,0.2,0.3,0.3,0.5,0.3])[i] as expected_coefficient
from generate_series(1,8) i;
insert into courier(courier_id,last_name,first_name,middle_name,phone_number,status,hire_date,dismissal_date,coefficient)
select courier_id,'Фамилия','Имя','Отчество','+70000000000',
       case when i=8 then 'уволен'::courier_status else 'свободен'::courier_status end,
       date_trunc('month',current_date)::date,
       case when i=8 then current_date end,0.3
from salary_cases;
create temporary table salary_orders on commit drop as
select exts.uuid_generate_v4() as order_id, c.courier_id,
       template.client_id,template.address_id,template.restaurant_id,template.product_id
from salary_cases c cross join lateral generate_series(1,c.deliveries) g
cross join (select o.client_id,o.address_id,o.restaurant_id,p.product_id
            from "order" o join product p using(restaurant_id) limit 1) template;
insert into "order"(order_id,courier_id,client_id,address_id,restaurant_id,order_timestamp,delivery_timestamp,order_amount,status)
select order_id,courier_id,client_id,address_id,restaurant_id,localtimestamp,localtimestamp,1000,'доставлен'
from salary_orders;
insert into order_structure select order_id,product_id,1 from salary_orders;
insert into payment(order_id,payment_type,amount,transaction_ref,transaction_timestamp,status)
select order_id,'карта',1100,order_id::text,localtimestamp,'успех' from salary_orders;
insert into courier(last_name,first_name,middle_name,phone_number,hire_date,coefficient)
values ('Будущий','Новый','Курьер','+70000000001',(date_trunc('month',current_date)+interval '1 month')::date,0.1);
call courier_salary();
call courier_salary();
do $$
begin
    if exists (select 1 from salary_cases t join courier c using(courier_id)
               join courier_pay p using(courier_id)
               where p.year=extract(year from current_date) and p.month=extract(month from current_date)
                 and (p.amount<>t.deliveries*30 or p.coefficient_used<>0.3
                      or c.coefficient<>t.expected_coefficient)) then
        raise exception 'Salary amount, coefficient or repeated calculation mismatch';
    end if;
    if (select count(*) from courier_pay p join salary_cases c using(courier_id)
        where p.year=extract(year from current_date) and p.month=extract(month from current_date))<>8 then
        raise exception 'Missing salary case';
    end if;
    if exists (select 1 from courier_pay p join courier c using(courier_id)
               where c.hire_date>current_date) then
        raise exception 'Future employee received salary';
    end if;
    raise notice 'Salary boundary checks passed';
end;
$$;
set constraints all immediate;
rollback;
