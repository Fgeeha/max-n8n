#!/usr/bin/env bash
# Выполнения сценариев и сводка по данным бота — прямо из Postgres.
#
# Использование:
#   scripts/n8n-executions.sh [local|prod] [N]       последние N выполнений
#   scripts/n8n-executions.sh [local|prod] stats     сводка по данным бота
set -euo pipefail
cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-local}"
ARG="${2:-15}"
COMPOSE_FILE="docker/docker-compose.${ENVIRONMENT}.yml"
[ -f "$COMPOSE_FILE" ] || { echo "Нет файла $COMPOSE_FILE" >&2; exit 1; }
set -a; . ./.env; set +a

DC=(docker compose --env-file .env -f "$COMPOSE_FILE")
psql_n8n() { "${DC[@]}" exec -T db psql -X -U "$POSTGRES_USER" -d "${DB_NAME:-n8n}" "$@"; }
psql_app() { "${DC[@]}" exec -T db psql -X -U "$POSTGRES_USER" -d "${APP_DB_NAME:-maxbot}" "$@"; }

if [ "$ARG" = "stats" ]; then
  psql_app \
    -c "select count(*) as пользователей, max(last_seen) as последняя_активность from bot_users;" \
    -c "select update_type as тип, count(*) as событий from bot_events group by 1 order by 2 desc;" \
    -c "select marker, lease_until > now() as опрос_идёт, updated_at from bot_state;" \
    -c "select count(*) as ошибок_отправки, max(created_at) as последняя from bot_send_failures;"
  exit 0
fi

psql_n8n -c "
select e.id,
       w.name          as сценарий,
       e.status        as статус,
       e.mode          as режим,
       e.\"startedAt\"  as начало,
       round(extract(epoch from (e.\"stoppedAt\" - e.\"startedAt\"))::numeric, 2) as сек
  from execution_entity e
  join workflow_entity w on w.id = e.\"workflowId\"
 order by e.id desc
 limit ${ARG};"
