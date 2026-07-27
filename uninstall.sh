#!/usr/bin/env bash
# Remove only artifacts proven to belong to xray-split-tunnel.
set -euo pipefail
umask 077

unset XST_SUB_URL SUB_URL subscription_url xst_secret_url escaped_url
export -n BYPASS_DOMAINS BYPASS_CIDRS 2>/dev/null || true

XST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$XST_ROOT/lib/common.sh"

PURGE=0
usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge]

Without --purge the launchd job, plist, managed shell block, logs and owned
xst symlink are removed; protected runtime state is retained.

--purge additionally removes the exact XST_HOME directory, but only when its
ownership and .xst-managed marker prove that this installer created it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1 ;;
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

[[ "$(id -u)" != 0 ]] ||
  die "не запускай uninstall.sh от root; sudo используется точечно"

audit_uninstall_state() {
  if [[ "$PURGE" == 1 ]]; then
    xst_audit_state_home
  else
    xst_audit_state_home_applied_runtime
  fi
}

xst_validate_state_path
audit_uninstall_state ||
  die "uninstall разрешён только для audited managed XST_HOME"

PURGE_CONTAINER=""
PURGE_PARENT=""
PURGE_LOCK_TOKEN=""
PURGE_STATE_MOVED=0
PURGE_TOMBSTONE_PROVEN=0

purge_container_root_is_safe() {
  [[ -n "$PURGE_CONTAINER" && -n "$PURGE_PARENT" ]] || return 1
  [[ "$PURGE_CONTAINER" == "$PURGE_PARENT"/.xst-purge.* ]] || return 1
  xst_check_owned_directory "$PURGE_CONTAINER" 700
}

purge_tombstone_is_proven() {
  local tombstone="$PURGE_CONTAINER/state"
  local moved_lock="$tombstone/.xst-operation.lock"
  local moved_owner="$moved_lock/owner" entry entry_count=0
  purge_container_root_is_safe || return 1
  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    [[ "$entry" == "$tombstone" ]] || return 1
  done < <(find "$PURGE_CONTAINER" -mindepth 1 -maxdepth 1 -print0)
  [[ "$entry_count" -eq 1 ]] || return 1
  xst_check_owned_directory "$tombstone" 700 || return 1
  xst_check_owned_file "$tombstone/.xst-managed" 600 || return 1
  printf '%s\n' "$MANAGED_MARKER_VALUE" |
    cmp -s - "$tombstone/.xst-managed" || return 1
  xst_check_owned_directory "$moved_lock" 700 || return 1
  xst_check_owned_file "$moved_owner" 600 || return 1
  printf '%s\n' "$PURGE_LOCK_TOKEN" | cmp -s - "$moved_owner"
}

remove_proven_purge_tombstone() {
  if [[ ! -e "$PURGE_CONTAINER" && ! -L "$PURGE_CONTAINER" ]]; then
    PURGE_STATE_MOVED=0
    PURGE_TOMBSTONE_PROVEN=0
    PURGE_CONTAINER=""
    return 0
  fi
  if [[ "$PURGE_TOMBSTONE_PROVEN" != 1 ]]; then
    purge_tombstone_is_proven || return 1
    PURGE_TOMBSTONE_PROVEN=1
  fi
  purge_container_root_is_safe || return 1
  rm -rf -- "$PURGE_CONTAINER" || return 1
  [[ ! -e "$PURGE_CONTAINER" && ! -L "$PURGE_CONTAINER" ]] || return 1
  PURGE_STATE_MOVED=0
  PURGE_TOMBSTONE_PROVEN=0
  PURGE_CONTAINER=""
}

