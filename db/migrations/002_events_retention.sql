-- Чистка журнала событий. Без неё bot_events растёт бесконечно: на боевом
-- потоке это десятки тысяч строк в сутки.
-- Вызывается из make db-vacuum или из cron на хосте.
CREATE OR REPLACE FUNCTION prune_bot_events(keep_days integer DEFAULT 30)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    removed bigint;
BEGIN
    DELETE FROM bot_events
     WHERE created_at < now() - make_interval(days => keep_days);
    GET DIAGNOSTICS removed = ROW_COUNT;

    DELETE FROM bot_send_failures
     WHERE created_at < now() - make_interval(days => keep_days);

    DELETE FROM dialog_state
     WHERE expires_at IS NOT NULL AND expires_at < now();

    RETURN removed;
END;
$$;
