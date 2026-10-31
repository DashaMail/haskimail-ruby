# Push шаблонов

`templates.push` **переносит** (не копирует) все шаблоны одного сервера на другой. Метод есть только у
`AccountClient` (ключ аккаунта).

```ruby
require "haskimail"

account = Haskimail::AccountClient.new(ENV.fetch("HASKIMAIL_ACCOUNT_TOKEN"))
```

## Пробный прогон

Сначала посмотрите, что будет перенесено, — с `perform_changes: false` ничего не меняется:

```ruby
preview = account.templates.push(source_server_id: 11_834, destination_server_id: 11_835, perform_changes: false)

puts "Шаблонов: #{preview.total_count}"
preview.templates.each { |template| puts "  [#{template.template_id}] #{template.name}" }
```

## Перенос

```ruby
result = account.templates.push(source_server_id: 11_834, destination_server_id: 11_835, perform_changes: true)
puts "Перенесено шаблонов: #{result.total_count}"
```

### Параметры

| Параметр | Поле API | Описание |
|----------|----------|----------|
| `source_server_id:` | `SourceServerID` | ID сервера-источника |
| `destination_server_id:` | `DestinationServerID` | ID сервера-назначения |
| `perform_changes:` | `PerformChanges` | `true` — перенести; `false` — только показать (пробный прогон) |

Все три параметра обязательны. У `perform_changes:` нет значения по умолчанию намеренно: это
разрушительная операция, и выбор должен быть явным. Значение, отличное от `true`/`false`, —
`Haskimail::ValidationError`.

`push` повторяется автоматически только когда запрос точно не был выполнен: соединение не
установилось, ответ 429/503 или `ErrorCode 36` (см. [[Повторы и надёжность]]).
Если вызов завершился `Haskimail::ConnectionError` с `request_sent? == true`, перенос мог выполниться:
проверьте шаблоны на обоих серверах, прежде чем запускать его снова.

Остальные операции с шаблонами — на странице [[Шаблоны]].
