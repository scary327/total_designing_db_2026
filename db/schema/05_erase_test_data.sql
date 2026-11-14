-- FOOD-103. Удаление всех тестовых данных.
-- TRUNCATE одним оператором по всем таблицам схемы снимает вопрос порядка
-- удаления по FK. Типы, функции, процедуры, триггеры и представления не
-- затрагиваются. Повторный вызов на пустых таблицах не падает.

SET search_path TO kalugin_food;

CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
BEGIN
    TRUNCATE TABLE review,
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
END;
$$;
