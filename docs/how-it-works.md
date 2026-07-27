# Как работает split tunneling

## Граница решения

`xray-split-tunnel` не создаёт системный VPN-интерфейс и не перехватывает трафик
всех приложений. Он поднимает два локальных proxy:

- HTTP на `127.0.0.1:10809`;
- SOCKS5 на `127.0.0.1:10808`.

Через XRay идёт только приложение, которому задан proxy. Для shell это
делается точечно через `xst run` либо явно экспортированными proxy-переменными.
Остальные приложения продолжают пользоваться системной маршрутизацией.

```text
приложение
    |
    | HTTP/SOCKS proxy
    v
XRay на loopback
    |
    +-- приватные и заданные CIDR --------> direct --+
    +-- заданные корпоративные домены ----> direct --+--> системный стек
    |                                                +--> Citrix, если подключён
    +-- остальное ------------------------> proxy -------> внешний XRay-сервер
```

## Три согласованных слоя

### 1. Маршрутизация XRay

`lib/xstlib.py` сначала создаёт приоритетное `direct`-правило корпоративных
доменных суффиксов, затем правило приватных и дополнительных CIDR. После них
сохраняются только provider rules, ведущие в контролируемый `block`; чужие
`direct`-правила отбрасываются. Проект принудительно использует
`IPIfNonMatch`: явный suffix проверяется до DNS, а не совпавший hostname может
быть разрешён системным resolver для проверки дополнительного CIDR. Если ни
одно правило не совпало, используется проверенный первый proxy outbound.

Это имеет privacy-следствие: DNS-запрос имени, которое в итоге пойдёт через
proxy outbound, может сначала попасть в системный resolver macOS/Citrix.
Проект намеренно не переносит provider DNS-конфигурацию и не обещает DNS
privacy. Если такая утечка имени недопустима, текущая схема `IPIfNonMatch` с
CIDR bypass не подходит без отдельного спроектированного DNS-слоя.

`direct` означает outbound xray-core `freedom`: соединение открывает системный
сетевой стек macOS. Если Citrix уже добавил маршрут к корпоративной сети,
соединение уйдёт через него. XRay не поднимает Citrix и не создаёт эти маршруты.

### 2. Переменные shell

Сгенерированный `shell.sh` объединяет уже существующие `NO_PROXY`/`no_proxy`
с managed значениями для loopback и корпоративных доменов, не стирая прежние
исключения. Это позволяет proxy-aware CLI обратиться к ним напрямую, не
заходя в XRay. CIDR в `NO_PROXY` поддерживают не все программы, поэтому
главной защитой для запроса, уже вошедшего в XRay, остаются routing rules.

Глобальные `HTTPS_PROXY`/`HTTP_PROXY` по умолчанию не нужны. `xst run` задаёт их
только дочернему процессу и не меняет текущий shell.

Опциональная `claude-xst` применяет тот же session-scoped environment и
включает `CLAUDE_CODE_PROXY_RESOLVES_HOSTS=1` для сохранения domain-routing,
но не добавляет информацию в контекст Claude. `claude-xst-aware` использует
тот же сетевой слой и дополнительно передаёт Claude несекретную инструкцию не
сбрасывать proxy/NO_PROXY. Это помогает reasoning агента, но сетевой выбор
остаётся детерминированным: NO_PROXY у proxy-aware клиента и routing rules
внутри XRay.

### 3. Системные маршруты Citrix

Citrix Secure Access устанавливает свои маршруты, DNS и, при необходимости,
доступ к внутренним resolver. Это отдельный prerequisite. Его установка,
профиль, сертификаты, пароль и UI-автоматизация находятся вне этого проекта;
см. `citrix-prerequisites.md` и соседний репозиторий
`../secure-access-helper`.

## Launchd scope

По умолчанию создаётся пользовательский LaunchAgent с label `com.xst.xray` в
`~/Library/LaunchAgents/`. Он загружается в домен `gui/$UID`, запускается после
входа пользователя в графическую сессию и перезапускается благодаря
`KeepAlive`:

- до логина proxy недоступен;
- сервис имеет права текущего пользователя;
- другой пользователь macOS получает отдельное состояние и отдельный agent;
- `xst stop` выгружает agent до следующего `xst start`/`xst restart`, повторной
  установки или нового входа пользователя, когда launchd снова прочитает plist.

