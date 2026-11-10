-- FOOD-108. Отчёт «сколько денег» по месяцам (BR-11.9).
--
-- Серия месяцев от первого до последнего месяца с доставленными заказами
-- строится рекурсивным CTE, поэтому месяцы без заказов тоже попадают в
-- отчёт с нулевыми суммами. Месяц заказа — по order_timestamp (так же, как
-- в courier_salary и insert_test_data). Комиссия предыдущего месяца — LAG.

set search_path to kalugin_food;

create or replace view how_much_money as
with recursive bounds as (
    select date_trunc('month', min(o.order_timestamp)) as first_month,
           date_trunc('month', max(o.order_timestamp)) as last_month
      from "order" o
     where o.status = 'доставлен'
),
months (month_start) as (
    select b.first_month
      from bounds b
     where b.first_month is not null
    union all
    select m.month_start + interval '1 month'
      from months m
      cross join bounds b
     where m.month_start < b.last_month
),
orders_by_month as (
    select date_trunc('month', o.order_timestamp) as month_start,
           sum(o.order_amount)                    as sum_no_commission,
           sum(o.total_amount)                    as sum_with_commission
      from "order" o
     where o.status = 'доставлен'
     group by 1
),
pay_by_month as (
    select make_date(cp.year, cp.month, 1)::timestamp as month_start,
           sum(cp.amount)                             as courier_pay
      from courier_pay cp
     group by 1
),
monthly as (
    select m.month_start,
           coalesce(obm.sum_no_commission, 0)   as sum_no_commission,
           coalesce(obm.sum_with_commission, 0) as sum_with_commission,
           coalesce(obm.sum_with_commission, 0)
             - coalesce(obm.sum_no_commission, 0) as commission,
           coalesce(pbm.courier_pay, 0)         as courier_pay
      from months m
      left join orders_by_month obm on obm.month_start = m.month_start
      left join pay_by_month    pbm on pbm.month_start = m.month_start
)
select to_char(month_start, 'YYYY-MM')::text                           as year_month,
       sum_no_commission::numeric                                      as sum_no_commission,
       sum_with_commission::numeric                                    as sum_with_commission,
       commission::numeric                                             as commission,
       (lag(commission) over (order by month_start))::numeric          as prev_commission,
       (commission - lag(commission) over (order by month_start))::numeric as commission_diff,
       courier_pay::numeric                                            as courier_pay,
       (commission - courier_pay)::numeric                             as net_profit
  from monthly
 order by month_start;
