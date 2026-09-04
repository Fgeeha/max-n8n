#!/usr/bin/env bash
# Небольшой помощник для ручных запросов к Bot API MAX.
# Токен читается из .env и никогда не печатается.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env не найден" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MAX_BOT_TOKEN:?MAX_BOT_TOKEN не задан в .env}"
API="${MAX_API_URL:-https://botapi.max.ru}"

pp() { python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),ensure_ascii=False,indent=2))'; }

call() {
  curl -sS -m 40 -H "Authorization: $MAX_BOT_TOKEN" -H 'Content-Type: application/json' "$@"
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
  send)
    # Отладочная отправка: scripts/max-api.sh send <chat_id> "текст"
    chat="${2:?нужен chat_id}"; text="${3:?нужен текст}"
    python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$text" \
      | call -X POST --data-binary @- "$API/messages?chat_id=$chat" | pp
    ;;
  *)
    echo "Использование: $0 {me|chats|updates|reset|send <chat_id> <текст>}" >&2
    exit 2
    ;;
esac
