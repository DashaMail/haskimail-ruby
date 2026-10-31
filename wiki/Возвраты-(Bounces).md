# Возвраты (Bounces)

Возврат — письмо, которое не удалось доставить. Доступны через `client.bounces` (ключ сервера) и
`account.bounces` (ключ аккаунта, все серверы).

## Сводка по типам

`delivery_stats` — число возвратов по типам за последние 45 дней:

```ruby
require "haskimail"

client = Haskimail::ServerClient.new(ENV.fetch("HASKIMAIL_SERVER_TOKEN"))

stats = client.bounces.delivery_stats
stats.bounces.each do |bounce|
  puts "#{bounce.name}: #{bounce.count} (#{bounce[:type] || 'все типы'})"
end
# All: 1 (все типы)
# Hard bounce: 1 (HardBounce)
```

У строки `All` нет поля `Type`, поэтому здесь используется `bounce[:type]` (вернёт `nil`), а не
`bounce.type` (бросит `NoMethodError`).

## Список возвратов

```ruby
page = client.bounces.list(type: "HardBounce", from_date: Date.today - 7, count: 100, offset: 0)

puts "Всего: #{page.total_count}"
page.bounces.each do |bounce|
  puts "#{bounce.bounced_at} #{bounce.email} — #{bounce.type}: #{bounce.description}"
end
```

Новые возвраты идут первыми. Поля записи: `Type`, `Name`, `TypeCode`, `RecordType`, `Email`, `MessageID`,
`ServerID`, `MessageStream`, `Subject`, `Tag`, `Description`, `BouncedAt`.

### Фильтры

| Параметр | Параметр API | Описание |
|----------|--------------|----------|
| `type:` | `type` | `HardBounce`, `SoftBounce`, `BlkBounce`, `SpmBounce`, `BulkBounce`, `SpamBlock` |
| `email_filter:` | `emailFilter` | Адрес получателя |
| `tag:` | `tag` | Тег письма |
| `message_id:` | `messageID` | ID сообщения |
| `message_stream:` | `messagestream` | ID канала |
| `from_date:`, `to_date:` | `fromdate`, `todate` | Период: `Date`, `Time` или строка `"YYYY-MM-DD"` |
| `count:`, `offset:` | `count`, `offset` | Страница (только в `list`); `count` — положительное целое |

Даты передаются без времени: `Time` переводится в московскую дату. Неизвестный `type:` или опечатка в имени
фильтра — `Haskimail::ValidationError` со списком допустимых значений.

## Все возвраты

`each` обходит все страницы лениво (по умолчанию по 500 записей) и принимает те же фильтры, кроме
`count`/`offset` — вместо них `page_size:`:

```ruby
client.bounces.each(type: "HardBounce") { |bounce| puts bounce.email }

hard = client.bounces.each(from_date: Date.today - 30).select { |bounce| bounce.type == "HardBounce" }
first_ten = client.bounces.each(page_size: 50).first(10)
```

## Тестовые возвраты

Чтобы проверить обработку возвратов, отправьте письмо на тестовый адрес — событие придёт сразу
(см. [[Тестирование]]):

```ruby
client.emails.deliver(from: "shop@example.com", to: Haskimail::TestAddresses::HARD_BOUNCE,
                      subject: "Проверка", text_body: "Тест")
```

См. также: [[Стоп-листы (Suppressions)]], события `bounced` в [[Вебхуки]], статистика возвратов в
[[Статистика]].
