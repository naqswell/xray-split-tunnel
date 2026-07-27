#!/usr/bin/env bash
# Shared, Bash 3.2-compatible helpers. This file is sourced by entrypoints.

XST_HOME="${XST_HOME:-$HOME/.config/xray-split-tunnel}"
ENV_FILE="$XST_HOME/env"
APPLIED_ENV_FILE="$XST_HOME/applied.env"
SUB_URL_FILE="$XST_HOME/sub-url"
SUB_JSON="$XST_HOME/subscription.json"
CONFIG_JSON="$XST_HOME/config.json"
STATE_FILE="$XST_HOME/current-index"
ACTIVE_HASH_FILE="$XST_HOME/active-config.sha256"
SHELL_SNIPPET="$XST_HOME/shell.sh"
MANAGED_MARKER="$XST_HOME/.xst-managed"
OPERATION_LOCK_DIR="$XST_HOME/.xst-operation.lock"
OPERATION_LOCK_OWNER_FILE="$OPERATION_LOCK_DIR/owner"

DEFAULT_LABEL="com.xst.xray"
DEFAULT_HTTP_PORT="10809"
DEFAULT_SOCKS_PORT="10808"
DEFAULT_UA="Happ/1.5.0"
DEFAULT_SERVICE_SCOPE="user"
MANAGED_MARKER_VALUE="xray-split-tunnel:v1"
ZSHRC_BEGIN="# >>> xray-split-tunnel >>>"
ZSHRC_END="# <<< xray-split-tunnel <<<"

LABEL="${LABEL:-$DEFAULT_LABEL}"
HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
SOCKS_PORT="${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}"
BYPASS_DOMAINS="${BYPASS_DOMAINS:-}"
BYPASS_CIDRS="${BYPASS_CIDRS:-}"
XRAY_BIN="${XRAY_BIN:-}"
XRAY_VERSION="${XRAY_VERSION:-}"
EXPORT_HTTPS_PROXY="${EXPORT_HTTPS_PROXY:-0}"
SUB_UA="${SUB_UA:-$DEFAULT_UA}"
SERVICE_SCOPE="${SERVICE_SCOPE:-$DEFAULT_SERVICE_SCOPE}"
INSTALL_VERSION="${INSTALL_VERSION:-}"
INSTALL_REVISION="${INSTALL_REVISION:-}"

# Domain/CIDR policy can be confidential. A caller may have exported these
# generic names before invoking an entrypoint; keep their values available for
# validation, but never let child processes inherit them.
export -n BYPASS_DOMAINS BYPASS_CIDRS 2>/dev/null || true

if [[ -t 1 ]]; then
  C_R=$'\033[0m'
  C_B=$'\033[1m'
  C_G=$'\033[32m'
  C_Y=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
else
  C_R=""
  C_B=""
  C_G=""
  C_Y=""
  C_RED=""
  C_DIM=""
fi

log() { printf '%s==>%s %s\n' "$C_B" "$C_R" "$*"; }
ok() { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_R" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
die() {
  fail "$*"
  return 1 2>/dev/null || exit 1
}
hint() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_R"; }

xst_python() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$XST_ROOT/lib/xstlib.py" "$@"
}

xst_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"
}

xst_owner_uid() {
  if stat -f '%u' "$1" >/dev/null 2>&1; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

xst_owner_gid() {
  if stat -f '%g' "$1" >/dev/null 2>&1; then
    stat -f '%g' "$1"
  else
    stat -c '%g' "$1"
  fi
}

xst_file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

xst_check_owned_directory() {
  local path="$1" expected_mode="$2" expected_uid="${3:-$(id -u)}" actual_mode
  if [[ -L "$path" || ! -d "$path" ]]; then
    fail "каталог отсутствует или является симлинком: $path"
    return 1
  fi
  if [[ "$(xst_owner_uid "$path")" != "$expected_uid" ]]; then
    fail "каталог принадлежит неожиданному пользователю: $path"
    return 1
  fi
  actual_mode="$(xst_file_mode "$path")" || return 1
  if [[ "$actual_mode" != "$expected_mode" ]]; then
    fail "ожидались права $expected_mode у $path, получено $actual_mode"
    return 1
  fi
}

xst_check_owned_file() {
  local path="$1" expected_mode="$2" expected_uid="${3:-$(id -u)}" actual_mode
  if [[ -L "$path" || ! -f "$path" ]]; then
    fail "файл отсутствует или является симлинком: $path"
    return 1
  fi
  if [[ "$(xst_owner_uid "$path")" != "$expected_uid" ]]; then
    fail "файл принадлежит неожиданному пользователю: $path"
    return 1
  fi
  actual_mode="$(xst_file_mode "$path")" || return 1
  if [[ "$actual_mode" != "$expected_mode" ]]; then
    fail "ожидались права $expected_mode у $path, получено $actual_mode"
    return 1
  fi
}

xst_validate_state_path() {
  local resolved home_resolved
  resolved="$(xst_realpath "$XST_HOME")" || return 1
  home_resolved="$(xst_realpath "$HOME")" || return 1
  case "$resolved" in
    ""|"/"|"$home_resolved"|"/Users"|"/home"|"/private"|"/private/tmp"|"/tmp"|"/var"|"/private/var")
      die "опасный XST_HOME запрещён: $resolved"
      return 1
      ;;
  esac
  if [[ -L "$XST_HOME" ]]; then
    die "XST_HOME не должен быть симлинком: $XST_HOME"
    return 1
  fi
}

xst_check_managed_marker() {
  xst_check_owned_directory "$XST_HOME" 700 || return 1
  xst_check_owned_file "$MANAGED_MARKER" 600 || return 1
  if ! printf '%s\n' "$MANAGED_MARKER_VALUE" | cmp -s - "$MANAGED_MARKER"; then
    fail "неизвестный или повреждённый маркер установки"
    return 1
  fi
}

