#!/usr/bin/env bash
# Показывает последние выполнения сценария из базы n8n.
# Важно: база в режиме WAL, поэтому копировать нужно вместе с -wal,
# иначе видно устаревший снимок на момент последнего чекпоинта.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for f in database.sqlite database.sqlite-wal database.sqlite-shm; do
  docker cp "max-n8n:/home/node/.n8n/$f" "$TMP/" 2>/dev/null || true
done

python3 - "$TMP/database.sqlite" "${1:-10}" <<'PY'
import sqlite3, sys, json
db, limit = sys.argv[1], int(sys.argv[2])
c = sqlite3.connect(db)
rows = list(c.execute('select id,status,startedAt from execution_entity order by id desc limit ?', (limit,)))
print(f'{"id":>5}  {"статус":<9} {"начало":<24} что произошло')
for i, st, t in rows:
    d = c.execute('select data from execution_data where executionId=?', (i,)).fetchone()
    what = 'пустой опрос'
    if d:
        arr = json.loads(d[0])
        def res(v):
            while isinstance(v, str) and v.isdigit() and int(v) < len(arr): v = arr[int(v)]
            return v
        paths = {str(res(e['api_path'])) for e in arr if isinstance(e, dict) and 'api_path' in e}
        if paths: what = 'отправка в MAX: ' + ', '.join(sorted(paths))
    print(f'{i:>5}  {st:<9} {t:<24} {what}')
PY
