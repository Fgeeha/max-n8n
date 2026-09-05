#!/usr/bin/env bash
# Идемпотентный прогон SQL-миграций из db/migrations по возрастанию имени.
# Применённые версии отмечаются в schema_migrations, повторно не выполняются.
# Каждый файл идёт в одной транзакции: упал — не зачтён.
#
# После миграций досеивает контент бота (экраны, товары) из
# db/seed/bot_content.json. Только недостающие строки: правки, сделанные через
# админку в n8n, не перетираются.
#
# Использование: scripts/db-migrate.sh [local|prod]
set -euo pipefail
cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-local}"
COMPOSE_FILE="docker/docker-compose.${ENVIRONMENT}.yml"
[ -f "$COMPOSE_FILE" ] || { echo "Нет файла $COMPOSE_FILE" >&2; exit 1; }
[ -f .env ] || { echo ".env не найден" >&2; exit 1; }

set -a; . ./.env; set +a
APP_DB_NAME="${APP_DB_NAME:-maxbot}"
DC=(docker compose --env-file .env -f "$COMPOSE_FILE")

psql_app() {
  "${DC[@]}" exec -T db psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$APP_DB_NAME" "$@"
}

# База бота создаётся отдельно от базы n8n: POSTGRES_DB заводит только n8n-скую.
if ! "${DC[@]}" exec -T db psql -tAX -U "$POSTGRES_USER" -d postgres \
       -c "select 1 from pg_database where datname='$APP_DB_NAME'" | grep -q 1; then
  echo "Создаю базу $APP_DB_NAME"
  "${DC[@]}" exec -T db createdb -U "$POSTGRES_USER" "$APP_DB_NAME"
fi

psql_app -q -c "CREATE TABLE IF NOT EXISTS schema_migrations (
    version    text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);"

applied=0
for f in db/migrations/*.sql; do
  version=$(basename "$f")
  if psql_app -tAX -c "select 1 from schema_migrations where version='$version'" | grep -q 1; then
    echo "  уже применена: $version"
    continue
  fi
  echo "  применяю: $version"
  # Файл и отметка о нём — одной транзакцией, чтобы не разъехались.
  { echo "BEGIN;"; cat "$f";
    echo "INSERT INTO schema_migrations (version) VALUES ('$version');";
    echo "COMMIT;"; } | psql_app -q -f -
  applied=$((applied + 1))
done

echo "Контент бота: досеиваю недостающие экраны и товары"
psql_app -q -v content="$(cat db/seed/bot_content.json)" <<'SQL'
INSERT INTO bot_screens (key, text, buttons)
SELECT key, text, buttons
  FROM jsonb_to_recordset((:'content')::jsonb -> 'screens')
       AS t(key text, text text, buttons jsonb)
ON CONFLICT (key) DO NOTHING;

INSERT INTO bot_products (id, title, price_rub, short, description, sort)
SELECT id, title, price_rub, COALESCE(short, ''), COALESCE(description, ''), COALESCE(sort, 100)
  FROM jsonb_to_recordset((:'content')::jsonb -> 'products')
       AS t(id text, title text, price_rub integer, short text, description text, sort integer)
ON CONFLICT (id) DO NOTHING;
SQL

echo "Готово. Применено новых миграций: $applied"
