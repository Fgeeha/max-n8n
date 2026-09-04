#!/usr/bin/env bash
# Идемпотентный прогон SQL-миграций из db/migrations по возрастанию имени.
# Применённые версии отмечаются в schema_migrations, повторно не выполняются.
# Каждый файл идёт в одной транзакции: упал — не зачтён.
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

echo "Готово. Применено новых миграций: $applied"
