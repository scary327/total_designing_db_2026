-- FOOD-109. Пользователь-аудитор inspector и его права.
-- Запускается от суперпользователя после восстановления бэкапа:
--   psql -U postgres -d <база> -f db/schema/grants.sql
-- Скрипт идемпотентен: повторный запуск не падает.

-- 1. Роль с паролем
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'inspector') then
        create role inspector login password 'NetoSQL2025';
    else
        alter role inspector login password 'NetoSQL2025';
    end if;
end;
$$;

-- 2. Подключение к текущей базе и временные объекты
do $$
begin
    execute format('grant connect, temporary on database %I to inspector', current_database());
end;
$$;

-- 3. Системные схемы (по умолчанию есть у PUBLIC, выдаём явно на случай отзыва)
grant usage on schema information_schema to inspector;
grant usage on schema pg_catalog to inspector;

-- 4. Схема exts — для exts.uuid_generate_v4()
grant usage on schema exts to inspector;
grant execute on all functions in schema exts to inspector;

-- 5. Полный доступ к схеме проекта и всем её объектам
grant all privileges on schema kalugin_food to inspector;
grant all privileges on all tables in schema kalugin_food to inspector;
grant all privileges on all sequences in schema kalugin_food to inspector;
grant all privileges on all routines in schema kalugin_food to inspector;

-- enum-типы (USAGE по умолчанию есть у PUBLIC, выдаём явно)
do $$
declare
    r record;
begin
    for r in
        select t.typname
          from pg_type t
          join pg_namespace n on n.oid = t.typnamespace
         where n.nspname = 'kalugin_food'
           and t.typtype = 'e'
    loop
        execute format('grant usage on type kalugin_food.%I to inspector', r.typname);
    end loop;
end;
$$;

-- объекты, которые будут созданы в схеме позже
alter default privileges in schema kalugin_food grant all on tables to inspector;
alter default privileges in schema kalugin_food grant all on sequences to inspector;
alter default privileges in schema kalugin_food grant all on routines to inspector;
alter default privileges in schema kalugin_food grant usage on types to inspector;

-- 6. Путь поиска по умолчанию для inspector
alter role inspector set search_path = kalugin_food, exts, public;
