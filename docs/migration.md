# Миграция с `com.nqs.xray`

## Почему нужна отдельная процедура

Legacy setup использует системный LaunchDaemon `com.nqs.xray`, обычно:

- plist: `/Library/LaunchDaemons/com.nqs.xray.plist`;
- конфиг: `~/.config/xray/config.json`;
- HTTP: `127.0.0.1:10809`;
- SOCKS5: `127.0.0.1:10808`.

Новый setup использует label `com.xst.xray` и поддерживает user LaunchAgent
либо system LaunchDaemon, но оставляет те же дефолтные порты. Два процесса не
могут слушать их одновременно. Проверка только факта «порт слушается» способна
принять legacy-процесс за новый.

Обычный установщик намеренно ничего не делает с `com.nqs.xray`. Он откажет,
пока legacy job загружен или
`/Library/LaunchDaemons/com.nqs.xray.plist` остаётся на месте. Legacy plist
сначала сохраняется в durable rollback-каталоге вне
`/Library/LaunchDaemons`, затем job выгружается и оригинал убирается из
активного launchd-пути.

## Preflight

Не выводите содержимое старого конфига: в нём есть ключи. Соберите только
метаданные:

```sh
sudo launchctl print system/com.nqs.xray
launchctl print "gui/$(id -u)/com.xst.xray"
sudo launchctl print system/com.xst.xray
lsof -nP -iTCP:10809 -sTCP:LISTEN
lsof -nP -iTCP:10808 -sTCP:LISTEN
```

Эти проверки могут вернуть non-zero, если соответствующего job/listener нет.
Не продолжайте, если существующий `com.xst.xray` не доказан как прежняя
managed XST-установка или найден XST plist в противоположном scope.

Зафиксируйте потребителей старого proxy:

- `mac-setup`, который мог создавать `com.nqs.xray`;
- `remote-work-setup/bin/vpn` и связанные doctor-команды;
- shell-обёртки с переменной `VPN_PROXY`;
- приложения с жёстко заданным `127.0.0.1:10809`.

Потребители, использующие только HTTP endpoint `127.0.0.1:10809`, продолжат
работать после переключения. Управляющие скрипты, label, старые пути и
`VPN_PROXY` автоматически не мигрируют.

## Переключение

1. Подготовьте новый checkout в стабильном пути и защищённый `sub-url`.

2. Создайте новый durable rollback-каталог, скопируйте туда legacy plist и
   проверьте копию. Команды намеренно откажут, если этот путь уже занят:

   ```sh
   ROLLBACK_DIR="$HOME/.local/share/xst-migration/com.nqs.xray"
   test ! -e "$ROLLBACK_DIR"
   install -d -m 700 "$HOME/.local/share/xst-migration"
   mkdir -m 700 "$ROLLBACK_DIR"
   sudo install -o "$(id -un)" -g "$(id -gn)" -m 0600 \
     /Library/LaunchDaemons/com.nqs.xray.plist \
     "$ROLLBACK_DIR/com.nqs.xray.plist"
   sudo cmp -s /Library/LaunchDaemons/com.nqs.xray.plist \
     "$ROLLBACK_DIR/com.nqs.xray.plist"
   plutil -lint "$ROLLBACK_DIR/com.nqs.xray.plist"
   shasum -a 256 "$ROLLBACK_DIR/com.nqs.xray.plist" \
     > "$ROLLBACK_DIR/com.nqs.xray.plist.sha256"
   chmod 600 "$ROLLBACK_DIR/com.nqs.xray.plist.sha256"
   ```

   Не используйте XST state directory для этой копии:
   `uninstall.sh --purge` не должен затронуть legacy rollback. Зафиксируйте
   путь, но не содержимое plist, в акте миграции. Старый секретный config
   остаётся на прежнем месте и тоже не удаляется.

3. Выгрузите старый daemon и вынесите оригинальный plist из активного
   LaunchDaemons-пути в тот же rollback-каталог:

   ```sh
   sudo launchctl bootout system /Library/LaunchDaemons/com.nqs.xray.plist
   sudo mv /Library/LaunchDaemons/com.nqs.xray.plist \
     "$ROLLBACK_DIR/com.nqs.xray.plist.removed-from-launchd"
   test ! -e /Library/LaunchDaemons/com.nqs.xray.plist
   ```

4. Докажите, что оба порта свободны:

   ```sh
   ! lsof -nP -iTCP:10809 -sTCP:LISTEN
   ! lsof -nP -iTCP:10808 -sTCP:LISTEN
   ```

5. Выполните dry-run, затем установку с явными решениями по shell и scope.
   Для сохранения always-on поведения legacy выберите `system`:

   ```sh
   cd "$HOME/Projects/setup/xray-split-tunnel"
   XST_ZSHRC=0 XST_SERVICE_SCOPE=system ./install.sh --dry-run
   XST_ZSHRC=0 XST_SERVICE_SCOPE=system ./install.sh
   ```

   Эта команда не предназначена для смены scope существующей
   XST-установки. Такой конфликт требует отдельного uninstall/migration.