xst_state_file_is_known() {
  case "$1" in
    env|applied.env|sub-url|subscription.json|config.json|current-index|active-config.sha256|shell.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

xst_check_operation_lock() {
  local expected_token="${1:-}" entry entry_count=0 stored_token token_uid
  xst_check_owned_directory "$OPERATION_LOCK_DIR" 700 || return 1
  xst_check_owned_file "$OPERATION_LOCK_OWNER_FILE" 600 || return 1
  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    if [[ "$entry" != "$OPERATION_LOCK_OWNER_FILE" ]]; then
      fail "operation lock содержит неизвестные данные"
      return 1
    fi
  done < <(find "$OPERATION_LOCK_DIR" -mindepth 1 -maxdepth 1 -print0)
  if [[ "$entry_count" -ne 1 ]]; then
    fail "operation lock имеет некорректную структуру"
    return 1
  fi
  IFS= read -r stored_token < "$OPERATION_LOCK_OWNER_FILE" || {
    fail "operation lock не содержит owner token"
    return 1
  }
  if [[ ! "$stored_token" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
    fail "operation lock содержит некорректный owner token"
    return 1
  fi
  token_uid="${stored_token%%:*}"
  if [[ "$token_uid" != "$(id -u)" ]]; then
    fail "operation lock owner token принадлежит другому пользователю"
    return 1
  fi
  if [[ -n "$expected_token" && "$stored_token" != "$expected_token" ]]; then
    fail "operation lock принадлежит другой операции"
    return 1
  fi
  if ! printf '%s\n' "$stored_token" | cmp -s - "$OPERATION_LOCK_OWNER_FILE"; then
    fail "operation lock owner token повреждён"
    return 1
  fi
}

xst_audit_state_home() {
  local entry name
  xst_validate_state_path || return 1
  xst_check_managed_marker || return 1
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    case "$name" in
      .xst-managed)
        ;;
      .xst-operation.lock)
        xst_check_operation_lock || return 1
        ;;
      *)
        if ! xst_state_file_is_known "$name"; then
          fail "каталог состояния содержит неизвестные данные"
          return 1
        fi
        xst_check_owned_file "$entry" 600 || return 1
        ;;
    esac
  done < <(find "$XST_HOME" -mindepth 1 -maxdepth 1 -print0)
}

xst_audit_state_home_applied_runtime() {
  local entry name
  xst_validate_state_path || return 1
  xst_check_managed_marker || return 1
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    case "$name" in
      .xst-managed|env)
        # Pending env is deliberately not trusted by applied-runtime commands.
        # doctor reports its condition; apply performs the strict audit.
        ;;
      .xst-operation.lock)
        xst_check_operation_lock || return 1
        ;;
      *)
        if ! xst_state_file_is_known "$name"; then
          fail "каталог состояния содержит неизвестные данные"
          return 1
        fi
        xst_check_owned_file "$entry" 600 || return 1
        ;;
    esac
  done < <(find "$XST_HOME" -mindepth 1 -maxdepth 1 -print0)
}

xst_restore_saved_trap() {
  local saved_trap="$1" signal_name="$2"
  if [[ -n "$saved_trap" ]]; then
    # `trap -p` is generated by Bash itself; no external data is evaluated.
    eval "$saved_trap"
  else
    trap - "$signal_name"
  fi
}

xst_with_masked_signals() {
  local saved_hup saved_int saved_term rc=0
  saved_hup="$(trap -p HUP || true)"
  saved_int="$(trap -p INT || true)"
  saved_term="$(trap -p TERM || true)"
  trap '' HUP INT TERM
  "$@" || rc=$?
  xst_restore_saved_trap "$saved_hup" HUP
  xst_restore_saved_trap "$saved_int" INT
  xst_restore_saved_trap "$saved_term" TERM
  return "$rc"
}

xst_validate_state_home_layout() (
  local allow_proven_legacy="${1:-0}"
  local entry name entry_count=0 has_marker=0 has_sub_url=0
  local has_env=0 has_subscription=0 has_config=0 has_index=0
  local has_active_hash=0 has_shell=0
  xst_validate_state_path || return 1
  if [[ ! -e "$XST_HOME" && ! -L "$XST_HOME" ]]; then
    return 0
  fi
  xst_check_owned_directory "$XST_HOME" 700 || return 1

  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    name="${entry##*/}"
    case "$name" in
      .xst-managed)
        has_marker=1
        ;;
      .xst-operation.lock)
        fail "XST_HOME заблокирован другой операцией; lock автоматически не удаляется"
        return 1
        ;;
      *)
        if ! xst_state_file_is_known "$name"; then
          fail "неуправляемый непустой XST_HOME запрещён"
          return 1
        fi
        xst_check_owned_file "$entry" 600 || return 1
        case "$name" in
          sub-url) has_sub_url=1 ;;
          env) has_env=1 ;;
          subscription.json) has_subscription=1 ;;
          config.json) has_config=1 ;;
          current-index) has_index=1 ;;
          active-config.sha256) has_active_hash=1 ;;
          shell.sh) has_shell=1 ;;
        esac
        ;;
    esac
  done < <(find "$XST_HOME" -mindepth 1 -maxdepth 1 -print0)

  if [[ "$has_marker" == 1 ]]; then
    xst_audit_state_home || return 1
    return 0
  fi

  # Safe first-install layouts are empty or contain only the locally
  # pre-provisioned protected subscription URL. A markerless in-place upgrade
  # is accepted only for a complete legacy XST state, never for an arbitrary
  # collection of look-alike files.
  if [[ "$entry_count" -eq 0 ]] ||
    [[ "$entry_count" -eq 1 && "$has_sub_url" == 1 ]] ||
    [[ "$allow_proven_legacy" == 1 &&
      "$has_env" == 1 && "$has_subscription" == 1 &&
      "$has_config" == 1 && "$has_index" == 1 &&
      "$has_active_hash" == 1 && "$has_shell" == 1 ]]; then
    :
  else
    fail "неуправляемый непустой XST_HOME запрещён"
    return 1
  fi
)

