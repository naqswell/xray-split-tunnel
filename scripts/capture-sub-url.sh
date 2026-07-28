#!/usr/bin/env bash
# Capture the subscription URL outside the AI/chat context using a native
# macOS hidden-input dialog, then store it as protected XST state.
set -euo pipefail
umask 077

XST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$XST_ROOT/lib/common.sh"

REPLACE=0
case "${1:-}" in
  "") ;;
  --replace) REPLACE=1 ;;
  --help|-h)
    printf 'Usage: ./scripts/capture-sub-url.sh [--replace]\n'
    exit 0
    ;;
  *)
    die "неизвестный аргумент: $1"
    ;;
esac
[[ $# -le 1 ]] || die "слишком много аргументов"

[[ "$(id -u)" != 0 ]] ||
  die "не запускай capture-sub-url.sh от root"
[[ "$(uname -s)" == Darwin ]] ||
  die "защищённый GUI-ввод поддерживается только на macOS"
command -v osascript >/dev/null 2>&1 ||
  die "osascript не найден"

subscription_url=""
CAPTURE_COMMITTED=0
cleanup_capture() {
  local cleanup_rc=0
  trap '' HUP INT TERM
  subscription_url=""
  unset subscription_url
  if [[ -n "${XST_OPERATION_LOCK_TOKEN:-}" ]]; then
    if [[ "$CAPTURE_COMMITTED" == 1 ]]; then
      xst_release_operation_lock >/dev/null 2>&1 || cleanup_rc=1
    else
      _xst_abort_prepared_operation_lock >/dev/null 2>&1 || cleanup_rc=1
    fi
  fi
  return "$cleanup_rc"
}
trap cleanup_capture EXIT
trap 'exit 130' HUP INT TERM

xst_prepare_and_acquire_operation_lock 1 ||
  die "не удалось безопасно подготовить XST_HOME"

if [[ -e "$SUB_URL_FILE" || -L "$SUB_URL_FILE" ]]; then
  xst_check_secret_file "$SUB_URL_FILE" 600 ||
    die "существующий sub-url не прошёл owner/mode/symlink проверку"
  if [[ "$REPLACE" != 1 ]]; then
    existing_url=""
    xst_read_secret_url_file "$SUB_URL_FILE" existing_url ||
      die "существующий sub-url некорректен; используй --replace"
    existing_url=""
    unset existing_url
    CAPTURE_COMMITTED=1
    xst_release_operation_lock ||
      die "sub-url проверен, но operation lock не удалось снять"
    ok "subscription URL уже подготовлен (значение скрыто)"
    exit 0
  fi
fi

if ! subscription_url="$(
  osascript <<'APPLESCRIPT'
set promptText to "Вставьте новую ссылку подписки XRay. Значение будет скрыто и не попадёт в чат Claude."
set dialogResult to display dialog promptText ¬
  default answer "" with hidden answer ¬
  buttons {"Отмена", "Сохранить"} ¬
  default button "Сохранить" cancel button "Отмена" ¬
  with title "XRay Split Tunnel"
return text returned of dialogResult
APPLESCRIPT
)"; then
  die "ввод subscription URL отменён"
fi
export -n subscription_url 2>/dev/null || true
[[ -n "$subscription_url" ]] ||
  die "subscription URL не введён"
printf '%s' "$subscription_url" | xst_validate_https_url ||
  die "введён некорректный subscription URL"

write_subscription_url() {
  printf '%s\n' "$subscription_url" |
    xst_atomic_from_stdin "$SUB_URL_FILE" 600
}
xst_with_masked_signals write_subscription_url ||
  die "не удалось атомарно сохранить sub-url"
subscription_url=""
unset subscription_url
xst_check_secret_file "$SUB_URL_FILE" 600 ||
  die "сохранённый sub-url не прошёл проверку прав"

CAPTURE_COMMITTED=1
xst_release_operation_lock ||
  die "sub-url сохранён, но operation lock не удалось снять"
ok "subscription URL сохранён в $SUB_URL_FILE (значение скрыто)"
