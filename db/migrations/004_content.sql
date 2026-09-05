-- Контент бота как данные, а не как код. Экраны и товары лежат здесь,
-- нода «Сценарий» их только подставляет. Добавить экран или товар —
-- строка в таблице (форма «Админка контента» в n8n), граф сценария не трогается.
--
-- Плейсхолдеры в text и buttons: {name} {user_id} {chat_id} — из события;
-- {id} {title} {short} {description} {price} — товар; {qty} {total} {phone}
-- {order_id} {client} — заказ; {lat} {lon} {echo} {rates_date} {rates_lines}
-- {orders} — экранно-специфичные. Список — в db/seed/bot_content.json.
CREATE TABLE IF NOT EXISTS bot_screens (
    key         text         PRIMARY KEY,
    text        text         NOT NULL,
    -- Ряды кнопок MAX: [[{type, text, payload|url}], ...]. Пусто — без клавиатуры.
    buttons     jsonb        NOT NULL DEFAULT '[]'::jsonb
                             CHECK (jsonb_typeof(buttons) = 'array'),
    updated_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bot_products (
    id          text         PRIMARY KEY,
    title       text         NOT NULL,
    price_rub   integer      NOT NULL CHECK (price_rub >= 0),
    short       text         NOT NULL DEFAULT '',
    description text         NOT NULL DEFAULT '',
    sort        integer      NOT NULL DEFAULT 100,
    -- Снятый с продажи товар остаётся в истории заказов, но исчезает из каталога.
    active      boolean      NOT NULL DEFAULT true,
    updated_at  timestamptz  NOT NULL DEFAULT now()
);
