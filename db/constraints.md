# Обоснование ограничений

Схема: `kalugin_food`. DDL — `db/schema/02_tables.sql`, триггеры — `db/schema/03_triggers.sql`.
Формат: «что ограничиваем — потому что BR-N.M требует …».

---

## Общие решения

- **Имя таблицы заказа — `"order"` в кавычках** (BR-13.1). Переименование не делал: имя совпадает с ERD и с проверочными запросами, кавычки нужны только в SQL.
- **Все ID — `uuid DEFAULT exts.uuid_generate_v4()`** (BR-11.1, BR-13.3). Схема `exts` не создаётся и не пересоздаётся.
- **Идентификатор транзакции назван `payment.transaction_ref`, а не `transaction_id`.** Это внешний строковый код провайдера (BR-8.3), а не UUID нашей системы. Суффикс `_id` в схеме зарезервирован за UUID-ключами (проверка B.4 ищет столбцы `%_id` не типа `uuid`).
- **Пустые строки запрещены** CHECK `<> ''` на обязательных текстовых полях: пустая строка — это «значения нет», а BR-11.3/BR-11.4 разрешают отсутствие значения только там, где бизнес это допускает, и требуют обеспечивать это схемой. На nullable-полях (`apartment_office`, `photo_url`) тот же CHECK запрещает пустую строку вместо NULL.
- **Даты и время — `timestamp`/`date`/`time` без часового пояса** (BR-11.2).
- **Типы данных** (BR-11.6):
  - деньги — `numeric(12,2)` (цена блюда — `numeric(10,2)`): копейки хранятся точно, без ошибок округления `float`;
  - рейтинг блюда/ресторана — `numeric(3,2)`: значения 0.00–5.00, среднее хранится с двумя знаками;
  - рейтинг отзыва — `numeric(1,0)`: целое 1–5;
  - коэффициент — `numeric(2,1)`: 0.1–0.5;
  - количество — `numeric(8,3)`: дробное количество (0.5 кг, BR-7.15);
  - телефон — `char(12)`: формат `+7XXXXXXXXXX` ровно 12 символов (`char(11)` не вмещает `+7` и 10 цифр);
  - пароль — `char(32)`: md5 всегда 32 hex-символа;
  - строки: логин 50, ФИО 150, улица 150, дом 10, квартира/офис 10, названия 100, идентификатор транзакции 64.
- **Повторный вызов `insert_test_data(n)` добавляет данные**, а не заменяет их (tests.md C.9). Каждый вызов связывает между собой только строки своей порции (заказы — только на курьеров, клиентов и рестораны этой же порции), поэтому выплаты курьеров из прошлых вызовов остаются согласованными с заказами. Уникальные поля (логин, телефон клиента, название категории, идентификатор транзакции) генерируются со счётчиком или проверкой на существование.
- **Месяц заказа для зарплаты и отчётов — по `order_timestamp`** (как в проверке tests.md C.8). Одинаково в `insert_test_data`, `courier_salary` и `how_much_money`.

---

## Enum-типы

| Тип | Значения | BR |
|---|---|---|
| `restaurant_status` | `активен`, `неактивен` | BR-4.3 |
| `product_status` | `доступно`, `нет_в_наличии`, `архив` | BR-5.5 |
| `courier_status` | `свободен`, `занят`, `на_доставке`, `уволен` | BR-6.2 |
| `order_status` | `создан`, `готовится`, `в_доставке`, `доставлен`, `отменён` | BR-7.7 |
| `order_pay_status` | `ожидает`, `оплачен`, `ошибка` | BR-7.9 |
| `payment_status` | `успех`, `ошибка`, `в_обработке` | BR-8.2 |
| `payment_type` | `карта`, `наличные`, `безнал` | BR-8.2, BR-8.6 |
| `review_entity_type` | `блюдо`, `ресторан`, `заказ` | BR-9.1 |

Значения не добавлялись и не менялись относительно BR. Все статусы реализованы как `CREATE TYPE ... AS ENUM` — потому что BR-11.5 запрещает `varchar` для перечислений.

---

## Ловушки

### Ловушка 1: `payment` — неполная сущность

