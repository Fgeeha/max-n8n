# max-n8n

No-code платформа для бота MAX на n8n: меню, кнопки, ветвление сценариев — без
отдельного бота, которого надо писать и деплоить.

Началось как проверка гипотезы («можно ли вообще?»), доведено до прод-сборки:
Postgres, Redis, queue mode, вебхуки, идемпотентность, миграции.

- Что умеет демо-бот и как добавить своё — [`docs/scenarios.md`](docs/scenarios.md)
- Итоги проверки гипотезы — [`docs/verdict.md`](docs/verdict.md)
- Развёртывание в проде — [`docs/production.md`](docs/production.md)
- Особенности Bot API MAX — [`docs/max-bot-api.md`](docs/max-bot-api.md)
- Сертификат Минцифры — [`certs/README.md`](certs/README.md)

## Что внутри

| Путь | Что это |
|---|---|
| `docker/docker-compose.local.yml` | n8n + postgres, обычный режим, polling |
| `docker/docker-compose.prod.yml` | n8n main + worker + postgres + redis, queue mode, вебхук |
| `workflows/max-bot-core.json` | движок: журнал, пользователь, меню, каталог, заказы, отправка |
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

### Что умеет демо-бот

```
/start ─► Главное меню
            ├─ 🏢 О компании ──► [🌐 сайт] [📋 скопировать телефон] [⬅️ назад]
            ├─ 📋 Каталог ─────► товары ─► карточка ─► 🛒 Заказать ─► форма из 2 шагов
            ├─ 💱 Курс валют ──► запрос к API ЦБ РФ
            ├─ 🧾 Мои заказы ──► выборка из Postgres
            └─ 📍 Я рядом? ────► приём геопозиции

текстом:  /whoami — свой user_id   ·   «эхо <текст>» — повтор
```

Форма заказа: id товара берётся из кнопки, количество и телефон бот спрашивает
по очереди (кнопками или текстом), промежуточные ответы лежат в `dialog_state`.
Готовый заказ ложится в `orders` и уходит сообщением каждому из `ADMIN_IDS`.
Свой `user_id` для `ADMIN_IDS` подскажет команда `/whoami`.

### Где менять кнопки

Всё поведение — одна нода **«Сценарий»** в `max-bot-core`. Открыть в UI n8n,
поправить, нажать Save. Рестарт не нужен.

```js
// новый экран
if (key === 'delivery') return out({
  text: '🚚 *Доставка*\n\nПо городу — бесплатно от 3000 ₽.',
  buttons: [[{ type: 'callback', text: '⬅️ Назад', payload: 'main' }]],
});

// новый товар — кнопка в каталоге появится сама
d: { title: 'Кружка «Пар»', price: 590, short: 'керамика, 350 мл', desc: '…' },
```

Подробнее, включая список идей для новых примеров, — в
[`docs/scenarios.md`](docs/scenarios.md).

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
