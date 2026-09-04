#!/usr/bin/env bash
# Небольшой помощник для ручных запросов к Bot API MAX.
# Токен читается из .env и никогда не печатается.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env не найден" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MAX_BOT_TOKEN:?MAX_BOT_TOKEN не задан в .env}"
API="${MAX_API_BASE_URL:-https://botapi.max.ru}"
CURL_CA=(); [ -n "${MAX_CA_BUNDLE:-}" ] && [ -f "${MAX_CA_BUNDLE}" ] && CURL_CA=(--cacert "$MAX_CA_BUNDLE")

pp() { python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),ensure_ascii=False,indent=2))'; }

call() {
  curl -sS -m 40 "${CURL_CA[@]}" -H "Authorization: $MAX_BOT_TOKEN" -H 'Content-Type: application/json' "$@"
}

case "${1:-me}" in
  me)
    call "$API/me" | pp
    ;;
  chats)
    call "$API/chats?count=50" | pp
    ;;
  updates)
    # Читает очередь, не подтверждая её (marker не передаётся).
    call "$API/updates?limit=20&timeout=0" | pp
    ;;
  reset)
    # Подтверждает всю накопленную очередь, чтобы n8n стартовал с чистого листа.
    marker=$(call "$API/updates?limit=100&timeout=0" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("marker") or "")')
    if [ -z "$marker" ]; then echo "Очередь пуста"; exit 0; fi
    call "$API/updates?limit=100&timeout=0&marker=$marker" >/dev/null
    echo "Очередь подтверждена до marker=$marker"
    ;;
  subscriptions)
    call "$API/subscriptions" | pp
    ;;
  subscribe)
    # Регистрирует вебхук в MAX. Адрес собирается из WEBHOOK_HOST и WEBHOOK_PATH.
    : "${WEBHOOK_HOST:?WEBHOOK_HOST не задан в .env}"
    : "${WEBHOOK_SECRET:?WEBHOOK_SECRET не задан в .env}"
    url="${WEBHOOK_HOST%/}/webhook${WEBHOOK_PATH:-/max-updates}"
    echo "Подписываю $url"
    python3 -c 'import json,sys;print(json.dumps({"url":sys.argv[1],"secret":sys.argv[2],"update_types":["message_created","message_callback","bot_started"]}))' \
      "$url" "$WEBHOOK_SECRET" \
      | call -X POST --data-binary @- "$API/subscriptions" | pp
    ;;
  unsubscribe)
    # ВНИМАНИЕ: пока подписка жива, long polling работать не будет — очередь одна.
    : "${WEBHOOK_HOST:?WEBHOOK_HOST не задан в .env}"
    url="${WEBHOOK_HOST%/}/webhook${WEBHOOK_PATH:-/max-updates}"
    call -X DELETE "$API/subscriptions?url=$url" | pp
    ;;
  send)
    # Отладочная отправка: scripts/max-api.sh send <chat_id> "текст"
    chat="${2:?нужен chat_id}"; text="${3:?нужен текст}"
    python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$text" \
      | call -X POST --data-binary @- "$API/messages?chat_id=$chat" | pp
    ;;
  *)
    echo "Использование: $0 {me|chats|updates|reset|subscriptions|subscribe|unsubscribe|send <chat_id> <текст>}" >&2
    exit 2
    ;;
esac
