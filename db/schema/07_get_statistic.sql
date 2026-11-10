-- FOOD-106. Статистика по ресторанам.
-- Имена колонок результата — контракт бэкенда (BR-13.2).
--
-- Оптимизация (BR-11.8):
--   * доставленные заказы читаются из "order" один раз (MATERIALIZED CTE)
--     и переиспользуются во всех агрегатах;
--   * каждая таблица (restaurant, client, order_structure, product)
--     сканируется один раз, только через JOIN, без коррелированных подзапросов;
--   * «лучшее» значение выбирается обычным агрегатом
--     (array_agg ... order by ...)[1], без оконных функций;
--     при равенстве — случайный выбор (random() вторым ключом сортировки).
--
-- best_user — логин клиента: ФИО клиента не хранится (BR-2.6).

set search_path to kalugin_food;

create or replace function get_statistic()
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
        select co.restaurant_id,
               (array_agg(co.login order by co.orders_cnt desc, random()))[1] as login
          from client_orders co
         group by co.restaurant_id
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
        select pq.restaurant_id,
               (array_agg(pq.product_name order by pq.qty desc, random()))[1] as product_name
          from product_qty pq
         group by pq.restaurant_id
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
