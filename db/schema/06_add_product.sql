-- FOOD-104. Добавление блюда.
-- Принимает все атрибуты product, кроме product_id (генерируется через
-- exts.uuid_generate_v4()). Перед вставкой проверяет входные данные и
-- падает с понятным сообщением; ограничения таблицы остаются последней
-- линией защиты.

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
language plpgsql
set search_path = kalugin_food, exts
as $$
declare
    v_product_id uuid := exts.uuid_generate_v4();
begin
    if p_restaurant_id is null
       or not exists (select 1 from restaurant where restaurant_id = p_restaurant_id) then
        raise exception 'add_product: ресторан с id % не существует', p_restaurant_id
            using errcode = 'foreign_key_violation';
    end if;

    if p_product_category_id is null
       or not exists (select 1 from product_category
                       where product_category_id = p_product_category_id) then
        raise exception 'add_product: категория блюд с id % не существует', p_product_category_id
            using errcode = 'foreign_key_violation';
    end if;

    if p_name is null or p_name = '' then
        raise exception 'add_product: название блюда обязательно (BR-5.2)'
            using errcode = 'check_violation';
    end if;

    if length(p_name) > 100 then
        raise exception 'add_product: название блюда длиннее 100 символов'
            using errcode = 'check_violation';
    end if;

    if p_price is null or p_price < 0 then
        raise exception 'add_product: цена должна быть неотрицательной (BR-5.3), передано %', p_price
            using errcode = 'check_violation';
    end if;

    if p_rating is not null and (p_rating < 0 or p_rating > 5) then
        raise exception 'add_product: рейтинг должен быть от 0 до 5 (BR-5.4), передано %', p_rating
            using errcode = 'check_violation';
    end if;

    if p_status is null
       or not (p_status = any (enum_range(null::product_status)::text[])) then
        raise exception 'add_product: недопустимый статус блюда "%", допустимо: % (BR-5.5)',
            p_status, enum_range(null::product_status)
            using errcode = 'check_violation';
    end if;

    if p_description is null or p_description = '' then
        raise exception 'add_product: описание блюда обязательно (BR-5.2)'
            using errcode = 'check_violation';
    end if;

    if p_photo_url = '' then
        raise exception 'add_product: ссылка на фото не может быть пустой строкой, передайте NULL (BR-5.6)'
            using errcode = 'check_violation';
    end if;

    insert into product (product_id, product_name, product_category_id, price,
                         restaurant_id, photo_url, rating, status, description)
    values (v_product_id, p_name, p_product_category_id, p_price,
            p_restaurant_id, p_photo_url, round(p_rating, 2), p_status::product_status,
            p_description);

    raise notice 'add_product: добавлено блюдо %', v_product_id;
end;
$$;
