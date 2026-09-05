# Развёртывание в проде

n8n 2.37.10, Postgres 17, Redis 7. Проверено 2026-09-04.

## Схема

```
                    maxbots-network (общая с banword-max-bot и cult-max-bot)
                    ├── reverse-proxy (TLS, снаружи)
                    │        │  https://<домен>/webhook/max-updates
                    │        ▼
                    ├── n8n (main)         маршруты вебхуков и расписания
                    │        │  постановка задач
                    │        ▼
                    └── worker × N ────────► Bot API MAX (исходящие)
                             │
        max-n8n-backend (internal)
                             ├── postgres  база n8n + база бота
                             └── redis     очередь задач
```

`main` держит HTTP и расписания, `worker` исполняет сценарии. Оба обязаны иметь
**один и тот же** `N8N_ENCRYPTION_KEY`, иначе worker не расшифрует credentials.

Worker сидит в двух сетях: `max-n8n-backend` (Postgres и Redis) и
`maxbots-network` (выход к Bot API MAX). Только внутренней сети не хватает —
она `internal: true`, из неё нет ни DNS, ни исходящего трафика, и запросы к MAX
висят до таймаута, а выполнения остаются в статусе `running`.

## Базы данных

Один инстанс Postgres, две базы.

| База | Кто пишет | Что лежит |
|---|---|---|
| `n8n` (`DB_NAME`) | сам n8n | сценарии, credentials, история выполнений |
| `maxbot` (`APP_DB_NAME`) | сценарии через ноду Postgres | состояние бота |

Схему `maxbot` заводят миграции из `db/migrations` (`make migrate-prod`):

| Таблица | Зачем |
|---|---|
| `bot_state` | позиция в очереди обновлений MAX (`marker`) и аренда на опрос |
| `bot_users` | кто писал боту, `chat_id` личного диалога для рассылок |
| `bot_events` | журнал событий и ключ идемпотентности `dedup_key` |
| `dialog_state` | текущий шаг многошаговых сценариев (`jsonb` под свободные данные) |
| `orders` | заказы из формы: товар, количество, телефон, сумма, статус |
| `bot_send_failures` | исходящие вызовы MAX, завершившиеся ошибкой |
| `schema_migrations` | учёт применённых миграций |

### Почему аренда, а не static data n8n

В обычном режиме n8n `$getWorkflowStaticData()` хватало для хранения `marker`.
В queue mode сценарий исполняет worker, и их несколько: два опроса, стартовавшие
одновременно, поделили бы между собой апдейты. Поэтому опрос сперва забирает
аренду одним запросом:

```sql
UPDATE bot_state
   SET lease_until = now() + interval '60 seconds'
 WHERE id = 1 AND lease_until < now()
RETURNING marker;
```

Пустой результат — опрос уже идёт, выходим. Аренда истекает сама, поэтому
упавший или убитый worker не блокирует следующий опрос навсегда.

### Правки .env требуют пересоздания контейнера

`docker compose restart` переиспользует окружение уже созданного контейнера:
новые `ADMIN_IDS`, токен или `MAX_API_BASE_URL` до n8n не доедут, а симптом
неочевидный — сценарий работает, но ведёт себя по-старому. `make provision`
делает `up -d --force-recreate n8n`.

### Идемпотентность

В webhook-режиме MAX повторяет доставку при таймауте. Без защиты бот отвечал бы
дважды. Каждое событие пишется в `bot_events` с уникальным `dedup_key`
(`msg:<mid>` или `cb:<callback_id>`), и `ON CONFLICT DO NOTHING` не вернёт
строку. Следом стоит нода «Новое событие?»: она обрывает ветку, если `id` не
вернулся. Одной уникальности мало — нода Postgres при нуле строк отдаёт
`{success: true}`, а не пустой выход, и без явной проверки ветка шла бы дальше.

## Пять сценариев вместо одного

| Сценарий | Роль |
|---|---|
| `max-bot-core` | движок: журнал, пользователь, логика экранов и формы заказа |
| `max-bot-send` | отправка в MAX: `/messages` или `/answers`, журнал ошибок; вызывается из движка и любого другого сценария |
| `max-bot-admin` | админка контента: формы `/form/maxbot-screens`, `/form/maxbot-products` за Basic Auth |
| `max-bot-polling` | источник апдейтов через `GET /updates` |
| `max-bot-webhook` | источник апдейтов через `POST /webhook/max-updates` |

Источники приводят апдейт к одной структуре и зовут движок нодой Execute
Workflow, движок так же зовёт отправку — поэтому и логика, и отправка описаны
один раз. `BOT_MODE` в `.env` решает, какой источник включается; второй
`make provision` принудительно выключает — они делят одну очередь обновлений
MAX и работали бы друг против друга.

Движок и отправка активируются всегда: в n8n 2.x сценарий с Execute Workflow
Trigger обязан быть активным, иначе вызов падает с `Workflow is not active and
cannot be executed`. Админка тоже всегда активна.

Формы админки — публичные URL на том же домене, что и вебхук
(`$WEBHOOK_HOST/form/maxbot-screens`). Они закрыты Basic Auth из
`ADMIN_FORM_USER` / `ADMIN_FORM_PASSWORD`; `make provision` без этих переменных
не запустится. Если reverse-proxy пропускает наружу только `/webhook/`, то и
`/form/` надо открыть явно — или ходить в формы изнутри сети.

