# Инструкция для AI-агента

Ты устанавливаешь XRay split tunnel на macOS и интегрируешь его с уже
настроенным Citrix. Прочитай этот файл, `README.md`,
`docs/subscription-format.md`, `docs/how-it-works.md`,
`docs/citrix-prerequisites.md`, `docs/migration.md` и `SECURITY.md` целиком до
первого изменения системы.

## Ожидаемый результат

- один launchd-job `com.xst.xray`: по умолчанию user LaunchAgent в
  `gui/$UID`, либо явно выбранный system LaunchDaemon для работы до GUI-login;
- HTTP proxy на `127.0.0.1:10809`;
- SOCKS5 proxy на `127.0.0.1:10808`;
- подтверждённые корпоративные domain suffix и CIDR идут в `direct`;
- остальной proxy-трафик выходит через выбранный XRay server;
- Citrix отдельно показывает `Connected`, а реальный внутренний HTTPS-ресурс
  доступен;
- `xst verify` возвращает `0`.

Не называй результат «полностью готовым», если выполнена только проверка XRay.

## Жёсткие границы

- Не проси и не принимай subscription URL, Citrix-пароль, `.p12`, приватный
  ключ или полный XRay config в чате.
- Не выводи `sub-url`, `subscription.json`, `config.json`, Keychain secret или
  внутренний URL в tool output.
- Не передавай subscription URL через аргумент или environment.
- Не выдумывай домены, CIDR, gateway, server selection или Citrix profile.
- Не меняй Citrix profile, сертификаты, Keychain ACL и watchdog без отдельного
  согласия владельца и инструкций `secure-access-helper`.
- Не включай глобальный `HTTPS_PROXY` без явной просьбы.
- Не меняй `~/.zshrc`, пока `XST_ZSHRC` не выбран явно.
- Не удаляй legacy plist/config или rollback-копию без отдельного разрешения.
- Не публикуй логи без редактирования `id`, `publicKey`, `shortId`,
  `serverName`/`sni`, endpoint, внутреннего FQDN и публичного IP.

## Один запрос владельцу до установки

Спроси одним сообщением только:

1. подготовлен ли локальный `~/.config/xray-split-tunnel/sub-url`;
2. точные domain suffix для bypass;
3. дополнительные корпоративные CIDR вне автоматически добавляемых сетей;
4. индекс или однозначное название XRay server;
5. нужен ли `SERVICE_SCOPE=user` или `system`; для паритета с текущим
   always-on setup используй `system`, только после согласия на точечный sudo;
6. разрешено ли менять обычный `~/.zshrc`; для dotfiles/stow/symlink предложи
   `XST_ZSHRC=0`;
7. установлен ли Citrix, импортированы ли profile/identity/CA и прошла ли
   ручная проверка внутреннего ресурса;
8. готов ли опубликованный `secure-access-helper`.

Если `sub-url` не подготовлен, попроси владельца самому выполнить локально:

```sh
install -d -m 700 "$HOME/.config/xray-split-tunnel"
/bin/bash -c 'umask 077; read -r -s -p "Subscription URL: " url; printf "\n"; printf "%s\n" "$url" > "$HOME/.config/xray-split-tunnel/sub-url"'
chmod 600 "$HOME/.config/xray-split-tunnel/sub-url"
```

Продолжай после ответа «файл подготовлен». Проверяй `stat`, но никогда `cat`.
Если URL уже был отправлен в чат, сначала потребуй его ротацию.

## Preflight без изменений

Работай только из стабильного checkout:

```sh
cd "$HOME/Projects/setup/xray-split-tunnel"
pwd
git status --short --branch
stat -f '%Su %Lp %N' "$HOME/.config/xray-split-tunnel" \
  "$HOME/.config/xray-split-tunnel/sub-url"
make test
```

Ожидаются владелец текущего пользователя, `700` у каталога и `600` у файла.
Не исправляй чужого владельца молча. Если release-копия не содержит `.git`,
сверь переданную SHA-256 с release manifest, а bare hash в `REVISION` — с
`commit=` в manifest. `make test` обязан вернуть `0`.

Существующий `XST_HOME` допустим только в одном из перечисленных состояний:
новый пустой каталог, каталог с действительным ownership marker XST,
preprovisioned-каталог только с `sub-url`, либо полный markerless legacy state
с `env`, `subscription.json`, `config.json`, `current-index`,
`active-config.sha256`, `shell.sh` и только allowlisted XST-файлами.
Markerless legacy принимается только когда hash совпадает с config, а
существующий plist дополнительно доказывает прежнюю XST-установку с теми же
label/scope/bin/config. Все state-файлы user-owned `0600`; сам каталог —
`0700`. Произвольный непустой каталог, symlink, чужой владелец, частичный или
не доказанный legacy state и неожиданный файл — причина остановиться, а не
«починить» права или удалить содержимое.

Проверь конфликт обоих service scopes и портов:

```sh
sudo launchctl print system/com.nqs.xray
launchctl print "gui/$(id -u)/com.xst.xray"
sudo launchctl print system/com.xst.xray
lsof -nP -iTCP:10809 -sTCP:LISTEN
lsof -nP -iTCP:10808 -sTCP:LISTEN
```