**Какие атрибуты добавил в `payment` и почему** (BR-8.2):

```
payment_type          payment_type   NOT NULL — тип оплаты попытки (BR-8.2, BR-8.6);
amount                numeric(12,2)  NOT NULL — сумма попытки (BR-8.2), равна total_amount заказа (BR-8.4);
transaction_ref       varchar(64)    NOT NULL UNIQUE — внешний идентификатор транзакции
                                     от провайдера (BR-8.2, BR-8.3, BR-8.5: данных карт нет);
transaction_timestamp timestamp      NOT NULL — дата и время транзакции (BR-8.2);
status                payment_status NOT NULL — 'успех' / 'ошибка' / 'в_обработке' (BR-8.2).
```

**Где хранится тип оплаты — `payment` или `order`** (BR-8.6):

```
В payment. BR-8.6 прямо говорит, что тип относится к попытке оплаты: у одного заказа
могут быть попытки картой и наличными. В order хранится только агрегированный
pay_status (BR-7.8), который пересчитывает триггер payment_pay_status по BR-8.7.
```

### Ловушка 2: `order.address_id` — принадлежность клиенту (BR-7.4)

**Как обеспечено, что адрес доставки принадлежит клиенту:**

```
Составной FK:
  "order"(client_id, address_id) -> client_address(client_id, address_id)
Целевой ключ — PK client_address (client_id, address_id).
Заказ с адресом, который не привязан к этому клиенту, не вставится —
проверка декларативная, без триггера и без кода приложения.
Отдельные FK "order".client_id -> client и "order".address_id -> address
тоже оставлены: они есть в ERD.
```

### Ловушка 3: `order_structure` — один ресторан в заказе (BR-7.3)

**Как обеспечено, что все блюда из `order.restaurant_id`:**

```
В order_structure добавлен столбец restaurant_id и два составных FK:
  (order_id,   restaurant_id) -> "order"(order_id,   restaurant_id)
  (product_id, restaurant_id) -> product(product_id, restaurant_id)
Для них на "order" и product добавлены UNIQUE (order_id, restaurant_id) и
UNIQUE (product_id, restaurant_id) — составной FK требует уникальности
ровно этих столбцов у родителя.
Если ресторан блюда отличается от ресторана заказа, хотя бы один из двух FK
не сойдётся, и строка не вставится.

Нормализация: restaurant_id здесь — контролируемая избыточность (формально
он зависит от части ключа, см. раздел «Нормализация»). Его значение не
хранится «просто так»: оно жёстко сверено FK и с заказом, и с блюдом, поэтому
не может разойтись с ними (нет аномалий обновления).
Выбран декларативный способ вместо триггера: проще, быстрее и не обходится.
```

### Ловушка 4: `review` — полиморфизм (BR-9.1)

**Как реализована валидность `review.entity_id`:**

```
Полиморфизм: entity_type (enum) + entity_id (uuid) без FK.
FK не может ссылаться «на одну из трёх таблиц», поэтому entity_id проверяет
триггер review_entity_check (BEFORE INSERT OR UPDATE):
  'блюдо'    -> блюдо есть в order_structure этого заказа;
  'ресторан' -> entity_id = "order".restaurant_id этого заказа;
  'заказ'    -> entity_id = order_id.
Этим же триггером дата отзыва не может быть раньше даты заказа.

Что «отзыв только на свой заказ» (BR-9.2), обеспечивает составной FK
  review(order_id, client_id) -> "order"(order_id, client_id)
(на "order" для него есть UNIQUE (order_id, client_id)).

Почему не нормализация (три nullable-FK product_id / restaurant_id / order_id
с CHECK «ровно один не NULL»): контракт FOOD-105 и BR-9.6 сформулирован через
entity_type и entity_id, а проверку «блюдо из этого заказа» всё равно пришлось
бы делать триггером.
```

---

## CHECK-ограничения

