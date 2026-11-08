-- FOOD-101. Таблицы и ограничения целостности.
-- Обоснование каждого ограничения — в db/constraints.md.

set search_path to kalugin_food;

-- ---------------------------------------------------------------------------
-- Адрес (BR-3.1 .. BR-3.5)
-- ---------------------------------------------------------------------------
create table address (
    address_id       uuid         not null default exts.uuid_generate_v4(),
    street           varchar(150) not null,
    house_number     varchar(10)  not null,
    apartment_office varchar(10),
    constraint address_pk primary key (address_id),
    constraint address_street_not_empty_chk check (street <> ''),
    constraint address_house_not_empty_chk check (house_number <> ''),
    constraint address_apartment_not_empty_chk check (apartment_office <> '')
);

-- ---------------------------------------------------------------------------
-- Клиент (BR-2.1 .. BR-2.6)
-- ---------------------------------------------------------------------------
create table client (
    client_id    uuid        not null default exts.uuid_generate_v4(),
    login        varchar(50) not null,
    password     char(32)    not null,
    phone_number char(12)    not null,
    constraint client_pk primary key (client_id),
    constraint client_login_uq unique (login),
    constraint client_phone_uq unique (phone_number),
    constraint client_login_not_empty_chk check (login <> ''),
    constraint client_password_md5_chk check (password ~ '^[0-9a-f]{32}$'),
    constraint client_phone_format_chk check (phone_number ~ '^\+7[0-9]{10}$')
);

-- ---------------------------------------------------------------------------
-- Адреса клиента, M:N (BR-2.4, BR-2.5)
-- ---------------------------------------------------------------------------
create table client_address (
    client_id  uuid not null,
    address_id uuid not null,
    constraint client_address_pk primary key (client_id, address_id),
    constraint client_address_client_fk foreign key (client_id)
        references client (client_id) on delete cascade,
    constraint client_address_address_fk foreign key (address_id)
        references address (address_id) on delete restrict
);

-- ---------------------------------------------------------------------------
-- Ресторан (BR-3.3, BR-4.1 .. BR-4.5)
-- ---------------------------------------------------------------------------
create table restaurant (
    restaurant_id   uuid              not null default exts.uuid_generate_v4(),
    restaurant_name varchar(100)      not null,
    address_id      uuid              not null,
    description     text              not null,
    work_start      time              not null,
    work_end        time              not null,
    company_details text              not null,
    rating          numeric(3, 2),
    status          restaurant_status not null default 'активен',
    constraint restaurant_pk primary key (restaurant_id),
    constraint restaurant_address_uq unique (address_id),
    constraint restaurant_address_fk foreign key (address_id)
        references address (address_id) on delete restrict,
    constraint restaurant_name_not_empty_chk check (restaurant_name <> ''),
    constraint restaurant_description_not_empty_chk check (description <> ''),
    constraint restaurant_details_not_empty_chk check (company_details <> ''),
    constraint restaurant_work_time_chk check (work_end > work_start),
    constraint restaurant_rating_chk check (rating between 0 and 5)
);

-- ---------------------------------------------------------------------------
-- Курьер (BR-6.1 .. BR-6.5)
-- ---------------------------------------------------------------------------
create table courier (
    courier_id     uuid           not null default exts.uuid_generate_v4(),
    fio            varchar(150)   not null,
    phone_number   char(12)       not null,
    status         courier_status not null default 'свободен',
    hire_date      date           not null,
    dismissal_date date,
    coefficient    numeric(2, 1)  not null default 0.1,
    constraint courier_pk primary key (courier_id),
    constraint courier_fio_not_empty_chk check (fio <> ''),
    constraint courier_phone_format_chk check (phone_number ~ '^\+7[0-9]{10}$'),
    constraint courier_coefficient_chk check (coefficient between 0.1 and 0.5),
    constraint courier_dismissed_has_date_chk
        check (status <> 'уволен' or dismissal_date is not null),
    constraint courier_dismissal_after_hire_chk check (dismissal_date >= hire_date)
);

