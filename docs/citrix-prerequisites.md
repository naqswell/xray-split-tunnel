# Citrix: prerequisites и интеграция

## Ответственность компонентов

`xray-split-tunnel` не устанавливает, не авторизует и не ремонтирует Citrix
Secure Access. Он только гарантирует, что перечисленные корпоративные
назначения выходят через системный стек macOS, где ими уже управляет Citrix.

Автоматизация Citrix находится в отдельном checkout:

```text
~/Projects/setup/
├── xray-split-tunnel/
└── secure-access-helper/
```

Для воспроизводимого handoff оба checkout должны быть опубликованными
версиями, а не локальными незапушенными ветками.

## Что подготовить до XRay

Владелец корпоративного доступа должен:

1. установить одобренную организацией версию Citrix Secure Access;
2. создать или импортировать рабочий connection profile;
3. импортировать client identity с приватным ключом в login Keychain;
4. импортировать требуемые root/intermediate CA по политике организации;
5. один раз подключиться вручную и подтвердить доступ к реальному внутреннему
   HTTPS-ресурсу;
6. передать точный список корпоративных доменных суффиксов и CIDR для bypass.

Нельзя угадывать gateway, домены или подсети по DNS-кэшу и нельзя копировать
профиль/сертификаты с другой машины без разрешения владельца.

Client identity передаётся только защищённым каналом. Экспорт `.p12` удаляется
с обеих машин после импорта и не попадает в Git, чат или облачную папку.

## Установка helper

Получите опубликованную версию `secure-access-helper` и разместите её в
`~/Projects/setup/secure-access-helper`, затем следуйте его `README.md`:

```sh
cd "$HOME/Projects/setup/secure-access-helper"
./install.sh
secure-access-helper doctor
secure-access-helper connect
secure-access-helper status
```

Пароль вводится самим пользователем в локальный prompt и хранится в macOS
Keychain. Агенту пароль не сообщается.

`status` должен показывать фактическое состояние `Connected`, полученное через
`scutil`. Закрывшееся окно Citrix или успешный UI-клик не считаются
подтверждением туннеля.

Watchdog ставится отдельно и только после ручного успешного подключения:

```sh
secure-access-helper install-agent
```

Для UI scripting потребуются Accessibility-права. LaunchAgent watchdog имеет
отдельный TCC-контекст; успешный `doctor` из Terminal не доказывает, что
фоновый reconnect сможет управлять UI. Это проверяется живым разрывом при
разблокированной GUI-сессии и просмотром watchdog-лога.

## Сбор bypass-данных

В handoff нужно зафиксировать без секретов:

- доменные суффиксы внутренних сервисов;
- дополнительные CIDR вне RFC1918;
- один реальный HTTPS URL для ручной приёмки, переданный закрыто, если сам FQDN
  конфиденциален;
- ожидаемый результат `secure-access-helper status`.

RFC1918, loopback, link-local и IPv6 ULA/link-local добавляются XST
автоматически. Корпоративная сеть `11.0.0.0/8` не является приватной RFC1918 и,
если она используется, должна быть явно указана в `BYPASS_CIDRS`.

## Критерии приёмки Citrix + XRay

Сначала:

```sh
secure-access-helper doctor
secure-access-helper connect
secure-access-helper status
xst verify
```

Затем пользователь локально вводит реальный URL, не передавая его агенту:

