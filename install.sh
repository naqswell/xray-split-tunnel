#!/usr/bin/env bash
# Install or safely re-apply xray-split-tunnel on macOS.
set -euo pipefail
umask 077

# Reject legacy secret-bearing environment interfaces before the first child
# process can inherit them. Protected files/stdin are the only supported
# automation channels for subscription and bypass data.
if [[ ${XST_SUB_URL+x} == x ]]; then
  printf 'xst: XST_SUB_URL запрещён; используй защищённый sub-url\n' >&2
  exit 1
fi
if [[ ${XST_BYPASS_DOMAINS+x} == x || ${XST_BYPASS_CIDRS+x} == x ]]; then
  printf 'xst: XST_BYPASS_DOMAINS/XST_BYPASS_CIDRS запрещены; используй XST_BYPASS_FILE\n' >&2
  exit 1
fi
unset XST_SUB_URL XST_BYPASS_DOMAINS XST_BYPASS_CIDRS
unset SUB_URL subscription_url xst_secret_url escaped_url
export -n BYPASS_DOMAINS BYPASS_CIDRS 2>/dev/null || true

XST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$XST_ROOT/lib/common.sh"

INTERACTIVE=1
DRY_RUN=0
ASSUME_YES="${XST_ASSUME_YES:-0}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--non-interactive] [--yes] [--dry-run]

  --non-interactive  Never prompt. XST_ZSHRC=0|1 is mandatory.
  --yes              Allow dependency installation prompts only.
  --dry-run          Download/read, normalize, build and validate in a
                     temporary directory without changing the system.

The subscription URL must be in a protected file. Use the default
~/.config/xray-split-tunnel/sub-url or XST_SUB_URL_FILE=/protected/path.
Confidential non-interactive bypass values must be in XST_BYPASS_FILE.
XST_SUB_URL and XST_BYPASS_DOMAINS/XST_BYPASS_CIDRS are rejected.
Set XST_CLAUDE_COMMAND=1 and/or XST_CLAUDE_AWARE_COMMAND=1 for optional
Claude launch commands.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive|-n) INTERACTIVE=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "неизвестный аргумент: $1"
      ;;
  esac
  shift
done
[[ -t 0 ]] || INTERACTIVE=0

if [[ "$(id -u)" == 0 ]]; then
  die "не запускай install.sh от root; sudo используется точечно для system scope"
fi
case "${XST_ZSHRC+x}:${XST_ZSHRC:-}" in
  x:0|x:1) ;;
  *)
    die "задай явное решение XST_ZSHRC=0 или XST_ZSHRC=1"
    ;;
esac
case "${XST_LINK_BIN:-1}" in
  0|1) ;;
  *) die "XST_LINK_BIN должен быть 0 или 1" ;;
esac
if [[ ${XST_CLAUDE_COMMAND+x} == x ]]; then
  case "$XST_CLAUDE_COMMAND" in
    0|1) ;;
    *) die "XST_CLAUDE_COMMAND должен быть 0 или 1" ;;
  esac