-- ---------------------------------------------------------------------------
-- Выплаты курьерам (BR-10.1 .. BR-10.4)
-- ---------------------------------------------------------------------------
create table courier_pay (
    year             integer        not null,
    month            integer        not null,
    courier_id       uuid           not null,
    amount           numeric(12, 2) not null,
    coefficient_used numeric(2, 1)  not null,
    constraint courier_pay_pk primary key (year, month, courier_id),
    constraint courier_pay_courier_fk foreign key (courier_id)
        references courier (courier_id) on delete restrict,
    constraint courier_pay_month_chk check (month between 1 and 12),
    constraint courier_pay_amount_chk check (amount >= 0),
    constraint courier_pay_coefficient_chk check (coefficient_used between 0.1 and 0.5)
);

-- ---------------------------------------------------------------------------
-- Категория блюд — справочник (BR-5.7)
-- ---------------------------------------------------------------------------
create table product_category (
    product_category_id   uuid         not null default exts.uuid_generate_v4(),
    product_category_name varchar(100) not null,
    constraint product_category_pk primary key (product_category_id),
    constraint product_category_name_uq unique (product_category_name),
    constraint product_category_name_not_empty_chk check (product_category_name <> '')
);

-- ---------------------------------------------------------------------------
-- Блюдо (BR-5.1 .. BR-5.6)
-- ---------------------------------------------------------------------------
create table product (
    product_id          uuid           not null default exts.uuid_generate_v4(),
    product_name        varchar(100)   not null,
    product_category_id uuid           not null,
    price               numeric(10, 2) not null,
    restaurant_id       uuid           not null,
    photo_url           text,
    rating              numeric(3, 2),
    status              product_status not null default 'доступно',
    description         text           not null,
    constraint product_pk primary key (product_id),
    -- целевой ключ для составного FK из order_structure (BR-7.3)
    constraint product_restaurant_uq unique (product_id, restaurant_id),
    constraint product_category_fk foreign key (product_category_id)
        references product_category (product_category_id) on delete restrict,
    constraint product_restaurant_fk foreign key (restaurant_id)
        references restaurant (restaurant_id) on delete restrict,
    constraint product_name_not_empty_chk check (product_name <> ''),
    constraint product_description_not_empty_chk check (description <> ''),
    constraint product_photo_not_empty_chk check (photo_url <> ''),
    constraint product_price_chk check (price >= 0),
    constraint product_rating_chk check (rating between 0 and 5)
);

-- ---------------------------------------------------------------------------
-- Заказ (BR-7.1 .. BR-7.13). Имя в кавычках — order зарезервировано (BR-13.1).
-- commission и total_amount вычисляются из order_amount (BR-1.4, BR-7.10).
-- ---------------------------------------------------------------------------
create table "order" (
    order_id           uuid             not null default exts.uuid_generate_v4(),
    courier_id         uuid             not null,
    client_id          uuid             not null,
    address_id         uuid             not null,
    restaurant_id      uuid             not null,
    order_timestamp    timestamp        not null default localtimestamp,
    delivery_timestamp timestamp,
    order_amount       numeric(12, 2)   not null,
    commission         numeric(12, 2)   not null
        generated always as (round(order_amount * 0.10, 2)) stored,
    total_amount       numeric(12, 2)   not null
        generated always as (order_amount + round(order_amount * 0.10, 2)) stored,
    status             order_status     not null default 'создан',
    pay_status         order_pay_status not null default 'ожидает',
    description        text             not null,
    constraint order_pk primary key (order_id),
    -- целевые ключи для составных FK (BR-7.3, BR-8.4, BR-9.2)
    constraint order_restaurant_uq unique (order_id, restaurant_id),
    constraint order_client_uq unique (order_id, client_id),
    constraint order_total_uq unique (order_id, total_amount),
    constraint order_courier_fk foreign key (courier_id)
        references courier (courier_id) on delete restrict,
    constraint order_client_fk foreign key (client_id)
        references client (client_id) on delete restrict,
    constraint order_address_fk foreign key (address_id)
        references address (address_id) on delete restrict,
    constraint order_restaurant_fk foreign key (restaurant_id)
        references restaurant (restaurant_id) on delete restrict,
    -- адрес доставки — только один из адресов этого клиента (BR-7.4)
    constraint order_client_address_fk foreign key (client_id, address_id)
        references client_address (client_id, address_id) on delete restrict,
    constraint order_description_not_empty_chk check (description <> ''),
    constraint order_amount_positive_chk check (order_amount > 0),
    constraint order_total_min_chk check (total_amount >= 1000),
    constraint order_delivery_after_create_chk
        check (delivery_timestamp >= order_timestamp),
    constraint order_delivered_has_time_chk
        check (status <> 'доставлен' or delivery_timestamp is not null)
);