| Таблица | Столбец | Условие | BR | Обоснование |
|---|---|---|---|---|
| `address` | `street`, `house_number` | `<> ''` | BR-3.1, BR-11.3 | Адрес описывается улицей и домом — они обязательны, пустая строка не допускается |
| `address` | `apartment_office` | `<> ''` | BR-3.2, BR-11.3 | Квартира необязательна, но её отсутствие — NULL, а не пустая строка |
| `client` | `login` | `<> ''` | BR-2.1, BR-11.4 | Клиент регистрируется по логину — он не может быть пустым |
| `client` | `password` | `~ '^[0-9a-f]{32}$'` | BR-2.3 | Пароль хранится как md5 — ровно 32 hex-символа |
| `client` | `phone_number` | `~ '^\+7[0-9]{10}$'` | BR-2.1, BR-2.2 | Телефон — идентификатор клиента; единый формат нужен, чтобы UNIQUE не обходился разным написанием одного номера |
| `restaurant` | `restaurant_name`, `description`, `company_details` | `<> ''` | BR-4.1, BR-4.5, BR-11.3 | У ресторана есть название, описание и реквизиты — обязательные значения |
| `restaurant` | `work_end`, `work_start` | `work_end > work_start` | BR-4.4 | Время закрытия позже времени открытия |
| `restaurant` | `rating` | `rating BETWEEN 0 AND 5` | BR-4.2 | Рейтинг ресторана от 0 до 5 (NULL проходит CHECK — см. раздел NULL) |
| `courier` | `fio` | `<> ''` | BR-6.1 | У курьера есть ФИО |
| `courier` | `phone_number` | `~ '^\+7[0-9]{10}$'` | BR-6.1 | Телефон курьера в том же формате, что у клиента |
| `courier` | `coefficient` | `BETWEEN 0.1 AND 0.5` | BR-6.4 | Коэффициент от 0.1 до 0.5 включительно |
| `courier` | `status`, `dismissal_date` | `status <> 'уволен' OR dismissal_date IS NOT NULL` | BR-6.3 | Уволенный курьер обязан иметь дату увольнения; работающий — не обязан, поэтому это импликация, а не равенство |
| `courier` | `dismissal_date`, `hire_date` | `dismissal_date >= hire_date` | BR-6.1, BR-6.3 | Увольнение не может предшествовать найму |
| `courier_pay` | `month` | `BETWEEN 1 AND 12` | BR-10.1, BR-10.3 | Выплата ежемесячная, месяц — номер календарного месяца |
| `courier_pay` | `amount` | `amount >= 0` | BR-10.4 | Сумма зарплаты неотрицательна |
| `courier_pay` | `coefficient_used` | `BETWEEN 0.1 AND 0.5` | BR-6.4, BR-10.2 | Применённый коэффициент — коэффициент курьера, тот же диапазон |
| `product_category` | `product_category_name` | `<> ''` | BR-5.7 | Справочник: идентификатор и название, название обязательно |
| `product` | `product_name`, `description` | `<> ''` | BR-5.2 | У блюда есть название и описание |
| `product` | `photo_url` | `<> ''` | BR-5.6, BR-11.3 | Фото необязательно — его нет = NULL, а не пустая строка |
| `product` | `price` | `price >= 0` | BR-5.3 | Цена блюда неотрицательна |
| `product` | `rating` | `rating BETWEEN 0 AND 5` | BR-5.4 | Рейтинг блюда от 0 до 5 |
| `"order"` | `description` | `<> ''` | BR-11.3 | Поле из ERD; BR не разрешает ему быть пустым |
| `"order"` | `order_amount` | `order_amount > 0` | BR-7.10, BR-7.14 | Сумма без комиссии — стоимость блюд; в заказе минимум одна позиция с положительным количеством |
| `"order"` | `total_amount` | `total_amount >= 1000` | BR-1.8, BR-7.11 | Общая сумма заказа не менее 1000 ₽ |
| `"order"` | `delivery_timestamp` | `delivery_timestamp >= order_timestamp` | BR-7.13 | Окончание доставки не раньше создания заказа |
| `"order"` | `status`, `delivery_timestamp` | `status <> 'доставлен' OR delivery_timestamp IS NOT NULL` | BR-7.12 | Время доставки заполняется, когда заказ доставлен; до этого может быть пустым — поэтому импликация |
| `payment` | `transaction_ref` | `<> ''` | BR-8.3 | Внешний идентификатор транзакции обязателен |
| `order_structure` | `quantity` | `quantity > 0` | BR-7.15 | Количество — положительное число (может быть дробным) |
| `review` | `description` | `<> ''` | BR-9.3 | У отзыва есть текст |
| `review` | `photo_url` | `<> ''` | BR-9.3, BR-11.3 | Фото необязательно — NULL, а не пустая строка |
| `review` | `rating` | `rating BETWEEN 1 AND 5` | BR-9.4 | Рейтинг отзыва от 1 до 5 |

