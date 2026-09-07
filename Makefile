# Единая точка входа для всех команд проекта.

.DEFAULT_GOAL := help
COMPOSE ?= docker compose

# --- Источники образов ---
# Дефолт — публичные реестры. В закрытом контуре переопределяются из окружения:
#   POSTGRES_IMAGE=harbor.volganet.ru/dockerhub-proxy/postgres:17-alpine \
#   REDIS_IMAGE=harbor.volganet.ru/dockerhub-proxy/redis:7-alpine \
#   N8N_IMAGE=harbor.volganet.ru/dockerhub-proxy/n8nio/n8n:2.37.10 \
#   make up-prod
N8N_IMAGE ?= docker.n8n.io/n8nio/n8n:2.37.10
POSTGRES_IMAGE ?= postgres:17-alpine
REDIS_IMAGE ?= redis:7-alpine
export N8N_IMAGE POSTGRES_IMAGE REDIS_IMAGE

DC_LOCAL := $(COMPOSE) --env-file .env -f docker/docker-compose.local.yml
DC_PROD  := $(COMPOSE) --env-file .env -f docker/docker-compose.prod.yml

.PHONY: help \
        up-local down-local restart-local up-prod down-prod restart-prod \
        logs-local logs-prod status-local status-prod \
        migrate migrate-prod provision provision-prod \
        subscribe unsubscribe subscriptions \
        executions stats requests test check bot-info bot-updates bot-reset \
        dump restore dump-prod restore-prod db-shell db-vacuum \
        clean clean-prod

help: ## Показать список целей
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- запуск ----

up-local: ## Поднять локальное окружение (n8n + postgres, polling)
	@mkdir -p certs
	$(DC_LOCAL) up -d
	@echo "n8n: http://localhost:$${N8N_PORT:-5678}"

down-local: ## Остановить локальное окружение
	$(DC_LOCAL) down

restart-local: ## Перезапустить локальное окружение
	$(DC_LOCAL) restart

up-prod: ## Поднять прод (n8n main + worker + postgres + redis, queue mode)
	@mkdir -p certs
	@docker network inspect maxbots-network >/dev/null 2>&1 \
	  || docker network create maxbots-network
	$(DC_PROD) up -d
	@echo "n8n слушает внутри maxbots-network под именем max-n8n:5678"

down-prod: ## Остановить прод
	$(DC_PROD) down

restart-prod: ## Перезапустить прод
	$(DC_PROD) restart

logs-local: ## Логи локального окружения
	$(DC_LOCAL) logs -f --tail=100

logs-prod: ## Логи прода
	$(DC_PROD) logs -f --tail=100

status-local: ## Состояние контейнеров локального окружения
	$(DC_LOCAL) ps

status-prod: ## Состояние контейнеров прода
	$(DC_PROD) ps

# ------------------------------------------------------- база и сценарии ----

migrate: ## Применить миграции БД локально
	@scripts/db-migrate.sh local

migrate-prod: ## Применить миграции БД на проде
	@scripts/db-migrate.sh prod

provision: ## Залить креды и сценарии в n8n и включить нужный источник (локально)
	@scripts/n8n-provision.sh local

provision-prod: ## То же на проде
	@scripts/n8n-provision.sh prod

# ------------------------------------------------------------ вебхук MAX ----

subscriptions: ## Показать текущие подписки на вебхук
	@scripts/max-api.sh subscriptions

subscribe: ## Зарегистрировать вебхук в MAX (нужен BOT_MODE=webhook)
	@scripts/max-api.sh subscribe

unsubscribe: ## Снять подписку на вебхук (иначе long polling не получит апдейты)
	@scripts/max-api.sh unsubscribe

# ------------------------------------------------------------- проверка ----

test: ## Прогнать проверки логики сценариев (без обращения к MAX и БД)
	docker run --rm -v "$(CURDIR):/w" -w /w --entrypoint node $(N8N_IMAGE) \
	  scripts/test-workflow.mjs

check: ## Проверить токен и связность с Bot API MAX
	@scripts/max-api.sh me

executions: ## Последние выполнения сценариев
	@scripts/n8n-executions.sh local 15

stats: ## Сводка по данным бота: пользователи, события, ошибки отправки
	@scripts/n8n-executions.sh local stats

requests: ## Заявки «перезвоните мне» из простого бота и user_id написавших
	@scripts/n8n-executions.sh local requests

bot-info: ## Показать данные бота
	@scripts/max-api.sh me

bot-updates: ## Очередь необработанных обновлений (без подтверждения)
	@scripts/max-api.sh updates

bot-reset: ## Подтвердить всю накопленную очередь обновлений MAX
	@scripts/max-api.sh reset

# ---------------------------------------------------------- обслуживание ----
# Креды берутся из окружения контейнера db (POSTGRES_*), .env в make не тащим.
# restore ПЕРЕЗАПИСЫВАЕТ данные текущей БД — обязателен аргумент f=<файл>.

db-shell: ## psql в базе бота (локально)
	$(DC_LOCAL) exec db sh -c 'psql -U "$$POSTGRES_USER" "$${APP_DB_NAME:-maxbot}"'

db-vacuum: ## Почистить журнал событий старше 30 дней (локально)
	$(DC_LOCAL) exec -T db sh -c \
	  'psql -qtAX -U "$$POSTGRES_USER" -d "$${APP_DB_NAME:-maxbot}" -c "select prune_bot_events(30)"' \
	  | xargs -I{} echo "Удалено событий: {}"

dump: ## Дамп локальных БД: make dump [f=backup.dump]
	$(DC_LOCAL) exec -T db sh -c 'pg_dumpall -U "$$POSTGRES_USER"' \
	  > $(or $(f),dump_local_$(shell date +%Y%m%d_%H%M%S).sql)

restore: ## Восстановить локальные БД: make restore f=backup.sql
	@test -n "$(f)" || { echo "Укажи файл: make restore f=backup.sql"; exit 1; }
	$(DC_LOCAL) exec -T db sh -c 'psql -U "$$POSTGRES_USER" -d postgres' < $(f)

dump-prod: ## Дамп прод-БД: make dump-prod [f=backup.sql]
	$(DC_PROD) exec -T db sh -c 'pg_dumpall -U "$$POSTGRES_USER"' \
	  > $(or $(f),dump_prod_$(shell date +%Y%m%d_%H%M%S).sql)

restore-prod: ## Восстановить прод-БД: make restore-prod f=backup.sql
	@test -n "$(f)" || { echo "Укажи файл: make restore-prod f=backup.sql"; exit 1; }
	$(DC_PROD) exec -T db sh -c 'psql -U "$$POSTGRES_USER" -d postgres' < $(f)

clean: ## Удалить локальные контейнеры вместе с томами (данные пропадут)
	$(DC_LOCAL) down -v

clean-prod: ## Удалить прод-контейнеры вместе с томами (данные пропадут)
	$(DC_PROD) down -v
