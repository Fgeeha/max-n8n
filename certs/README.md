# Корневой сертификат Минцифры РФ

## Зачем

`platform-api2.max.ru` — домен Bot API MAX, на который платформа перешла
19 июля 2026. Его сертификат подписан цепочкой Минцифры РФ, которой нет в
системных хранилищах Alpine и Debian-slim. Без этого файла исходящие запросы
из n8n падают с `certificate verify failed`.

Проверить, что дело именно в этом:

```bash
curl -sI https://platform-api2.max.ru/me      # ошибка TLS
curl -sI https://botapi.max.ru/me             # 401 — сертификат общедоверенный
```

`botapi.max.ru` отдаёт тот же API с общедоверенным сертификатом, поэтому
локально можно обойтись без CA-bundle: в `.env` задать
`MAX_API_BASE_URL=https://botapi.max.ru` и пустой `MAX_CA_BUNDLE`.

## Как получить

1. Скачать корневой сертификат с https://www.gosuslugi.ru/crt
   (только с официальных источников: gosuslugi.ru, mindigital.gov.ru).
2. Положить файл сюда под именем `russian-trusted-root-ca.pem`
   (подходит и DER, и PEM).
3. В `.env` указать путь **внутри контейнера**:
   `MAX_CA_BUNDLE=/certs/russian-trusted-root-ca.pem`
4. `make restart-local` (или `restart-prod`).

Каталог монтируется в контейнеры n8n как `/certs:ro`, а значение
`MAX_CA_BUNDLE` уходит в `NODE_EXTRA_CA_CERTS`. Node добавляет этот
сертификат **к** системным, а не вместо них, поэтому остальные HTTPS-вызовы
из сценариев продолжают работать.

## Важно

- Сам `.crt`/`.pem` в репозиторий не коммитится (см. `.gitignore`).
- Каталог должен существовать до `docker compose up`, иначе Docker создаст
  его от root и запись в него с хоста работать не будет. `make up-local`
  и `make up-prod` создают его сами.
- На входящие вебхуки не влияет: TLS для них терминирует reverse-proxy,
  туда нужен сертификат от общедоверенного УЦ (Let's Encrypt и т.п.).
