-- FOOD-101. Таблицы и ограничения целостности.
-- Обоснование каждого ограничения — в db/constraints.md.

SET search_path TO kalugin_food;

-- ---------------------------------------------------------------------------
-- Адрес (BR-3.1 .. BR-3.5)
-- ---------------------------------------------------------------------------
CREATE TABLE address (
    address_id       UUID         NOT NULL DEFAULT exts.uuid_generate_v4(),
    street           varchar(150) NOT NULL,
    house_number     varchar(10)  NOT NULL,
    apartment_office varchar(10),
    CONSTRAINT address_pk PRIMARY KEY (address_id),
    CONSTRAINT address_street_not_empty_chk CHECK (street <> ''),
    CONSTRAINT address_house_not_empty_chk CHECK (house_number <> ''),
    CONSTRAINT address_apartment_not_empty_chk CHECK (apartment_office <> '')
);

-- ---------------------------------------------------------------------------
-- Клиент (BR-2.1 .. BR-2.6)
-- ---------------------------------------------------------------------------
CREATE TABLE client (
    client_id    UUID        NOT NULL DEFAULT exts.uuid_generate_v4(),
    login        varchar(50) NOT NULL,
    password     char(32)    NOT NULL,
    phone_number char(12)    NOT NULL,
    CONSTRAINT client_pk PRIMARY KEY (client_id),
    CONSTRAINT client_login_uq UNIQUE (login),
    CONSTRAINT client_phone_uq UNIQUE (phone_number),
    CONSTRAINT client_login_not_empty_chk CHECK (login <> ''),
    CONSTRAINT client_password_md5_chk CHECK (password ~ '^[0-9a-f]{32}$'),
    CONSTRAINT client_phone_format_chk CHECK (phone_number ~ '^\+7[0-9]{10}$')
);

-- ---------------------------------------------------------------------------
-- Адреса клиента, M:N (BR-2.4, BR-2.5)
-- ---------------------------------------------------------------------------
CREATE TABLE client_address (
    client_id  UUID NOT NULL,
    address_id UUID NOT NULL,
    CONSTRAINT client_address_pk PRIMARY KEY (client_id, address_id),
    CONSTRAINT client_address_client_fk FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE CASCADE,
    CONSTRAINT client_address_address_fk FOREIGN KEY (address_id)
        REFERENCES address (address_id)
);

-- ---------------------------------------------------------------------------
-- Ресторан (BR-3.3, BR-4.1 .. BR-4.5)
-- ---------------------------------------------------------------------------
CREATE TABLE restaurant (
    restaurant_id   UUID              NOT NULL DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100)      NOT NULL,
    address_id      UUID              NOT NULL,
    description     text              NOT NULL,
    work_start      TIME              NOT NULL,
    work_end        TIME              NOT NULL,
    inn             varchar(12)       NOT NULL,
    ogrn            varchar(15)       NOT NULL,
    bank_account    varchar(20)       NOT NULL,
    rating          numeric(3, 2),
    status          restaurant_status NOT NULL DEFAULT 'активен',
    CONSTRAINT restaurant_pk PRIMARY KEY (restaurant_id),
    CONSTRAINT restaurant_address_uq UNIQUE (address_id),
    CONSTRAINT restaurant_address_fk FOREIGN KEY (address_id)
        REFERENCES address (address_id),
    CONSTRAINT restaurant_name_not_empty_chk CHECK (restaurant_name <> ''),
    CONSTRAINT restaurant_description_not_empty_chk CHECK (description <> ''),
    CONSTRAINT restaurant_inn_not_empty_chk CHECK (inn <> ''),
    CONSTRAINT restaurant_ogrn_not_empty_chk CHECK (ogrn <> ''),
    CONSTRAINT restaurant_bank_account_not_empty_chk CHECK (bank_account <> ''),
    CONSTRAINT restaurant_work_time_chk CHECK (work_end > work_start),
    CONSTRAINT restaurant_rating_chk CHECK (rating BETWEEN 0 AND 5)
);

