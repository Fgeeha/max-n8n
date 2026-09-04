-- Схема базы бота. Отдельная база от n8n: n8n хранит сценарии и историю
-- выполнений в своей, бизнес-состояние бота живёт здесь.

-- Позиция в очереди обновлений MAX и аренда на опрос.
-- Одна строка. lease_until нужен потому, что в queue mode сценарий выполняет
-- worker, а их может быть несколько: без аренды два опроса пойдут парой и
-- поделят между собой апдейты. Претендент забирает аренду одним UPDATE и
-- только тогда идёт в MAX.
CREATE TABLE IF NOT EXISTS bot_state (
    id          smallint     PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    marker      bigint,
    lease_until timestamptz  NOT NULL DEFAULT now() - interval '1 second',
    updated_at  timestamptz  NOT NULL DEFAULT now()
);

INSERT INTO bot_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Пользователи, писавшие боту. chat_id личного диалога нужен, чтобы уметь
-- инициировать рассылку без входящего сообщения.
CREATE TABLE IF NOT EXISTS bot_users (
    user_id     bigint       PRIMARY KEY,
    chat_id     bigint,
    name        text,
    username    text,
    is_blocked  boolean      NOT NULL DEFAULT false,
    first_seen  timestamptz  NOT NULL DEFAULT now(),
    last_seen   timestamptz  NOT NULL DEFAULT now(),
    events_count integer     NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS bot_users_last_seen_idx ON bot_users (last_seen DESC);

-- Журнал событий: и аудит, и защита от повторной обработки.
-- В webhook-режиме MAX повторяет доставку при таймауте, поэтому нужен ключ
-- идемпотентности: mid сообщения или callback_id нажатия.
CREATE TABLE IF NOT EXISTS bot_events (
    id           bigserial    PRIMARY KEY,
    dedup_key    text         NOT NULL UNIQUE,
    update_type  text         NOT NULL,
    user_id      bigint,
    chat_id      bigint,
    chat_type    text,
    text         text,
    payload      text,
    raw          jsonb,
    created_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bot_events_created_at_idx ON bot_events (created_at DESC);
CREATE INDEX IF NOT EXISTS bot_events_user_idx ON bot_events (user_id, created_at DESC);

-- Состояние диалога: то, чего не давала static data n8n.
-- Многошаговые формы (заявка, опрос) держат здесь текущий шаг и накопленные
-- ответы. data — свободный jsonb, чтобы не заводить миграцию под каждый сценарий.
CREATE TABLE IF NOT EXISTS dialog_state (
    user_id     bigint       PRIMARY KEY,
    screen      text         NOT NULL DEFAULT 'main',
    step        text,
    data        jsonb        NOT NULL DEFAULT '{}'::jsonb,
    expires_at  timestamptz,
    updated_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dialog_state_expires_idx ON dialog_state (expires_at)
    WHERE expires_at IS NOT NULL;

-- Исходящие вызовы MAX API, завершившиеся ошибкой. Нужен, чтобы разбирать
-- инциденты: history выполнений n8n прунится по EXECUTIONS_DATA_MAX_AGE.
CREATE TABLE IF NOT EXISTS bot_send_failures (
    id          bigserial    PRIMARY KEY,
    api_path    text         NOT NULL,
    user_id     bigint,
    chat_id     bigint,
    status_code integer,
    error       text,
    body        jsonb,
    created_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bot_send_failures_created_at_idx
    ON bot_send_failures (created_at DESC);
