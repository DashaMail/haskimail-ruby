# Стоп-листы (Suppressions)

Стоп-лист — адреса, на которые канал не отправляет письма. Стоп-лист привязан к каналу (см.
[[Каналы сообщений]]). `client.suppressions` работает только с ключом сервера.

## Получить стоп-лист

```ruby
require "haskimail"

client = Haskimail::ServerClient.new(ENV.fetch("HASKIMAIL_SERVER_TOKEN"))

list = client.suppressions.list("2081")
list.suppressions.each do |entry|
  puts "#{entry.email_address} — #{entry.suppression_reason} (#{entry.created_at})"
end
```

Поля записи: `EmailAddress`, `SuppressionReason`, `Origin`, `CreatedAt`. Причины:

| `SuppressionReason` | Описание |
|---------------------|----------|
| `HardBounce` | Постоянный возврат |
| `SpamComplaint` | Получатель пожаловался на спам |
| `ManualSuppression` | Добавлен вручную или получатель отписался |

Метод возвращает весь стоп-лист канала, фильтров нет.

## Добавить в стоп-лист

Принимает один адрес или массив. Пробелы по краям обрезаются; пустой список или пустой адрес —
`Haskimail::ValidationError`.

```ruby
result = client.suppressions.create("2081", ["no-mail@example.com", "not-an-email"])

result.suppressions.each do |entry|
  puts "#{entry.email_address}: #{entry.status} #{entry.message}"
end
# no-mail@example.com: Suppressed
# not-an-email: Failed An invalid email address was provided.
```

Результат приходит по каждому адресу: `Status` — `Suppressed` или `Failed`, причина отказа — в `Message`.
Ошибка в одном адресе не бросает исключение — проверяйте статусы.

## Удалить из стоп-листа

```ruby
result = client.suppressions.delete("2081", "no-mail@example.com")
result.suppressions.first.status # => "Deleted"
```

`Status` для удаления — `Deleted` или `Failed`. Удаляются только адреса, добавленные вручную. Адреса с
жёстким возвратом и жалобой API не удаляет: ответ — `Failed` с сообщением
`"You can not delete an unsubscribed suppression."`.

`create` и `delete` безопасно повторять, поэтому SDK повторяет их при сетевых сбоях так же, как GET
(см. [[Повторы и надёжность]]). Изменения стоп-листа приходят событием `subscription_change` (см. [[Вебхуки]]).