-- ---------------------------------------------------------------------------
-- Курьер (BR-6.1 .. BR-6.5)
-- ---------------------------------------------------------------------------
CREATE TABLE courier (
    courier_id     UUID           NOT NULL DEFAULT exts.uuid_generate_v4(),
    last_name      varchar(50)    NOT NULL,
    first_name     varchar(50)    NOT NULL,
    middle_name    varchar(50)    NOT NULL,
    phone_number   char(12)       NOT NULL,
    status         courier_status NOT NULL DEFAULT 'свободен',
    hire_date      date           NOT NULL,
    dismissal_date date,
    coefficient    numeric(2, 1)  NOT NULL DEFAULT 0.1,
    CONSTRAINT courier_pk PRIMARY KEY (courier_id),
    CONSTRAINT courier_last_name_not_empty_chk CHECK (last_name <> ''),
    CONSTRAINT courier_first_name_not_empty_chk CHECK (first_name <> ''),
    CONSTRAINT courier_middle_name_not_empty_chk CHECK (middle_name <> ''),
    CONSTRAINT courier_phone_format_chk CHECK (phone_number ~ '^\+7[0-9]{10}$'),
    CONSTRAINT courier_coefficient_chk CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CONSTRAINT courier_dismissed_has_date_chk
        CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL),
    CONSTRAINT courier_dismissal_after_hire_chk CHECK (dismissal_date >= hire_date)
);

-- ---------------------------------------------------------------------------
-- Выплаты курьерам (BR-10.1 .. BR-10.4)
-- ---------------------------------------------------------------------------
CREATE TABLE courier_pay (
    YEAR             integer        NOT NULL,
    MONTH            integer        NOT NULL,
    courier_id       UUID           NOT NULL,
    amount           numeric(8, 2)  NOT NULL,
    coefficient_used numeric(2, 1)  NOT NULL,
    CONSTRAINT courier_pay_pk PRIMARY KEY (YEAR, MONTH, courier_id),
    CONSTRAINT courier_pay_courier_fk FOREIGN KEY (courier_id)
        REFERENCES courier (courier_id),
    CONSTRAINT courier_pay_month_chk CHECK (MONTH BETWEEN 1 AND 12),
    CONSTRAINT courier_pay_amount_chk CHECK (amount >= 0),
    CONSTRAINT courier_pay_coefficient_chk CHECK (coefficient_used BETWEEN 0.1 AND 0.5)
);

-- ---------------------------------------------------------------------------
-- Категория блюд — справочник (BR-5.7)
-- ---------------------------------------------------------------------------
CREATE TABLE product_category (
    product_category_id   UUID         NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL,
    CONSTRAINT product_category_pk PRIMARY KEY (product_category_id),
    CONSTRAINT product_category_name_uq UNIQUE (product_category_name),
    CONSTRAINT product_category_name_not_empty_chk CHECK (product_category_name <> '')
);

-- ---------------------------------------------------------------------------
-- Блюдо (BR-5.1 .. BR-5.6)
-- ---------------------------------------------------------------------------
CREATE TABLE product (
    product_id          UUID           NOT NULL DEFAULT exts.uuid_generate_v4(),
    product_name        varchar(100)   NOT NULL,
    product_category_id UUID           NOT NULL,
    price               numeric(7, 2)  NOT NULL,
    restaurant_id       UUID           NOT NULL,
    photo_url           text,
    rating              numeric(3, 2),
    status              product_status NOT NULL DEFAULT 'доступно',
    description         text           NOT NULL,
    CONSTRAINT product_pk PRIMARY KEY (product_id),
    -- целевой ключ для составного FK из order_structure (BR-7.3)
    CONSTRAINT product_restaurant_uq UNIQUE (product_id, restaurant_id),
    CONSTRAINT product_category_fk FOREIGN KEY (product_category_id)
        REFERENCES product_category (product_category_id),
    CONSTRAINT product_restaurant_fk FOREIGN KEY (restaurant_id)
        REFERENCES restaurant (restaurant_id),
    CONSTRAINT product_name_not_empty_chk CHECK (product_name <> ''),
    CONSTRAINT product_description_not_empty_chk CHECK (description <> ''),
    CONSTRAINT product_photo_not_empty_chk CHECK (photo_url <> ''),
    CONSTRAINT product_price_chk CHECK (price >= 0),
    CONSTRAINT product_rating_chk CHECK (rating BETWEEN 0 AND 5)
);

