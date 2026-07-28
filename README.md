# xray-split-tunnel

Установка XRay на macOS с раздельной маршрутизацией для корпоративного
доступа через Citrix Secure Access.

Проект поднимает локальные HTTP- и SOCKS5-прокси, направляет корпоративные
домены и сети в системный стек macOS, а остальной прокси-трафик — через
выбранный XRay-сервер.

```text
приложение
    |
    | HTTP 127.0.0.1:10809
    | SOCKS5 127.0.0.1:10808
    v
 xray-core
    |
    +-- корпоративные домены и CIDR --> direct --> macOS / Citrix
    |
    +-- остальной трафик ------------> XRay server
```

Это explicit proxy, а не системный full-tunnel VPN: через XRay идут только
приложения, которым назначен прокси или которые запущены через `xst run`.

## Быстрый старт через Claude Code

Откройте Claude Code в любом каталоге и отправьте ему один запрос:

```text
Установи XRay split tunneling из репозитория
https://github.com/naqswell/xray-split-tunnel.

Сам клонируй последнюю стабильную версию в постоянный служебный каталог,
прочитай CLAUDE.md и AGENTS.md и выполни весь сценарий установки.

Не проси меня создавать файлы или выполнять команды. Для subscription URL
сам запусти scripts/capture-sub-url.sh: я вставлю ссылку только в скрытое
системное окно macOS, не в чат.

Сначала выполни preflight и dry-run. Затем покажи краткое резюме изменений,
запроси одно подтверждение и выполни установку, xst verify и отдельную
проверку Citrix.
```

Claude самостоятельно:

1. клонирует репозиторий в постоянный каталог;
2. проверит окружение и существующие XRay/launchd-конфликты;
3. откроет защищённый ввод ссылки подписки;
4. соберёт параметры split tunneling;
5. выполнит тесты и `--dry-run`;
6. после подтверждения установит сервис и команды;
7. запустит автоматическую проверку XRay и отдельную приёмку Citrix.

От пользователя потребуются только:

- вставить subscription URL в скрытое системное окно;
- подтвердить параметры установки;
- ввести пароль macOS, если выбран system scope с `sudo`;
- пройти корпоративную авторизацию Citrix, если она ещё не выполнена.

Subscription URL не нужно отправлять Claude или сохранять вручную.

## Требования

- macOS 15 или новее;
- `python3`, `curl`, `lsof` и стандартные утилиты macOS;
- Homebrew и `xray`, либо разрешение установить `xray` через Homebrew;
- XRay JSON subscription или обычный полный XRay JSON;
- для корпоративного доступа — установленный Citrix Secure Access, рабочий
  профиль, client identity и CA-цепочка;
- точные корпоративные domain suffix и дополнительные CIDR.

Проект устанавливает и настраивает XRay. Citrix-клиент, профиль и сертификаты
относятся к корпоративному доступу и проверяются отдельно по
[`docs/citrix-prerequisites.md`](docs/citrix-prerequisites.md).

## Ручная установка

Этот раздел нужен только для установки без AI-агента.

Клонируйте репозиторий в любой постоянный каталог:

```sh
git clone https://github.com/naqswell/xray-split-tunnel.git
cd xray-split-tunnel
```

Checkout нельзя удалять после установки: команды в `~/.local/bin` ссылаются
на него. Если каталог был перенесён, повторно запустите `install.sh`.

### 1. Введите subscription URL

```sh
./scripts/capture-sub-url.sh
```

Откроется нативное окно macOS со скрытым вводом. Helper проверит HTTPS URL и
атомарно сохранит его в `~/.config/xray-split-tunnel/sub-url` с правами
`0600`.

Для замены ссылки:

```sh
./scripts/capture-sub-url.sh --replace
```

### 2. Выполните dry-run

```sh
XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh --dry-run
```

Dry-run загружает и проверяет subscription, собирает все конфиги, запускает
`xray run -test` и проверяет launchd plist, не устанавливая сервис.

### 3. Установите сервис

```sh
XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh
```

Для запуска XRay до входа пользователя в macOS выберите system scope:

```sh
XST_ZSHRC=0 XST_SERVICE_SCOPE=system ./install.sh
```

System scope требует точечного `sudo`. Сам процесс XRay продолжает работать от
целевого пользователя, а секретный конфиг не копируется в `/Library`.

## Обычный XRay JSON без подписки

Вместо URL можно передать локальный файл:

```sh
chmod 600 /path/to/config.json
XST_SUB_FILE=/path/to/config.json \
  XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh --dry-run
XST_SUB_FILE=/path/to/config.json \
  XST_ZSHRC=0 XST_SERVICE_SCOPE=user ./install.sh
```

Поддерживается один полный XRay-конфиг с корневым массивом `outbounds`, массив
конфигов или один из документированных wrapper-форматов.

XST использует proxy outbounds, но заменяет исходные `inbounds`, `routing`,
DNS/API/logging и другие чувствительные top-level секции своими безопасными
настройками. Подробности:
[`docs/subscription-format.md`](docs/subscription-format.md).

Для локального файла автоматический `xst update` недоступен. Новую версию
применяют повторным запуском установщика с `XST_SUB_FILE`.

## Основные параметры установки

