# xray-split-tunnel

Production-oriented setup для macOS: локальный **xray-core** с HTTP/SOCKS5
proxy и правилами раздельной маршрутизации. Корпоративные домены и сети идут
через системный стек macOS, всё остальное — через выбранный XRay outbound.

Это не системный full-tunnel VPN. Трафик попадает в XRay только у приложений,
которым задан proxy. Citrix Secure Access устанавливается и подключается
отдельно; поддерживаемая интеграция описана в
[`docs/citrix-prerequisites.md`](docs/citrix-prerequisites.md).

```text
приложение с HTTP/SOCKS proxy
             |
             v
 xray-core, launchd com.xst.xray (user или system scope)
 HTTP 127.0.0.1:10809 · SOCKS5 127.0.0.1:10808
             |
             +-- private + BYPASS_CIDRS ------> direct ---> macOS/Citrix
             +-- BYPASS_DOMAINS --------------> direct ---> macOS/Citrix
             +-- всё остальное ---------------> XRay server
```

## Что входит в handoff

Для воспроизводимого setup нужны:

- опубликованный release этого репозитория;
- опубликованный release соседнего `secure-access-helper`;
- действующая XRay JSON subscription, введённая владельцем локально;
- точные корпоративные domain suffix и CIDR;
- установленный и вручную проверенный Citrix Secure Access с профилем,
  client identity и CA-цепочкой;
- один реальный внутренний HTTPS-ресурс для ручной приёмки.

Пароль Citrix, subscription URL, сертификаты и рабочие конфиги не входят в Git
и не передаются AI-агенту.

## Требования

- macOS 15 или новее, Apple Silicon или Intel;
- активная графическая сессия для `SERVICE_SCOPE=user`; для always-on режима
  доступен `SERVICE_SCOPE=system`;
- `python3`, `curl`, `lsof` и стандартные macOS utilities;
- Homebrew и `xray`, либо разрешение установить `xray` через Homebrew;
- subscription, которая возвращает полный XRay JSON — см.
  [`docs/subscription-format.md`](docs/subscription-format.md); выбранный
  container ограничен 512 candidate elements до фильтрации.

По умолчанию проект использует пользовательский LaunchAgent. Опциональный
system LaunchDaemon запускается до GUI-login, но требует точечного `sudo` для
установки/управления plist. Сам XRay в system scope всё равно работает от
целевого пользователя, а секретный config не копируется в `/Library`.

## Подготовка release-копии

Получите версионированный архив и SHA-256 у сопровождающего по независимым
каналам. После проверки распакуйте checkout в стабильный путь:

```sh
mkdir -p "$HOME/Projects/setup"
cd "$HOME/Projects/setup/xray-split-tunnel"
git status --short --branch
make test
```

Каталог должен остаться именно
`~/Projects/setup/xray-split-tunnel`: `~/.local/bin/xst` ссылается в checkout.
Не запускайте production-установку из Downloads, временного каталога или
случайной worktree.

Если release-копия передана без `.git`, вместо `git status` сверьте SHA-256
архива с отдельно полученной суммой. Затем сверьте hash в файле `REVISION`
внутри распакованного архива со значением `commit=` в release manifest.
`scripts/release.sh` проверяет эту подстановку при сборке. `make test` должен
завершиться с кодом `0` до первого изменения системы.

Публичный remote у проекта пока не зафиксирован в документации, поэтому здесь
намеренно нет вымышленной команды `git clone`. Сопровождающий обязан указать
реальный release tag, commit и checksum при передаче.

## Безопасный ввод subscription URL

URL содержит bearer-токен. Не вставляйте его в чат, shell-команду, environment
или лог агента. Владелец машины вводит URL без echo в локальный файл:

```sh
install -d -m 700 "$HOME/.config/xray-split-tunnel"
/bin/bash -c 'umask 077; read -r -s -p "Subscription URL: " url; printf "\n"; printf "%s\n" "$url" > "$HOME/.config/xray-split-tunnel/sub-url"'
chmod 600 "$HOME/.config/xray-split-tunnel/sub-url"
```

