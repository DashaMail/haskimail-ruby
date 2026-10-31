# Участие в разработке

Спасибо, что помогаете улучшить SDK! Нашли уязвимость — не открывайте issue, а напишите по адресу
из [SECURITY.md](SECURITY.md).

## Окружение

```bash
git clone https://github.com/Dashamail/haskimail-ruby.git
cd haskimail-ruby
bin/setup          # bundle install
bundle exec rake   # тесты, RBS, Steep и RuboCop (CI вдобавок проверяет YARD, сборку гема,
                   # bundle-audit, фаззинг со случайным seed и матрицу Ruby × json)
```

Поддерживаются Ruby 3.1 – 4.0 и json 2.x – 3.x. Runtime-зависимостей у gem нет и не должно
появляться: всё делается стандартной библиотекой. `Gemfile.lock` не коммитится намеренно: ни один
lock-файл не разрешается на всех поддерживаемых Ruby, а CI раз в неделю собирает свежие версии
зависимостей и так ловит несовместимые релизы (как json 3.0).

## Правила

- **Источник истины — [документация Haskimail](https://haskimail.ru/developer).** Новый метод или
  поле добавляются только вместе со ссылкой на раздел документации в комментарии и в контрактном
  тесте `test/unit/contract_test.rb`.
- **100% покрытие строк и веток** обязательно (`bundle exec rake coverage`); предупреждение Ruby из
  `lib/` тоже роняет прогон.
- Каждое исправление ошибки сопровождается тестом, который падает без исправления. Для проверок
  и лимитов — тест ровно на границе и на шаг за ней.
- `FakeTransport` по умолчанию отвечает `200` на любой запрос; где важно число запросов (повторы,
  пагинация), включайте `@transport.strict!`. Неиспользованные ответы в очереди роняют тест.
- Никаких сетевых запросов в тестах: юнит-тесты используют `FakeTransport`, интеграционные —
  локальный HTTPS-сервер из `test/support/https_server.rb`.
- Публичный API описан в `sig/haskimail.rbs`, внутренности — в `sig/haskimail/internal.rbs`;
  обновляйте сигнатуры вместе с кодом (`rake rbs steep`).
- Всё публичное документируется в YARD: CI требует 100% (`bundle exec yard stats --list-undoc`).
- Изменения для пользователей записываются в `CHANGELOG.md` (раздел «Не выпущено»).
- Стиль — RuboCop с конфигурацией репозитория, строки до 120 символов.

## Полезные команды

```bash
bundle exec rake test                                      # тесты
COVERAGE=0 bundle exec ruby -Itest test/unit/emails_test.rb  # один файл
FUZZ_SEED=123 FUZZ_ITERATIONS=5000 COVERAGE=0 \
  bundle exec ruby -Itest test/unit/fuzz_test.rb           # фаззинг с заданным seed
ruby -Ilib examples/smoke_test.rb                          # проверка на живом API (ничего не отправляет)
```

## Выпуск версии

Порядок выпуска описан в [RELEASING.md](RELEASING.md).
