-- FOOD-104. Добавление блюда.
-- Принимает все атрибуты product, кроме product_id. Значение по умолчанию
-- генерирует product_id; ограничения таблицы проверяют входные данные.
-- Ошибки FK, CHECK и NOT NULL выдаёт PostgreSQL с именем ограничения.

SET search_path TO kalugin_food;

CREATE OR REPLACE PROCEDURE add_product(
    p_restaurant_id       UUID,
    p_product_category_id UUID,
    p_name                varchar,
    p_price               numeric,
    p_description         text,
    p_status              text    DEFAULT 'доступно',
    p_rating              numeric DEFAULT NULL,
    p_photo_url           text    DEFAULT NULL
)
LANGUAGE PLPGSQL
SET search_path = kalugin_food, exts
AS $$
BEGIN
    INSERT INTO product (product_name, product_category_id, price,
                         restaurant_id, photo_url, rating, status, description)
    VALUES (p_name, p_product_category_id, p_price,
            p_restaurant_id, p_photo_url, p_rating, p_status::product_status,
            p_description);
END;
$$;