-- ---------------------------------------------------------------------------
-- Заказ (BR-7.1 .. BR-7.13). Имя в кавычках — order зарезервировано (BR-13.1).
-- commission и total_amount вычисляются из order_amount (BR-1.4, BR-7.10).
-- ---------------------------------------------------------------------------
CREATE TABLE "order" (
    order_id           UUID             NOT NULL DEFAULT exts.uuid_generate_v4(),
    courier_id         UUID             NOT NULL,
    client_id          UUID             NOT NULL,
    address_id         UUID             NOT NULL,
    restaurant_id      UUID             NOT NULL,
    order_timestamp    timestamp        NOT NULL DEFAULT LOCALTIMESTAMP,
    delivery_timestamp timestamp,
    order_amount       numeric(12, 2)   NOT NULL,
    commission         numeric(12, 2)   NOT NULL
        GENERATED always AS (round(order_amount * 0.10, 2)) stored,
    total_amount       numeric(12, 2)   NOT NULL
        GENERATED always AS (order_amount + round(order_amount * 0.10, 2)) stored,
    status             order_status     NOT NULL DEFAULT 'создан',
    pay_status         order_pay_status NOT NULL DEFAULT 'ожидает',
    description        text,
    CONSTRAINT order_pk PRIMARY KEY (order_id),
    -- целевые ключи для составных FK (BR-7.3, BR-8.4, BR-9.2)
    CONSTRAINT order_restaurant_uq UNIQUE (order_id, restaurant_id),
    CONSTRAINT order_client_uq UNIQUE (order_id, client_id),
    CONSTRAINT order_total_uq UNIQUE (order_id, total_amount),
    CONSTRAINT order_courier_fk FOREIGN KEY (courier_id)
        REFERENCES courier (courier_id),
    CONSTRAINT order_client_fk FOREIGN KEY (client_id)
        REFERENCES client (client_id),
    CONSTRAINT order_address_fk FOREIGN KEY (address_id)
        REFERENCES address (address_id),
    CONSTRAINT order_restaurant_fk FOREIGN KEY (restaurant_id)
        REFERENCES restaurant (restaurant_id),
    -- адрес доставки — только один из адресов этого клиента (BR-7.4)
    CONSTRAINT order_client_address_fk FOREIGN KEY (client_id, address_id)
        REFERENCES client_address (client_id, address_id),
    CONSTRAINT order_amount_positive_chk CHECK (order_amount > 0),
    CONSTRAINT order_total_min_chk CHECK (total_amount >= 1000),
    CONSTRAINT order_delivery_after_create_chk
        CHECK (delivery_timestamp >= order_timestamp),
    CONSTRAINT order_delivered_has_time_chk
        CHECK (status <> 'доставлен' OR delivery_timestamp IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- Попытка оплаты (BR-8.1 .. BR-8.6)
-- ---------------------------------------------------------------------------
CREATE TABLE payment (
    payment_id            UUID           NOT NULL DEFAULT exts.uuid_generate_v4(),
    order_id              UUID           NOT NULL,
    payment_type          payment_type   NOT NULL,
    amount                numeric(12, 2) NOT NULL,
    transaction_ref       varchar(64)    NOT NULL,
    transaction_timestamp timestamp      NOT NULL,
    status                payment_status NOT NULL,
    CONSTRAINT payment_pk PRIMARY KEY (payment_id),
    CONSTRAINT payment_transaction_uq UNIQUE (transaction_ref),
    CONSTRAINT payment_order_fk FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    -- сумма попытки = общая сумма заказа (BR-8.4)
    CONSTRAINT payment_order_amount_fk FOREIGN KEY (order_id, amount)
        REFERENCES "order" (order_id, total_amount) ON DELETE CASCADE,
    CONSTRAINT payment_transaction_not_empty_chk CHECK (transaction_ref <> '')
);

-- не более одной успешной попытки на заказ (BR-8.1)
CREATE UNIQUE INDEX payment_one_success_uq
    ON payment (order_id)
    WHERE status = 'успех';

-- ---------------------------------------------------------------------------
-- Состав заказа (BR-7.3, BR-7.14 .. BR-7.16)
-- restaurant_id нужен для составных FK, гарантирующих BR-7.3.
-- ---------------------------------------------------------------------------
CREATE TABLE order_structure (
    order_id      UUID          NOT NULL,
    product_id    UUID          NOT NULL,
    restaurant_id UUID          NOT NULL,
    quantity      numeric(8, 3) NOT NULL,
    CONSTRAINT order_structure_pk PRIMARY KEY (order_id, product_id),
    CONSTRAINT order_structure_order_fk FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    CONSTRAINT order_structure_product_fk FOREIGN KEY (product_id)
        REFERENCES product (product_id),
    CONSTRAINT order_structure_order_restaurant_fk FOREIGN KEY (order_id, restaurant_id)
        REFERENCES "order" (order_id, restaurant_id) ON DELETE CASCADE,
    CONSTRAINT order_structure_product_restaurant_fk FOREIGN KEY (product_id, restaurant_id)
        REFERENCES product (product_id, restaurant_id),
    CONSTRAINT order_structure_quantity_chk CHECK (quantity > 0)
);

-- ---------------------------------------------------------------------------
-- Отзыв (BR-9.1 .. BR-9.5). entity_id — полиморфная ссылка,
-- проверяется триггером review_entity_check (03_triggers.sql).
-- ---------------------------------------------------------------------------
CREATE TABLE review (
    review_id        UUID               NOT NULL DEFAULT exts.uuid_generate_v4(),
    client_id        UUID               NOT NULL,
    review_timestamp timestamp          NOT NULL DEFAULT LOCALTIMESTAMP,
    entity_id        UUID               NOT NULL,
    entity_type      review_entity_type NOT NULL,
    order_id         UUID               NOT NULL,
    description      text               NOT NULL,
    photo_url        text,
    rating           numeric(1, 0)      NOT NULL,
    CONSTRAINT review_pk PRIMARY KEY (review_id),
    CONSTRAINT review_entity_uq UNIQUE (order_id, entity_type, entity_id),
    CONSTRAINT review_client_fk FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE CASCADE,
    CONSTRAINT review_order_fk FOREIGN KEY (order_id)
        REFERENCES "order" (order_id) ON DELETE CASCADE,
    -- отзыв оставляет только клиент этого заказа (BR-9.2)
    CONSTRAINT review_order_client_fk FOREIGN KEY (order_id, client_id)
        REFERENCES "order" (order_id, client_id) ON DELETE CASCADE,
    CONSTRAINT review_description_not_empty_chk CHECK (description <> ''),
    CONSTRAINT review_photo_not_empty_chk CHECK (photo_url <> ''),
    CONSTRAINT review_rating_chk CHECK (rating BETWEEN 1 AND 5)
);

-- ---------------------------------------------------------------------------
-- Индексы на FK-столбцы, по которым идут выборки в процедурах и отчётах.
-- ---------------------------------------------------------------------------
CREATE INDEX order_courier_idx ON "order" (courier_id);
CREATE INDEX order_restaurant_idx ON "order" (restaurant_id);
CREATE INDEX order_status_ts_idx ON "order" (status, order_timestamp);
CREATE INDEX product_restaurant_idx ON product (restaurant_id);
CREATE INDEX order_structure_product_idx ON order_structure (product_id);
CREATE INDEX review_entity_idx ON review (entity_type, entity_id);
CREATE INDEX payment_order_idx ON payment (order_id);