cleanup_uninstall() {
  local cleanup_rc=0
  trap '' HUP INT TERM
  if [[ "${PURGE_STATE_MOVED:-0}" == 1 ]]; then
    XST_OPERATION_LOCK_TOKEN=""
    if ! remove_proven_purge_tombstone; then
      fail "purge tombstone сохранён для ручной проверки: $PURGE_CONTAINER"
      cleanup_rc=1
    fi
  fi
  if [[ -n "${XST_OPERATION_LOCK_TOKEN:-}" ]]; then
    xst_release_operation_lock >/dev/null 2>&1 || true
  fi
  return "$cleanup_rc"
}
trap cleanup_uninstall EXIT
trap 'exit 130' HUP INT TERM
if [[ "$PURGE" == 1 ]]; then
  UNINSTALL_LOCK_MODE=full
else
  UNINSTALL_LOCK_MODE=applied
fi
xst_acquire_operation_lock "$UNINSTALL_LOCK_MODE" ||
  die "другая state-changing операция уже выполняется; lock не удалялся"

# From this point through removal every state/service/artifact proof is made
# under the same exclusive lock, so a concurrent install cannot stale it.
audit_uninstall_state ||
  die "state изменился до захвата uninstall lock"
xst_check_owned_file "$APPLIED_ENV_FILE" 600 ||
  die "applied.env отсутствует; service identity нельзя доказать"
if [[ "$PURGE" == 1 ]]; then
  xst_check_owned_file "$ENV_FILE" 600 ||
    die "purge требует безопасный pending env"
  xst_assert_purge_target "$XST_OPERATION_LOCK_TOKEN"
fi

# applied.env, not a potentially edited pending env, is the authority for the
# service identity that may be stopped and removed.
SETTINGS_ENV_FILE="$ENV_FILE"
ENV_FILE="$APPLIED_ENV_FILE"
xst_load_env
ENV_FILE="$SETTINGS_ENV_FILE"
[[ "$LABEL" != "com.nqs.xray" ]] ||
  die "legacy com.nqs.xray удаляется только вручную по docs/migration.md"
xst_set_service_paths

if [[ "$SERVICE_SCOPE" == system ]]; then
  ALTERNATE_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  ALTERNATE_TARGET="gui/$(id -u)/$LABEL"
else
  ALTERNATE_PLIST="/Library/LaunchDaemons/$LABEL.plist"
  ALTERNATE_TARGET="system/$LABEL"
fi
if [[ -e "$ALTERNATE_PLIST" || -L "$ALTERNATE_PLIST" ]] ||
  xst_launchctl_target_exists "$ALTERNATE_TARGET"; then
  die "тот же label найден в противоположном launchd scope; uninstall остановлен"
fi

PLIST_OWNED=0
if [[ -e "$PLIST" || -L "$PLIST" ]]; then
  [[ ! -L "$PLIST" && -f "$PLIST" ]] ||
    die "target plist не является обычным файлом"
  xst_check_plist_permissions ||
    die "target plist не прошёл owner/mode проверку"
  xst_plist_matches_runtime 1 ||
    die "target plist не соответствует exact applied runtime/hardening"
  PLIST_OWNED=1
fi
if xst_launchctl_target_exists "$SERVICE_TARGET"; then
  [[ "$PLIST_OWNED" == 1 ]] ||
    die "launchd target загружен без доказанного owned plist"
  SERVICE_PID="$(xst_service_pid || true)"
  if [[ -n "$SERVICE_PID" ]] && ! xst_process_matches_runtime "$SERVICE_PID"; then
    die "live process не совпадает с exact executable/argv/uid; target не изменён"
  fi
fi

LINK_PATH="$HOME/.local/bin/xst"
LINK_OWNED=0
if [[ -e "$LINK_PATH" || -L "$LINK_PATH" ]]; then
  if [[ -L "$LINK_PATH" &&
        "$(xst_realpath "$LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/xst")" ]]; then
    LINK_OWNED=1
  elif [[ -L "$LINK_PATH" ]]; then
    warn "$LINK_PATH указывает на другой файл и будет оставлен"
  else
    warn "$LINK_PATH не является owned symlink и будет оставлен"
  fi