---

## UNIQUE-ограничения

| Таблица | Столбцы | BR | Обоснование |
|---|---|---|---|
| `client` | `login` | BR-2.2 | Логин уникален |
| `client` | `phone_number` | BR-2.2 | Телефон уникален |
| `client_address` | PK `(client_id, address_id)` | BR-2.5 | Один и тот же адрес нельзя привязать к одному клиенту дважды |
| `restaurant` | `address_id` | BR-3.3, BR-3.4 | У ресторана ровно один адрес, два ресторана не делят один адрес |
| `courier_pay` | PK `(year, month, courier_id)` | BR-10.3 | За месяц у курьера ровно одна запись |
| `product_category` | `product_category_name` | BR-5.7 | Категория — справочник: одно название — одна запись, иначе блюда одной категории расползутся по дублям |
| `product` | `(product_id, restaurant_id)` | BR-7.3 | Целевой ключ для составного FK из `order_structure` (ловушка 3) |
| `"order"` | `(order_id, restaurant_id)` | BR-7.3 | Целевой ключ для составного FK из `order_structure` (ловушка 3) |
| `"order"` | `(order_id, client_id)` | BR-9.2 | Целевой ключ для составного FK из `review` (ловушка 4) |
| `"order"` | `(order_id, total_amount)` | BR-8.4 | Целевой ключ для FK `payment(order_id, amount)` |
| `payment` | `transaction_ref` | BR-8.3 | Идентификатор финансовой транзакции уникален |
| `payment` | `(order_id) WHERE status = 'успех'` — частичный уникальный индекс `payment_one_success_uq` | BR-8.1 | У заказа может быть несколько попыток, но успешная — не более одной |
| `order_structure` | PK `(order_id, product_id)` | BR-7.16 | Одно блюдо не встречается в заказе дважды — увеличивается количество |
| `review` | `(order_id, entity_type, entity_id)` | BR-9.5 | В рамках заказа не более одного отзыва на каждый объект |

---

## FK-ограничения

