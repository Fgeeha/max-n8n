#!/usr/bin/env bash
# Заливает в n8n учётные данные и сценарии, затем включает нужные.
#
# Какой источник апдейтов активируется, решает BOT_MODE из .env:
#   polling — max-bot-polling  (локально, без публичного адреса)
#   webhook — max-bot-webhook  (прод, за reverse-proxy)
# Второй источник принудительно выключается: они делят одну очередь обновлений
# MAX и, работая вместе, будут отбирать апдейты друг у друга.
#
# Движок (max-bot-core) и отправка (max-bot-send) включаются всегда: в n8n 2.x
# сценарий с Execute Workflow Trigger обязан быть активным, иначе вызов падает с
# "Workflow is not active and cannot be executed". Админка контента (формы)
# тоже всегда активна — она за Basic Auth.
#
# Использование: scripts/n8n-provision.sh [local|prod]
set -euo pipefail
cd "$(dirname "$0")/.."

ENVIRONMENT="${1:-local}"
COMPOSE_FILE="docker/docker-compose.${ENVIRONMENT}.yml"
[ -f "$COMPOSE_FILE" ] || { echo "Нет файла $COMPOSE_FILE" >&2; exit 1; }
[ -f .env ] || { echo ".env не найден" >&2; exit 1; }
set -a; . ./.env; set +a

DC=(docker compose --env-file .env -f "$COMPOSE_FILE")
N8N=("${DC[@]}" exec -T n8n n8n)

CORE_ID=maxbotcore000001
SEND_ID=maxbotsend000001
ADMIN_ID=maxbotadmn000001
POLL_ID=maxbotpoll000001
HOOK_ID=maxbothook000001

BOT_MODE="${BOT_MODE:-polling}"
case "$BOT_MODE" in
  polling) ACTIVE_SRC=$POLL_ID; INACTIVE_SRC=$HOOK_ID ;;
  webhook)
    ACTIVE_SRC=$HOOK_ID; INACTIVE_SRC=$POLL_ID
    [ -n "${WEBHOOK_SECRET:-}" ] || {
      echo "BOT_MODE=webhook требует WEBHOOK_SECRET в .env" >&2; exit 1; }
    [ -n "${WEBHOOK_HOST:-}" ] || {
      echo "BOT_MODE=webhook требует WEBHOOK_HOST в .env" >&2; exit 1; }
    ;;
  *) echo "BOT_MODE должен быть polling или webhook, а не '$BOT_MODE'" >&2; exit 1 ;;
esac
# Формы админки контента торчат наружу как /form/..., поэтому без пароля не поднимаем.
[ -n "${ADMIN_FORM_USER:-}" ] && [ -n "${ADMIN_FORM_PASSWORD:-}" ] || {
  echo "Нужны ADMIN_FORM_USER и ADMIN_FORM_PASSWORD в .env — логин к формам админки контента" >&2; exit 1; }

echo "== Учётные данные (секретов в файле нет — только ссылки на \$env)"
for f in credentials/*.json; do
  "${DC[@]}" cp "$f" n8n:/tmp/cred.json >/dev/null
  "${N8N[@]}" import:credentials --input=/tmp/cred.json 2>&1 | tail -1
  "${DC[@]}" exec -T n8n rm -f /tmp/cred.json
done

echo "== Сценарии"
for f in workflows/*.json; do
  "${N8N[@]}" import:workflow --input="/workflows/$(basename "$f")" 2>&1 | tail -1
done

echo "== Активация (BOT_MODE=$BOT_MODE)"
"${N8N[@]}" update:workflow --id=$CORE_ID       --active=true  >/dev/null
"${N8N[@]}" update:workflow --id=$SEND_ID       --active=true  >/dev/null
"${N8N[@]}" update:workflow --id=$ADMIN_ID      --active=true  >/dev/null
"${N8N[@]}" update:workflow --id=$ACTIVE_SRC    --active=true  >/dev/null
"${N8N[@]}" update:workflow --id=$INACTIVE_SRC  --active=false >/dev/null
echo "   движок: $CORE_ID, отправка: $SEND_ID, админка: $ADMIN_ID"
echo "   источник: $ACTIVE_SRC, выключен: $INACTIVE_SRC"

# Именно up -d, а не restart: restart переиспользует окружение уже созданного
# контейнера, и правки в .env (ADMIN_IDS, токен, MAX_API_BASE_URL) не доезжают.
echo "== Пересоздание n8n, чтобы применить активацию и свежий .env"
"${DC[@]}" up -d --force-recreate n8n >/dev/null
# Проверяем изнутри контейнера: в проде порт наружу не проброшен.
until "${DC[@]}" exec -T n8n wget -q -O /dev/null http://localhost:5678/healthz 2>/dev/null; do
  sleep 3
done
echo "Готово."