```sh
/bin/bash -c '
set +x
read -r -s -p "Internal HTTPS URL: " url
printf "\n"
printf "%s" "$url" | python3 -c '"'"'
import sys
from urllib.parse import urlsplit
value = sys.stdin.read(8193)
try:
    parsed = urlsplit(value)
except ValueError:
    raise SystemExit(1)
valid = (
    len(value) <= 8192
    and parsed.scheme == "https"
    and parsed.hostname
    and parsed.username is None
    and parsed.password is None
    and not any(ord(ch) <= 32 or ord(ch) == 127 for ch in value)
)
raise SystemExit(0 if valid else 1)
'"'"' || { printf "invalid internal HTTPS URL\n" >&2; exit 1; }
escaped_url="${url//\\/\\\\}"
escaped_url="${escaped_url//\"/\\\"}"
code="$(
  printf "url = \"%s\"\n" "$escaped_url" | env \
    -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy \
    -u NO_PROXY -u no_proxy \
    curl -q --proto "=https" --connect-timeout 15 --silent \
      --output /dev/null --write-out "%{http_code}" --config - \
      2>/dev/null
)" || { printf "direct HTTPS request failed\n" >&2; exit 1; }
printf "HTTP %s\n" "$code"
test -n "$code" && test "$code" != 000
'
```

`curl -q` обязан оставаться первым curl option: это отключает
пользовательский `~/.curlrc`, который иначе способен незаметно добавить proxy,
`-k`, output или другой endpoint.

При включённых proxy-переменных тот же ресурс должен оставаться доступным
благодаря `NO_PROXY`. Для проверки именно XRay routing команда ниже проверяет
владельца/права сгенерированного `shell.sh`, берёт из него фактический
`XST_PROXY_URL`, очищает `NO_PROXY` только у тестового процесса и явно
направляет запрос в этот локальный proxy. URL и значение proxy не печатаются:

```sh
/bin/bash -c '
set +x
state="$HOME/.config/xray-split-tunnel/shell.sh"
test -f "$state" && test ! -L "$state"
test "$(stat -f "%u" "$state")" = "$(id -u)"
test "$(stat -f "%Lp" "$state")" = 600
. "$state"
case "$XST_PROXY_URL" in
  http://127.0.0.1:*) proxy_port="${XST_PROXY_URL##*:}" ;;
  *) printf "invalid protected XST proxy state\n" >&2; exit 1 ;;
esac
case "$proxy_port" in
  ""|*[!0-9]*) printf "invalid protected XST proxy state\n" >&2; exit 1 ;;
esac
test "$proxy_port" -ge 1 && test "$proxy_port" -le 65535
read -r -s -p "Internal HTTPS URL: " url
printf "\n"
printf "%s" "$url" | python3 -c '"'"'
import sys
from urllib.parse import urlsplit
value = sys.stdin.read(8193)
try:
    parsed = urlsplit(value)
except ValueError:
    raise SystemExit(1)
valid = (
    len(value) <= 8192
    and parsed.scheme == "https"
    and parsed.hostname
    and parsed.username is None
    and parsed.password is None
    and not any(ord(ch) <= 32 or ord(ch) == 127 for ch in value)
)
raise SystemExit(0 if valid else 1)
'"'"' || { printf "invalid internal HTTPS URL\n" >&2; exit 1; }
escaped_url="${url//\\/\\\\}"
escaped_url="${escaped_url//\"/\\\"}"
code="$(
  printf "url = \"%s\"\n" "$escaped_url" | env \
    -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy \
    -u NO_PROXY -u no_proxy \
    curl -q --proto "=https" --proxy "$XST_PROXY_URL" --connect-timeout 15 \
      --silent --output /dev/null --write-out "%{http_code}" --config - \
      2>/dev/null
)" || { printf "proxied HTTPS request failed\n" >&2; exit 1; }
printf "HTTP through XRay/direct: %s\n" "$code"
test -n "$code" && test "$code" != 000
'
```

Оба запроса должны установить TLS с доверенной CA и получить ненулевой HTTP
status. Не добавляйте `-k`: иначе проверка не выявит отсутствующую
корпоративную CA-цепочку.

В обоих примерах URL передаётся curl через config stream на stdin, а не через
argv/environment; поэтому bearer/path не виден в списке процессов.

Полная приёмка завершается только если внешний запрос через `xst run` показывает
IP XRay, а внутренний ресурс остаётся доступен при состоянии Citrix
`Connected`.