После этого агенту сообщают только: «`sub-url` подготовлен». Если ссылка уже
появлялась в чате или истории, её нужно перевыпустить до установки. Полная
политика — в [`SECURITY.md`](SECURITY.md).

### Обычный XRay JSON вместо подписки

Подписка необязательна. Один полный XRay JSON с корневым непустым массивом
`outbounds` можно передать как защищённый локальный файл:

```sh
install -d -m 700 "$HOME/.local/share/xst-import"
chmod 600 "$HOME/.local/share/xst-import/config.json"
XST_SUB_FILE="$HOME/.local/share/xst-import/config.json" \
  XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh --dry-run
XST_SUB_FILE="$HOME/.local/share/xst-import/config.json" \
  XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh
```

XST использует proxy-outbound подключения, но намеренно заменяет исходные
`inbounds` и `routing` своими loopback listener и правилами split tunneling.
Это безопасный импорт, а не запуск произвольного конфига «как есть». Для
локального файла автоматический `xst update` недоступен: чтобы применить его
новую версию, повторите установку с `XST_SUB_FILE`. Поддерживаемые протоколы и
формы JSON перечислены в
[`docs/subscription-format.md`](docs/subscription-format.md).

Для неинтерактивной установки корпоративные suffix/CIDR также передаются не
через environment, а через локальный файл `0600`:

```sh
install -d -m 700 "$HOME/.local/share/xst-input"
install -m 600 /dev/null "$HOME/.local/share/xst-input/bypass.env"
"${EDITOR:-vi}" "$HOME/.local/share/xst-input/bypass.env"
```

Формат файла data-only: ровно по одному ключу `BYPASS_DOMAINS=...` и
`BYPASS_CIDRS=...`. Затем передаётся только несекретный путь
`XST_BYPASS_FILE="$HOME/.local/share/xst-input/bypass.env"`.
Переменные `XST_BYPASS_DOMAINS`/`XST_BYPASS_CIDRS` отклоняются.

## Установка

Сначала решите, разрешено ли менять `~/.zshrc`:

- `XST_ZSHRC=0` — безопасный выбор для dotfiles/stow/symlink и любой
  автоматической установки;
- `XST_ZSHRC=1` — только если владелец явно разрешил изменить обычный
  пользовательский `~/.zshrc`.

Затем запустите:

```sh
cd "$HOME/Projects/setup/xray-split-tunnel"
XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh --dry-run
XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh
```

Для паритета с always-on setup явно выберите:

```sh
XST_ZSHRC=0 XST_SERVICE_SCOPE=system ./install.sh
```

Неинтерактивный запуск не отвечает «да» за владельца: установка Homebrew
разрешается отдельным `XST_INSTALL_XRAY=1`, а shell и service scope всегда
передаются явно.

Интерактивная установка объяснит различие и отдельно спросит про две
независимые команды:

- `claude-xst` — только запускает Claude через managed proxy/NO_PROXY, ничего
  не добавляя в контекст Claude;
- `claude-xst-aware` — делает то же и добавляет в сессию краткую несекретную
  инструкцию о split tunneling.

Можно установить одну команду, обе или ни одной. Для non-interactive режима
выбор задаётся независимо через `XST_CLAUDE_COMMAND=0|1` и
`XST_CLAUDE_AWARE_COMMAND=0|1`; по умолчанию новые команды не создаются, а
уже принадлежащие этой установке symlink сохраняются.

Установщик спросит сервер, корпоративные domain suffix, дополнительные CIDR и
порты. RFC1918, loopback, link-local и IPv6 ULA/link-local добавляются
автоматически. Публичные корпоративные диапазоны, включая `11.0.0.0/8`, нужно
указывать явно.

Неинтерактивную установку выполняйте только по [`AGENTS.md`](AGENTS.md). URL
должен браться из заранее подготовленного `sub-url`, а `XST_ZSHRC` всё равно
задаётся явно.

Если выбран `XST_ZSHRC=0`, подключите сниппет в управляемом shell-конфиге:

```sh
[ -f "$HOME/.config/xray-split-tunnel/shell.sh" ] && source "$HOME/.config/xray-split-tunnel/shell.sh"
```

