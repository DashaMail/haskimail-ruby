# Haskimail Ruby — Документация

Добро пожаловать в документацию официальной Ruby-библиотеки для [Haskimail API](https://haskimail.ru/developer).

Гем `haskimail` покрывает все методы справочника API: отправку писем и пакетов, шаблоны, поиск
сообщений, открытия и клики, входящие письма, возвраты, каналы, стоп-листы, вебхуки, правила для
входящих, статистику, серверы и домены, а также разбор и проверку подписи вебхуков. Runtime-зависимостей
нет, поддерживается Ruby 3.1 – 4.0.

```ruby
require "haskimail"

client = Haskimail::ServerClient.new(ENV.fetch("HASKIMAIL_SERVER_TOKEN"))
result = client.emails.deliver(from: "shop@example.com", to: "ivan@example.com",
                               subject: "Заказ №1042 оформлен", text_body: "Здравствуйте!")
puts result.message_id
```

## Содержание

### Начало работы
- [[Установка и настройка]]
- [[Отправка писем]]

### ServerClient API
- [[Отправка писем]]
- [[Пакетная отправка]]
- [[Шаблоны]]
- [[Возвраты (Bounces)]]
- [[Исходящие сообщения]]
- [[Открытия и клики]]
- [[Входящие сообщения]]
- [[Правила для входящих]]
- [[Статистика]]
- [[Вебхуки]]
- [[Каналы сообщений]]
- [[Стоп-листы (Suppressions)]]

### AccountClient API
- [[Серверы]]
- [[Домены]]
- [[Push шаблонов]]

### Справочник
- [[Обработка ошибок]]
- [[Повторы и надёжность]]
- [[Тестирование]]

## Ссылки

- [Документация API Haskimail](https://haskimail.ru/developer)
- [README и исходный код](https://github.com/Dashamail/haskimail-ruby)
- [RubyGems](https://rubygems.org/gems/haskimail)