-- ---------------------------------------------------------------------------
-- Попытка оплаты (BR-8.1 .. BR-8.6)
-- ---------------------------------------------------------------------------
create table payment (
    payment_id            uuid           not null default exts.uuid_generate_v4(),
    order_id              uuid           not null,
    payment_type          payment_type   not null,
    amount                numeric(12, 2) not null,
    transaction_ref       varchar(64)    not null,
    transaction_timestamp timestamp      not null,
    status                payment_status not null,
    constraint payment_pk primary key (payment_id),
    constraint payment_transaction_uq unique (transaction_ref),
    constraint payment_order_fk foreign key (order_id)
        references "order" (order_id) on delete cascade,
    -- сумма попытки = общая сумма заказа (BR-8.4)
    constraint payment_order_amount_fk foreign key (order_id, amount)
        references "order" (order_id, total_amount) on delete cascade,
    constraint payment_transaction_not_empty_chk check (transaction_ref <> '')
);

-- не более одной успешной попытки на заказ (BR-8.1)
create unique index payment_one_success_uq
    on payment (order_id)
    where status = 'успех';

-- ---------------------------------------------------------------------------
-- Состав заказа (BR-7.3, BR-7.14 .. BR-7.16)
-- restaurant_id нужен для составных FK, гарантирующих BR-7.3.
-- ---------------------------------------------------------------------------
create table order_structure (
    order_id      uuid          not null,
    product_id    uuid          not null,
    restaurant_id uuid          not null,
    quantity      numeric(8, 3) not null,
    constraint order_structure_pk primary key (order_id, product_id),
    constraint order_structure_order_fk foreign key (order_id)
        references "order" (order_id) on delete cascade,
    constraint order_structure_product_fk foreign key (product_id)
        references product (product_id) on delete restrict,
    constraint order_structure_order_restaurant_fk foreign key (order_id, restaurant_id)
        references "order" (order_id, restaurant_id) on delete cascade,
    constraint order_structure_product_restaurant_fk foreign key (product_id, restaurant_id)
        references product (product_id, restaurant_id) on delete restrict,
    constraint order_structure_quantity_chk check (quantity > 0)
);

-- ---------------------------------------------------------------------------
-- Отзыв (BR-9.1 .. BR-9.5). entity_id — полиморфная ссылка,
-- проверяется триггером review_entity_check (03_triggers.sql).
-- ---------------------------------------------------------------------------
create table review (
    review_id        uuid               not null default exts.uuid_generate_v4(),
    client_id        uuid               not null,
    review_timestamp timestamp          not null default localtimestamp,
    entity_id        uuid               not null,
    entity_type      review_entity_type not null,
    order_id         uuid               not null,
    description      text               not null,
    photo_url        text,
    rating           numeric(1, 0)      not null,
    constraint review_pk primary key (review_id),
    constraint review_entity_uq unique (order_id, entity_type, entity_id),
    constraint review_client_fk foreign key (client_id)
        references client (client_id) on delete cascade,
    constraint review_order_fk foreign key (order_id)
        references "order" (order_id) on delete cascade,
    -- отзыв оставляет только клиент этого заказа (BR-9.2)
    constraint review_order_client_fk foreign key (order_id, client_id)
        references "order" (order_id, client_id) on delete cascade,
    constraint review_description_not_empty_chk check (description <> ''),
    constraint review_photo_not_empty_chk check (photo_url <> ''),
    constraint review_rating_chk check (rating between 1 and 5)
);

-- ---------------------------------------------------------------------------
-- Индексы на FK-столбцы, по которым идут выборки в процедурах и отчётах.
-- ---------------------------------------------------------------------------
create index order_courier_idx on "order" (courier_id);
create index order_restaurant_idx on "order" (restaurant_id);
create index order_status_ts_idx on "order" (status, order_timestamp);
create index product_restaurant_idx on product (restaurant_id);
create index order_structure_product_idx on order_structure (product_id);
create index review_entity_idx on review (entity_type, entity_id);
create index payment_order_idx on payment (order_id);