fi
CLAUDE_LINK_PATH="$HOME/.local/bin/claude-xst"
CLAUDE_LINK_OWNED=0
if [[ -e "$CLAUDE_LINK_PATH" || -L "$CLAUDE_LINK_PATH" ]]; then
  if [[ -L "$CLAUDE_LINK_PATH" &&
        "$(xst_realpath "$CLAUDE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst")" ]]; then
    CLAUDE_LINK_OWNED=1
  elif [[ -L "$CLAUDE_LINK_PATH" ]]; then
    warn "$CLAUDE_LINK_PATH указывает на другой файл и будет оставлен"
  else
    warn "$CLAUDE_LINK_PATH не является owned symlink и будет оставлен"
  fi
fi
CLAUDE_AWARE_LINK_PATH="$HOME/.local/bin/claude-xst-aware"
CLAUDE_AWARE_LINK_OWNED=0
if [[ -e "$CLAUDE_AWARE_LINK_PATH" || -L "$CLAUDE_AWARE_LINK_PATH" ]]; then
  if [[ -L "$CLAUDE_AWARE_LINK_PATH" &&
        "$(xst_realpath "$CLAUDE_AWARE_LINK_PATH")" == "$(xst_realpath "$XST_ROOT/bin/claude-xst-aware")" ]]; then
    CLAUDE_AWARE_LINK_OWNED=1
  elif [[ -L "$CLAUDE_AWARE_LINK_PATH" ]]; then
    warn "$CLAUDE_AWARE_LINK_PATH указывает на другой файл и будет оставлен"
  else
    warn "$CLAUDE_AWARE_LINK_PATH не является owned symlink и будет оставлен"
  fi
fi

ZSHRC="$HOME/.zshrc"
ZSH_BEGIN_COUNT="$(grep -cFx "$ZSHRC_BEGIN" "$ZSHRC" 2>/dev/null || true)"
ZSH_END_COUNT="$(grep -cFx "$ZSHRC_END" "$ZSHRC" 2>/dev/null || true)"
if [[ "$ZSH_BEGIN_COUNT" != "$ZSH_END_COUNT" || "$ZSH_BEGIN_COUNT" -gt 1 ]]; then
  die "повреждены managed markers в ~/.zshrc; uninstall ничего не менял"
fi
if [[ "$ZSH_BEGIN_COUNT" == 1 ]]; then
  [[ ! -L "$ZSHRC" && -f "$ZSHRC" ]] ||
    die "~/.zshrc с managed block должен быть обычным файлом"
  awk -v begin="$ZSHRC_BEGIN" -v end="$ZSHRC_END" '
    $0 == begin { if (opened || closed) exit 1; opened=1; next }
    $0 == end { if (!opened || closed) exit 1; closed=1; next }
    END { if (!opened || !closed) exit 1 }
  ' "$ZSHRC" ||
    die "managed block в ~/.zshrc имеет неверный порядок; uninstall ничего не менял"
  [[ -w "$HOME" ]] ||
    die "HOME недоступен для атомарного обновления ~/.zshrc"
fi

LOGS_OWNED="$PLIST_OWNED"
for log_file in "$LOG_OUT" "$LOG_ERR"; do
  if [[ -e "$log_file" || -L "$log_file" ]]; then
    if [[ "$LOGS_OWNED" != 1 ]]; then
      warn "log без доказанного owned plist будет оставлен: $log_file"
      continue
    fi
    xst_check_owned_file "$log_file" 600 ||
      die "owned log не прошёл owner/mode/symlink проверку; uninstall ничего не менял"
  fi
done

log "останавливаю $SERVICE_TARGET"
if ! xst_launchctl_bootout_verified "$SERVICE_TARGET"; then
  die "launchctl target не удалось доказанно выгрузить; plist и файлы не удалены"
fi
ok "service отсутствует в launchd"

