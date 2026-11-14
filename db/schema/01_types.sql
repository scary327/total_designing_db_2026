-- FOOD-101. Перечислимые типы (BR-11.5: только enum, не varchar).

SET search_path TO kalugin_food;

-- BR-4.3
CREATE TYPE restaurant_status AS ENUM ('активен', 'неактивен');

-- BR-5.5
CREATE TYPE product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');

-- BR-6.2
CREATE TYPE courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');

-- BR-7.7
CREATE TYPE order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');

-- BR-7.9
CREATE TYPE order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');

-- BR-8.2
CREATE TYPE payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');

-- BR-8.2
CREATE TYPE payment_type AS ENUM ('карта', 'наличные', 'безнал');

-- BR-9.1
CREATE TYPE review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');
