-- FOOD-109. Пользователь-аудитор inspector и его права.
-- Запускается от суперпользователя после восстановления бэкапа:
--   psql -U postgres -d <база> -f db/schema/grants.sql
-- Скрипт идемпотентен: повторный запуск не падает.

-- 1. Создаём роль только при её отсутствии; существующий пароль не меняем.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector login password 'NetoSQL2025';
    END IF;
END;
$$;

-- 2. Подключение к текущей базе и временные объекты
DO $$
BEGIN
    EXECUTE format('grant connect, temporary on database %I to inspector', current_database());
END;
$$;

-- 3. Системные схемы (по умолчанию есть у PUBLIC, выдаём явно на случай отзыва)
GRANT USAGE ON SCHEMA information_schema TO inspector;
GRANT USAGE ON SCHEMA pg_catalog TO inspector;

-- 4. Схема exts — для exts.uuid_generate_v4()
GRANT USAGE ON SCHEMA exts TO inspector;
GRANT EXECUTE ON ALL functions IN SCHEMA exts TO inspector;

-- 5. Полный доступ к схеме проекта и всем её объектам
GRANT ALL PRIVILEGES ON SCHEMA kalugin_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA kalugin_food TO inspector;
GRANT ALL PRIVILEGES ON ALL sequences IN SCHEMA kalugin_food TO inspector;
GRANT ALL PRIVILEGES ON ALL routines IN SCHEMA kalugin_food TO inspector;

-- enum-типы (USAGE по умолчанию есть у PUBLIC, выдаём явно)
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT t.typname
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = 'kalugin_food'
           AND t.typtype = 'e'
    LOOP
        EXECUTE format('grant usage on type kalugin_food.%I to inspector', r.typname);
    END LOOP;
END;
$$;

-- Права выдаются только существующим объектам; будущие объекты проверяются отдельно.

-- 6. Путь поиска по умолчанию для inspector
ALTER ROLE inspector SET search_path = kalugin_food, exts, PUBLIC;
