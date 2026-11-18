# statickit

Статические сборки `jq`, `curl`, `xz` в миниатюрном мультиарх-образе (`scratch`)
для копирования (`COPY`) в произвольные контейнерные образы (в первую очередь —
Elasticsearch).

## Зачем

Типичный целевой образ Elasticsearch построен на старых базовых дистрибутивах
(например, ubuntu 20.04 / glibc 2.31). Динамические бинари из свежих
дистрибутивов в них не переносимы (символы `GLIBC_2.33+`, `XZ_5.4`), а любые
`RUN` в целевом Dockerfile ломают сборку чужой архитектуры на amd64-раннерах
(нет qemu/binfmt). Статически слинкованные (musl) бинари не имеют
рантайм-зависимостей и переносятся в целевой образ инструкцией `COPY` — ноль
`RUN`, целевой Dockerfile собирается под любую архитектуру через `--platform`.

## Пины версий

| инструмент | версия | sha256 tarball |
|---|---|---|
| jq (jqlang/jq) | 1.8.2 | `71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af` |
| xz (tukaani-project/xz) | 5.8.4 | `0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9` |
| curl (curl/curl) | 8.23.0 | `e3de77cfa6367083c776a26647fc9f633b538c06c3baa73d931a252ac8f72b49` |
| OpenSSL (TLS-стек curl) | 3.6.5 | `a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98` |

Версии и суммы — ARG в Dockerfile; сборка скачивает tarball и падает на
несовпадении суммы. Сборка дополнительно содержит страховочную проверку:
любой нестатический бинарь в `/tools` роняет билд.

## Публикация образа

1. Настроить репозиторий (Settings → Secrets and variables → Actions):
   - secrets `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (dockerhub-токен с правом write);
   - variable `DOCKERHUB_USER` — namespace на dockerhub (туда льётся `statickit`),
     строго строчными (`wuwux`): имя с заглавными буквами docker-клиенты
     разбирают как hostname реестра, push/pull ломаются.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` (или Manual run workflow).
3. Workflow собирает образы на нативных раннерах amd64 (`ubuntu-24.04`) и
   arm64 (`ubuntu-24.04-arm`), склеивает мультиарх-манифест `:X.Y.Z` +
   `:latest` (префикс `v` из git-тега отбрасывается), digest пишет в Step Summary.
4. То же зеркалится в `ghcr.io/<владелец-строчными>/statickit` (пуш встроенным
   `GITHUB_TOKEN`, отдельных секретов нет). При пуше из публичного репа пакет
   наследует его публичную видимость; приватным он будет только при пуше вручную
   под PAT — тогда public включается в настройках пакета.
5. По тому же тегу автоматически создаётся GitHub Release: pull-ссылки и digest'ы
   обоих реестров прямо на странице релиза.

## Потребление

Пиньте мультиарх-манифест **digest'ом** (плавающий тег = плавающее содержимое):

```dockerfile
ARG TOOLS_REF=<registry>/<user>/statickit@sha256:<digest>
FROM ${TOOLS_REF} AS tools

FROM <target-base-image>
COPY --from=tools /tools/ /usr/local/bin/
```

Манифест-индекс по digest разрешается билдером под целевую платформу сборки;
`COPY` — файловая операция, исполнителя не требует. Если у целевой сборки есть
кэш-прокси реестра, образ доступен через него тем же digest'ом.

Апгрейд: новый тег здесь → новый digest из Step Summary → bump `TOOLS_REF`
в потребителе.

## Локальная проверка

```sh
docker build -t statickit-local .
docker create --name t statickit-local && docker cp t:/tools ./tools && docker rm t
file ./tools/*   # все три: statically linked
# запуск — в linux-контейнере (статика musl не запускается на macOS-хосте):
docker run --rm -v "$PWD/tools:/tools:ro" alpine:3.22 /tools/jq -n '"ok"'
```

## Лицензии

Код репозитория (Dockerfile, workflow, docs) — MIT (`LICENSE`).

Бинари в образе — перераспределение upstream-компонентов; их тексты лежат в
`LICENSES/` и копируются в образ (`/tools/licenses/`):

| компонент | лицензия |
|---|---|
| jq (+ встроенный oniguruma) | MIT |
| curl | curl license (MIT-подобная) |
| xz (liblzma и CLI) | 0BSD; бандленный LGPL getopt_long не линкуется (musl даёт свой) |
| OpenSSL (TLS-стек curl) | Apache-2.0 — текст обязан распространяться с бинарём, для этого и едет в образе |
