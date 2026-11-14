-- FOOD-104. Добавление блюда.
-- Принимает все атрибуты product, кроме product_id. Значение по умолчанию
-- генерирует product_id; ограничения таблицы проверяют входные данные.
-- Ошибки FK, CHECK и NOT NULL выдаёт PostgreSQL с именем ограничения.

set search_path to kalugin_food;

create or replace procedure add_product(
    p_restaurant_id       uuid,
    p_product_category_id uuid,
    p_name                varchar,
    p_price               numeric,
    p_description         text,
    p_status              text    default 'доступно',
    p_rating              numeric default null,
    p_photo_url           text    default null
)
set search_path = kalugin_food, exts
as $$
begin
    insert into product (product_name, product_category_id, price,
                         restaurant_id, photo_url, rating, status, description)
    values (p_name, p_product_category_id, p_price,
            p_restaurant_id, p_photo_url, p_rating, p_status::product_status,
            p_description);
end;
$$ language plpgsql;
