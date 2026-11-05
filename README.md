<a href="https://haskimail.ru">
    <img src="https://github.com/Dashamail/haskimail-ruby/raw/main/haskimail.png" alt="Haskimail Logo" title="Haskimail" width="120" height="120" align="right">
</a>

# Haskimail Ruby

Официальная Ruby-библиотека для [Haskimail HTTP API](https://haskimail.ru/developer).

[![Gem Version](https://img.shields.io/gem/v/haskimail.svg)](https://rubygems.org/gems/haskimail)
[![CI](https://github.com/Dashamail/haskimail-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/Dashamail/haskimail-ruby/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Библиотека для [Haskimail](https://haskimail.ru) — сервиса транзакционных писем. Покрывает все 62 метода
[справочника API](https://haskimail.ru/developer): отправку писем и пакетов, шаблоны, поиск сообщений,
открытия и клики, входящие письма, возвраты, каналы, стоп-листы, вебхуки, правила для входящих,
статистику, серверы и домены, а также разбор и проверку подписи вебхуков.

- **Ноль runtime-зависимостей** — только стандартная библиотека Ruby (`net/http`, `json`, `openssl`).
- **Безопасно по умолчанию** — TLS 1.2+ с обязательной проверкой сертификата, защита от подмены
  заголовков письма и path traversal, токены не попадают в логи, `inspect` и `pp`.
- **Надёжно** — повторы с экспоненциальной задержкой только там, где это безопасно: отправка письма
  повторяется, лишь когда запрос не дошёл до обработки, поэтому повтор не создаёт дубль.
- **Документированные лимиты проверяются до отправки** — 50 получателей, длина темы, размер тел и
  вложений, запрещённые типы файлов: ошибка понятна сразу, без сетевого запроса.
- **Удобно** — `snake_case`-параметры, ленивая пагинация через `Enumerable`, типизированные ошибки,
  RBS-сигнатуры, потокобезопасные неизменяемые клиенты.
- Ruby **3.1 – 4.0**.

## Содержание

- [Установка](#установка) · [Быстрый старт](#быстрый-старт) · [Два клиента](#два-клиента--два-ключа)
- [Параметры и ответы](#параметры-и-ответы) · [Отправка](#отправка) · [Пагинация](#пагинация)
- [Все методы](#все-методы) · [Ошибки](#ошибки) · [Повторы](#повторы) · [Настройка](#настройка)
- [Вебхуки](#вебхуки) · [Тестирование](#тестирование-интеграции) · [Разработка](#разработка) · [Ссылки](#ссылки)

## Установка

```ruby
# Gemfile
gem "haskimail"
```

## Быстрый старт

```ruby
require "haskimail"

client = Haskimail::ServerClient.new(ENV.fetch("HASKIMAIL_SERVER_TOKEN"))

result = client.emails.deliver(
  from: "Магазин <shop@example.com>",
  to: "ivan@example.com",
  subject: "Ваш заказ №1042 оформлен",
  html_body: "<p>Здравствуйте! Заказ №1042 оформлен.</p>",
  text_body: "Здравствуйте! Заказ №1042 оформлен.",
  tag: "orders",
  metadata: { order_id: "1042" },
  message_stream: "2081"
)

result.message_id # => "6f1c0b2d9e8a4f7b3c5d2e1a0b9c8d7e"
```

`ServerClient.new` без аргумента берёт токен из `ENV["HASKIMAIL_SERVER_TOKEN"]`,
`AccountClient.new` — из `ENV["HASKIMAIL_ACCOUNT_TOKEN"]`.

## Два клиента — два ключа

| Клиент | Заголовок | Ресурсы |
|---|---|---|
| `Haskimail::ServerClient` | `X-Haskimail-Server-Token` | `emails`, `templates`, `messages`, `opens`, `clicks`, `inbound_messages`, `bounces`, `message_streams`, `suppressions`, `webhooks`, `inbound_rules`, `stats` |
| `Haskimail::AccountClient` | `X-Haskimail-Account-Token` | `servers`, `domains`, `templates` (+ `push`), а также по всем серверам аккаунта: `messages`, `opens`, `clicks`, `bounces`, `message_streams`, `webhooks`, `stats` |

Серверный ключ видит данные только своего сервера, ключ аккаунта — «работает со всеми серверами
аккаунта» (раздел «Обзор» документации). Явно ключ аккаунта описан для списков шаблонов, сообщений,
открытий, кликов, возвратов, каналов, вебхуков и статистики, создания шаблона, канала и вебхука и
проверки шаблона; остальные методы этих ресурсов SDK отправляет с ним по общему правилу. Отправка
писем, входящие письма, правила для входящих и стоп-листы работают только с серверным ключом.

С ключом аккаунта `templates.create` требует `associated_server_id:`, `message_streams.create` —
`server_id:` (SDK проверяет это до запроса), а вебхуку стоит явно передать `message_stream:`.

## Параметры и ответы

Поля передаются в `snake_case` (`html_body:`, `template_id:`, `message_stream:`) — SDK сам
превращает их в имена API (`HtmlBody`, `TemplateId`, `MessageStream`). Строковые ключи уходят как
есть: `{ "HtmlBody" => "..." }`. Значения `metadata`, `template_model` и `test_render_model` — ваши
данные, их ключи не переименовываются. Поля со значением `nil` не отправляются. Строки в любой
кодировке (в том числе бинарные, как `request.raw_post`) приводятся к UTF-8; битый текст —
`Haskimail::ValidationError`.

Ответ — неизменяемый `Haskimail::ApiObject` без потерь данных:

```ruby
domain = account.domains.get(3127)
domain.dkim_verified                 # snake_case
domain[:spf_text_value][:value]      # то же через []
domain["DKIMVerified"]               # точное имя из API
domain.to_h                          # исходный Hash (изменяемая копия)
Haskimail.parse_time(message.received_at) # "2026-10-07 14:30:12" (МСК) => Time
```

Обращение через точку к отсутствующему полю бросает `NoMethodError` (опечатки не проходят молча).
Для необязательных полей используйте `[]` — он вернёт `nil`. Ключи, которые не являются
идентификаторами (например, `"Apple Mail"` в статистике почтовых клиентов), доступны через `[]`.

## Отправка

```ruby
client.emails.deliver(
  from: "shop@example.com",
  to: ["ivan@example.com", "anna@example.com"],       # массив склеится в "a, b"
  subject: "Счёт",
  html_body: '<p>Счёт во вложении</p><img src="cid:logo">',
  headers: { "X-Order-Id" => "1042" },                 # или [{ name:, value: }]
  attachments: [
    Haskimail::Attachment.from_file("invoice.pdf"),    # Base64 и MIME-тип SDK посчитает сам
    Haskimail::Attachment.from_file("logo.png", content_id: "cid:logo") # встроенная картинка
  ]
)

# По шаблону. Ключи модели — буквальные фрагменты шаблона, вместе со скобками
client.emails.deliver_with_template(
  template_alias: "order-created",
  template_model: { "{{name}}" => "Иван", "{{order}}" => "1042" },
  from: "shop@example.com", to: "ivan@example.com"
)
```

До отправки SDK проверяет [документированные ограничения](https://haskimail.ru/developer/user-guide/send-email-with-api):

- не больше 50 получателей в `To`, `Cc` и `Bcc` вместе (запятые в кавычках, комментариях `(...)` и
  `<...>` адреса не разделяют);
- `From` — до 255 символов, `Subject` — до 2000, `Tag` — до 1000 (в единицах UTF-16, как считает
  Haskimail);
- непустой `HtmlBody` или `TextBody`, каждый до 5 МБ; всё письмо вместе с вложениями (после Base64) —
  до 10 МБ;
- вложения без запрещённых расширений (`exe`, `bat`, `scr`, `msi`…, в том числе `virus.exe. ` и `.exe`);
- для писем по шаблону — ровно одно из `template_id` и `template_alias`;
- пакет — от 1 до 500 писем и не больше 50 МБ;
- в полях-заголовках, именах и значениях заголовков, а также в имени, `ContentType` и `ContentID`
  вложений нет переводов строк, управляющих символов и разделителей строк Unicode.

Проверки не обойти другим написанием имени поля: `"subject"`, `:replyTo` или `"reply_to"`
приводятся к документированному `Subject` / `ReplyTo`, а два написания одного поля в одном письме —
`ValidationError`.

### Пакетная отправка

API отвечает `200`, даже если часть писем отклонена, поэтому пакет возвращает `BatchResult`, а не
бросает исключение:

```ruby
batch = client.emails.deliver_batch(messages)           # до 500 писем
batch = client.emails.deliver_batch_with_templates(messages)

batch.success?                 # все ли приняты
batch.failed.each { |r| logger.warn("#{r.to}: #{r.error_code} #{r.message}") }
batch.successful.flat_map(&:message_ids)
batch.to_json                  # исходные ответы API
```

Результатов всегда столько же, сколько писем, и в том же порядке. Если API вернул другое число
результатов, SDK бросает `UnexpectedResponseError`: часть писем могла уйти, проверьте журнал
сообщений перед повторной отправкой.

## Пагинация

`list` возвращает одну страницу, `each` — ленивый `Enumerable` по всем страницам:

```ruby
client.messages.each(tag: "orders", from_date: Date.today - 7).first(50)
client.bounces.each(type: "HardBounce") { |bounce| unsubscribe(bounce.email) }
client.opens.each.lazy.select { |open| open.country == "RU" }.first(10)
```

Даты принимаются как `Date`, `Time`/`DateTime` (переводятся в московское время, как ожидает API)
или строка. Документированные диапазоны проверяются до запроса: `count` от 1 до 500 у сообщений,
открытий, кликов, входящих и правил, а у сообщений, открытий и кликов ещё `count + offset` не больше
10 000 — `each` сам останавливается на этой границе. В остальных списках `count` — положительное
целое. Размер страницы `each` по умолчанию совпадает с документацией: 50 у серверов, 500 у остальных.

## Все методы

```ruby
client.templates.list / each / get(id_or_alias) / create(...) / delete(id_or_alias)
client.templates.update(id, name:, subject:, html_body:, text_body:) # все 4 поля обязательны: API затирает пропущенные
client.templates.validate(subject:, html_body:, test_render_model: {...})

client.messages.list(**filters) / each / details(message_id)
client.opens.list / each / for_message(message_id)
client.clicks.list / each / for_message(message_id)
client.inbound_messages.list(status: :failed) / each / details(id) / bypass(id) / retry(id)

client.bounces.delivery_stats / list(**filters) / each
client.message_streams.list / get(id) / create(name:, message_stream_type:) / update(id, name:) /
                       archive(id) / unarchive(id)
client.suppressions.list(stream_id) / create(stream_id, emails) / delete(stream_id, emails)
client.webhooks.list / get(id) / create(url:, message_stream:, triggers: { delivery: true, bounce: true }) /
                update(id, url:, triggers:) / delete(id)
client.inbound_rules.list / each / create("example.org") / delete(id)
client.stats.summary / sends / bounces / spam_complaints / opens / clicks / opens_by_platform /
             opens_by_email_client / clicks_by_browser_family / clicks_by_platform

account = Haskimail::AccountClient.new
account.servers.list / each / get(id) / create(name:, color:, ...) / update(id, ...) / delete(id)
# color — один из 8 документированных (регистр не важен). API молча ставит purple вместо
# неизвестного цвета; SDK вместо этого бросает ValidationError, чтобы опечатка не прошла.
account.domains.list / each / get(id) / create("example.com") / delete(id) / verify_dkim(id) / verify_spf(id)
account.templates.push(source_server_id:, destination_server_id:, perform_changes: false) # пробный прогон
```

Фильтры передаются ключевыми словами (`from_email:`, `message_stream:`, `from_date:`…); опечатка в
имени фильтра — `ValidationError` со списком допустимых. Произвольный запрос с сохранением
аутентификации, повторов и обработки ошибок:

```ruby
client.request(:get, "/messages", query: { "count" => 10 })
```

## Ошибки

```ruby
begin
  client.emails.deliver(...)
rescue Haskimail::UnprocessableEntityError => e
  e.error_code                 # => 1226
  e.error_code == Haskimail::ErrorCodes::MESSAGE_STREAM_NOT_FOUND
  e.error_code_description     # => "Канал не найден"
rescue Haskimail::AuthenticationError   # 401 — неверный ключ
rescue Haskimail::ConnectionError => e  # сеть / таймаут / TLS
  e.request_sent?              # false — запрос точно не ушёл
rescue Haskimail::Error                 # всё остальное из SDK
end
```

Некоторые ошибки в данных API отдаёт с HTTP 404, а не 422: несуществующий шаблон при `get`, канал, вебхук,
домен. Если важен код ошибки, ловите общий `Haskimail::ApiError` и проверяйте `e.error_code` —
подробнее в [вики](https://github.com/Dashamail/haskimail-ruby/wiki/Обработка-ошибок).

`Haskimail::Error` ловит любые сбои запроса, проверки параметров и разбора вебхука. Только вызов
метода Ruby с неверными аргументами (например, без обязательного ключевого слова) даёт обычный
`ArgumentError`.

```
Haskimail::Error
├── ConfigurationError, ValidationError, SignatureVerificationError
├── ConnectionError ── TimeoutError, TlsError
└── ApiError (http_status, error_code, api_message, response_body)
    ├── AuthenticationError 401, ForbiddenError 403, NotFoundError 404
    ├── PayloadTooLargeError 413, UnprocessableEntityError 422, RateLimitError 429
    ├── ServerError 5xx ── ServiceUnavailableError 503
    └── UnexpectedResponseError (2xx с непонятным телом)
```

Все коды из [справочника ошибок](https://haskimail.ru/developer/api/overview#error-codes) — в
`Haskimail::ErrorCodes`.

## Повторы

| Ситуация | GET / PUT / DELETE | POST (отправка письма) |
|---|---|---|
| Соединение не установлено (DNS, refused, open timeout) | повтор | повтор — запрос не ушёл |
| Таймаут чтения, обрыв после отправки | повтор | **нет** — письмо могло уйти |
| 429, 503 (сервис отказал до обработки) | повтор | повтор |
| 500 / 502 / 504 | повтор | **нет** — письмо могло уйти |
| `ErrorCode 36` (временная ошибка отправки) | повтор | повтор |
| `ErrorCode 100` (внутренняя ошибка, «повторите позже») | повтор | **нет** |
| Ошибка TLS / сертификата | **нет** | **нет** |

По умолчанию 2 повтора с экспоненциальной задержкой (до 0.5 → 1 → 2 с …, с джиттером, максимум 8 с),
`Retry-After` учитывается (секунды или дата, не больше 30 с). Безопасные POST (проверка шаблона,
архивация канала, стоп-листы) повторяются как GET. `inbound_messages.bypass/retry` и
`templates.push` повторяются только как отправка письма — когда запрос точно не был выполнен
(соединение не установилось, 429/503, `ErrorCode 36`). DELETE повторяется, поэтому если первый ответ потерялся,
повтор может вернуть «не найдено» для уже удалённого объекта.

## Настройка

```ruby
Haskimail.configure do |config|
  config.open_timeout  = 5      # секунды
  config.read_timeout  = 30
  config.write_timeout = 30
  config.max_retries   = 2      # 0..10
  config.logger        = Rails.logger # метод, путь, статус, время; без токенов и email-адресов
  config.proxy         = "http://user:pass@proxy.local:3128" # иначе — из окружения, см. ниже
  config.ca_file       = "/etc/ssl/corp-ca.pem"              # доп. CA (к системным) для TLS-прокси
  config.user_agent    = "my-shop/2.1"
end

# Или для одного клиента:
Haskimail::ServerClient.new(token, read_timeout: 10, max_retries: 0)
```

Без `config.proxy` прокси берётся из переменной `https_proxy`, `HTTPS_PROXY` или `http_proxy`
(в этом порядке; `http_proxy` — как у самого Net::HTTP). Как и в `URI#find_proxy`, он не
используется для loopback-адресов и для хостов из `no_proxy` (имена, суффиксы доменов вида
`.example.com` или `*.example.com`, диапазоны CIDR; `*` — без прокси для всех). Адрес проверяется так же строго, как явный: `proxy.local:3128` понимается как
`http://proxy.local:3128`, а `https://` и `socks5://` — `ConfigurationError` при создании клиента,
потому что Net::HTTP передал бы пароль открытым текстом или не смог бы им воспользоваться. Заглавная
`HTTP_PROXY` намеренно игнорируется (уязвимость httpoxy в CGI). `proxy: false` — прямое соединение
без прокси, переменные окружения не читаются.

`Haskimail.configure` меняет настройки атомарно (если блок упал — ничего не меняется), а
`Haskimail.configuration` возвращает замороженный объект. Клиент делает снимок настроек при создании
и дальше неизменяем — один экземпляр можно использовать из многих потоков. Отключить проверку
TLS-сертификата нельзя намеренно. Объект настроек нельзя сохранить через `Marshal` (в нём может быть
пароль прокси), а в YAML и `inspect` пароль скрыт.

## Вебхуки

```ruby
# Rails
def create
  event = Haskimail::Webhook.construct_event(request.raw_post,
                                             signing_key: ENV.fetch("HASKIMAIL_WEBHOOK_KEY"))
  return head(:ok) if already_processed?(event.idempotency_key) # Haskimail может прислать дубль

  case event.type
  when :bounced              then mark_bounced(event.recipient, event.bounce_category) # :hard_bounce, ...
  when :complained           then unsubscribe(event.recipient)
  when :subscription_change  then sync_suppression(event.recipient, event.suppressed?)
  when :delivered, :opened, :clicked, :sent then track(event) # :sent — только сервер-песочница
  end
  head :ok
rescue Haskimail::SignatureVerificationError, Haskimail::ValidationError
  head :forbidden # 4xx — Haskimail не будет повторять
end
```

`event.metadata` — ваши `metadata` письма в виде Hash, `event.tag`, `event.occurred_at` (`Time`),
`event.server_id`, `event.stream_id`. Регистр типа события (`complained`/`COMPLAINED`) не важен.
`event.idempotency_key` для кликов включает ссылку, так что клики по разным ссылкам в одну секунду
не склеиваются. На событие вебхука Haskimail ждёт ответ до 10 секунд, повторяет при 5xx и не
повторяет при 4xx.

Входящие письма не подписываются — защитите URL HTTP Basic-авторизацией
(`https://user:pass@your-app.example/hooks/inbound`). Ответ на них Haskimail ждёт до 60 секунд и
повторяет при любом ответе, кроме 2xx и 403, а 403 останавливает повторы навсегда — поэтому отвечайте 403 только на чужие запросы
(полный пример — `examples/rails_webhook_controller.rb`):

```ruby
message = Haskimail::Webhook.parse_inbound(request.raw_post)
message.mailbox_hash             # "ticket-42" из адреса hash+ticket-42@inbound.haskimail.ru
message.stripped_text_reply
message.spam_score               # из X-Spam-Score
message.attachments.each { |a| store(a.name, a.content) } # уже декодированы из Base64
message.inspect                  # кратко: MessageID, From, To, Subject и число вложений
```

Размер тела ограничен: 1 МБ для событий и 64 МБ для входящих писем (`max_size:` меняет лимит).
Превышение — `Haskimail::WebhookPayloadTooLargeError` (подкласс `ValidationError`); для входящих
отвечайте на него 413, чтобы письмо осталось доступным для повтора.

> **Ограничение протокола.** Подпись Haskimail — `md5(recipient + message_id + ключ)`: она
> подтверждает только эти два поля, остальные (`event`, `SuppressSending`…) не подписаны. SDK
> проверяет подпись в постоянное время, использует только точные имена подписанных полей, отклоняет
> неоднозначные дубли полей и ожидает `recipient` вида `local@domain` без пробелов, а `message_id`
> из букв, цифр, `-` и `_` (как во всех примерах документации). Держите URL вебхука в секрете,
> используйте HTTPS и по возможности Basic-авторизацию. Подробнее — в [SECURITY.md](SECURITY.md).

## Тестирование интеграции

```ruby
# Проверка запроса без отправки: письмо не создаётся, вебхуки не срабатывают
Haskimail::ServerClient.new(Haskimail::TEST_TOKEN).emails.deliver(...)

# Тестовые адреса: письмо никуда не уходит, а событие возврата/жалобы приходит на вебхук сразу.
# Работают на живом сервере и в песочнице, не расходуют лимит (но не с TEST_TOKEN).
client.emails.deliver(from: "shop@example.com", to: Haskimail::TestAddresses::HARD_BOUNCE, ...)
Haskimail::TestAddresses::SOFT_BOUNCE / BLOCKED / SPAM_COMPLAINT

# Сервер-песочница: всё как на живом, но письма не доставляются
account.servers.create(name: "Staging", color: "yellow", delivery_type: "Sandbox")
```

Скрипт `examples/smoke_test.rb` проверяет SDK на живом API, ничего не отправляя и не изменяя:

```bash
ruby -Ilib examples/smoke_test.rb
HASKIMAIL_SERVER_TOKEN=... HASKIMAIL_ACCOUNT_TOKEN=... SMOKE_FROM=you@your-domain.example \
  ruby -Ilib examples/smoke_test.rb
```

## Разработка

```bash
bin/setup                   # bundle install
bundle exec rake            # тесты (100% строк и веток) + RBS + Steep + RuboCop
bundle exec rake test       # только тесты
bin/console                 # IRB с загруженным SDK
```

Тесты не ходят в сеть: юнит-тесты используют подменный транспорт, интеграционные — настоящий
локальный HTTPS-сервер с самоподписанным сертификатом (TLS, таймауты, gzip, повторы, многопоточность).
Отдельно есть контрактный тест на все 62 метода справочника, тесты на обезличенных реальных ответах
API и фаззинг со свойствами (`FUZZ_SEED`, `FUZZ_ITERATIONS`). CI гоняет Ruby 3.1–4.0 с json 2.x и 3.x,
проверяет типы Steep по RBS, 100% документирования YARD и раз в неделю — свежие версии зависимостей.
Подробнее — в [CONTRIBUTING.md](https://github.com/Dashamail/haskimail-ruby/blob/main/CONTRIBUTING.md),
выпуск версий — в [RELEASING.md](https://github.com/Dashamail/haskimail-ruby/blob/main/RELEASING.md).

## Ссылки

- [Документация API Haskimail](https://haskimail.ru/developer)
- [Wiki](https://github.com/Dashamail/haskimail-ruby/wiki) — подробное руководство с примерами
- [RubyGems](https://rubygems.org/gems/haskimail) — страница гема
- [haskimail.js](https://github.com/Dashamail/haskimail.js) — Node.js SDK
- [haskimail-python](https://github.com/Dashamail/haskimail-python) — Python SDK
- [Dashamail](https://dashamail.ru) — платформа email-маркетинга

## Лицензия

MIT. Подробнее в файле [LICENSE](LICENSE).
