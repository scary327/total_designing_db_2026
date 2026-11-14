-- Только для отдельной тестовой БД: создаёт вспомогательную функцию.
-- Альтернативный вариант: MAX + JOIN + DISTINCT ON для сравнения времени.

set search_path to kalugin_food;

create or replace function benchmark_statistic_alt()
returns table (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
language sql
volatile
set search_path = kalugin_food, exts
as $$
    with delivered as materialized (
        select o.order_id,
               o.restaurant_id,
               o.client_id,
               o.total_amount
          from "order" o
         where o.status = 'доставлен'
    ),
    rest_money as (
        select d.restaurant_id,
               sum(d.total_amount)           as sum_total,
               round(avg(d.total_amount), 2) as avg_total
          from delivered d
         group by d.restaurant_id
    ),
    client_orders as (
        select d.restaurant_id,
               c.login,
               count(*) as orders_cnt
          from delivered d
          join client c on c.client_id = d.client_id
         group by d.restaurant_id, c.client_id, c.login
    ),
    best_client as (
        select distinct on (co.restaurant_id) co.restaurant_id, co.login
        from client_orders co
        join (select restaurant_id, max(orders_cnt) as max_count
                from client_orders group by restaurant_id) maxima
          on maxima.restaurant_id = co.restaurant_id and maxima.max_count = co.orders_cnt
        order by co.restaurant_id, random()
    ),
    product_qty as (
        select d.restaurant_id,
               p.product_name,
               sum(os.quantity) as qty
          from delivered d
          join order_structure os on os.order_id = d.order_id
          join product p on p.product_id = os.product_id
         group by d.restaurant_id, p.product_id, p.product_name
    ),
    best_product as (
        select distinct on (pq.restaurant_id) pq.restaurant_id, pq.product_name
        from product_qty pq
        join (select restaurant_id, max(qty) as max_qty
                from product_qty group by restaurant_id) maxima
          on maxima.restaurant_id = pq.restaurant_id and maxima.max_qty = pq.qty
        order by pq.restaurant_id, random()
    )
    select r.restaurant_name,
           bp.product_name,
           coalesce(rm.sum_total, 0),
           coalesce(rm.avg_total, 0),
           bc.login
      from restaurant r
      left join rest_money   rm on rm.restaurant_id = r.restaurant_id
      left join best_product bp on bp.restaurant_id = r.restaurant_id
      left join best_client  bc on bc.restaurant_id = r.restaurant_id
     order by r.restaurant_name;
$$;