| Таблица | Столбцы | → Таблица | BR | Обоснование |
|---|---|---|---|---|
| `client_address` | `client_id` | `client(client_id)` `ON DELETE CASCADE` | BR-2.4 | Связь клиента с его адресами; при удалении клиента связь удаляется, сам адрес — нет (BR-3.5) |
| `client_address` | `address_id` | `address(address_id)` `ON DELETE RESTRICT` | BR-2.4, BR-3.5 | Адрес не удаляется, пока используется |
| `restaurant` | `address_id` | `address(address_id)` `ON DELETE RESTRICT` | BR-3.3, BR-3.5 | У ресторана ровно один адрес; адрес не удаляется |
| `courier_pay` | `courier_id` | `courier(courier_id)` `ON DELETE RESTRICT` | BR-10.2 | Выплата начисляется конкретному курьеру; курьер с историей выплат не удаляется |
| `product` | `product_category_id` | `product_category(product_category_id)` `ON DELETE RESTRICT` | BR-5.1, BR-5.7 | Блюдо принадлежит ровно одной категории из справочника; категория с блюдами не удаляется |
| `product` | `restaurant_id` | `restaurant(restaurant_id)` `ON DELETE RESTRICT` | BR-5.1 | Блюдо принадлежит ровно одному ресторану |
| `"order"` | `client_id` | `client(client_id)` `ON DELETE RESTRICT` | BR-7.1, BR-7.2 | Заказ оформляет клиент; клиент с заказами не удаляется |
| `"order"` | `restaurant_id` | `restaurant(restaurant_id)` `ON DELETE RESTRICT` | BR-7.2 | Заказ привязан к одному ресторану |
| `"order"` | `courier_id` | `courier(courier_id)` `ON DELETE RESTRICT` | BR-7.5 | Доставку выполняет курьер |
| `"order"` | `address_id` | `address(address_id)` `ON DELETE RESTRICT` | BR-7.4, BR-3.5 | Заказ доставляется по одному адресу; история заказов сохраняется |
| `"order"` | `(client_id, address_id)` | `client_address(client_id, address_id)` `ON DELETE RESTRICT` | BR-7.4 | Адрес доставки — один из адресов этого клиента (ловушка 2); адрес, по которому были заказы, нельзя отвязать от клиента |
| `payment` | `order_id` | `"order"(order_id)` `ON DELETE CASCADE` | BR-8.1 | Попытка оплаты относится к заказу |
| `payment` | `(order_id, amount)` | `"order"(order_id, total_amount)` `ON DELETE CASCADE` | BR-8.4 | Сумма попытки оплаты равна общей сумме заказа |
| `order_structure` | `order_id` | `"order"(order_id)` `ON DELETE CASCADE` | BR-7.14 | Позиция принадлежит заказу |
| `order_structure` | `product_id` | `product(product_id)` `ON DELETE RESTRICT` | BR-7.14 | Позиция — это блюдо; блюдо из истории заказов не удаляется (для этого есть статус `архив`) |
| `order_structure` | `(order_id, restaurant_id)` | `"order"(order_id, restaurant_id)` `ON DELETE CASCADE` | BR-7.3 | Ресторан позиции = ресторан заказа (ловушка 3) |
| `order_structure` | `(product_id, restaurant_id)` | `product(product_id, restaurant_id)` `ON DELETE RESTRICT` | BR-7.3 | Ресторан позиции = ресторан блюда (ловушка 3) |
| `review` | `client_id` | `client(client_id)` `ON DELETE CASCADE` | BR-9.1 | Отзыв оставляет клиент |
| `review` | `order_id` | `"order"(order_id)` `ON DELETE CASCADE` | BR-9.2 | Отзыв всегда связан с конкретным заказом |
| `review` | `(order_id, client_id)` | `"order"(order_id, client_id)` `ON DELETE CASCADE` | BR-9.2 | Отзыв только на свой заказ (ловушка 4) |

Итого 20 FK, у каждого действие `ON DELETE` задано явно:

- **`RESTRICT`** (12 FK) — ссылки на справочники и участников заказа: `address`, `client`, `courier`, `restaurant`, `product`, `product_category`, а также `"order"` → `client_address`. Пока на родителя ссылаются заказы, блюда или выплаты, удалить его нельзя: история заказов и выплат не теряется (BR-3.5), «висячих» ссылок не бывает. Выбран `RESTRICT`, а не `NO ACTION` по умолчанию: нарушение обнаруживается сразу, проверку нельзя отложить до конца транзакции.
- **`CASCADE`** (8 FK) — подчинённые строки, которые без родителя не имеют смысла: адреса клиента (`client_address` → `client`), позиции заказа (`order_structure` → `"order"`, оба FK), попытки оплаты (`payment` → `"order"`, оба FK), отзывы (`review` → `"order"`, оба FK, и `review` → `client`). Удаление заказа удаляет его состав, оплаты и отзывы. Удаление клиента с заказами всё равно блокирует `order_client_fk` (`RESTRICT`), поэтому каскад по клиенту срабатывает только для клиента без заказов (у него удаляются привязки адресов).

---

## NOT NULL (только бизнес-обязательные)