6. Выполните `xst verify`, затем полную ручную приёмку из
   [`citrix-prerequisites.md`](citrix-prerequisites.md).

7. Переведите управляющие скрипты со старого label/path на `xst`. Если старым
   обёрткам нужен `VPN_PROXY`, задайте его совместимость явно в управляемом
   shell-конфиге; XST экспортирует `XST_PROXY_URL`, но не обязан поддерживать
   legacy-имя.

Если `~/.zshrc` является symlink в dotfiles/stow-репозиторий, оставьте
`XST_ZSHRC=0` и добавьте source-строку вручную в исходный управляемый файл:

```sh
[ -f "$HOME/.config/xray-split-tunnel/shell.sh" ] && source "$HOME/.config/xray-split-tunnel/shell.sh"
```

Сгенерированный `shell.sh` сам объединяет существующие `NO_PROXY`/`no_proxy`
с managed списком и не стирает корпоративные исключения.

## Rollback

Installer rollback защищает только собственную XST transaction через запись
state/plist, старт, разрешённую shell/link-интеграцию и фиксацию
`applied.env`. Он не знает путь legacy-копии и не восстанавливает
`com.nqs.xray` после commit, провала позднего `xst verify` или ручной Citrix
acceptance.

Если новая автоматическая или ручная проверка не прошла, сначала выгрузите
новый job в реально выбранном scope и вынесите его plist из каталога, который
launchd прочитает при следующем login/boot. Для дефолтного system label:

```sh
ROLLBACK_DIR="$HOME/.local/share/xst-migration/com.nqs.xray"
sudo launchctl bootout system/com.xst.xray
if [ -f /Library/LaunchDaemons/com.xst.xray.plist ]; then
  test ! -e "$ROLLBACK_DIR/com.xst.xray.failed.plist"
  sudo mv /Library/LaunchDaemons/com.xst.xray.plist \
    "$ROLLBACK_DIR/com.xst.xray.failed.plist"
fi
! lsof -nP -iTCP:10809 -sTCP:LISTEN
! lsof -nP -iTCP:10808 -sTCP:LISTEN
```

Если был выбран `SERVICE_SCOPE=user`, вместо system bootout/move:

```sh
ROLLBACK_DIR="$HOME/.local/share/xst-migration/com.nqs.xray"
launchctl bootout "gui/$(id -u)/com.xst.xray"
if [ -f "$HOME/Library/LaunchAgents/com.xst.xray.plist" ]; then
  test ! -e "$ROLLBACK_DIR/com.xst.xray.failed.plist"
  mv "$HOME/Library/LaunchAgents/com.xst.xray.plist" \
    "$ROLLBACK_DIR/com.xst.xray.failed.plist"
fi
```

Если использован другой XST label или порты, подставьте только заранее
зафиксированные фактические значения. Не останавливайте job по догадке.

После освобождения портов восстановите проверенную legacy-копию с ожидаемыми
system ownership/mode и загрузите её:

```sh
ROLLBACK_DIR="$HOME/.local/share/xst-migration/com.nqs.xray"
shasum -a 256 -c "$ROLLBACK_DIR/com.nqs.xray.plist.sha256"
sudo install -o root -g wheel -m 0644 \
  "$ROLLBACK_DIR/com.nqs.xray.plist" \
  /Library/LaunchDaemons/com.nqs.xray.plist
sudo plutil -lint /Library/LaunchDaemons/com.nqs.xray.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.nqs.xray.plist
sudo launchctl print system/com.nqs.xray
lsof -nP -iTCP:10809 -sTCP:LISTEN
lsof -nP -iTCP:10808 -sTCP:LISTEN
```

После восстановления повторите старую рабочую проверку внешнего IP и
внутреннего ресурса. Не запускайте legacy daemon, пока новый agent занимает
порты. Если stop/move/restore/bootstrap завершился ошибкой, не продолжайте
поверх частичного состояния: сохраните оба plist и диагностируйте конкретный
launchd target.

## Завершение миграции

Legacy rollback-копии и старый секретный config можно вывести из эксплуатации
только после успешной работы нового setup в обычной пользовательской сессии и
после перезагрузки. Удаление выполняет владелец машины; AI-агент не удаляет
rollback без отдельного явного разрешения.

Итоговый handoff фиксирует:

- commit/tag обоих репозиториев;
- label `com.xst.xray`, выбранный scope и фактические порты;
- путь durable rollback-каталога без содержимого plist;
- источник управляемой shell-конфигурации;
- список обновлённых legacy-потребителей;
- результат `xst verify`, Citrix `status` и ручной проверки внутреннего
  ресурса — без URL, ключей и конфигов.