xst_state_home_is_initial_layout() (
  local entry name
  xst_audit_state_home || return 1
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    case "$name" in
      .xst-managed|sub-url)
        ;;
      .xst-operation.lock)
        xst_check_operation_lock || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done < <(find "$XST_HOME" -mindepth 1 -maxdepth 1 -print0)
)

xst_prepare_state_home() (
  local allow_proven_legacy="${1:-0}" parent old_umask
  xst_validate_state_home_layout "$allow_proven_legacy" || return 1
  old_umask="$(umask)"
  umask 077
  if [[ ! -e "$XST_HOME" ]]; then
    parent="$(dirname "$XST_HOME")"
    mkdir -p "$parent" || return 1
    if ! mkdir "$XST_HOME"; then
      fail "не удалось атомарно создать XST_HOME"
      return 1
    fi
    chmod 700 "$XST_HOME" || return 1
  fi
  xst_validate_state_home_layout "$allow_proven_legacy" || return 1
  if [[ -f "$MANAGED_MARKER" && ! -L "$MANAGED_MARKER" ]]; then
    umask "$old_umask"
    return 0
  fi

  printf '%s\n' "$MANAGED_MARKER_VALUE" |
    xst_atomic_from_stdin "$MANAGED_MARKER" 600 || return 1
  xst_audit_state_home || return 1
  umask "$old_umask"
)

_xst_abort_prepared_operation_lock() {
  if [[ "${XST_PREPARED_MARKER_CREATED:-0}" == 1 &&
        -f "$MANAGED_MARKER" && ! -L "$MANAGED_MARKER" ]] &&
    xst_check_owned_file "$MANAGED_MARKER" 600 >/dev/null 2>&1 &&
    printf '%s\n' "$MANAGED_MARKER_VALUE" | cmp -s - "$MANAGED_MARKER"; then
    rm -f "$MANAGED_MARKER" || true
  fi
  if [[ "${XST_PREPARED_LOCK_DIR_CREATED:-0}" == 1 ]]; then
    rm -f "$OPERATION_LOCK_OWNER_FILE" 2>/dev/null || true
    rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
  fi
  if [[ "${XST_PREPARED_STATE_CREATED:-0}" == 1 ]]; then
    rmdir "$XST_HOME" 2>/dev/null || true
  fi
  XST_OPERATION_LOCK_TOKEN=""
  XST_PREPARED_LOCK_DIR_CREATED=0
  XST_PREPARED_MARKER_CREATED=0
  XST_PREPARED_STATE_CREATED=0
}

_xst_prepare_and_acquire_operation_lock_critical() {
  local allow_proven_legacy="${1:-0}" old_umask parent token
  XST_OPERATION_LOCK_TOKEN=""
  XST_PREPARED_LOCK_DIR_CREATED=0
  XST_PREPARED_MARKER_CREATED=0
  XST_PREPARED_STATE_CREATED=0
  xst_validate_state_home_layout "$allow_proven_legacy" || return 1

  old_umask="$(umask)"
  umask 077
  if [[ ! -e "$XST_HOME" ]]; then
    parent="$(dirname "$XST_HOME")"
    mkdir -p "$parent" || {
      umask "$old_umask"
      return 1
    }
    if mkdir "$XST_HOME" 2>/dev/null; then
      XST_PREPARED_STATE_CREATED=1
      chmod 700 "$XST_HOME" || {
        rmdir "$XST_HOME" 2>/dev/null || true
        XST_PREPARED_STATE_CREATED=0
        umask "$old_umask"
        return 1
      }
    fi
  fi
  xst_validate_state_home_layout "$allow_proven_legacy" || {
    _xst_abort_prepared_operation_lock
    umask "$old_umask"
    return 1
  }
  if ! mkdir "$OPERATION_LOCK_DIR" 2>/dev/null; then
    umask "$old_umask"
    fail "другая операция уже удерживает XST_HOME lock; он не удаляется автоматически"
    return 1
  fi
  XST_PREPARED_LOCK_DIR_CREATED=1
  chmod 700 "$OPERATION_LOCK_DIR" || {
    _xst_abort_prepared_operation_lock
    umask "$old_umask"
    return 1
  }
  token="$(id -u):$$:${RANDOM:-0}:${RANDOM:-0}"
  if ! printf '%s\n' "$token" |
    xst_atomic_from_stdin "$OPERATION_LOCK_OWNER_FILE" 600; then
    _xst_abort_prepared_operation_lock
    umask "$old_umask"
    return 1
  fi
  XST_OPERATION_LOCK_TOKEN="$token"
  if [[ -e "$MANAGED_MARKER" || -L "$MANAGED_MARKER" ]]; then
    if ! xst_check_owned_file "$MANAGED_MARKER" 600 ||
      ! printf '%s\n' "$MANAGED_MARKER_VALUE" | cmp -s - "$MANAGED_MARKER"; then
      fail "managed marker появился или изменился до захвата install lock"
      _xst_abort_prepared_operation_lock
      umask "$old_umask"
      return 1
    fi
  else
    if ! printf '%s\n' "$MANAGED_MARKER_VALUE" |
      xst_atomic_from_stdin "$MANAGED_MARKER" 600; then
      _xst_abort_prepared_operation_lock
      umask "$old_umask"
      return 1
    fi
    XST_PREPARED_MARKER_CREATED=1
  fi
  umask "$old_umask"
  if ! xst_audit_state_home ||
    ! xst_check_operation_lock "$XST_OPERATION_LOCK_TOKEN"; then
    _xst_abort_prepared_operation_lock
    return 1
  fi
}

xst_prepare_and_acquire_operation_lock() {
  xst_with_masked_signals \
    _xst_prepare_and_acquire_operation_lock_critical "$@"
}