fi
if [[ ${XST_CLAUDE_AWARE_COMMAND+x} == x ]]; then
  case "$XST_CLAUDE_AWARE_COMMAND" in
    0|1) ;;
    *) die "XST_CLAUDE_AWARE_COMMAND должен быть 0 или 1" ;;
  esac
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xst-install.XXXXXX")"
chmod 700 "$WORK_DIR"
INSTALL_ROLLBACK_NEEDED=0
PRESERVE_WORK_DIR=0
EARLY_MARKER_CREATED=0
EARLY_STATE_CREATED=0
cleanup_install() {
  local rollback_rc=0 marker_cleanup_needed=0 state_cleanup_needed=0
  trap '' HUP INT TERM
  if [[ "${INSTALL_ROLLBACK_NEEDED:-0}" == 1 ]] &&
    type rollback_service_install >/dev/null 2>&1; then
    set +e
    rollback_service_install
    rollback_rc=$?
    INSTALL_ROLLBACK_NEEDED=0
    if [[ $rollback_rc -ne 0 ]]; then
      PRESERVE_WORK_DIR=1
      EARLY_MARKER_CREATED=0
      EARLY_STATE_CREATED=0
      XST_PREPARED_MARKER_CREATED=0
      XST_PREPARED_STATE_CREATED=0
    fi
  fi
  [[ "${EARLY_MARKER_CREATED:-0}" == 1 ||
      "${XST_PREPARED_MARKER_CREATED:-0}" == 1 ]] &&
    marker_cleanup_needed=1
  [[ "${EARLY_STATE_CREATED:-0}" == 1 ||
      "${XST_PREPARED_STATE_CREATED:-0}" == 1 ]] &&
    state_cleanup_needed=1
  if [[ "$marker_cleanup_needed" == 1 &&
        -n "${XST_OPERATION_LOCK_TOKEN:-}" ]] &&
    xst_check_operation_lock "$XST_OPERATION_LOCK_TOKEN" >/dev/null 2>&1 &&
    [[ -f "$MANAGED_MARKER" && ! -L "$MANAGED_MARKER" ]] &&
    xst_check_owned_file "$MANAGED_MARKER" 600 >/dev/null 2>&1 &&
    printf '%s\n' "$MANAGED_MARKER_VALUE" | cmp -s - "$MANAGED_MARKER"; then
    rm -f "$MANAGED_MARKER" || true
  fi
  if type xst_release_operation_lock >/dev/null 2>&1; then
    xst_release_operation_lock >/dev/null 2>&1 || true
  fi
  if [[ "$state_cleanup_needed" == 1 &&
        -d "$XST_HOME" && ! -L "$XST_HOME" ]]; then
    rmdir "$XST_HOME" 2>/dev/null || true
  fi
  XST_PREPARED_MARKER_CREATED=0
  XST_PREPARED_STATE_CREATED=0
  if [[ "${PRESERVE_WORK_DIR:-0}" != 1 &&
        -n "${WORK_DIR:-}" &&
        "$WORK_DIR" == "${TMPDIR:-/tmp}"/xst-install.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup_install EXIT
trap 'exit 130' HUP INT TERM

ask() {
  local result_var="$1" prompt="$2" default="$3" preset_set="$4" preset="$5"
  local hide_value="${6:-0}" reply shown
  if [[ "$preset_set" == 1 ]]; then
    printf -v "$result_var" '%s' "$preset"
    if [[ "$hide_value" == 1 ]]; then
      ok "$prompt → задано из окружения"
    else
      shown="${preset:-(пусто)}"
      ok "$prompt → $shown (из окружения)"
    fi
    return
  fi
  if [[ "$INTERACTIVE" == 0 ]]; then
    printf -v "$result_var" '%s' "$default"
    if [[ "$hide_value" == 1 ]]; then
      ok "$prompt → используется сохранённое значение"
    else
      shown="${default:-(пусто)}"
      ok "$prompt → $shown (дефолт)"
    fi
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s?%s %s [%s]: ' "$C_B" "$C_R" "$prompt" "$default")" reply
    reply="${reply:-$default}"
  else
    read -r -p "$(printf '%s?%s %s: ' "$C_B" "$C_R" "$prompt")" reply
  fi
  printf -v "$result_var" '%s' "$reply"
}

confirm_dependency_install() {
  local reply
  if [[ "${XST_INSTALL_XRAY:-0}" == 1 || "$ASSUME_YES" == 1 ]]; then
    return 0
  fi
  if [[ "$INTERACTIVE" == 0 ]]; then
    return 1
  fi
  read -r -p "xray не найден. Выполнить brew install xray? [y/N]: " reply
  [[ "$reply" =~ ^[YyДд]$ ]]
}

log "Шаг 1/9 — preflight"
[[ "$(uname -s)" == Darwin ]] || die "production installer поддерживает только macOS"
command -v python3 >/dev/null || die "нет python3"
command -v curl >/dev/null || die "нет curl"
command -v lsof >/dev/null || die "нет lsof"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' ||
  die "требуется Python 3.9 или новее"
ok "macOS $(sw_vers -productVersion), python3 $(python3 -V 2>&1 | awk '{print $2}')"

OLD_LABEL=""
OLD_SERVICE_SCOPE=""
OLD_XRAY_BIN=""
OLD_HTTP_PORT=""
OLD_SOCKS_PORT=""
OLD_PLIST=""
OLD_SERVICE_TARGET=""
HAD_ENV=0
HAD_APPLIED_ENV=0
MARKERLESS_LEGACY=0
ROLLBACK_MARKER_EXISTED=0
[[ -f "$MANAGED_MARKER" && ! -L "$MANAGED_MARKER" ]] &&
  ROLLBACK_MARKER_EXISTED=1
xst_validate_state_path
xst_validate_state_home_layout 1 ||
  die "XST_HOME не соответствует допустимому fresh/managed/legacy layout"
if [[ "$DRY_RUN" == 0 ]]; then
  xst_prepare_and_acquire_operation_lock 1 ||
    die "не удалось подготовить state и атомарно захватить install lock"
  EARLY_MARKER_CREATED="${XST_PREPARED_MARKER_CREATED:-0}"
  EARLY_STATE_CREATED="${XST_PREPARED_STATE_CREATED:-0}"
  if [[ "$EARLY_MARKER_CREATED" == 1 ]]; then
    ROLLBACK_MARKER_EXISTED=0
  else
    ROLLBACK_MARKER_EXISTED=1
  fi
fi

reset_settings_defaults() {
  LABEL="$DEFAULT_LABEL"
  HTTP_PORT="$DEFAULT_HTTP_PORT"
  SOCKS_PORT="$DEFAULT_SOCKS_PORT"
  BYPASS_DOMAINS=""
  BYPASS_CIDRS=""
  XRAY_BIN=""
  XRAY_VERSION=""
  EXPORT_HTTPS_PROXY=0
  SUB_UA="$DEFAULT_UA"
  SERVICE_SCOPE="$DEFAULT_SERVICE_SCOPE"
  INSTALL_VERSION=""
  INSTALL_REVISION=""
}

load_settings_file() {
  local settings_path="$1" saved_env_file="$ENV_FILE"
  reset_settings_defaults
  ENV_FILE="$settings_path"
  if ! xst_read_env || ! xst_validate_settings 0; then
    ENV_FILE="$saved_env_file"
    return 1
  fi
  ENV_FILE="$saved_env_file"
}

if [[ -f "$APPLIED_ENV_FILE" ]]; then
  xst_check_secret_file "$APPLIED_ENV_FILE" 600 ||
    die "существующий applied.env не прошёл owner/mode/symlink проверку"
  load_settings_file "$APPLIED_ENV_FILE" ||
    die "существующий applied.env не прошёл settings validation"
  HAD_APPLIED_ENV=1
  OLD_LABEL="$LABEL"
  OLD_SERVICE_SCOPE="$SERVICE_SCOPE"
  OLD_XRAY_BIN="$XRAY_BIN"
  OLD_HTTP_PORT="$HTTP_PORT"
  OLD_SOCKS_PORT="$SOCKS_PORT"
elif [[ "$ROLLBACK_MARKER_EXISTED" == 1 && -f "$ENV_FILE" ]]; then
  die "managed state содержит env без applied.env; service identity не доказана"
fi

if [[ -f "$ENV_FILE" ]]; then
  xst_check_secret_file "$ENV_FILE" 600 ||
    die "существующий env не прошёл owner/mode/symlink проверку"
  load_settings_file "$ENV_FILE" ||
    die "существующий env не прошёл settings validation"
  HAD_ENV=1
  if [[ "$ROLLBACK_MARKER_EXISTED" == 0 ]]; then
    MARKERLESS_LEGACY=1
  fi
  if [[ "$HAD_APPLIED_ENV" == 0 ]]; then
    [[ "$ROLLBACK_MARKER_EXISTED" == 0 ]] ||
      die "managed state не содержит applied.env; service identity не доказана"
    OLD_LABEL="$LABEL"
    OLD_SERVICE_SCOPE="$SERVICE_SCOPE"
    OLD_XRAY_BIN="$XRAY_BIN"
    OLD_HTTP_PORT="$HTTP_PORT"
    OLD_SOCKS_PORT="$SOCKS_PORT"
  fi
else
  if [[ -e "$MANAGED_MARKER" || -L "$MANAGED_MARKER" ]]; then
    xst_state_home_is_initial_layout ||
      die "managed state без env не является безопасным initial layout"
  fi
  # Fresh, empty and sub-url-only dry-runs must validate the same defaults as
  # the real install, which has already created its marker at this point.
  reset_settings_defaults
fi

if [[ -n "$OLD_LABEL" ]]; then
  if [[ "$OLD_SERVICE_SCOPE" == system ]]; then
    OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"
    OLD_SERVICE_TARGET="system/$OLD_LABEL"
  else
    OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
    OLD_SERVICE_TARGET="gui/$(id -u)/$OLD_LABEL"
  fi
fi

XRAY_BIN="$(xst_find_xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  if [[ "$DRY_RUN" == 1 ]]; then
    die "dry-run требует уже установленный xray"
  fi
  command -v brew >/dev/null || die "xray не найден и Homebrew не установлен"
  if ! confirm_dependency_install; then
    die "xray не установлен; задай XST_INSTALL_XRAY=1 только после разрешения владельца"
  fi
  env \
    -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy \
    brew install xray
  XRAY_BIN="$(xst_find_xray || true)"
fi
[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die "xray не установлен"
XRAY_VERSION="$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
[[ -n "$XRAY_VERSION" ]] || die "не удалось определить версию xray"
ok "xray $XRAY_VERSION"

INSTALL_VERSION="$(sed -n '1p' "$XST_ROOT/VERSION" 2>/dev/null || printf 'dev')"
GIT_TOP="$(git -C "$XST_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$GIT_TOP" && "$(xst_realpath "$GIT_TOP")" == "$(xst_realpath "$XST_ROOT")" ]]; then
  INSTALL_REVISION="$(git -C "$XST_ROOT" rev-parse --verify HEAD)"
  if ! GIT_STATUS="$(git -C "$XST_ROOT" status --porcelain --untracked-files=normal)"; then
    die "git status завершился ошибкой; provenance установки не доказан"
  fi
  if [[ -n "$GIT_STATUS" ]]; then
    INSTALL_REVISION="${INSTALL_REVISION}-dirty-unverified"
  fi
else
  INSTALL_REVISION="$(sed -n '1p' "$XST_ROOT/REVISION" 2>/dev/null || true)"
  if [[ ! "$INSTALL_REVISION" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]]; then
    INSTALL_REVISION="archive-unverified"
  fi
fi

log "Шаг 2/9 — защищённый источник подписки"
SUB_SOURCE_FILE="${XST_SUB_FILE:-}"
URL_SOURCE_FILE="${XST_SUB_URL_FILE:-$SUB_URL_FILE}"
unset SUB_URL
SUB_URL=""
export -n SUB_URL 2>/dev/null || true

if [[ -n "$SUB_SOURCE_FILE" ]]; then
  xst_check_secret_file "$SUB_SOURCE_FILE" 600 ||
    die "защити локальный JSON правами 600"
  ok "используется локальный JSON (содержимое скрыто)"
else
  if [[ ! -f "$URL_SOURCE_FILE" && "$INTERACTIVE" == 1 ]]; then
    read -r -s -p "Subscription URL (ввод скрыт): " SUB_URL
    printf '\n'
    printf '%s' "$SUB_URL" | xst_validate_https_url ||
      die "некорректный subscription URL"
  else
    xst_read_secret_url_file "$URL_SOURCE_FILE" SUB_URL ||
      die "подготовь защищённый HTTPS sub-url и не передавай URL агенту"
  fi
  ok "subscription URL прочитан из защищённого источника (значение скрыто)"
fi

if [[ -n "$SUB_SOURCE_FILE" ]]; then
  cp "$SUB_SOURCE_FILE" "$WORK_DIR/subscription.raw"
else
  log "  скачиваю подписку напрямую с HTTPS-only policy…"
  xst_fetch_subscription "$SUB_URL" "$WORK_DIR/subscription.raw" ||
    die "не удалось безопасно скачать подписку"
fi
COUNT="$(xst_python normalize "$WORK_DIR/subscription.raw" "$WORK_DIR/subscription.json")"
ok "получено конфигов: $COUNT"

log "Шаг 3/9 — сервер"
if [[ "$INTERACTIVE" == 1 ]]; then
  xst_python list "$WORK_DIR/subscription.json"
fi
PREVIOUS_INDEX="0"
if [[ -f "$STATE_FILE" ]]; then
  IFS= read -r PREVIOUS_INDEX < "$STATE_FILE"
fi
if [[ ${XST_SERVER+x} == x ]]; then
  ask SERVER_SEL "Сервер (индекс или часть названия)" "$PREVIOUS_INDEX" 1 "$XST_SERVER"
else
  ask SERVER_SEL "Сервер (индекс или часть названия)" "$PREVIOUS_INDEX" 0 ""
fi
INDEX="$(xst_python resolve "$WORK_DIR/subscription.json" "$SERVER_SEL")"

log "Шаг 4/9 — bypass"
if [[ -n "${XST_BYPASS_FILE:-}" ]]; then
  xst_read_bypass_file "$XST_BYPASS_FILE" ||
    die "XST_BYPASS_FILE должен быть защищённым data-only файлом"
  ok "bypass domains/CIDRs загружены из защищённого файла (значения скрыты)"
else
  ask BYPASS_DOMAINS "Домены в обход" "$BYPASS_DOMAINS" 0 "" 1
  ask BYPASS_CIDRS "Дополнительные CIDR в обход" "$BYPASS_CIDRS" 0 "" 1
fi
export -n BYPASS_DOMAINS BYPASS_CIDRS 2>/dev/null || true

log "Шаг 5/9 — локальный сервис"
if [[ ${XST_HTTP_PORT+x} == x ]]; then
  ask HTTP_PORT "HTTP proxy port" "$HTTP_PORT" 1 "$XST_HTTP_PORT"
else
  ask HTTP_PORT "HTTP proxy port" "$HTTP_PORT" 0 ""
fi
if [[ ${XST_SOCKS_PORT+x} == x ]]; then
  ask SOCKS_PORT "SOCKS5 proxy port" "$SOCKS_PORT" 1 "$XST_SOCKS_PORT"
else
  ask SOCKS_PORT "SOCKS5 proxy port" "$SOCKS_PORT" 0 ""
fi
if [[ ${XST_LABEL+x} == x ]]; then
  ask LABEL "launchd label" "$LABEL" 1 "$XST_LABEL"
else
  ask LABEL "launchd label" "$LABEL" 0 ""
fi
if [[ ${XST_SERVICE_SCOPE+x} == x ]]; then
  ask SERVICE_SCOPE "service scope (user/system)" "$SERVICE_SCOPE" 1 "$XST_SERVICE_SCOPE"
else
  ask SERVICE_SCOPE "service scope (user/system)" "$SERVICE_SCOPE" 0 ""
fi

if [[ ${XST_EXPORT_HTTPS_PROXY+x} == x ]]; then
  EXPORT_HTTPS_PROXY="$XST_EXPORT_HTTPS_PROXY"
elif [[ "$INTERACTIVE" == 1 ]]; then
  read -r -p "Экспортировать HTTP(S)_PROXY глобально? [y/N]: " proxy_reply
  if [[ "$proxy_reply" =~ ^[YyДд]$ ]]; then
    EXPORT_HTTPS_PROXY=1
  else
    EXPORT_HTTPS_PROXY=0
  fi
fi

LINK_PATH="$HOME/.local/bin/xst"
CLAUDE_LINK_PATH="$HOME/.local/bin/claude-xst"
CLAUDE_AWARE_LINK_PATH="$HOME/.local/bin/claude-xst-aware"
CLAUDE_LINK_OWNED=0
CLAUDE_AWARE_LINK_OWNED=0
if [[ -L "$CLAUDE_LINK_PATH" &&
      "$(xst_realpath "$CLAUDE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst")" ]]; then
  CLAUDE_LINK_OWNED=1
fi
if [[ -L "$CLAUDE_AWARE_LINK_PATH" &&
      "$(xst_realpath "$CLAUDE_AWARE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst-aware")" ]]; then
  CLAUDE_AWARE_LINK_OWNED=1
fi
CLAUDE_COMMAND_ENABLED="$CLAUDE_LINK_OWNED"
CLAUDE_AWARE_COMMAND_ENABLED="$CLAUDE_AWARE_LINK_OWNED"
if [[ "$INTERACTIVE" == 1 ]]; then
  printf '\nОпциональные команды Claude Code (можно выбрать любую, обе или ни одной):\n'
  printf '  claude-xst       — запускает Claude через XST и передаёт proxy/NO_PROXY; контекст Claude не меняется.\n'
  printf '  claude-xst-aware — делает то же и добавляет в сессию краткую инструкцию о split tunneling.\n\n'
fi
if [[ ${XST_CLAUDE_COMMAND+x} == x ]]; then
  CLAUDE_COMMAND_ENABLED="$XST_CLAUDE_COMMAND"
elif [[ "$INTERACTIVE" == 1 ]]; then
  if [[ "$CLAUDE_COMMAND_ENABLED" == 1 ]]; then
    read -r -p "Оставить claude-xst (только сетевой слой, без инструкций Claude)? [Y/n]: " claude_reply
    [[ ! "$claude_reply" =~ ^[NnНн]$ ]] || CLAUDE_COMMAND_ENABLED=0
  else
    read -r -p "Установить claude-xst (только сетевой слой, без инструкций Claude)? [y/N]: " claude_reply
    [[ "$claude_reply" =~ ^[YyДд]$ ]] && CLAUDE_COMMAND_ENABLED=1
  fi
fi
if [[ ${XST_CLAUDE_AWARE_COMMAND+x} == x ]]; then
  CLAUDE_AWARE_COMMAND_ENABLED="$XST_CLAUDE_AWARE_COMMAND"
elif [[ "$INTERACTIVE" == 1 ]]; then
  if [[ "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 ]]; then
    read -r -p "Оставить claude-xst-aware (сетевой слой + инструкция Claude)? [Y/n]: " claude_reply
    [[ ! "$claude_reply" =~ ^[NnНн]$ ]] || CLAUDE_AWARE_COMMAND_ENABLED=0
  else
    read -r -p "Установить claude-xst-aware (сетевой слой + инструкция Claude)? [y/N]: " claude_reply
    [[ "$claude_reply" =~ ^[YyДд]$ ]] && CLAUDE_AWARE_COMMAND_ENABLED=1
  fi
fi
if [[ "$CLAUDE_COMMAND_ENABLED" == 1 ||
      "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 ]] &&
  ! command -v claude >/dev/null 2>&1; then
  warn "Claude CLI пока не найден; XST-команды заработают после установки claude"
fi

SUB_UA="${SUB_UA:-$DEFAULT_UA}"
xst_validate_settings 1
xst_set_service_paths

if [[ -n "$OLD_LABEL" ]] &&
  { [[ "$OLD_LABEL" != "$LABEL" ]] || [[ "$OLD_SERVICE_SCOPE" != "$SERVICE_SCOPE" ]]; }; then
  if [[ -e "$OLD_PLIST" || -L "$OLD_PLIST" ]] ||
    launchctl print "$OLD_SERVICE_TARGET" >/dev/null 2>&1; then
    die "смена label/scope требует сначала ./uninstall.sh; старый job не изменён"
  fi
fi

if [[ "$XST_ZSHRC" == 1 && -L "$HOME/.zshrc" ]]; then
  die "~/.zshrc является симлинком; используй XST_ZSHRC=0 и измени dotfiles явно"
fi
if [[ "$XST_ZSHRC" == 1 ]]; then
  if [[ -e "$HOME/.zshrc" && ! -f "$HOME/.zshrc" ]]; then
    die "~/.zshrc должен быть обычным файлом"
  fi
  ZSH_BEGIN_COUNT="$(grep -cFx "$ZSHRC_BEGIN" "$HOME/.zshrc" 2>/dev/null || true)"
  ZSH_END_COUNT="$(grep -cFx "$ZSHRC_END" "$HOME/.zshrc" 2>/dev/null || true)"
  if [[ "$ZSH_BEGIN_COUNT" != "$ZSH_END_COUNT" || "$ZSH_BEGIN_COUNT" -gt 1 ]]; then
    die "повреждены managed markers в ~/.zshrc; service commit не начат"
  fi
  if [[ "$ZSH_BEGIN_COUNT" == 1 ]] && ! awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
    $0 == begin { if (opened || closed) exit 1; opened=1; next }
    $0 == end { if (!opened || closed) exit 1; closed=1; next }
    END { if (!opened || !closed) exit 1 }
  ' "$HOME/.zshrc"; then
    die "managed block в ~/.zshrc имеет неверный порядок; service commit не начат"
  fi
  [[ -w "$HOME" ]] || die "HOME недоступен для атомарного обновления ~/.zshrc"
fi
if [[ "${XST_LINK_BIN:-1}" == 1 && ( -e "$LINK_PATH" || -L "$LINK_PATH" ) ]]; then
  if [[ ! -L "$LINK_PATH" || "$(xst_realpath "$LINK_PATH")" != "$(xst_realpath "$XST_ROOT/bin/xst")" ]]; then
    die "$LINK_PATH уже существует и не принадлежит этой установке"
  fi
fi
if [[ "$CLAUDE_COMMAND_ENABLED" == 1 &&
      ( -e "$CLAUDE_LINK_PATH" || -L "$CLAUDE_LINK_PATH" ) &&
      "$CLAUDE_LINK_OWNED" != 1 ]]; then
  die "$CLAUDE_LINK_PATH уже существует и не принадлежит этой установке"
fi
if [[ "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 &&
      ( -e "$CLAUDE_AWARE_LINK_PATH" || -L "$CLAUDE_AWARE_LINK_PATH" ) &&
      "$CLAUDE_AWARE_LINK_OWNED" != 1 ]]; then
  die "$CLAUDE_AWARE_LINK_PATH уже существует и не принадлежит этой установке"
fi
LINK_DIRECTORY_MUTATION=0
if [[ "${XST_LINK_BIN:-1}" == 1 ||
      "$CLAUDE_COMMAND_ENABLED" == 1 ||
      "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 ||
      "$CLAUDE_LINK_OWNED" == 1 ||
      "$CLAUDE_AWARE_LINK_OWNED" == 1 ]]; then
  LINK_DIRECTORY_MUTATION=1
fi
if [[ "$LINK_DIRECTORY_MUTATION" == 1 ]]; then
  [[ ! -L "$HOME/.local" && ! -L "$HOME/.local/bin" ]] ||
    die "~/.local и ~/.local/bin не должны быть симлинками; отключи command links"
  if [[ -e "$HOME/.local" && ! -d "$HOME/.local" ]]; then
    die "~/.local существует и не является каталогом"
  fi
  if [[ -e "$HOME/.local/bin" && ! -d "$HOME/.local/bin" ]]; then
    die "~/.local/bin существует и не является каталогом"
  fi
  if [[ -d "$HOME/.local/bin" ]]; then
    [[ -w "$HOME/.local/bin" ]] || die "~/.local/bin недоступен для записи"
  elif [[ -d "$HOME/.local" ]]; then
    [[ -w "$HOME/.local" ]] || die "~/.local недоступен для создания bin"
  else
    [[ -w "$HOME" ]] || die "HOME недоступен для создания ~/.local/bin"
  fi
fi

if [[ "$LABEL" == "com.nqs.xray" ]]; then
  die "legacy label com.nqs.xray нельзя перезаписывать in-place; используй docs/migration.md"
fi
if [[ -e /Library/LaunchDaemons/com.nqs.xray.plist ||
      -L /Library/LaunchDaemons/com.nqs.xray.plist ]] ||
  launchctl print system/com.nqs.xray >/dev/null 2>&1; then
  die "legacy com.nqs.xray всё ещё активен в LaunchDaemons; выполни docs/migration.md"
fi

EXISTING_TARGET_OWNED=0
if [[ -e "$PLIST" || -L "$PLIST" ]]; then
  [[ ! -L "$PLIST" && -f "$PLIST" ]] ||
    die "target plist не является обычным файлом: $PLIST"
  if [[ -z "$OLD_LABEL" || "$OLD_LABEL" != "$LABEL" ||
        "$OLD_SERVICE_SCOPE" != "$SERVICE_SCOPE" ]]; then
    die "target plist уже существует, но ownership этой XST-установкой не доказан: $PLIST"
  fi
  if [[ "$OLD_SERVICE_SCOPE" == system ]]; then
    xst_check_plist_permissions "$PLIST" system ||
      die "существующий system plist не прошёл owner/mode проверку"
  else
    [[ "$(xst_owner_uid "$PLIST")" == "$(id -u)" ]] ||
      die "существующий user plist принадлежит другому пользователю"
    case "$(xst_file_mode "$PLIST")" in
      600|644) ;;
      *) die "существующий user plist имеет недопустимые права" ;;
    esac
  fi
  OLD_USER_NAME=""
  [[ "$OLD_SERVICE_SCOPE" == system ]] && OLD_USER_NAME="$(id -un)"
  xst_python check-plist "$PLIST" \
    --label "$OLD_LABEL" \
    --xray-bin "$OLD_XRAY_BIN" \
    --config "$CONFIG_JSON" \
    --home "$HOME" \
    --user-name "$OLD_USER_NAME" >/dev/null ||
    die "существующий plist не соответствует сохранённой XST-установке"
  EXISTING_TARGET_OWNED=1
fi

if [[ "$SERVICE_SCOPE" == system ]]; then
  ALTERNATE_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  ALTERNATE_TARGET="gui/$(id -u)/$LABEL"
else
  ALTERNATE_PLIST="/Library/LaunchDaemons/$LABEL.plist"
  ALTERNATE_TARGET="system/$LABEL"
fi
if [[ -e "$ALTERNATE_PLIST" || -L "$ALTERNATE_PLIST" ]] ||
  xst_launchctl_target_exists "$ALTERNATE_TARGET"; then
  die "тот же label найден в другом launchd scope: $ALTERNATE_TARGET"
fi

if xst_launchctl_target_exists "$SERVICE_TARGET" &&
  [[ "$EXISTING_TARGET_OWNED" != 1 ]]; then
  die "launchd target уже загружен, но ownership этой XST-установкой не доказан"
fi
for runtime_log in "$LOG_OUT" "$LOG_ERR"; do
  if [[ -L "$runtime_log" || ( -e "$runtime_log" && ! -f "$runtime_log" ) ]]; then
    die "launchd log path должен быть обычным файлом, не symlink: $runtime_log"
  fi
  if [[ -f "$runtime_log" ]]; then
    [[ "$EXISTING_TARGET_OWNED" == 1 ]] ||
      die "существующий log не принадлежит доказанной XST-установке: $runtime_log"
    [[ "$(xst_owner_uid "$runtime_log")" == "$(id -u)" ]] ||
      die "существующий log принадлежит другому пользователю: $runtime_log"
  fi
done
[[ ! -L "$HOME/Library/Logs" ]] ||
  die "~/Library/Logs не должен быть симлинком"
if [[ "$SERVICE_SCOPE" == user ]]; then
  [[ ! -L "$HOME/Library/LaunchAgents" ]] ||
    die "~/Library/LaunchAgents не должен быть симлинком"
fi

EXPECTED_PID=""
if [[ "$EXISTING_TARGET_OWNED" == 1 ]]; then
  EXPECTED_PID="$(xst_service_pid || true)"
  if xst_launchctl_target_exists "$SERVICE_TARGET"; then
    [[ -n "$EXPECTED_PID" ]] ||
      die "существующий owned target загружен без доказуемого PID"
    CURRENT_XRAY_BIN="$XRAY_BIN"
    XRAY_BIN="$OLD_XRAY_BIN"
    if ! xst_process_matches_runtime "$EXPECTED_PID"; then
      XRAY_BIN="$CURRENT_XRAY_BIN"
      die "процесс существующего target не совпадает с сохранёнными executable/argv/uid"
    fi
    XRAY_BIN="$CURRENT_XRAY_BIN"
  fi
fi
if [[ "$MARKERLESS_LEGACY" == 1 && "$EXISTING_TARGET_OWNED" != 1 ]]; then
  die "markerless legacy state не доказал ownership exact plist/runtime identity"
fi
if [[ "$MARKERLESS_LEGACY" == 1 ]] && ! xst_active_config_is_proven; then
  die "markerless legacy state не имеет доказанного active-config.sha256; используй migration runbook"
fi
for port in "$HTTP_PORT" "$SOCKS_PORT"; do
  LISTENER_PIDS="$(xst_listener_pids "$port" || true)"
  for listener_pid in $LISTENER_PIDS; do
    if [[ -z "$EXPECTED_PID" || "$listener_pid" != "$EXPECTED_PID" ]]; then
      die "порт $port занят посторонним PID $listener_pid; установка не меняла сервис"
    fi
  done
done

log "Шаг 6/9 — сборка и проверка всех конфигов"
VALID_COUNT=0
for ((config_index = 0; config_index < COUNT; config_index++)); do
  xst_emit_bypass_inputs |
    xst_python apply \
      "$WORK_DIR/subscription.json" \
      "$config_index" \
      "$WORK_DIR/config-$config_index.json" \
      --http-port "$HTTP_PORT" \
      --socks-port "$SOCKS_PORT" \
      --bypass-stdin >/dev/null
  if ! "$XRAY_BIN" run -test -config "$WORK_DIR/config-$config_index.json" >/dev/null 2>&1; then
    die "xray отверг конфиг с индексом $config_index; секретные детали скрыты"
  fi
  VALID_COUNT=$((VALID_COUNT + 1))
done
cp "$WORK_DIR/config-$INDEX.json" "$WORK_DIR/config.json"
ok "xray принял $VALID_COUNT/$COUNT конфигов"

PLIST_ARGS=(
  render-plist
  "$WORK_DIR/service.plist"
  --template "$XST_ROOT/templates/launchagent.plist.template"
  --label "$LABEL"
  --xray-bin "$XRAY_BIN"
  --config "$CONFIG_JSON"
  --home "$HOME"
  --log-out "$LOG_OUT"
  --log-err "$LOG_ERR"
)
if [[ "$SERVICE_SCOPE" == system ]]; then
  PLIST_ARGS+=(--user-name "$(id -un)")
fi
xst_python "${PLIST_ARGS[@]}"
PLIST_USER_NAME=""
[[ "$SERVICE_SCOPE" == system ]] && PLIST_USER_NAME="$(id -un)"
xst_python check-plist "$WORK_DIR/service.plist" \
  --label "$LABEL" \
  --xray-bin "$XRAY_BIN" \
  --config "$CONFIG_JSON" \
  --home "$HOME" \
  --user-name "$PLIST_USER_NAME" \
  --strict-hardening \
  --log-out "$LOG_OUT" \
  --log-err "$LOG_ERR" >/dev/null ||
  die "сгенерированный plist не прошёл production hardening check"

if [[ "$DRY_RUN" == 1 ]]; then
  log "DRY RUN успешно завершён"
  hint "проверены subscription, все конфиги, routing inputs, xray и plist"
  hint "файлы, launchd, shell и Homebrew не изменялись"
  exit 0
fi

log "Шаг 7/9 — атомарная установка"
mkdir -p "$WORK_DIR/rollback"
for managed_name in env applied.env sub-url subscription.json config.json current-index active-config.sha256 shell.sh; do
  if [[ -f "$XST_HOME/$managed_name" ]]; then
    cp -p "$XST_HOME/$managed_name" "$WORK_DIR/rollback/$managed_name"
  fi
done
if [[ -f "$PLIST" ]]; then
  cp -p "$PLIST" "$WORK_DIR/rollback/service.plist"
fi
ROLLBACK_SERVICE_WAS_LOADED=0
xst_launchctl_target_exists "$SERVICE_TARGET" && ROLLBACK_SERVICE_WAS_LOADED=1
ROLLBACK_LOG_OUT_EXISTED=0
ROLLBACK_LOG_ERR_EXISTED=0
[[ -f "$LOG_OUT" ]] && ROLLBACK_LOG_OUT_EXISTED=1
[[ -f "$LOG_ERR" ]] && ROLLBACK_LOG_ERR_EXISTED=1
ROLLBACK_ZSHRC_EXISTED=0
if [[ "$XST_ZSHRC" == 1 && -f "$HOME/.zshrc" ]]; then
  cp -p "$HOME/.zshrc" "$WORK_DIR/rollback/zshrc"
  ROLLBACK_ZSHRC_EXISTED=1
fi
LINK_CREATED=0
CLAUDE_LINK_CREATED=0
CLAUDE_AWARE_LINK_CREATED=0
CLAUDE_LINK_REMOVED=0
CLAUDE_AWARE_LINK_REMOVED=0

rollback_service_install() {
  warn "восстанавливаю предыдущую транзакцию"
  local managed_name rc=0 restored_mode plist_mode runtime_env_source
  local new_plist="$PLIST" new_target="$SERVICE_TARGET" new_scope="$SERVICE_SCOPE"
  local new_log_out="$LOG_OUT" new_log_err="$LOG_ERR"

  for managed_name in env applied.env sub-url subscription.json config.json current-index active-config.sha256 shell.sh; do
    if [[ -f "$WORK_DIR/rollback/$managed_name" ]]; then
      if ! xst_atomic_from_stdin "$XST_HOME/$managed_name" 600 < "$WORK_DIR/rollback/$managed_name"; then
        warn "не удалось восстановить $managed_name"
        rc=1
      fi
    else
      if ! rm -f "$XST_HOME/$managed_name"; then
        warn "не удалось удалить новый $managed_name"
        rc=1
      fi
    fi
  done
  if [[ -f "$WORK_DIR/rollback/service.plist" ]]; then
    if [[ "$new_scope" == system ]]; then
      if ! sudo install -o root -g wheel -m 0644 "$WORK_DIR/rollback/service.plist" "$new_plist"; then
        warn "не удалось восстановить system plist"
        rc=1
      fi
    else
      plist_mode="$(xst_file_mode "$WORK_DIR/rollback/service.plist")"
      if ! xst_atomic_from_stdin "$new_plist" "$plist_mode" < "$WORK_DIR/rollback/service.plist"; then
        warn "не удалось восстановить user plist"
        rc=1
      fi
    fi
    if [[ "$ROLLBACK_SERVICE_WAS_LOADED" == 1 ]]; then
      runtime_env_source="$WORK_DIR/rollback/env"
      if [[ -f "$WORK_DIR/rollback/applied.env" ]]; then
        runtime_env_source="$WORK_DIR/rollback/applied.env"
      fi
      if [[ ! -f "$runtime_env_source" ]]; then
        warn "rollback snapshot не содержит runtime env"
        rc=1
      elif ! xst_atomic_from_stdin "$ENV_FILE" 600 < "$runtime_env_source"; then
        warn "не удалось временно восстановить runtime env"
        rc=1
      elif ! xst_load_env; then
        warn "восстановленный runtime env не прошёл проверку"
        rc=1
      elif ! xst_active_config_is_proven; then
        warn "rollback config не совпадает с ранее доказанным active hash"
        rc=1
      elif ! "$XRAY_BIN" run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
        warn "rollback config отвергнут xray"
        rc=1
      elif ! xst_launchctl_reload "$PLIST" >/dev/null 2>&1; then
        warn "не удалось перезагрузить предыдущий launchd job"
        rc=1
      elif ! xst_wait_for_service 40 >/dev/null; then
        warn "предыдущий launchd job не доказал оба listener"
        rc=1
      fi
    elif xst_launchctl_target_exists "$new_target"; then
      if ! xst_launchctl_bootout_verified "$new_target"; then
        warn "новый launchd job остался загружен после rollback"
        rc=1
      fi
    fi
  else
    if xst_launchctl_target_exists "$new_target" &&
      ! xst_launchctl_bootout_verified "$new_target"; then
      warn "не удалось выгрузить новый launchd job"
      rc=1
    fi
    if [[ "$new_scope" == system ]]; then
      if ! sudo rm -f "$new_plist"; then
        warn "не удалось удалить новый system plist"
        rc=1
      fi
    else
      if ! rm -f "$new_plist"; then
        warn "не удалось удалить новый user plist"
        rc=1
      fi
    fi
  fi

  if [[ -f "$WORK_DIR/rollback/env" ]]; then
    if ! xst_atomic_from_stdin "$ENV_FILE" 600 < "$WORK_DIR/rollback/env"; then
      warn "не удалось вернуть pending env после rollback"
      rc=1
    fi
  fi

  if [[ "$ROLLBACK_LOG_OUT_EXISTED" == 0 && -e "$new_log_out" ]]; then
    if [[ -L "$new_log_out" || ! -f "$new_log_out" ]]; then
      warn "новый stdout log был заменён извне; rollback его не удалял"
      rc=1
    elif ! rm -f "$new_log_out"; then
      warn "не удалось удалить новый stdout log"
      rc=1
    fi
  fi
  if [[ "$ROLLBACK_LOG_ERR_EXISTED" == 0 && -e "$new_log_err" ]]; then
    if [[ -L "$new_log_err" || ! -f "$new_log_err" ]]; then
      warn "новый stderr log был заменён извне; rollback его не удалял"
      rc=1
    elif ! rm -f "$new_log_err"; then
      warn "не удалось удалить новый stderr log"
      rc=1
    fi
  fi

  if [[ "$XST_ZSHRC" == 1 ]]; then
    if [[ "$ROLLBACK_ZSHRC_EXISTED" == 1 ]]; then
      restored_mode="$(stat -f '%Lp' "$WORK_DIR/rollback/zshrc" 2>/dev/null ||
        stat -c '%a' "$WORK_DIR/rollback/zshrc")"
      if ! xst_atomic_from_stdin "$HOME/.zshrc" "$restored_mode" < "$WORK_DIR/rollback/zshrc"; then
        warn "не удалось восстановить ~/.zshrc"
        rc=1
      fi
    elif [[ -e "$HOME/.zshrc" || -L "$HOME/.zshrc" ]]; then
      {
        printf '\n%s\n' "$ZSHRC_BEGIN"
        xst_zshrc_line
        printf '%s\n' "$ZSHRC_END"
      } > "$WORK_DIR/rollback/new-zshrc.expected"
      if [[ -L "$HOME/.zshrc" || ! -f "$HOME/.zshrc" ]] ||
        ! cmp -s "$WORK_DIR/rollback/new-zshrc.expected" "$HOME/.zshrc"; then
        warn "созданный ~/.zshrc был изменён извне; rollback его не удалял"
        rc=1
      elif ! rm -f "$HOME/.zshrc"; then
        warn "не удалось удалить созданный ~/.zshrc"
        rc=1
      fi
    fi
  fi
  if [[ "$LINK_CREATED" == 1 ]]; then
    if [[ -L "$LINK_PATH" &&
          "$(xst_realpath "$LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/xst")" ]]; then
      rm -f "$LINK_PATH" || rc=1
    elif [[ -e "$LINK_PATH" || -L "$LINK_PATH" ]]; then
      warn "новый xst link был заменён извне; rollback его не удалял"
      rc=1
    else
      :
    fi
  fi
  if [[ "$CLAUDE_LINK_CREATED" == 1 ]]; then
    if [[ -L "$CLAUDE_LINK_PATH" &&
          "$(xst_realpath "$CLAUDE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst")" ]]; then
      rm -f "$CLAUDE_LINK_PATH" || rc=1
    elif [[ -e "$CLAUDE_LINK_PATH" || -L "$CLAUDE_LINK_PATH" ]]; then
      warn "новый claude-xst link был заменён извне; rollback его не удалял"
      rc=1
    fi
  fi
  if [[ "$CLAUDE_AWARE_LINK_CREATED" == 1 ]]; then
    if [[ -L "$CLAUDE_AWARE_LINK_PATH" &&
          "$(xst_realpath "$CLAUDE_AWARE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst-aware")" ]]; then
      rm -f "$CLAUDE_AWARE_LINK_PATH" || rc=1
    elif [[ -e "$CLAUDE_AWARE_LINK_PATH" || -L "$CLAUDE_AWARE_LINK_PATH" ]]; then
      warn "новый claude-xst-aware link был заменён извне; rollback его не удалял"
      rc=1
    fi
  fi
  if [[ "$CLAUDE_LINK_REMOVED" == 1 ]]; then
    if [[ -L "$CLAUDE_LINK_PATH" &&
          "$(xst_realpath "$CLAUDE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst")" ]]; then
      :
    elif [[ ! -e "$CLAUDE_LINK_PATH" && ! -L "$CLAUDE_LINK_PATH" ]]; then
      ln -s "$XST_ROOT/bin/claude-xst" "$CLAUDE_LINK_PATH" || rc=1
    else
      warn "путь claude-xst занят извне; rollback link не восстановлен"
      rc=1
    fi
  fi
  if [[ "$CLAUDE_AWARE_LINK_REMOVED" == 1 ]]; then
    if [[ -L "$CLAUDE_AWARE_LINK_PATH" &&
          "$(xst_realpath "$CLAUDE_AWARE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst-aware")" ]]; then
      :
    elif [[ ! -e "$CLAUDE_AWARE_LINK_PATH" && ! -L "$CLAUDE_AWARE_LINK_PATH" ]]; then
      ln -s "$XST_ROOT/bin/claude-xst-aware" "$CLAUDE_AWARE_LINK_PATH" || rc=1
    else
      warn "путь claude-xst-aware занят извне; rollback link не восстановлен"
      rc=1
    fi
  fi
  if [[ "$ROLLBACK_MARKER_EXISTED" == 0 &&
        ( -e "$MANAGED_MARKER" || -L "$MANAGED_MARKER" ) ]]; then
    if xst_check_owned_file "$MANAGED_MARKER" 600 &&
      printf '%s\n' "$MANAGED_MARKER_VALUE" | cmp -s - "$MANAGED_MARKER"; then
      rm -f "$MANAGED_MARKER" || rc=1
    else
      warn "managed marker изменился; rollback его не удалял"
      rc=1
    fi
  fi
  return "$rc"
}

install_commit_failed() {
  local reason="$1" rollback_rc=0
  rollback_service_install || rollback_rc=$?
  INSTALL_ROLLBACK_NEEDED=0
  if [[ $rollback_rc -eq 0 ]]; then
    die "$reason; предыдущая версия доказанно восстановлена"
  fi
  PRESERVE_WORK_DIR=1
  die "$reason; rollback НЕ завершён, защищённый snapshot сохранён: $WORK_DIR/rollback"
}

INSTALL_ROLLBACK_NEEDED=1
xst_atomic_from_stdin "$SUB_JSON" 600 < "$WORK_DIR/subscription.json" ||
  install_commit_failed "не удалось записать subscription"
xst_atomic_from_stdin "$CONFIG_JSON" 600 < "$WORK_DIR/config.json" ||
  install_commit_failed "не удалось записать config"
printf '%s\n' "$INDEX" | xst_atomic_from_stdin "$STATE_FILE" 600 ||
  install_commit_failed "не удалось записать current-index"
if [[ -z "$SUB_SOURCE_FILE" && "$URL_SOURCE_FILE" != "$SUB_URL_FILE" ]]; then
  printf '%s\n' "$SUB_URL" | xst_atomic_from_stdin "$SUB_URL_FILE" 600 ||
    install_commit_failed "не удалось записать sub-url"
elif [[ -z "$SUB_SOURCE_FILE" && ! -f "$SUB_URL_FILE" ]]; then
  printf '%s\n' "$SUB_URL" | xst_atomic_from_stdin "$SUB_URL_FILE" 600 ||
    install_commit_failed "не удалось записать sub-url"
elif [[ -n "$SUB_SOURCE_FILE" ]]; then
  rm -f "$SUB_URL_FILE"
fi
xst_write_env || install_commit_failed "не удалось записать env"
xst_write_shell_snippet || install_commit_failed "не удалось записать shell snippet"
mkdir -p "$HOME/Library/Logs" || install_commit_failed "не удалось создать каталог логов"
for runtime_log in "$LOG_OUT" "$LOG_ERR"; do
  touch "$runtime_log" || install_commit_failed "не удалось подготовить launchd log"
  chmod 600 "$runtime_log" || install_commit_failed "не удалось защитить launchd log"
done

if [[ "$SERVICE_SCOPE" == system ]]; then
  sudo install -o root -g wheel -m 0644 "$WORK_DIR/service.plist" "$PLIST" ||
    install_commit_failed "не удалось установить system plist"
else
  mkdir -p "$HOME/Library/LaunchAgents" ||
    install_commit_failed "не удалось создать LaunchAgents"
  xst_atomic_from_stdin "$PLIST" 600 < "$WORK_DIR/service.plist" ||
    install_commit_failed "не удалось установить user plist"
fi
xst_check_plist_permissions ||
  install_commit_failed "plist не прошёл owner/mode проверку после установки"
xst_plist_matches_runtime 1 ||
  install_commit_failed "plist не прошёл production hardening check после установки"
for runtime_log in "$LOG_OUT" "$LOG_ERR"; do
  xst_check_owned_file "$runtime_log" 600 ||
    install_commit_failed "launchd log не прошёл owner/mode проверку"
done

if ! xst_launchctl_reload "$PLIST"; then
  install_commit_failed "launchctl не принял сервис"
fi
if ! RUNNING_PID="$(xst_wait_for_service 40)"; then
  install_commit_failed "новый xray не занял оба порта"
fi
xst_write_active_hash || install_commit_failed "не удалось зафиксировать active config hash"
ok "$SERVICE_TARGET запущен, pid $RUNNING_PID"

log "Шаг 8/9 — shell и локальные команды"
if [[ "$XST_ZSHRC" == 1 ]]; then
  xst_install_zshrc_block ||
    install_commit_failed "не удалось атомарно обновить ~/.zshrc"
  ok "управляемый блок добавлен в ~/.zshrc"
else
  warn "~/.zshrc не изменён; подключи shell.sh в управляемом dotfiles"
fi
if [[ "${XST_LINK_BIN:-1}" == 1 ]]; then
  mkdir -p "$HOME/.local/bin" ||
    install_commit_failed "не удалось создать ~/.local/bin"
  if [[ ! -L "$LINK_PATH" ]]; then
    create_xst_link() {
      LINK_CREATED=1
      ln -s "$XST_ROOT/bin/xst" "$LINK_PATH"
    }
    xst_with_masked_signals create_xst_link ||
      install_commit_failed "не удалось создать xst symlink"
  fi
  ok "xst → $LINK_PATH"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin отсутствует в PATH" ;;
  esac
fi
if [[ "$CLAUDE_COMMAND_ENABLED" == 1 || "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 ]]; then
  mkdir -p "$HOME/.local/bin" ||
    install_commit_failed "не удалось создать ~/.local/bin для Claude XST commands"
fi
if [[ "$CLAUDE_COMMAND_ENABLED" == 1 ]]; then
  if [[ "$CLAUDE_LINK_OWNED" != 1 ]]; then
    create_claude_xst_link() {
      CLAUDE_LINK_CREATED=1
      ln -s "$XST_ROOT/bin/claude-xst" "$CLAUDE_LINK_PATH"
    }
    xst_with_masked_signals create_claude_xst_link ||
      install_commit_failed "не удалось создать claude-xst symlink"
  fi
  ok "Claude через XRay без route-инструкции → $CLAUDE_LINK_PATH"
elif [[ "$CLAUDE_LINK_OWNED" == 1 ]]; then
  remove_claude_xst_link() {
    CLAUDE_LINK_REMOVED=1
    rm -f "$CLAUDE_LINK_PATH"
  }
  xst_with_masked_signals remove_claude_xst_link ||
    install_commit_failed "не удалось удалить отключённый claude-xst symlink"
  ok "команда claude-xst отключена"
fi
if [[ "$CLAUDE_AWARE_COMMAND_ENABLED" == 1 ]]; then
  if [[ "$CLAUDE_AWARE_LINK_OWNED" != 1 ]]; then
    create_claude_xst_aware_link() {
      CLAUDE_AWARE_LINK_CREATED=1
      ln -s "$XST_ROOT/bin/claude-xst-aware" "$CLAUDE_AWARE_LINK_PATH"
    }
    xst_with_masked_signals create_claude_xst_aware_link ||
      install_commit_failed "не удалось создать claude-xst-aware symlink"
  fi
  ok "Claude через XRay с route-инструкцией → $CLAUDE_AWARE_LINK_PATH"
elif [[ "$CLAUDE_AWARE_LINK_OWNED" == 1 ]]; then
  remove_claude_xst_aware_link() {
    CLAUDE_AWARE_LINK_REMOVED=1
    rm -f "$CLAUDE_AWARE_LINK_PATH"
  }
  xst_with_masked_signals remove_claude_xst_aware_link ||
    install_commit_failed "не удалось удалить отключённый claude-xst-aware symlink"
  ok "команда claude-xst-aware отключена"
fi
xst_atomic_from_stdin "$APPLIED_ENV_FILE" 600 < "$ENV_FILE" ||
  install_commit_failed "не удалось зафиксировать applied env"
commit_install_bookkeeping() {
  EARLY_MARKER_CREATED=0
  EARLY_STATE_CREATED=0
  XST_PREPARED_MARKER_CREATED=0
  XST_PREPARED_STATE_CREATED=0
  LINK_CREATED=0
  CLAUDE_LINK_CREATED=0
  CLAUDE_AWARE_LINK_CREATED=0
  CLAUDE_LINK_REMOVED=0
  CLAUDE_AWARE_LINK_REMOVED=0
  INSTALL_ROLLBACK_NEEDED=0
}
xst_with_masked_signals commit_install_bookkeeping
xst_release_operation_lock ||
  die "установка завершена, но operation lock не удалось снять вручную"

log "Шаг 9/9 — live verification"
if ! "$XST_ROOT/bin/xst" verify; then
  warn "сервис установлен, но acceptance не завершён; исправь причину и повтори xst verify"
  exit 1
fi

log "XRay готов"
hint "Citrix считается готовым только после отдельной ручной приёмки из docs/citrix-prerequisites.md"