| Таблица | Столбец | BR | Обоснование |
|---|---|---|---|
| `client` | `login`, `password`, `phone_number` | BR-2.1 | Клиент регистрируется по логину, паролю и телефону — все три обязательны |
| `restaurant` | `work_start`, `work_end` | BR-4.4 | График работы — время открытия и закрытия |
| `restaurant` | `company_details` | BR-4.5 | Реквизиты обязательны (меняются, но не отсутствуют) |
| `courier` | `hire_date` | BR-6.1 | У курьера-сотрудника всегда есть дата найма |
| `courier` | `coefficient` | BR-6.4, BR-6.5 | Коэффициент всегда задан, начальное значение 0.1 |
| `"order"` | `courier_id` | BR-1.3, BR-7.5 | Самовывоза нет — каждый заказ доставляет курьер |
| `"order"` | `address_id` | BR-1.3, BR-7.4 | Каждый заказ доставляется по адресу |
| `"order"` | `order_timestamp` | BR-7.1 | У заказа есть дата и время создания |
| `"order"` | `pay_status` | BR-7.8 | У заказа есть агрегированный статус оплаты |
| `payment` | `payment_type`, `amount`, `transaction_ref`, `transaction_timestamp`, `status` | BR-8.2 | Каждая попытка оплаты имеет все эти атрибуты |
| `review` | `rating`, `review_timestamp`, `description` | BR-9.3 | У отзыва есть текст, рейтинг и дата |
| `review` | `entity_type`, `entity_id`, `order_id` | BR-9.1, BR-9.2 | Отзыв всегда на конкретный объект в рамках заказа |

Остальные `NOT NULL` следуют из BR-11.3 («всё остальное — обязательно»).

---

## NULL (осознанно разрешено)

| Таблица | Столбец | BR | Почему NULL |
|---|---|---|---|
| `address` | `apartment_office` | BR-3.2, BR-11.3 | Частные дома и отдельные входы — указывать нечего |
| `restaurant` | `rating` | BR-9.7 | Нет отзывов на ресторан — рейтинг `NULL` |
| `product` | `rating` | BR-9.7 | Нет отзывов на блюдо — рейтинг `NULL` |
| `product` | `photo_url` | BR-5.6, BR-11.3 | Фотография блюда необязательна |
| `courier` | `dismissal_date` | BR-6.3, BR-11.3 | У работающего курьера даты увольнения нет |
| `"order"` | `delivery_timestamp` | BR-7.12, BR-11.3 | До доставки время окончания доставки пустое |
| `review` | `photo_url` | BR-9.3, BR-11.3 | Фотография в отзыве необязательна |

---

## DEFAULT и GENERATED

| Таблица | Столбец | Что | Обоснование |
|---|---|---|---|
| все таблицы с суррогатным ключом | `*_id` | `DEFAULT exts.uuid_generate_v4()` | BR-11.1: UUID генерируются на сервере |
| `courier` | `coefficient` | `DEFAULT 0.1` | BR-6.5: начальный коэффициент нового курьера |
| `courier` | `status` | `DEFAULT 'свободен'` | Новый курьер ещё не на заказе |
| `restaurant` | `status` | `DEFAULT 'активен'` | Новый партнёр по умолчанию работает |
| `product` | `status` | `DEFAULT 'доступно'` | Новое блюдо по умолчанию в меню |
| `"order"` | `status` | `DEFAULT 'создан'` | Первый статус жизненного цикла заказа (BR-7.7) |
| `"order"` | `pay_status` | `DEFAULT 'ожидает'` | Пока попыток оплаты нет, статус «ожидает» (BR-8.7) |
| `"order"`, `review` | `order_timestamp`, `review_timestamp` | `DEFAULT localtimestamp` | Время сервера без часового пояса (BR-11.2) |
| `"order"` | `commission` | `GENERATED ALWAYS AS (round(order_amount * 0.10, 2)) STORED` | BR-1.4, BR-7.10: комиссия — ровно 10% от стоимости блюд. Вычисляемый столбец нельзя записать вручную, поэтому он не может разойтись с `order_amount` |
| `"order"` | `total_amount` | `GENERATED ALWAYS AS (order_amount + round(order_amount * 0.10, 2)) STORED` | BR-7.10: общая сумма = сумма без комиссии + комиссия. Выражение строится от `order_amount`, потому что вычисляемый столбец не может ссылаться на другой вычисляемый. `STORED` нужен, чтобы на столбце работали CHECK `>= 1000`, UNIQUE и FK из `payment` |

## Триггеры целостности