Сгенерированный сниппет объединяет managed bypass с уже существующими
`NO_PROXY`/`no_proxy`, сохраняя прежние корпоративные исключения.

## Команды

```sh
xst status
xst doctor              # offline checks без внешней сети
xst list
xst switch 0
xst update
xst apply
xst check 192.168.1.1
xst run curl -q -fsS https://api.ipify.org
xst verify
xst logs
xst restart
xst stop
xst start
xst env
```

`xst switch` принимает индекс либо однозначную часть remarks. `xst update`
не переносит выбор по индексу: активный config должен иметь явное непустое
`remarks`, `remark`, `name`, `ps` или `tag`, и это полное имя должно
однозначно совпасть без учёта регистра с одним config новой подписки. Числовое
remarks остаётся именем, а не индексом. Без такого доказательства update
отменяется, сохраняя старое состояние. Перед загрузкой update также требует,
чтобы active hash совпадал, а текущие subscription/index и настройки из
`applied.env` детерминированно воспроизводили active config. После успешного
update нумерация может измениться: проверьте `xst list`.

## Как дать приложению XRay proxy

Глобальный `HTTPS_PROXY` по умолчанию выключен, чтобы корпоративные CLI не
попали в внешний туннель неожиданно.

- Разовый процесс: `xst run curl -q -fsS https://api.ipify.org`.
- Конкретное приложение: задайте HTTP proxy `127.0.0.1:10809` или SOCKS5
  `127.0.0.1:10808` в его настройках.
- Глобальный shell proxy: только после осознанного изменения
  `EXPORT_HTTPS_PROXY=1` в `~/.config/xray-split-tunnel/env` и `xst apply`.

Для Claude Code доступны две независимые опциональные команды:

```sh
claude-xst        # proxy/NO_PROXY, без дополнительной информации для Claude
claude-xst-aware  # то же + route-инструкция в контексте сессии
```

Обе команды не меняют обычную `claude` и `~/.claude/settings.json`. Они
запускают Claude через `xst run` и включают передачу hostname в proxy, поэтому
Claude и запущенные им proxy-aware команды наследуют обе формы
`HTTP(S)_PROXY` и `NO_PROXY`. `claude-xst` на этом останавливается: правила
пользователь может полностью описать в своём `CLAUDE.md`.
`claude-xst-aware` дополнительно передаёт стандартную несекретную инструкцию
из `templates/claude-xst-instructions.md`.

Корпоративные назначения идут системным путём, остальные — через XRay. XRay
routing остаётся вторым слоем проверки, если запрос всё же вошёл в proxy.
Утилита, которая полностью игнорирует стандартные proxy-переменные, этим
механизмом не перехватывается.

`NO_PROXY` — дополнительный shell-слой. Главная гарантия для запроса, уже
вошедшего в XRay, — routing rules `direct`.

Routing использует `IPIfNonMatch`: неизвестное доменное имя может быть
разрешено системным DNS, чтобы проверить IP/CIDR-правила, даже если затем
соединение пойдёт через XRay proxy. Это сознательный компромисс split
tunneling, а не DNS-privacy режим; подробности — в
[`docs/how-it-works.md`](docs/how-it-works.md).

## Изменение bypass

Отредактируйте `BYPASS_DOMAINS` и `BYPASS_CIDRS` в
`~/.config/xray-split-tunnel/env`, затем:

```sh
xst apply
xst verify
```

`env` — data-only формат `KEY=value`, а не shell script: не добавляйте
`export`, command substitution или shell escaping. Неизвестные/повторные ключи
отклоняются.

До успешного `xst apply` lifecycle и диагностика используют последний
доказанный `applied.env`; `status`, `logs` и emergency `stop` остаются
доступны, даже если pending `env` повреждён или отсутствует. При этом
`xst doctor` и `xst verify` возвращают non-zero, пока pending state не
применён или не восстановлен.

Проверяйте реальные значения через `xst check`. Не добавляйте домен или CIDR
«на всякий случай»: лишний bypass отправляет соответствующий трафик мимо
внешнего XRay.

## Проверка и приёмка

Автоматическая проверка:

```sh
xst verify
printf 'exit=%s\n' "$?"
```