| Параметр | Назначение | По умолчанию |
|---|---|---|
| `XST_SERVICE_SCOPE` | `user` LaunchAgent или `system` LaunchDaemon | `user` |
| `XST_ZSHRC` | разрешить изменение обычного `~/.zshrc` | требуется явный `0` или `1` |
| `XST_SERVER` | индекс или однозначная часть имени сервера | `0` |
| `XST_HTTP_PORT` | локальный HTTP proxy | `10809` |
| `XST_SOCKS_PORT` | локальный SOCKS5 proxy | `10808` |
| `XST_BYPASS_FILE` | защищённый файл с domain/CIDR bypass | нет |
| `XST_CLAUDE_COMMAND` | установить `claude-xst` | `0` |
| `XST_CLAUDE_AWARE_COMMAND` | установить `claude-xst-aware` | `0` |

RFC1918, loopback, link-local и IPv6 ULA/link-local добавляются в direct
автоматически. Публичные корпоративные сети необходимо указывать явно.

Глобальный `HTTP_PROXY`/`HTTPS_PROXY` по умолчанию не включается.

## Управление

```sh
xst status
xst doctor
xst list
xst switch 0
xst update
xst apply
xst check intranet.example.com
xst run curl -q -fsS https://api.ipify.org
xst verify
xst logs
xst restart
xst stop
xst start
xst env
```

- `xst doctor` выполняет offline-проверку состояния и прав.
- `xst list` показывает доступные серверы.
- `xst switch` переключает сервер по индексу или однозначной части имени.
- `xst update` безопасно обновляет subscription, сохраняя выбранный сервер по
  его устойчивой identity, а не по индексу.
- `xst check` показывает ожидаемый маршрут для одного hostname или IP.
- `xst run` запускает отдельный процесс с proxy и объединённым `NO_PROXY`.
- `xst verify` выполняет полную автоматическую проверку XRay.

## Claude через XRay

Установщик может добавить две независимые команды:

```sh
claude-xst
claude-xst-aware
```

`claude-xst` запускает Claude через `xst run`, передаёт обе формы
`HTTP(S)_PROXY` и `NO_PROXY`, но ничего не добавляет в контекст Claude.

`claude-xst-aware` использует тот же сетевой слой и дополнительно передаёт
несекретную инструкцию о правилах split tunneling. Это удобно, если сессия
должна понимать назначение proxy и `NO_PROXY`.

Обычная команда `claude` и `~/.claude/settings.json` не изменяются.

## Проверка

После установки:

```sh
xst verify
```

Успешный результат подтверждает:

- валидность активного XRay config;
- точное соответствие launchd job и plist;
- владельца процесса и оба loopback listener;
- различие direct и proxy egress;
- direct-маршрут для настроенных доменов и CIDR;
- согласованность `NO_PROXY`.

`xst verify` проверяет XRay, но не доказывает работу Citrix.

Для полной приёмки Citrix необходимы:

1. состояние `Connected`;
2. успешный прямой HTTPS-запрос к реальному внутреннему ресурсу;
3. успешный запрос к тому же ресурсу через XRay с маршрутом `direct`;
4. внешний egress через XRay, отличный от прямого.

Пошаговая процедура:
[`docs/citrix-prerequisites.md`](docs/citrix-prerequisites.md).

## Безопасность

Subscription URL, XRay config, UUID/Reality-параметры, Citrix credentials,
сертификаты и внутренние адреса не должны попадать в Git, чат или логи.

`scripts/capture-sub-url.sh` получает URL через скрытый системный диалог. URL
не передаётся через аргументы или environment и не печатается в stdout.

Если ссылка уже была опубликована в чате или issue, её необходимо отозвать и
перевыпустить перед production-установкой.

Рабочее состояние хранится в `~/.config/xray-split-tunnel`:

| Данные | Права |
|---|---|
| каталог состояния | `0700` |
| `sub-url`, `subscription.json`, `config.json`, настройки | `0600` |
| user LaunchAgent plist | `0600`, владелец — пользователь |
| system LaunchDaemon plist | `0644`, владелец — `root:wheel` |
| launchd logs | `0600` |

Полная модель угроз и правила работы с секретами:
[`SECURITY.md`](SECURITY.md).

## Миграция

Существующий LaunchDaemon `com.nqs.xray` обычно использует те же порты.
Установщик остановится, если обнаружит legacy setup или конфликтующий
plist/job.

Не удаляйте старую установку вручную. Используйте rollback-safe процедуру:
[`docs/migration.md`](docs/migration.md).

## Удаление

Из каталога репозитория:

```sh
./uninstall.sh
```

Обычное удаление останавливает сервис и удаляет принадлежащие установке
plist/job, logs и command symlinks, но сохраняет секретное состояние.

Полное удаление состояния:

```sh
./uninstall.sh --purge
```

`--purge` необратимо удаляет subscription и активный config.

## Документация

- [Инструкция для AI-агента](AGENTS.md)
- [Архитектура и маршрутизация](docs/how-it-works.md)
- [Формат subscription и локального JSON](docs/subscription-format.md)
- [Citrix prerequisites и acceptance](docs/citrix-prerequisites.md)
- [Миграция с legacy setup](docs/migration.md)
- [Политика безопасности](SECURITY.md)
- [История изменений](CHANGELOG.md)
