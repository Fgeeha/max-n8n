# max-n8n

No-code платформа для бота MAX на n8n: меню, кнопки, ветвление сценариев — без
отдельного бота, которого надо писать и деплоить.

Началось как проверка гипотезы («можно ли вообще?»), доведено до прод-сборки:
Postgres, Redis, queue mode, вебхуки, идемпотентность, миграции.

- Итоги проверки гипотезы — [`docs/verdict.md`](docs/verdict.md)
- Развёртывание в проде — [`docs/production.md`](docs/production.md)
- Особенности Bot API MAX — [`docs/max-bot-api.md`](docs/max-bot-api.md)
- Сертификат Минцифры — [`certs/README.md`](certs/README.md)

## Что внутри

| Путь | Что это |
|---|---|
| `docker/docker-compose.local.yml` | n8n + postgres, обычный режим, polling |
| `docker/docker-compose.prod.yml` | n8n main + worker + postgres + redis, queue mode, вебхук |
| `workflows/max-bot-core.json` | движок: журнал, пользователь, меню, отправка |
| `workflows/max-bot-polling.json` | источник апдейтов: `GET /updates` |
| `workflows/max-bot-webhook.json` | источник апдейтов: вебхук |
| `db/migrations/` | схема базы бота |
| `credentials/postgres-maxbot.json` | креды Postgres для n8n — без секретов, через `$env` |
| `scripts/` | миграции, провижининг, запросы к MAX, просмотр выполнений, тесты |

## Быстрый старт (локально)

```bash
cp .env.example .env    # заполнить MAX_BOT_TOKEN, POSTGRES_PASSWORD, N8N_ENCRYPTION_KEY
make check              # убедиться, что токен рабочий
make up-local           # n8n + postgres -> http://localhost:5678
make migrate            # создать базу бота и её схему
make provision          # залить сценарии и включить источник по BOT_MODE
```

Дальше — написать боту в личку в MAX. Через ≤10 секунд придёт меню с кнопками.

`make help` покажет остальные цели, `make executions` — что происходило,
`make stats` — сводку по данным бота.

Прод: `make up-prod && make migrate-prod && make provision-prod && make subscribe`.
Подробности и оговорки — в [`docs/production.md`](docs/production.md).

## Как это устроено

```
        BOT_MODE=polling                    BOT_MODE=webhook
     max-bot-polling                       max-bot-webhook
   Schedule (10 с)                        Webhook POST
        │                                       │
   аренда в bot_state ← защита от              проверка секрета
        │                двойного опроса        │
   GET /updates ──┬── сохранить marker          200 OK сразу
        │         │   (даже если апдейтов нет)  │
   разобрать      └───────────────┐             разобрать
        │                          │            │
        └──────────► max-bot-core ◄─────────────┘
                          │
        записать событие (dedup_key, ON CONFLICT DO NOTHING)
                          │
                    новое событие? ──нет──► стоп, дубль
                          │да
                  обновить пользователя
                          │
                  Switch: эхо / меню
                          │
                  POST /messages или /answers
                          │ошибка
                  bot_send_failures
```

### Где менять кнопки

Всё меню — один объект `MENU` в ноде **«Меню»** сценария `max-bot-core`.
Открыть ноду в UI n8n, поправить, нажать Save. Рестарт не нужен.

```js
main: {
  text: 'Привет, {name}! 👋\nВыберите раздел:',
  buttons: [
    [{ type: 'callback', text: '📋 Каталог', payload: 'catalog' }],
    [{ type: 'link', text: '🌐 Сайт', url: 'https://example.com' }],
  ],
},
```

Новый экран = новый ключ в `MENU` плюс кнопка с `payload: '<ключ>'`.
Роутинг подхватит сам.

## Безопасность

- Секреты только в `.env` (в `.gitignore`). В базу n8n не попадают: сценарии
  читают их выражением `{{ $env.MAX_BOT_TOKEN }}`, а файл credentials хранит
  ссылки `={{ $env.POSTGRES_PASSWORD }}`, а не значения.
- Вебхук проверяет заголовок `X-Max-Bot-Api-Secret`; без совпадения — 401.
- Бот **обрабатывает только личные диалоги**: групповые чаты и сообщения других
  ботов отсекаются (`ONLY_DIALOGS=true`). Это важно — боевой токен состоит в
  реальных групповых чатах.
- Postgres и Redis в сети `internal: true`, наружу не смотрят.
- Имена compose-проектов зафиксированы (`max-n8n-local`, `max-n8n`), чтобы
  `down -v` не задел чужие стеки на той же машине.