Успех — exit code `0`, валидный config, точное соответствие plist и config
path, ожидаемый xray PID, оба принадлежащих ему локальных порта, обязательные
валидные direct/proxy IP и успешные проверки всех domain/CIDR bypass.
Предупреждение или частичный успех не заменяют exit code `0`. Для диагностики
без внешней сети используйте `xst doctor`; он также проверяет владельцев,
права state-файлов/plist и отсутствие подмены symlink.

Автоматическая проверка не доказывает работу Citrix. Для полной приёмки нужны:

1. `secure-access-helper doctor`;
2. `secure-access-helper status` со значением `Connected`;
3. успешный доступ к одному реальному внутреннему HTTPS-ресурсу напрямую;
4. успешный доступ к тому же ресурсу через локальный XRay proxy с маршрутом
   `direct`;
5. внешний IP через `xst run`, отличный от прямого.

Точные команды и критерии приведены в
[`docs/citrix-prerequisites.md`](docs/citrix-prerequisites.md). Отчёт содержит
только exit codes, версии, label, порты и факт доступности; URL, IP, ключи и
конфиги в отчёт не копируются.

## Citrix

Рекомендуемый порядок:

1. установить и вручную проверить Citrix;
2. установить и проверить `../secure-access-helper`;
3. собрать точные bypass domains/CIDRs;
4. установить XST;
5. выполнить автоматическую и ручную приёмку.

`direct` использует системный стек и попадёт в Citrix только когда Citrix
действительно подключён и создал нужные route/DNS. XST не может исправить
неверный Citrix profile, отсутствующий client identity или CA.

## Миграция со старого setup

Legacy system LaunchDaemon `com.nqs.xray` обычно уже слушает те же порты
`10809`/`10808`. Не запускайте новый agent параллельно: это создаёт конфликт и
может дать ложную уверенность, что новый сервис работает.

Выполните пошаговый rollback-safe runbook:
[`docs/migration.md`](docs/migration.md). До новой установки legacy plist
сначала сохраняется в durable rollback-каталоге вне
`/Library/LaunchDaemons`, проверяется и только затем убирается из активного
launchd-пути. Установщик ожидаемо откажет, пока
`/Library/LaunchDaemons/com.nqs.xray.plist` остаётся на месте. Старый конфиг и
rollback-копия plist сохраняются до полной приёмки и перезагрузки.

Смена `SERVICE_SCOPE` или label существующей XST-установки не выполняется
неявно. Используйте явный uninstall/migration runbook: foreign plist/job и
артефакт XST в противоположном scope установщик не перезаписывает.

## Файлы и права

| Путь | Назначение |
|---|---|
| `~/.config/xray-split-tunnel/env` | настройки, `0600` |
| `~/.config/xray-split-tunnel/applied.env` | последние доказанно применённые настройки, `0600` |
| `~/.config/xray-split-tunnel/sub-url` | subscription URL, секрет, `0600` |
| `~/.config/xray-split-tunnel/subscription.json` | ответ провайдера, секрет, `0600` |
| `~/.config/xray-split-tunnel/config.json` | активный XRay config, секрет, `0600` |
| `~/.config/xray-split-tunnel/current-index` | выбранный config, `0600` |
| `~/.config/xray-split-tunnel/active-config.sha256` | proof активного config, `0600` |
| `~/.config/xray-split-tunnel/shell.sh` | shell-переменные, `0600` |
| `~/Library/LaunchAgents/com.xst.xray.plist` | plist при `SERVICE_SCOPE=user` |
| `/Library/LaunchDaemons/com.xst.xray.plist` | root-owned plist при `SERVICE_SCOPE=system` |
| `~/Library/Logs/com.xst.xray.out.log` | stdout XRay |
| `~/Library/Logs/com.xst.xray.err.log` | stderr XRay |
| `~/.local/bin/xst` | symlink на `bin/xst` в checkout |
| `~/.local/bin/claude-xst` | опциональный Claude с XST proxy/NO_PROXY без route-инструкции |
| `~/.local/bin/claude-xst-aware` | опциональный Claude с XST proxy/NO_PROXY и route-инструкцией |

