-- FOOD-103. Удаление всех тестовых данных.
-- TRUNCATE одним оператором по всем таблицам схемы снимает вопрос порядка
-- удаления по FK. Типы, функции, процедуры, триггеры и представления не
-- затрагиваются. Повторный вызов на пустых таблицах не падает.

set search_path to kalugin_food;

create or replace procedure erase_test_data()
language plpgsql
set search_path = kalugin_food, exts
as $$
begin
    truncate table review,
                   payment,
                   order_structure,
                   "order",
                   courier_pay,
                   product,
                   product_category,
                   client_address,
                   restaurant,
                   client,
                   courier,
                   address;
end;
$$;