_xst_acquire_operation_lock_critical() {
  local state_check_mode="${1:-full}" old_umask token
  case "$state_check_mode" in
    minimal|1)
      xst_validate_state_path && xst_check_managed_marker || return 1
      ;;
    applied)
      xst_audit_state_home_applied_runtime || return 1
      ;;
    full|0)
      xst_audit_state_home || return 1
      ;;
    *)
      fail "неизвестный режим проверки operation lock"
      return 1
      ;;
  esac
  old_umask="$(umask)"
  umask 077
  if ! mkdir "$OPERATION_LOCK_DIR" 2>/dev/null; then
    umask "$old_umask"
    fail "другая операция уже удерживает XST_HOME lock; он не удаляется автоматически"
    return 1
  fi
  chmod 700 "$OPERATION_LOCK_DIR" || {
    rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
    umask "$old_umask"
    return 1
  }
  token="$(id -u):$$:${RANDOM:-0}:${RANDOM:-0}"
  if ! printf '%s\n' "$token" |
    xst_atomic_from_stdin "$OPERATION_LOCK_OWNER_FILE" 600; then
    rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  XST_OPERATION_LOCK_TOKEN="$token"
  xst_check_operation_lock "$XST_OPERATION_LOCK_TOKEN"
}

xst_acquire_operation_lock() {
  xst_with_masked_signals _xst_acquire_operation_lock_critical "$@"
}

xst_release_operation_lock() {
  xst_with_masked_signals _xst_release_operation_lock_critical
}

_xst_release_operation_lock_critical() {
  if [[ -z "${XST_OPERATION_LOCK_TOKEN:-}" ]]; then
    fail "нет owner token для снятия operation lock"
    return 1
  fi
  xst_check_operation_lock "$XST_OPERATION_LOCK_TOKEN" || return 1
  rm -f "$OPERATION_LOCK_OWNER_FILE" || return 1
  if ! rmdir "$OPERATION_LOCK_DIR"; then
    fail "operation lock изменился; автоматическое удаление отменено"
    return 1
  fi
  XST_OPERATION_LOCK_TOKEN=""
  XST_PREPARED_LOCK_DIR_CREATED=0
}

xst_assert_purge_target() {
  local expected_lock_token="${1:-}" resolved
  xst_validate_state_path || return 1
  resolved="$(xst_realpath "$XST_HOME")" || return 1
  [[ -d "$resolved" ]] || {
    die "каталог состояния не найден: $resolved"
    return 1
  }
  if [[ -e "$OPERATION_LOCK_DIR" || -L "$OPERATION_LOCK_DIR" ]]; then
    if [[ -z "$expected_lock_token" ]] ||
      ! xst_check_operation_lock "$expected_lock_token"; then
      die "отказ purge: XST_HOME удерживается другой operation lock"
      return 1
    fi
  fi
  xst_audit_state_home || return 1
}

xst_atomic_from_stdin() {
  local destination="$1" mode="${2:-600}" directory temporary
  directory="$(dirname "$destination")"
  if [[ -L "$destination" ||
        ( -e "$destination" && ! -f "$destination" ) ]]; then
    fail "atomic destination должен быть обычным файлом: $destination"
    return 1
  fi
  mkdir -p "$directory" || return 1
  if [[ -L "$directory" || ! -d "$directory" ]]; then
    fail "atomic destination parent должен быть обычным каталогом: $directory"
    return 1
  fi
  temporary="$(mktemp "$directory/.xst.$(basename "$destination").XXXXXX")" || return 1
  if ! cat > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod "$mode" "$temporary"
  if ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary"
    return 1
  fi
}

xst_find_xray() {
  local candidate
  for candidate in \
    /opt/homebrew/bin/xray \
    /opt/homebrew/opt/xray/bin/xray \
    /usr/local/bin/xray \
    "$(command -v xray 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

xst_read_env() {
  local line key value seen_keys=""
  [[ -f "$ENV_FILE" ]] || {
    die "нет $ENV_FILE — сначала запусти install.sh"
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *)
        die "некорректная строка в $ENV_FILE"
        return 1
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    # Read legacy files generated by versions that wrapped values in quotes.
    if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
      value="${value#\"}"
      value="${value%\"}"
    fi
    case " $seen_keys " in
      *" $key "*)
        die "повторяющийся ключ $key в $ENV_FILE"
        return 1
        ;;
    esac
    seen_keys="$seen_keys $key"
    case "$key" in
      LABEL|HTTP_PORT|SOCKS_PORT|BYPASS_DOMAINS|BYPASS_CIDRS|XRAY_BIN|XRAY_VERSION|EXPORT_HTTPS_PROXY|SUB_UA|SERVICE_SCOPE|INSTALL_VERSION|INSTALL_REVISION)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        die "неизвестный ключ $key в $ENV_FILE"
        return 1
        ;;
    esac
  done < "$ENV_FILE"
}

xst_json_field() {
  python3 -c 'import json,sys; value=json.load(sys.stdin)[sys.argv[1]]; print(value)' "$1"
}

xst_emit_bypass_inputs() {
  printf '%s\0%s\0' "$BYPASS_DOMAINS" "$BYPASS_CIDRS"
}

xst_route_check() {
  local config_path="$1" destination="$2"
  printf '%s' "$destination" |
    xst_python route-check "$config_path" --host-stdin
}

