-- Заявки «перезвоните мне» из простого сценария без кода (max-bot-simple).
-- Телефон приходит либо вложением contact (кнопка request_contact), либо
-- текстом сообщения — тогда phone пуст, а номер лежит в message как написали.
CREATE TABLE IF NOT EXISTS callback_requests (
    id          bigserial    PRIMARY KEY,
    user_id     bigint       NOT NULL,
    chat_id     bigint,
    name        text,
    username    text,
    phone       text,
    message     text,
    -- new -> отправлено админам; дальше статус меняет оператор.
    status      text         NOT NULL DEFAULT 'new',
    created_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS callback_requests_status_idx
    ON callback_requests (status, created_at DESC);