Эти команды могут возвращать non-zero, если сервиса/слушателя нет. Если найден
legacy `com.nqs.xray`, остановись на обычной установке и выполни
`docs/migration.md`. Нельзя оставлять два сервиса на одинаковых портах.
Наличие `/Library/LaunchDaemons/com.nqs.xray.plist` тоже блокирует установку,
даже если job уже выгружен: сначала вынеси plist в durable rollback-каталог по
runbook. Существующий целевой plist/job разрешён только когда `applied.env` и сам
plist доказывают, что это прежняя установка XST с тем же label и scope.
Foreign plist/job и артефакт в противоположном scope не перезаписывай.

Проверь Citrix отдельно:

```sh
cd "$HOME/Projects/setup/secure-access-helper"
secure-access-helper doctor
secure-access-helper status
```

Если helper или Citrix ещё не готовы, XRay можно подготовить, но полная приёмка
останется незавершённой. Явно отрази это в отчёте.

## Установка

Интерактивный путь предпочтителен: он позволяет владельцу проверить значения.
Всегда задавай решение по shell явно:

```sh
cd "$HOME/Projects/setup/xray-split-tunnel"
XST_ZSHRC=0 ./install.sh
```

До изменений выполни production dry-run с теми же несекретными параметрами:

```sh
XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh --dry-run
```

Используй `XST_ZSHRC=1` только после явного разрешения. При `XST_ZSHRC=0`
предложи владельцу добавить source-строку в управляемый shell-файл:

```sh
[ -f "$HOME/.config/xray-split-tunnel/shell.sh" ] && source "$HOME/.config/xray-split-tunnel/shell.sh"
```

Неинтерактивный режим разрешён, когда все ответы уже получены. Передай
server/ports штатными `XST_*`, а конфиденциальные domains/CIDR — только через
заранее созданный защищённый `XST_BYPASS_FILE`. Не задавай `XST_SUB_URL`:
установщик должен прочитать заранее созданный `sub-url`. `XST_ZSHRC` в таком
запуске также обязателен. Не используй
`XST_ASSUME_YES=1` для действий, на которые владелец не дал согласия.

Переменные интерфейса:

| Переменная | Назначение | Значение по умолчанию |
|---|---|---|
| `XST_SUB_FILE` | защищённый локальный XRay JSON вместо URL | нет |
| `XST_SUB_URL_FILE` | защищённый файл с URL, если не стандартный `sub-url` | стандартный путь |
| `XST_BYPASS_FILE` | защищённый data-only файл с `BYPASS_DOMAINS` и `BYPASS_CIDRS` | нет |
| `XST_SERVER` | индекс или однозначная часть remarks | `0` |
| `XST_HTTP_PORT` | HTTP listener | `10809` |
| `XST_SOCKS_PORT` | SOCKS5 listener | `10808` |
| `XST_LABEL` | launchd label | `com.xst.xray` |
| `XST_SERVICE_SCOPE` | `user` LaunchAgent или `system` LaunchDaemon | `user` |
| `XST_EXPORT_HTTPS_PROXY` | `1` для глобального shell proxy | `0` |
| `XST_ZSHRC` | `0` не менять, `1` изменить с разрешения | обязательно выбрать |
| `XST_LINK_BIN` | `0` не создавать `~/.local/bin/xst` | `1` |
| `XST_CLAUDE_COMMAND` | `1` установить `claude-xst`: proxy/NO_PROXY без инструкции Claude | `0`, либо сохранить owned link |
| `XST_CLAUDE_AWARE_COMMAND` | `1` установить `claude-xst-aware`: proxy/NO_PROXY с route-инструкцией | `0`, либо сохранить owned link |
| `XST_HOME` | каталог состояния, только для изолированных тестов | стандартный путь |

`XST_SUB_URL`, `XST_BYPASS_DOMAINS` и `XST_BYPASS_CIDRS` намеренно
отклоняются: значения оказались бы в process environment или transcript.
`XST_BYPASS_FILE` хранится с правами `0600` в защищённом каталоге вне
`XST_HOME`; он содержит ровно `BYPASS_DOMAINS=...` и `BYPASS_CIDRS=...`.

Установка не мигрирует label или scope неявно. Если сохранённый `applied.env`
описывает другой `LABEL`/`SERVICE_SCOPE`, остановись и выполни явный
uninstall/migration runbook; не удаляй plist противоположного scope ради
повторного запуска.

Mutating-команды используют fail-fast lock-каталог
`$XST_HOME/.xst-operation.lock` с правами `0700`. Не запускай параллельно
install/apply/update/switch/lifecycle/uninstall. Занятый или оставшийся после
аварии lock автоматически не удаляется: сначала докажи, что другой процесс не
работает, и только затем передай решение владельцу.

## Автоматическая проверка

Запусти:

```sh
cd "$HOME/Projects/setup/xray-split-tunnel"
./bin/xst verify
verify_rc=$?
printf 'xst verify exit=%s\n' "$verify_rc"
```

Не продолжай к утверждению об успехе, если exit code не `0`. В выводе должны
быть подтверждены:

