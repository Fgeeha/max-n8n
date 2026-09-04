.DEFAULT_GOAL := help

COMPOSE := docker compose --env-file .env -f docker/docker-compose.yml
WORKFLOW := /workflows/max-bot-menu.json
WORKFLOW_ID := maxbotmenu0000001

.PHONY: help up down restart logs shell import export activate deactivate status executions test bot-info bot-updates bot-reset check clean

help: ## Показать список целей
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- запуск ----

up: ## Поднять n8n
	$(COMPOSE) up -d
	@echo "n8n: http://localhost:$${N8N_PORT:-5678}"

down: ## Остановить n8n
	$(COMPOSE) down

restart: ## Перезапустить n8n
	$(COMPOSE) restart

logs: ## Смотреть логи n8n
	$(COMPOSE) logs -f --tail=100 n8n

status: ## Показать состояние контейнеров
	$(COMPOSE) ps

executions: ## Показать последние выполнения сценария
	@scripts/n8n-executions.sh 15

shell: ## Открыть shell внутри контейнера n8n
	$(COMPOSE) exec n8n sh

# ------------------------------------------------------------- сценарии ----

import: ## Импортировать сценарий из workflows/ в n8n
	$(COMPOSE) exec n8n n8n import:workflow --separate --input=$(WORKFLOW)
	$(COMPOSE) restart n8n

export: ## Выгрузить сценарии из n8n обратно в workflows/
	$(COMPOSE) exec n8n n8n export:workflow --all --pretty --output=/tmp/wf.json
	$(COMPOSE) cp n8n:/tmp/wf.json ./workflows/export.json

activate: ## Включить сценарий (опрос MAX каждые 10 секунд)
	$(COMPOSE) exec -T n8n n8n update:workflow --id=$(WORKFLOW_ID) --active=true
	$(COMPOSE) restart n8n

deactivate: ## Выключить сценарий
	$(COMPOSE) exec -T n8n n8n update:workflow --id=$(WORKFLOW_ID) --active=false
	$(COMPOSE) restart n8n

# ------------------------------------------------------------- проверка ----

test: ## Прогнать проверки логики сценария (без обращения к MAX)
	docker run --rm -v "$(CURDIR):/w" -w /w --entrypoint node \
	  docker.n8n.io/n8nio/n8n:latest scripts/test-workflow.mjs

check: ## Проверить токен и связность с Bot API MAX
	@scripts/max-api.sh me

bot-info: ## Показать данные бота
	@scripts/max-api.sh me

bot-updates: ## Показать очередь необработанных обновлений (без подтверждения)
	@scripts/max-api.sh updates

bot-reset: ## Сбросить очередь обновлений MAX (подтвердить все старые апдейты)
	@scripts/max-api.sh reset

# ---------------------------------------------------------- обслуживание ----

clean: ## Удалить контейнер и том с данными n8n
	$(COMPOSE) down -v