Фактические label и порты могут отличаться; `xst env` показывает активные
пути без вывода содержимого секретных файлов.

Каталог состояния должен принадлежать текущему пользователю и иметь `0700`;
его секретные и служебные файлы — `0600` и не symlink. User plist принадлежит
пользователю и имеет `0600`; system plist принадлежит `root:wheel` и имеет
`0644`. Новый установщик принимает только пустой каталог, доказанно managed
XST-каталог или
preprovisioned каталог с единственным защищённым `sub-url`, либо полный
markerless legacy state с `env`, `subscription.json`, `config.json`,
`current-index`, `active-config.sha256` и `shell.sh`, причём hash и
существующий plist должны отдельно доказать ту же XST identity. В legacy state
допустимы только известные XST-файлы:
`env`, `applied.env`, `sub-url`, `subscription.json`, `config.json`,
`current-index`, `active-config.sha256`, `shell.sh`; каждый — user-owned
`0600`. Произвольный непустой каталог и foreign plist/job отклоняются.

Mutating-операции используют fail-fast lock
`~/.config/xray-split-tunnel/.xst-operation.lock` (`0700`). Не запускайте
install/apply/update/switch/lifecycle/uninstall параллельно. Не удаляйте
занятый или stale lock автоматически: сначала убедитесь, что другой процесс
не выполняет операцию, затем разберите причину аварийного завершения.

## Диагностика

| Симптом | Действие |
|---|---|
| label не загружен | `xst logs`, затем `xst restart` |
| один из портов занят | найдите владельца через `lsof`; при legacy setup выполните migration runbook |
| proxy IP отсутствует или совпадает с direct | проверьте `xst status`, subscription и outbound |
| XRay отвергает config | запустите `xray run -test` по пути из `xst env`, не публикуя сам config |
| домен идёт не в `direct` | исправьте точный suffix в `BYPASS_DOMAINS`, затем `xst apply` |
| IP идёт не в `direct` | добавьте подтверждённый CIDR в `BYPASS_CIDRS`, затем `xst apply` |
| Citrix `Connected`, но ресурс недоступен | проверьте profile, DNS, route, identity и CA отдельно от XST |

Архитектура и ограничения подробно описаны в
[`docs/how-it-works.md`](docs/how-it-works.md).

## Удаление

```sh
cd "$HOME/Projects/setup/xray-split-tunnel"
./uninstall.sh
```

Обычное удаление оставляет секретное состояние для восстановления. Полный
purge необратимо удаляет subscription и config:

```sh
./uninstall.sh --purge
```

Выполняйте purge только после проверки точного пути, наличия резервной копии
при необходимости и явного решения владельца. `xray` Homebrew-пакет
автоматически не удаляется. Uninstall берёт service identity только из
зафиксированного `applied.env` и удаляет plist/job/logs лишь после exact proof.
Обычный uninstall остаётся доступен при отсутствующем или повреждённом pending
`env`; необратимый `--purge` требует полного owner/mode/marker audit. При
удалении managed блока `~/.zshrc` создаётся уникальная локальная backup-копия.

## Публикация release

Архив собирается только из clean `HEAD` с exact tag `v$(cat VERSION)`:

```sh
./scripts/release.sh
```

Скрипт запускает tests, создаёт детерминированный `.tar.gz`, SHA-256 manifest
и проверяет, что `git archive` подставил commit в `REVISION`, совпадающий с
manifest. Существующие artifact paths и symlink output directory не
перезаписываются. Криптографическую подпись Git tag этот workflow не проверяет
и не заявляет.

До передачи сопровождающий должен:

1. убедиться, что Git не содержит runtime state, subscription, ключи и
   сертификаты;
2. выполнить `make test` и shell/static checks;
3. проверить установку, transaction rollback и отдельный migration rollback
   на чистом пользователе macOS;
4. зафиксировать commit, создать точный version tag и неизменяемый архив;
5. опубликовать SHA-256 отдельно от архива;
6. убедиться, что указанный release `secure-access-helper` тоже доступен;
7. приложить заполненный, но обезличенный acceptance checklist.

До выполнения этих шагов checkout является development-снимком, а не
передаваемым production release.
