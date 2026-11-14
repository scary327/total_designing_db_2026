-- FOOD-108. Отчёт «сколько денег» по месяцам (BR-11.9).
--
-- Серия месяцев от первого до последнего месяца с доставленными заказами
-- строится рекурсивным CTE, поэтому месяцы без заказов тоже попадают в
-- отчёт с нулевыми суммами. Месяц заказа — по order_timestamp (так же, как
-- в courier_salary и insert_test_data). Комиссия предыдущего месяца — LAG.

SET search_path TO kalugin_food;

CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE bounds AS (
    SELECT date_trunc('month', min(o.order_timestamp)) AS first_month,
           date_trunc('month', max(o.order_timestamp)) AS last_month
      FROM "order" o
     WHERE o.status = 'доставлен'
),
months (month_start) AS (
    SELECT b.first_month
      FROM bounds b
     WHERE b.first_month IS NOT NULL
    UNION ALL
    SELECT m.month_start + interval '1 month'
      FROM months m
      CROSS JOIN bounds b
     WHERE m.month_start < b.last_month
),
orders_by_month AS (
    SELECT date_trunc('month', o.order_timestamp) AS month_start,
           sum(o.order_amount)                    AS sum_no_commission,
           sum(o.total_amount)                    AS sum_with_commission
      FROM "order" o
     WHERE o.status = 'доставлен'
     GROUP BY 1
),
pay_by_month AS (
    SELECT make_date(cp.year, cp.month, 1)::timestamp AS month_start,
           sum(cp.amount)                             AS courier_pay
      FROM courier_pay cp
     GROUP BY 1
),
monthly AS (
    SELECT m.month_start,
           coalesce(obm.sum_no_commission, 0)   AS sum_no_commission,
           coalesce(obm.sum_with_commission, 0) AS sum_with_commission,
           coalesce(obm.sum_with_commission, 0)
             - coalesce(obm.sum_no_commission, 0) AS commission,
           coalesce(pbm.courier_pay, 0)         AS courier_pay
      FROM months m
      LEFT JOIN orders_by_month obm ON obm.month_start = m.month_start
      LEFT JOIN pay_by_month    pbm ON pbm.month_start = m.month_start
)
SELECT to_char(month_start, 'YYYY-MM')::text                           AS year_month,
       sum_no_commission::numeric                                      AS sum_no_commission,
       sum_with_commission::numeric                                    AS sum_with_commission,
       commission::numeric                                             AS commission,
       (lag(commission) OVER (ORDER BY month_start))::numeric          AS prev_commission,
       (commission - lag(commission) OVER (ORDER BY month_start))::numeric AS commission_diff,
       courier_pay::numeric                                            AS courier_pay,
       (commission - courier_pay)::numeric                             AS net_profit
  FROM monthly
 ORDER BY month_start;