if [[ "$PLIST_OWNED" == 1 ]]; then
  if [[ "$SERVICE_SCOPE" == system ]]; then
    sudo rm -f "$PLIST"
  else
    rm -f "$PLIST"
  fi
  [[ ! -e "$PLIST" && ! -L "$PLIST" ]] ||
    die "не удалось доказанно удалить plist"
  ok "plist удалён: $PLIST"
fi

if [[ "$LINK_OWNED" == 1 ]]; then
  rm -f "$LINK_PATH"
  [[ ! -e "$LINK_PATH" && ! -L "$LINK_PATH" ]] ||
    die "не удалось удалить owned xst symlink"
  ok "owned symlink удалён: $LINK_PATH"
fi
if [[ "$CLAUDE_LINK_OWNED" == 1 ]]; then
  rm -f "$CLAUDE_LINK_PATH"
  [[ ! -e "$CLAUDE_LINK_PATH" && ! -L "$CLAUDE_LINK_PATH" ]] ||
    die "не удалось удалить owned claude-xst symlink"
  ok "owned symlink удалён: $CLAUDE_LINK_PATH"
fi
if [[ "$CLAUDE_AWARE_LINK_OWNED" == 1 ]]; then
  rm -f "$CLAUDE_AWARE_LINK_PATH"
  [[ ! -e "$CLAUDE_AWARE_LINK_PATH" && ! -L "$CLAUDE_AWARE_LINK_PATH" ]] ||
    die "не удалось удалить owned claude-xst-aware symlink"
  ok "owned symlink удалён: $CLAUDE_AWARE_LINK_PATH"
fi

if [[ "$ZSH_BEGIN_COUNT" == 1 ]]; then
  xst_remove_zshrc_block
  ok "управляемый блок ~/.zshrc удалён; backup: ${XST_ZSHRC_BACKUP:-не создан}"
fi

if [[ "$LOGS_OWNED" == 1 ]]; then
  for log_file in "$LOG_OUT" "$LOG_ERR"; do
    if [[ -f "$log_file" && ! -L "$log_file" ]]; then
      rm -f "$log_file"
      ok "лог удалён: $log_file"
    fi
  done
fi

if [[ "$PURGE" == 1 ]]; then
  xst_assert_purge_target "$XST_OPERATION_LOCK_TOKEN"
  PURGE_TARGET="$(xst_realpath "$XST_HOME")"
  PURGE_PARENT="$(dirname "$PURGE_TARGET")"
  prepare_and_move_purge_tombstone() {
    PURGE_CONTAINER="$(mktemp -d "$PURGE_PARENT/.xst-purge.XXXXXX")" ||
      return 1
    chmod 700 "$PURGE_CONTAINER" || {
      rmdir "$PURGE_CONTAINER" 2>/dev/null || true
      PURGE_CONTAINER=""
      return 1
    }
    PURGE_LOCK_TOKEN="$XST_OPERATION_LOCK_TOKEN"
    PURGE_STATE_MOVED=1
    if ! mv "$PURGE_TARGET" "$PURGE_CONTAINER/state"; then
      PURGE_STATE_MOVED=0
      rmdir "$PURGE_CONTAINER" 2>/dev/null || true
      PURGE_CONTAINER=""
      return 1
    fi
    # The owned lock moved with the audited state. Clearing the live token in
    # the same signal-masked section keeps EXIT cleanup on the tombstone path.
    XST_OPERATION_LOCK_TOKEN=""
  }
  xst_with_masked_signals prepare_and_move_purge_tombstone ||
    die "не удалось атомарно вывести XST_HOME в защищённый purge tombstone"
  remove_proven_purge_tombstone ||
    die "purge tombstone не удалён; проверь $PURGE_CONTAINER вручную"
  ok "защищённое состояние удалено: $PURGE_TARGET (необратимо)"
else
  warn "$XST_HOME сохранён для rollback; --purge удалит его после повторной проверки"
  xst_release_operation_lock ||
    die "uninstall завершился, но owner lock не удалось доказанно снять"
fi

log "Удаление завершено. Homebrew-пакет xray оставлен."
