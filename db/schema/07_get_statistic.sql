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

SET search_path TO kalugin_food;

CREATE OR REPLACE FUNCTION get_statistic()
RETURNS TABLE (
    restaurant_name   varchar,
    best_product_name varchar,
    total_amount      numeric,
    avg_amount        numeric,
    best_user         varchar
)
LANGUAGE SQL
VOLATILE
SET search_path = kalugin_food, exts
AS $$
    WITH delivered AS MATERIALIZED (
        SELECT o.order_id,
               o.restaurant_id,
               o.client_id,
               o.total_amount
          FROM "order" o
         WHERE o.status = 'доставлен'
    ),
    rest_money AS (
        SELECT d.restaurant_id,
               sum(d.total_amount)           AS sum_total,
               round(avg(d.total_amount), 2) AS avg_total
          FROM delivered d
         GROUP BY d.restaurant_id
    ),
    client_orders AS (
        SELECT d.restaurant_id,
               c.login,
               count(*) AS orders_cnt
          FROM delivered d
          JOIN client c ON c.client_id = d.client_id
         GROUP BY d.restaurant_id, c.client_id, c.login
    ),
    best_client AS (
        SELECT co.restaurant_id,
               (array_agg(co.login ORDER BY co.orders_cnt DESC, random()))[1] AS login
          FROM client_orders co
         GROUP BY co.restaurant_id
    ),
    product_qty AS (
        SELECT d.restaurant_id,
               p.product_name,
               sum(os.quantity) AS qty
          FROM delivered d
          JOIN order_structure os ON os.order_id = d.order_id
          JOIN product p ON p.product_id = os.product_id
         GROUP BY d.restaurant_id, p.product_id, p.product_name
    ),
    best_product AS (
        SELECT pq.restaurant_id,
               (array_agg(pq.product_name ORDER BY pq.qty DESC, random()))[1] AS product_name
          FROM product_qty pq
         GROUP BY pq.restaurant_id
    )
    SELECT r.restaurant_name,
           bp.product_name,
           coalesce(rm.sum_total, 0),
           coalesce(rm.avg_total, 0),
           bc.login
      FROM restaurant r
      LEFT JOIN rest_money   rm ON rm.restaurant_id = r.restaurant_id
      LEFT JOIN best_product bp ON bp.restaurant_id = r.restaurant_id
      LEFT JOIN best_client  bc ON bc.restaurant_id = r.restaurant_id
     ORDER BY r.restaurant_name;
$$;