Контент (тексты экранов, кнопки, товары) живёт в таблицах `bot_screens` и
`bot_products` базы бота, а не в сценариях: `make migrate-prod` досеивает
стартовый набор из `db/seed/bot_content.json`, не трогая уже отредактированные
строки. Экспорт сценариев из n8n контент не содержит — бэкап контента это
`make dump-prod`.

## Порядок развёртывания

```bash
cp .env.example .env          # заполнить, обязательно N8N_ENCRYPTION_KEY
                              # и POSTGRES_PASSWORD (openssl rand -hex 32)
# корневой сертификат Минцифры — см. certs/README.md
docker network create maxbots-network   # если ещё нет; make up-prod создаст сам

make up-prod                  # postgres + redis + n8n main + worker
make migrate-prod             # база maxbot и её схема
make provision-prod           # credentials, сценарии, активация по BOT_MODE
make subscribe                # зарегистрировать вебхук в MAX
make subscriptions            # проверить, что подписка появилась
```

Reverse-proxy направляет `https://<домен>/webhook/max-updates` на `max-n8n:5678`
в `maxbots-network`. Наружу n8n порт не пробрасывает.

### Переключение polling ↔ webhook

```bash
make unsubscribe              # снять подписку, иначе long polling не получит апдейты
# BOT_MODE=polling в .env
make provision-prod
```

Держать оба режима одновременно нельзя: очередь обновлений у бота одна.

## Что обязательно задать в .env

Значения без дефолтов — compose откажется стартовать без них:

| Переменная | Почему обязательна |
|---|---|
| `MAX_BOT_TOKEN` | без него бот никто |
| `POSTGRES_PASSWORD` | пароль базы |
| `N8N_ENCRYPTION_KEY` | сменить = потерять все credentials |
| `N8N_HOST`, `WEBHOOK_HOST` | из них n8n строит адрес вебхука |
| `WEBHOOK_SECRET` | при `BOT_MODE=webhook` маршрут иначе принимает что угодно |

Именование переменных выровнено по `banword-max-bot` и `culture-max-bot`:
`MAX_API_BASE_URL`, `MAX_CA_BUNDLE`, `BOT_MODE`, `WEBHOOK_HOST`, `WEBHOOK_PATH`,
`WEBHOOK_SECRET`, `LOG_LEVEL`, `DB_*`, `POSTGRES_*`, `ADMIN_IDS`,
`MAX_API_RETRY_*`, источники образов через `POSTGRES_IMAGE` / `REDIS_IMAGE` /
`N8N_IMAGE`. Токен назван `MAX_BOT_TOKEN` — как в `culture-max-bot`
(в `banword-max-bot` он `BOT_TOKEN`).

Токен и пароль в базу n8n не попадают: сценарии читают их выражением
`{{ $env.MAX_BOT_TOKEN }}`, а `credentials/postgres-maxbot.json` хранит не
значения, а ссылки `={{ $env.POSTGRES_PASSWORD }}`.

## Смена мажорной версии Postgres

Postgres не стартует на каталоге данных от предыдущей мажорной версии:

```
FATAL: database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 16,
        which is not compatible with this version 17.11.
```

Поэтому подъём `POSTGRES_IMAGE` с 16 на 17 — не правка одной строки, а
`make dump-prod` → `make clean-prod` → `make up-prod` → `make restore-prod f=…`.
Версия выбрана 17, потому что n8n 2.37 пишет в лог, что 16 «outside the
supported range and receives compatibility support only». Соседние боты
(`banword-max-bot`, `culture-max-bot`) остаются на 16 — там своя база и своё
приложение, общего каталога данных с этим стеком нет.

## Эксплуатация

```bash
make status-prod        # состояние контейнеров
make logs-prod          # логи
./scripts/n8n-executions.sh prod 20    # последние выполнения
./scripts/n8n-executions.sh prod stats # пользователи, события, marker, ошибки
make dump-prod          # дамп обеих баз
make db-vacuum          # чистка журнала событий старше 30 дней
```

Ошибки отправки копятся в `bot_send_failures` — они переживают прунинг истории
выполнений n8n (`EXECUTIONS_DATA_MAX_AGE`, по умолчанию 168 часов).

Масштабирование: `N8N_WORKER_REPLICAS=2 make up-prod` (проверено, поднимает
`worker-1` и `worker-2`), `N8N_CONCURRENCY` — сколько задач тянет один worker.

## Что осталось за рамками

- **Аутентификация перед n8n.** UI отдаёт reverse-proxy; ограничение доступа —
  на нём (basic auth, SSO, allow-list по IP).
- **Метрики.** `N8N_METRICS=true` отдаёт Prometheus на `/metrics`; отдельного
  порта под них, как `METRICS_ADDR` в `banword-max-bot`, здесь нет.
- **Бэкап по расписанию.** `make dump-prod` есть, cron на хосте — нет.
- **CI/CD.** Образ берётся из публичного реестра; выкладка через Harbor
  (`HARBOR_*`, `IMAGE_TAG`), как в соседних ботах, не настроена — n8n
  используется готовым образом, собирать нечего.
- **Живой прогон webhook-режима через реальный домен.** Проверен изнутри
  `maxbots-network` (401 без секрета, 200 и запись в БД с секретом);
  публичного адреса под рукой не было.
