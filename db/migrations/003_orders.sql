-- Заказы из бота. Демонстрируют многошаговую форму: товар приходит из кнопки,
-- количество и телефон бот спрашивает по очереди, промежуточные ответы лежат
-- в dialog_state, а сюда попадает уже собранный заказ.
CREATE TABLE IF NOT EXISTS orders (
    id            bigserial    PRIMARY KEY,
    user_id       bigint       NOT NULL,
    chat_id       bigint,
    user_name     text,
    product_id    text         NOT NULL,
    product_title text,
    qty           integer      NOT NULL CHECK (qty > 0),
    price_rub     integer,
    total_rub     integer,
    phone         text,
    -- new -> отправлен админам; дальше статусы меняет оператор.
    status        text         NOT NULL DEFAULT 'new',
    created_at    timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS orders_user_idx ON orders (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_status_idx ON orders (status, created_at DESC);

-- Чистка dialog_state доезжает и до брошенных форм: пользователь начал заказ
-- и ушёл. Без TTL такая запись держала бы его в шаге «жду телефон» вечно.
COMMENT ON COLUMN dialog_state.expires_at IS
    'Когда шаг протухает. prune_bot_events() удаляет просроченные строки.';