| Триггер | Таблица | BR | Что делает |
|---|---|---|---|
| `review_entity_check_trg` (BEFORE INSERT/UPDATE) | `review` | BR-9.1, BR-9.2 | Проверяет полиморфную ссылку `entity_id` (ловушка 4) и что отзыв не раньше заказа |
| `payment_pay_status_trg` (AFTER INSERT/UPDATE/DELETE) | `payment` | BR-8.7 | Пересчитывает `"order".pay_status`: есть успешная попытка → `оплачен`; все попытки с ошибкой → `ошибка`; иначе → `ожидает` |
| `rating_change_trg` (AFTER INSERT/UPDATE/DELETE) | `review` | BR-9.6, BR-9.7 | FOOD-105: пересчитывает `product.rating` / `restaurant.rating` как `round(avg, 2)`, `NULL` если отзывов нет. Пропускается, если в транзакции установлен флаг `kalugin_food.skip_rating = 'on'`: его ставит `insert_test_data` и сама считает рейтинги порции одним `UPDATE` (samples, раздел 10) |

---

## Нормализация (3НФ)

```
1НФ: все значения атомарны — нет массивов, списков и повторяющихся групп.
     Адрес разложен на улицу, дом и квартиру; позиции заказа вынесены в
     order_structure, попытки оплаты — в payment, адреса клиента — в client_address.

2НФ: в таблицах с составным ключом неключевые атрибуты зависят от всего ключа:
     order_structure.quantity — от пары (заказ, блюдо);
     courier_pay.amount и coefficient_used — от тройки (год, месяц, курьер);
     в client_address неключевых атрибутов нет.
     Остальные таблицы имеют простой ключ (uuid).
     Исключение — order_structure.restaurant_id: он зависит от части ключа
     (определяется и order_id, и product_id по отдельности), то есть формально
     нарушает 2НФ. Это осознанная контролируемая избыточность, см. «Особые
     случаи» ниже.

3НФ: нет транзитивных зависимостей неключевых атрибутов от ключа через другие
     неключевые атрибуты. Например, ресторан блюда хранится только в product,
     данные клиента — только в client, а заказ ссылается на них по ключу.
     Дополнительные таблицы не потребовались: 12 таблиц ERD в 3НФ, кроме
     перечисленных ниже осознанных отступлений, каждое из которых защищено
     от аномалий схемой.

Особые случаи:
- order.commission = 10% от order_amount и order.total_amount = order_amount +
  commission — формально зависят от order_amount. Реализованы как
  GENERATED ALWAYS ... STORED: их нельзя изменить вручную, значение всегда
  выводится из order_amount, поэтому аномалии обновления невозможны. Хранятся
  физически, потому что на них есть CHECK (>= 1000) и FK из payment (BR-8.4),
  а отчёты читают их без пересчёта.
- product.rating и restaurant.rating — агрегаты по review. Это осознанная
  денормализация ради скорости чтения меню и карточки ресторана (рейтинг
  читается намного чаще, чем меняются отзывы). Согласованность поддерживает
  триггер rating_change при любом INSERT/UPDATE/DELETE отзыва (BR-9.7).
- order.pay_status — агрегат по payment (BR-8.7). Аналогично поддерживается
  триггером payment_pay_status.
- order_structure.restaurant_id — контролируемая избыточность (отступление
  от 2НФ): ресторан уже известен и по order_id ("order".restaurant_id), и по
  product_id (product.restaurant_id). Столбец нужен ради BR-7.3 «все блюда
  заказа — из ресторана заказа»: только с ним можно построить два составных FK
    (order_id,   restaurant_id) -> "order"(order_id,   restaurant_id)
    (product_id, restaurant_id) -> product(product_id, restaurant_id),
  которые проверяют правило декларативно, без триггера (ловушка 3).
  Аномалий обновления нет: значение сверено FK с обоими источниками и не
  может с ними разойтись — изменить ресторан у заказа или блюда, на которые
  ссылается состав, FK не даст.
- review.entity_id + entity_type — полиморфная ссылка. Не нарушает 3НФ:
  пара (тип, id) атомарно описывает объект отзыва и зависит только от
  review_id. Отсутствие FK компенсировано триггером (ловушка 4).
```
