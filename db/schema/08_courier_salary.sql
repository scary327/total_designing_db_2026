-- FOOD-107. Зарплата курьеров за текущий месяц (BR-10.2 .. BR-10.6).
--
-- Для каждого курьера, работавшего в текущем месяце (не уволен или уволен
-- в этом месяце):
--   1. число и сумма комиссий доставленных заказов за месяц (по дате заказа);
--   2. зарплата = коэффициент текущего месяца × сумма комиссий;
--   3. запись в courier_pay; повторный вызов обновляет её (BR-10.3);
--   4. новый коэффициент на следующий месяц: 0–150 → 0.1, 151–250 → 0.2,
--      251–500 → 0.3, > 500 → 0.5; уволенным не назначается (BR-10.6).
--
-- Коэффициент текущего месяца: если запись за месяц уже есть, берётся
-- coefficient_used из неё — после первого вызова courier.coefficient уже
-- содержит коэффициент следующего месяца, и повторный вызов не должен
-- пересчитать зарплату по нему.

SET search_path TO kalugin_food;

CREATE OR REPLACE PROCEDURE courier_salary()
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
DECLARE
    v_month_start timestamp := date_trunc('month', LOCALTIMESTAMP);
    v_year        integer   := extract(YEAR FROM v_month_start)::int;
    v_month       integer   := extract(MONTH FROM v_month_start)::int;
BEGIN
    WITH stats AS (
        SELECT c.courier_id,
               c.status,
               coalesce(cp.coefficient_used, c.coefficient) AS coef_used,
               count(o.order_id)                            AS delivered_cnt,
               coalesce(sum(o.commission), 0)               AS commission_sum
          FROM courier c
          LEFT JOIN courier_pay cp
                 ON cp.courier_id = c.courier_id
                AND cp.year = v_year
                AND cp.month = v_month
          LEFT JOIN "order" o
                 ON o.courier_id = c.courier_id
                AND o.status = 'доставлен'
                AND o.order_timestamp >= v_month_start
                AND o.order_timestamp <  v_month_start + interval '1 month'
         WHERE c.dismissal_date IS NULL
            OR c.dismissal_date >= v_month_start::date
         GROUP BY c.courier_id, c.status, cp.coefficient_used, c.coefficient
    ),
    pay AS (
        INSERT INTO courier_pay AS cp (YEAR, MONTH, courier_id, amount, coefficient_used)
        SELECT v_year, v_month, s.courier_id,
               round(s.coef_used * s.commission_sum, 2),
               s.coef_used
          FROM stats s
        ON CONFLICT (YEAR, MONTH, courier_id) DO UPDATE
           SET amount           = excluded.amount,
               coefficient_used = excluded.coefficient_used
    )
    UPDATE courier c
       SET coefficient = CASE
                             WHEN s.delivered_cnt > 500 THEN 0.5
                             WHEN s.delivered_cnt > 250 THEN 0.3
                             WHEN s.delivered_cnt > 150 THEN 0.2
                             ELSE 0.1
                         END
      FROM stats s
     WHERE s.courier_id = c.courier_id
       AND s.status <> 'уволен';
END;
$$;
