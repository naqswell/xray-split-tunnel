#!/usr/bin/env bash
# uninstall.sh — снять xray-split-tunnel: сервис, plist, симлинк, строка в ~/.zshrc.
# Секреты (подписка, конфиг) удаляются только с подтверждением или --purge.
set -euo pipefail

XST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$XST_ROOT/lib/common.sh"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

LABEL="$DEFAULT_LABEL"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

log "выгружаю сервис $LABEL"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && ok "выгружен" || warn "не был загружен"
[[ -f "$PLIST" ]] && rm -f "$PLIST" && ok "удалён $PLIST"

[[ -L "$HOME/.local/bin/xst" ]] && rm -f "$HOME/.local/bin/xst" && ok "снят симлинк ~/.local/bin/xst"

if grep -qF "xray-split-tunnel" "$HOME/.zshrc" 2>/dev/null; then
  cp "$HOME/.zshrc" "$HOME/.zshrc.xst-backup"
  grep -vF "xray-split-tunnel" "$HOME/.zshrc.xst-backup" > "$HOME/.zshrc"
  ok "строка убрана из ~/.zshrc (бэкап: ~/.zshrc.xst-backup)"
fi

if [[ $PURGE == 1 ]]; then
  rm -rf "$XST_HOME"
  ok "удалён $XST_HOME (подписка, конфиг, параметры)"
else
  warn "$XST_HOME оставлен (подписка и конфиг). Удалить: $0 --purge"
fi

log "Готово. xray остался установленным: brew uninstall xray — если больше не нужен."