1. `xray run -test` для активного конфига;
2. ожидаемый launchd-job, plist и его процесс с правильным config path;
3. HTTP и SOCKS listeners на ожидаемых loopback-портах;
4. непустые валидные direct/proxy IP и их различие;
5. `direct` для каждого `BYPASS_DOMAINS`;
6. `direct` для приватных и каждого `BYPASS_CIDRS`;
7. согласованный `NO_PROXY` для domain bypass.

Проверь реальные назначения по одному через `xst check`, не печатая
конфиденциальный список в итоговый отчёт.

Перед приёмкой `xst doctor` должен подтвердить permission audit: каталог
состояния принадлежит текущему пользователю и имеет `0700`, секретные/state
файлы — `0600` без symlink, user plist — user-owned `0600`, а system plist —
`root:wheel 0644`; target plist/job не должен быть foreign.

`xst update` сохраняет сервер не по индексу. Текущий config обязан иметь
явное непустое `remarks`, `remark`, `name`, `ps` или `tag`; полное
необрезанное нормализованное значение должно дать единственное
case-insensitive exact совпадение в новой подписке. Для внутреннего сравнения
используется SHA-256 этой identity, поэтому длинные одинаковые отображаемые
префиксы не сливаются. Числовое remarks, включая `0`, остаётся именем. Нет
имени, нет совпадения или совпадений несколько — update завершается без замены
состояния. До download active hash и детерминированная пересборка из текущих
subscription/index/applied.env должны совпасть с active config. Выбранный
container подписки содержит не более 512 candidate
elements до фильтрации (DoS guard), и каждый нормализованный config проходит
`xray run -test`.

## Ручная приёмка Citrix

Автоматизация не знает внутренний ресурс и не может завершить этот шаг без
владельца.

```sh
secure-access-helper doctor
secure-access-helper connect
secure-access-helper status
xst run curl -q -fsS https://api.ipify.org
```

Затем владелец выполняет две команды с локальным hidden-from-agent URL из
`docs/citrix-prerequisites.md`: прямой HTTPS-запрос и запрос через XRay с
очищенным `NO_PROXY`. Оба должны установить доверенный TLS и вернуть ненулевой
HTTP status. `secure-access-helper status` должен оставаться `Connected`.

Если Citrix отключён, сертификат отсутствует или владелец не выполнил живую
проверку, статус результата — «XRay готов, Citrix acceptance не завершён».

## Диагностика и rollback

| Симптом | Действие |
|---|---|
| subscription не скачивается | не проси URL; владелец проверяет/заменяет `sub-url` локально |
| формат не распознан | `docs/subscription-format.md`; используйте обезличенно конвертированный `XST_SUB_FILE` |
| xray отвергает config | покажи только диагностические строки после редактирования секретов |
| порт занят | найди PID/command через `lsof`; для `com.nqs.xray` выполни migration runbook |
| IP совпадают | проверь владельца listener, launchd-job и outbound |
| bypass не `direct` | исправь только подтверждённое владельцем значение и повтори `xst apply` |
| Citrix resource не работает | отдели Citrix profile/DNS/route/identity/CA от XRay routing |

При миграции rollback выполняется строго по `docs/migration.md`. Не удаляй
старый сервис ради освобождения порта без предварительно проверенной durable
копии plist вне `/Library/LaunchDaemons`. Rollback XST-транзакции не
восстанавливает legacy `com.nqs.xray` и не откатывает последующую ручную
Citrix acceptance: для них применяется отдельная ручная процедура runbook.

## Итоговый отчёт

Сообщи:

- commit/tag XST и `secure-access-helper`;
- версию macOS и xray-core;
- фактический label и порты;
- `xst verify exit=0`;
- количество проверенных domain/CIDR без перечисления, если они
  конфиденциальны;
- Citrix status и результат живой проверки либо точную причину, почему этот
  acceptance остаётся незавершённым;
- выбранный режим `XST_ZSHRC`;
- какие опциональные команды установлены: `claude-xst` и/или
  `claude-xst-aware`;
- выполнена ли миграция legacy и сохранён ли rollback.

Не включай subscription URL, endpoint, UUID, Reality keys, внутренний URL,
публичные IP, Citrix account или содержимое конфигов.

## Устройство репозитория

| Путь | Роль |
|---|---|
| `install.sh` | установка и первичная проверка |
| `bin/xst` | управление и verification |
| `lib/xstlib.py` | нормализация JSON, сборка config, route-check |
| `lib/common.sh` | пути, загрузка, launchctl и shell snippet |
| `templates/launchagent.plist.template` | безопасно рендерится как LaunchAgent/LaunchDaemon |
| `uninstall.sh` | снятие сервиса; `--purge` удаляет секретное состояние |
| `REVISION`, `.gitattributes`, `scripts/release.sh` | provenance и воспроизводимая release-сборка |
| `docs/` | формат, архитектура, Citrix и migration runbooks |

Маршрутизацию, shell bypass и verification меняют согласованно. После любого
изменения обязательны tests, `xray run -test`, `xst verify` и ручная проверка
Citrix.
