# Выпуск версии

Гем публикуется на [RubyGems](https://rubygems.org/gems/haskimail) из GitHub Actions
(`.github/workflows/release.yml`) через
[trusted publishing](https://guides.rubygems.org/trusted-publishing/): API-ключ RubyGems нигде не хранится.

## Один раз перед первым выпуском

1. На rubygems.org в аккаунте Dashamail добавьте pending trusted publisher для гема `haskimail`:
   репозиторий `Dashamail/haskimail-ruby`, workflow `release.yml`, окружение `release`.
2. В настройках репозитория на GitHub создайте окружение `release` (Settings → Environments):
   - Deployment branches and tags → только теги `v*`;
   - Required reviewers — тот, кто подтверждает каждую публикацию.

## Каждый выпуск

1. Обновите версию в `lib/haskimail/version.rb` и перенесите записи из «Не выпущено» в новый раздел
   `CHANGELOG.md` (ссылки сравнения внизу файла тоже).
2. Убедитесь, что всё зелёное локально:
   ```bash
   bundle exec rake            # тесты (100% строк и веток), RBS, Steep, RuboCop
   gem build --strict haskimail.gemspec
   ```
3. Закоммитьте в `main`, дождитесь зелёного CI и поставьте тег:
   ```bash
   git tag -a v1.0.0 -m "Haskimail Ruby v1.0.0"
   git push origin v1.0.0
   ```
4. Workflow `release.yml` проверит, что тег стоит на коммите из `main` и совпадает с версией гема,
   прогонит тесты в отдельном задании без прав на публикацию и опубликует гем.

## Wiki

Папка `wiki/` — исходники вики. После изменений опубликуйте их (вики — отдельный git-репозиторий;
он появляется после создания первой страницы на вкладке Wiki):

```bash
git clone https://github.com/Dashamail/haskimail-ruby.wiki.git
cp haskimail-ruby/wiki/*.md haskimail-ruby.wiki/
cd haskimail-ruby.wiki && git add -A && git commit -m "Обновить вики" && git push
```

## Ручной выпуск (запасной вариант)

Если GitHub Actions недоступен. Тег после ручной публикации запустит `release.yml`, и тот
завершится ошибкой (версия уже на RubyGems) — это ожидаемо, гем от этого не меняется.

```bash
gem build --strict haskimail.gemspec
gem push haskimail-1.0.0.gem   # нужен аккаунт RubyGems с правами на гем и включённой MFA
git tag -a v1.0.0 -m "Haskimail Ruby v1.0.0" && git push origin v1.0.0
```