Для always-on режима `SERVICE_SCOPE=system` создаёт root-owned plist в
`/Library/LaunchDaemons`, но задаёт `UserName` текущего пользователя. Секретный
config остаётся в его `~/.config`, а xray стартует до GUI-login. Установка,
restart и uninstall system scope используют точечный `sudo`.

Label, scope, пути к бинарнику и конфигу зафиксированы в plist. `xst status`
сверяет exact real executable, полный argv и UID процесса, проверяет строгий
plist/log hardening, оба принадлежащих процессу IPv4 loopback listener и hash
применённого config. Команда
`~/.local/bin/xst` является ссылкой в checkout репозитория, поэтому checkout
должен оставаться в `~/Projects/setup/xray-split-tunnel`. После переноса нужно
повторно запустить установку.

Существующий target plist/job принимается только вместе с `env` и core plist,
которые доказывают прежнюю managed XST-установку в том же scope. Foreign
plist/job или XST plist в противоположном scope блокирует операцию. Изменение
`LABEL`/`SERVICE_SCOPE` поверх работающей установки запрещено: это отдельная
migration/uninstall операция, а не автоматический перенос.

## Состояние и обновление

Рабочие файлы находятся в `~/.config/xray-split-tunnel/`:

- `sub-url` — секретный URL;
- `subscription.json` — нормализованные конфиги;
- `current-index` — выбранный сервер;
- `env` — порты, label и bypass-настройки;
- `applied.env` — последние настройки, для которых runtime proof завершился;
- `config.json` — активный конфиг XRay;
- `active-config.sha256` — hash конфигурации после успешного запуска;
- `shell.sh` — сгенерированные переменные shell.

`xst update` скачивает подписку заново, а `xst apply` пересобирает активный
config из сохранённых данных. При update активный server переносится по
единственному case-insensitive exact полному имени из
`remarks`/`remark`/`name`/`ps`/`tag`, не по индексу. Сравнивается SHA-256
необрезанной нормализованной identity; числовое remarks, включая `0`, тоже
остаётся именем. Если идентичность нельзя доказать, обновление отменяется и
старая subscription остаётся активной. Выбранный container подписки
ограничен 512 candidate elements до фильтрации, и каждый нормализованный
config проходит `xray run -test`.

До сетевой загрузки `update` требует совпадения active hash и
детерминированно пересобирает текущий selection из subscription/index и
`applied.env`: результат должен байт-в-байт совпасть с active config.
`start`/`restart` также
не «узаконивают» вручную изменённый config — им нужен прежний active hash и
успешный `xray run -test`; для управляемой пересборки используется `xst apply`.

Mutating-команды захватывают fail-fast directory lock
`$XST_HOME/.xst-operation.lock` (`0700`). Они не ждут параллельную операцию и не
удаляют неизвестный/stale lock автоматически. Read-only диагностика не даёт
права снимать lock.

`apply`/`update` создают snapshot `env`, `applied.env`, `sub-url`,
subscription, config, index, active hash и сгенерированного `shell.sh`. Если
restart и проверка процесса/config/listeners не проходят, команда возвращает
snapshot, перезапускает сервис с последними доказанными settings из
`applied.env`, а pending edit `env` сохраняет для исправления. Install
transaction аналогично защищает
state/plist, запуск, active hash, явно разрешённый managed `~/.zshrc` block и
созданный ею command symlink до записи `applied.env` и signal-safe commit
bookkeeping. Это commit boundary; lock затем снимается с проверкой owner token.
Ошибка его снятия и провал идущего после commit `xst verify` не откатывают уже
принятую установку. Ручная Citrix acceptance и legacy migration всегда имеют
отдельный ручной rollback.

## Ограничения

- Split tunneling по домену зависит от имени назначения, доступного XRay через
  HTTP CONNECT/SNI sniffing. Приложение, подключающееся к IP напрямую, требует
  соответствующего CIDR.
- `xst check` — детерминированная проверка конфигурации, а не доказательство
  доступности реального ресурса.
- Успешный `xst verify` доказывает работу XRay, но не наличие Citrix-профиля,
  сертификата, DNS и прав доступа.
- Два процесса не могут одновременно слушать `10809`/`10808`. Перед миграцией
  со старого `com.nqs.xray` выполните `migration.md`.
- State directory обязан быть user-owned `0700`; state/secret files —
  user-owned `0600` без symlink. Произвольный непустой `XST_HOME` не
  усыновляется автоматически.
