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

set search_path to kalugin_food;

create or replace procedure courier_salary()
set search_path = kalugin_food, exts
as $$
declare
    v_month_start timestamp = date_trunc('month', localtimestamp);
    v_year        integer   = extract(year from v_month_start)::int;
    v_month       integer   = extract(month from v_month_start)::int;
begin
    with stats as (
        select c.courier_id,
               c.status,
               coalesce(cp.coefficient_used, c.coefficient) as coef_used,
               count(o.order_id)                            as delivered_cnt,
               coalesce(sum(o.commission), 0)               as commission_sum
          from courier c
          left join courier_pay cp
                 on cp.courier_id = c.courier_id
                and cp.year = v_year
                and cp.month = v_month
          left join "order" o
                 on o.courier_id = c.courier_id
                and o.status = 'доставлен'
                and o.order_timestamp >= v_month_start
                and o.order_timestamp <  v_month_start + interval '1 month'
         where c.hire_date < (v_month_start + interval '1 month')::date
           and (c.dismissal_date is null
                or c.dismissal_date >= v_month_start::date)
         group by c.courier_id, c.status, cp.coefficient_used, c.coefficient
    ),
    pay as (
        insert into courier_pay as cp (year, month, courier_id, amount, coefficient_used)
        select v_year, v_month, s.courier_id,
               round(s.coef_used * s.commission_sum, 2),
               s.coef_used
          from stats s
        on conflict (year, month, courier_id) do update
           set amount           = excluded.amount,
               coefficient_used = excluded.coefficient_used
    )
    update courier c
       set coefficient = case
                             when s.delivered_cnt > 500 then 0.5
                             when s.delivered_cnt > 250 then 0.3
                             when s.delivered_cnt > 150 then 0.2
                             else 0.1
                         end
      from stats s
     where s.courier_id = c.courier_id
       and s.status <> 'уволен';
end;
$$ language plpgsql;