xst_validate_settings() {
  local validated require_xray="${1:-1}" scalar
  if [[ ! "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    die "некорректный launchd label: $LABEL"
    return 1
  fi
  case "$EXPORT_HTTPS_PROXY" in
    0|1) ;;
    *)
      die "EXPORT_HTTPS_PROXY должен быть 0 или 1"
      return 1
      ;;
  esac
  case "$SERVICE_SCOPE" in
    user|system) ;;
    *)
      die "SERVICE_SCOPE должен быть user или system"
      return 1
      ;;
  esac
  if [[ "$SUB_UA" == *$'\n'* || "$SUB_UA" == *$'\r'* || ${#SUB_UA} -gt 256 ]]; then
    die "некорректный SUB_UA"
    return 1
  fi
  for scalar in "$XRAY_BIN" "$XRAY_VERSION" "$INSTALL_VERSION" "$INSTALL_REVISION"; do
    if [[ "$scalar" == *$'\n'* || "$scalar" == *$'\r'* ]]; then
      die "runtime settings содержат control-символы"
      return 1
    fi
  done
  if [[ -n "$XRAY_BIN" && "$XRAY_BIN" != /* ]]; then
    die "XRAY_BIN должен быть абсолютным путём"
    return 1
  fi
  validated="$(xst_emit_bypass_inputs |
    xst_python validate-inputs \
      --http-port "$HTTP_PORT" \
      --socks-port "$SOCKS_PORT" \
      --bypass-stdin)" || return 1
  HTTP_PORT="$(printf '%s' "$validated" | xst_json_field http_port)"
  SOCKS_PORT="$(printf '%s' "$validated" | xst_json_field socks_port)"
  BYPASS_DOMAINS="$(printf '%s' "$validated" | xst_json_field bypass_domains)"
  BYPASS_CIDRS="$(printf '%s' "$validated" | xst_json_field bypass_cidrs)"
  if [[ "$require_xray" == 1 && ( -z "$XRAY_BIN" || ! -x "$XRAY_BIN" ) ]]; then
    die "xray не найден по пути из $ENV_FILE: ${XRAY_BIN:-(пусто)}"
    return 1
  fi
}

xst_set_service_paths() {
  LOG_OUT="$HOME/Library/Logs/$LABEL.out.log"
  LOG_ERR="$HOME/Library/Logs/$LABEL.err.log"
  if [[ "$SERVICE_SCOPE" == "system" ]]; then
    PLIST="/Library/LaunchDaemons/$LABEL.plist"
    SERVICE_DOMAIN="system"
  else
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    SERVICE_DOMAIN="gui/$(id -u)"
  fi
  SERVICE_TARGET="$SERVICE_DOMAIN/$LABEL"
  PROXY_URL="http://127.0.0.1:$HTTP_PORT"
}

xst_load_env() {
  xst_read_env || return 1
  xst_validate_settings 1 || return 1
  xst_set_service_paths
}

xst_write_env() {
  xst_validate_settings 1 || return 1
  {
    printf '%s\n' "# xray-split-tunnel v1 — data-only, never sourced as shell."
    printf 'LABEL=%s\n' "$LABEL"
    printf 'HTTP_PORT=%s\n' "$HTTP_PORT"
    printf 'SOCKS_PORT=%s\n' "$SOCKS_PORT"
    printf 'BYPASS_DOMAINS=%s\n' "$BYPASS_DOMAINS"
    printf 'BYPASS_CIDRS=%s\n' "$BYPASS_CIDRS"
    printf 'XRAY_BIN=%s\n' "$XRAY_BIN"
    printf 'XRAY_VERSION=%s\n' "$XRAY_VERSION"
    printf 'EXPORT_HTTPS_PROXY=%s\n' "$EXPORT_HTTPS_PROXY"
    printf 'SUB_UA=%s\n' "$SUB_UA"
    printf 'SERVICE_SCOPE=%s\n' "$SERVICE_SCOPE"
    printf 'INSTALL_VERSION=%s\n' "$INSTALL_VERSION"
    printf 'INSTALL_REVISION=%s\n' "$INSTALL_REVISION"
  } | xst_atomic_from_stdin "$ENV_FILE" 600
}

xst_check_secret_file() {
  xst_check_owned_file "$1" "${2:-600}"
}

xst_validate_https_url() {
  python3 -c '
import sys
from urllib.parse import urlsplit
value = sys.stdin.read(8193)
try:
    parsed = urlsplit(value)
    hostname = parsed.hostname
except ValueError:
    parsed = None
    hostname = None
valid = bool(
    parsed is not None
    and len(value) <= 8192
    and parsed.scheme == "https"
    and hostname
    and parsed.username is None
    and parsed.password is None
    and not any(ord(ch) <= 32 or ord(ch) == 127 for ch in value)
)
raise SystemExit(0 if valid else 1)
' || {
    fail "subscription URL должен быть HTTPS URL без userinfo/control-символов"
    return 1
  }
}

xst_read_secret_url_file() {
  local source_path="$1" result_name="$2" secret_value=""
  [[ "$result_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    fail "internal error: invalid secret URL result name"
    return 1
  }
  export -n secret_value "$result_name" 2>/dev/null || true
  xst_check_secret_file "$source_path" 600 || return 1
  IFS= read -r secret_value < "$source_path" || [[ -n "$secret_value" ]] || {
    fail "secret URL file пуст или не читается"
    return 1
  }
  printf '%s' "$secret_value" | xst_validate_https_url || return 1
  printf -v "$result_name" '%s' "$secret_value"
  export -n "$result_name" 2>/dev/null || true
}

xst_read_bypass_file() {
  local source_path="$1" line key value seen_domains=0 seen_cidrs=0
  local file_domains="" file_cidrs="" file_size
  export -n file_domains file_cidrs BYPASS_DOMAINS BYPASS_CIDRS \
    2>/dev/null || true
  xst_check_secret_file "$source_path" 600 || return 1
  file_size="$(wc -c < "$source_path")" || return 1
  if [[ "$file_size" -gt 1048576 ]]; then
    fail "bypass file превышает лимит 1 MiB"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *)
        fail "некорректная строка в bypass file"
        return 1
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      BYPASS_DOMAINS)
        [[ "$seen_domains" == 0 ]] || {
          fail "повторяющийся BYPASS_DOMAINS в bypass file"
          return 1
        }
        file_domains="$value"
        seen_domains=1
        ;;
      BYPASS_CIDRS)
        [[ "$seen_cidrs" == 0 ]] || {
          fail "повторяющийся BYPASS_CIDRS в bypass file"
          return 1
        }
        file_cidrs="$value"
        seen_cidrs=1
        ;;
      *)
        fail "неизвестный ключ в bypass file"
        return 1
        ;;
    esac
  done < "$source_path"
  if [[ "$seen_domains" != 1 || "$seen_cidrs" != 1 ]]; then
    fail "bypass file должен содержать BYPASS_DOMAINS и BYPASS_CIDRS"
    return 1
  fi
  BYPASS_DOMAINS="$file_domains"
  BYPASS_CIDRS="$file_cidrs"
  export -n BYPASS_DOMAINS BYPASS_CIDRS 2>/dev/null || true
}

xst_fetch_subscription() (
  local xst_secret_url="$1" destination="$2" directory temporary="" jar=""
  local escaped_url rc=0 downloaded_size old_umask

  # Even if a caller accidentally exported a variable with this internal
  # name, the bearer URL must never reach curl's process environment.
  export -n xst_secret_url escaped_url 2>/dev/null || true
  if ! printf '%s' "$xst_secret_url" | xst_validate_https_url; then
    return 1
  fi

  xst_fetch_cleanup() {
    [[ -z "$temporary" ]] || rm -f "$temporary"
    [[ -z "$jar" ]] || rm -f "$jar"
  }
  trap 'xst_fetch_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  directory="$(dirname "$destination")"
  mkdir -p "$directory"
  old_umask="$(umask)"
  umask 077
  temporary="$(mktemp "$directory/.subscription.XXXXXX")" || return 1
  jar="$(mktemp "${TMPDIR:-/tmp}/xst-cookie.XXXXXX")" || {
    return 1
  }
  chmod 600 "$temporary" "$jar"
  umask "$old_umask"

  escaped_url="${xst_secret_url//\\/\\\\}"
  escaped_url="${escaped_url//\"/\\\"}"

  # -q must be curl's first argument. The URL is supplied only through curl's
  # stdin config, so neither argv nor environment contains the bearer token.
  if printf 'url = "%s"\n' "$escaped_url" |
    env \
      -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
      -u https_proxy -u http_proxy -u all_proxy \
      -u XST_SUB_URL -u SUB_URL -u subscription_url \
      -u xst_secret_url -u escaped_url \
      -u XST_BYPASS_DOMAINS -u XST_BYPASS_CIDRS \
      -u BYPASS_DOMAINS -u BYPASS_CIDRS \
      curl -q \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --max-time 45 \
        --connect-timeout 15 \
        --max-filesize 10485760 \
        --fail \
        --silent \
        --show-error \
        --location \
        --max-redirs 5 \
        -A "${SUB_UA:-$DEFAULT_UA}" \
        -c "$jar" \
        -b "$jar" \
        --config - \
        -o "$temporary"; then
    rc=0
  else
    rc="${PIPESTATUS[1]:-1}"
  fi
  if [[ "$rc" -ne 0 || ! -s "$temporary" ]]; then
    [[ "$rc" -ne 0 ]] && return "$rc"
    return 1
  fi
  downloaded_size="$(wc -c < "$temporary")" || return 1
  if [[ "$downloaded_size" -gt 10485760 ]]; then
    fail "subscription превышает лимит 10 MiB"
    return 1
  fi
  chmod 600 "$temporary"
  mv -f "$temporary" "$destination" || return 1
  temporary=""
  rm -f "$jar" || return 1
  jar=""
)

xst_launchctl() {
  if [[ "$SERVICE_SCOPE" == "system" ]]; then
    sudo launchctl "$@"
  else
    launchctl "$@"
  fi
}

xst_launchctl_target_exists() {
  local target="${1:-$SERVICE_TARGET}"
  launchctl print "$target" >/dev/null 2>&1
}

xst_launchctl_bootout_target() {
  local target="$1"
  case "$target" in
    system/*)
      sudo launchctl bootout "$target"
      ;;
    gui/*)
      launchctl bootout "$target"
      ;;
    *)
      fail "некорректный launchctl target: $target"
      return 1
      ;;
  esac
}

xst_launchctl_bootout_verified() {
  local target="${1:-$SERVICE_TARGET}"
  if ! xst_launchctl_target_exists "$target"; then
    return 0
  fi
  if ! xst_launchctl_bootout_target "$target"; then
    if xst_launchctl_target_exists "$target"; then
      fail "launchctl не смог выгрузить $target"
      return 1
    fi
  fi
  if xst_launchctl_target_exists "$target"; then
    fail "launchctl target всё ещё загружен после bootout: $target"
    return 1
  fi
}

xst_launchctl_reload() {
  local plist="$1"
  xst_launchctl_bootout_verified "$SERVICE_TARGET" || return 1
  xst_launchctl bootstrap "$SERVICE_DOMAIN" "$plist" || return 1
  if ! xst_launchctl_target_exists "$SERVICE_TARGET"; then
    fail "launchctl bootstrap не создал ожидаемый target: $SERVICE_TARGET"
    return 1
  fi
}

xst_service_pid() {
  launchctl print "$SERVICE_TARGET" 2>/dev/null |
    awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}'
}

xst_process_uid_matches() {
  local pid="$1" expected_uid="${2:-$(id -u)}" actual_uid
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  actual_uid="$(ps -p "$pid" -o uid= 2>/dev/null |
    awk 'NF { print $1; exit }')" || return 1
  [[ "$actual_uid" == "$expected_uid" ]]
}

xst_process_executable_matches() {
  local pid="$1" process_executable expected_executable
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$XRAY_BIN" && "$XRAY_BIN" == /* ]] || return 1
  process_executable="$(lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null |
    awk '/^n/ { print substr($0, 2); exit }')" || return 1
  [[ -n "$process_executable" ]] || return 1
  [[ "$process_executable" != *" (deleted)" ]] || return 1
  process_executable="$(xst_realpath "$process_executable")" || return 1
  expected_executable="$(xst_realpath "$XRAY_BIN")" || return 1
  [[ "$process_executable" == "$expected_executable" ]]
}

xst_process_argv_matches() {
  local pid="$1" process_command expected_command
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  process_command="$(ps -ww -p "$pid" -o command= 2>/dev/null |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$/' |
    head -n 1)" || return 1
  expected_command="$XRAY_BIN run -config $CONFIG_JSON"
  [[ -n "$process_command" && "$process_command" == "$expected_command" ]]
}

xst_process_matches_runtime() {
  local pid="$1"
  xst_process_uid_matches "$pid" "$(id -u)" &&
    xst_process_executable_matches "$pid" &&
    xst_process_argv_matches "$pid"
}

xst_process_is_xray() {
  xst_process_executable_matches "$1"
}

xst_process_uses_config() {
  xst_process_argv_matches "$1"
}

xst_plist_matches_runtime() {
  local strict="${1:-0}" user_name=""
  [[ "$SERVICE_SCOPE" == system ]] && user_name="$(id -un)"
  if [[ "$strict" == 1 ]]; then
    xst_python check-plist "$PLIST" \
      --label "$LABEL" \
      --xray-bin "$XRAY_BIN" \
      --config "$CONFIG_JSON" \
      --home "$HOME" \
      --user-name "$user_name" \
      --strict-hardening \
      --log-out "$LOG_OUT" \
      --log-err "$LOG_ERR" >/dev/null
    return
  fi
  xst_python check-plist "$PLIST" \
    --label "$LABEL" \
    --xray-bin "$XRAY_BIN" \
    --config "$CONFIG_JSON" \
    --home "$HOME" \
    --user-name "$user_name" >/dev/null
}

xst_check_plist_permissions() {
  local path="${1:-$PLIST}" scope="${2:-$SERVICE_SCOPE}"
  case "$scope" in
    user)
      xst_check_owned_file "$path" 600 "$(id -u)"
      ;;
    system)
      xst_check_owned_file "$path" 644 0 || return 1
      if [[ "$(xst_owner_gid "$path")" != 0 ]]; then
        fail "system plist должен принадлежать группе wheel/root: $path"
        return 1
      fi
      ;;
    *)
      fail "неизвестный service scope для проверки plist"
      return 1
      ;;
  esac
}

xst_is_loopback_listener_by_pid() {
  local port="$1" pid="$2" addresses
  [[ "$port" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ ]] || return 1
  addresses="$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -Fn 2>/dev/null |
    awk '/^n/ { print substr($0, 2) }')" || return 1
  [[ "$addresses" == "127.0.0.1:$port" ]]
}

xst_is_listening_by_pid() {
  xst_is_loopback_listener_by_pid "$1" "$2"
}

xst_listener_pids() {
  lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sort -u
}

xst_wait_for_service() {
  local attempts="${1:-30}" pid
  while [[ "$attempts" -gt 0 ]]; do
    pid="$(xst_service_pid || true)"
    if [[ -n "$pid" ]] &&
      xst_process_matches_runtime "$pid" &&
      xst_is_listening_by_pid "$HTTP_PORT" "$pid" &&
      xst_is_listening_by_pid "$SOCKS_PORT" "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.25
  done
  return 1
}

xst_config_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

xst_write_active_hash() {
  xst_config_hash "$CONFIG_JSON" | xst_atomic_from_stdin "$ACTIVE_HASH_FILE" 600
}

xst_active_config_is_proven() {
  local expected_hash actual_hash
  xst_check_owned_file "$ACTIVE_HASH_FILE" 600 || return 1
  xst_check_owned_file "$CONFIG_JSON" 600 || return 1
  IFS= read -r expected_hash < "$ACTIVE_HASH_FILE" || return 1
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_hash="$(xst_config_hash "$CONFIG_JSON")" || return 1
  [[ "$actual_hash" == "$expected_hash" ]]
}

xst_merge_no_proxy_values() {
  local input remainder item existing output="" duplicate merged_count=0
  local -a merged_items=()
  for input in "$@"; do
    if [[ "$input" == *$'\n'* || "$input" == *$'\r'* ]]; then
      fail "NO_PROXY содержит control-символы"
      return 1
    fi
    remainder="$input,"
    while [[ "$remainder" == *,* ]]; do
      item="${remainder%%,*}"
      remainder="${remainder#*,}"
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      [[ -n "$item" ]] || continue
      duplicate=0
      if [[ "$merged_count" -gt 0 ]]; then
        for existing in "${merged_items[@]}"; do
          if [[ "$existing" == "$item" ]]; then
            duplicate=1
            break
          fi
        done
      fi
      if [[ "$duplicate" == 0 ]]; then
        merged_items[$merged_count]="$item"
        merged_count=$((merged_count + 1))
      fi
    done
  done
  if [[ "$merged_count" -gt 0 ]]; then
    for item in "${merged_items[@]}"; do
      if [[ -n "$output" ]]; then
        output="$output,$item"
      else
        output="$item"
      fi
    done
  fi
  printf '%s\n' "$output"
}

xst_no_proxy_value() {
  local validated domains cidrs no_proxy_list domain cidr
  validated="$(xst_emit_bypass_inputs |
    xst_python validate-inputs \
      --http-port "$HTTP_PORT" \
      --socks-port "$SOCKS_PORT" \
      --bypass-stdin)" || return 1
  domains="$(printf '%s' "$validated" | xst_json_field bypass_domains)"
  cidrs="$(printf '%s' "$validated" | xst_json_field bypass_cidrs)"
  no_proxy_list="localhost,127.0.0.1,::1"
  for domain in ${domains//,/ }; do
    no_proxy_list="$no_proxy_list,.${domain#.}"
  done
  for cidr in ${cidrs//,/ }; do
    no_proxy_list="$no_proxy_list,$cidr"
  done
  printf '%s\n' "$no_proxy_list"
}

xst_render_shell_snippet() {
  local no_proxy_list
  no_proxy_list="$(xst_no_proxy_value)" || return 1
  printf '%s\n' "# xray-split-tunnel — generated; edit env, then run 'xst apply'."
  printf 'export XST_PROXY_URL=%q\n' "http://127.0.0.1:$HTTP_PORT"
  printf 'export XST_SOCKS_URL=%q\n' "socks5://127.0.0.1:$SOCKS_PORT"
  printf '_xst_managed_no_proxy=%q\n' "$no_proxy_list"
  cat <<'EOF'
_xst_merged_no_proxy="${NO_PROXY:-}"
if [ -n "${no_proxy:-}" ] && [ "$no_proxy" != "$_xst_merged_no_proxy" ]; then
  _xst_merged_no_proxy="${_xst_merged_no_proxy:+${_xst_merged_no_proxy},}${no_proxy}"
fi
_xst_remaining_no_proxy="${_xst_managed_no_proxy},"
while [ -n "$_xst_remaining_no_proxy" ]; do
  _xst_no_proxy_item="${_xst_remaining_no_proxy%%,*}"
  _xst_remaining_no_proxy="${_xst_remaining_no_proxy#*,}"
  [ -n "$_xst_no_proxy_item" ] || continue
  case ",${_xst_merged_no_proxy}," in
    *,"$_xst_no_proxy_item",*) ;;
    *) _xst_merged_no_proxy="${_xst_merged_no_proxy:+${_xst_merged_no_proxy},}${_xst_no_proxy_item}" ;;
  esac
done
export NO_PROXY="$_xst_merged_no_proxy"
export no_proxy="$NO_PROXY"
unset _xst_managed_no_proxy _xst_merged_no_proxy _xst_remaining_no_proxy _xst_no_proxy_item
EOF
  if [[ "$EXPORT_HTTPS_PROXY" == 1 ]]; then
    printf '%s\n' 'export HTTPS_PROXY="$XST_PROXY_URL"'
    printf '%s\n' 'export HTTP_PROXY="$XST_PROXY_URL"'
    printf '%s\n' 'export https_proxy="$XST_PROXY_URL"'
    printf '%s\n' 'export http_proxy="$XST_PROXY_URL"'
  fi
}

xst_write_shell_snippet() {
  xst_render_shell_snippet | xst_atomic_from_stdin "$SHELL_SNIPPET" 600
}

xst_zshrc_line() {
  if [[ "$(xst_realpath "$XST_HOME")" == "$(xst_realpath "$HOME/.config/xray-split-tunnel")" ]]; then
    printf '%s\n' '[ -f "$HOME/.config/xray-split-tunnel/shell.sh" ] && source "$HOME/.config/xray-split-tunnel/shell.sh"'
  else
    printf '[ -f %q ] && source %q\n' "$SHELL_SNIPPET" "$SHELL_SNIPPET"
  fi
}

xst_install_zshrc_block() {
  local zshrc="$HOME/.zshrc" temporary begin_count=0 end_count=0 original_mode=600
  if [[ -e "$zshrc" || -L "$zshrc" ]]; then
    [[ ! -L "$zshrc" && -f "$zshrc" ]] ||
      die "$zshrc должен быть обычным файлом"
    begin_count="$(grep -cFx "$ZSHRC_BEGIN" "$zshrc" 2>/dev/null || true)"
    end_count="$(grep -cFx "$ZSHRC_END" "$zshrc" 2>/dev/null || true)"
    original_mode="$(stat -f '%Lp' "$zshrc" 2>/dev/null || stat -c '%a' "$zshrc")"
  fi
  if [[ "$begin_count" != "$end_count" || "$begin_count" -gt 1 ]]; then
    die "повреждён managed block в $zshrc; исправь markers вручную"
    return 1
  fi
  if [[ "$begin_count" == 1 ]] && ! awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
    $0 == begin { if (opened || closed) exit 1; opened=1; next }
    $0 == end { if (!opened || closed) exit 1; closed=1; next }
    END { if (!opened || !closed) exit 1 }
  ' "$zshrc"; then
    die "managed block в $zshrc имеет неверный порядок markers"
    return 1
  fi
  temporary="$(mktemp "$(dirname "$zshrc")/.zshrc.xst.XXXXXX")" || return 1
  {
    if [[ "$begin_count" == 1 ]]; then
      awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
        $0 == begin { skipping=1; next }
        $0 == end { skipping=0; next }
        !skipping { print }
      ' "$zshrc"
    elif [[ -f "$zshrc" ]]; then
      cat "$zshrc"
    fi
    printf '\n%s\n' "$ZSHRC_BEGIN"
    xst_zshrc_line
    printf '%s\n' "$ZSHRC_END"
  } > "$temporary"
  if ! chmod "$original_mode" "$temporary" ||
    ! mv -f "$temporary" "$zshrc"; then
    rm -f "$temporary"
    return 1
  fi
}

xst_remove_zshrc_block() {
  local zshrc="$HOME/.zshrc" temporary backup begin_count end_count original_mode
  [[ -f "$zshrc" ]] || return 0
  begin_count="$(grep -cFx "$ZSHRC_BEGIN" "$zshrc" 2>/dev/null || true)"
  end_count="$(grep -cFx "$ZSHRC_END" "$zshrc" 2>/dev/null || true)"
  if [[ "$begin_count" == 0 && "$end_count" == 0 ]]; then
    return 0
  fi
  if [[ "$begin_count" != 1 || "$end_count" != 1 ]]; then
    die "повреждён managed block в $zshrc; автоматическое удаление отменено"
    return 1
  fi
  if ! awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
    $0 == begin { if (opened || closed) exit 1; opened=1; next }
    $0 == end { if (!opened || closed) exit 1; closed=1; next }
    END { if (!opened || !closed) exit 1 }
  ' "$zshrc"; then
    die "managed block в $zshrc имеет неверный порядок markers"
    return 1
  fi
  temporary="$(mktemp "$(dirname "$zshrc")/.zshrc.xst.XXXXXX")" || return 1
  awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
    $0 == begin { skipping=1; next }
    $0 == end { skipping=0; next }
    !skipping { print }
  ' "$zshrc" > "$temporary"
  original_mode="$(stat -f '%Lp' "$zshrc" 2>/dev/null || stat -c '%a' "$zshrc")"
  chmod "$original_mode" "$temporary"
  backup="$(mktemp "$HOME/.zshrc.xst-backup.XXXXXX")" || {
    rm -f "$temporary"
    return 1
  }
  if ! cp "$zshrc" "$backup"; then
    rm -f "$temporary" "$backup"
    return 1
  fi
  chmod "$original_mode" "$backup"
  if ! mv -f "$temporary" "$zshrc"; then
    rm -f "$temporary"
    return 1
  fi
  XST_ZSHRC_BACKUP="$backup"
}
