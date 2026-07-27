#!/usr/bin/env bash
# Общие переменные и хелперы для install.sh, uninstall.sh и bin/xst.
# Подключается через `source`, самостоятельно не запускается.

XST_HOME="${XST_HOME:-$HOME/.config/xray-split-tunnel}"
ENV_FILE="$XST_HOME/env"
SUB_URL_FILE="$XST_HOME/sub-url"
SUB_JSON="$XST_HOME/subscription.json"
CONFIG_JSON="$XST_HOME/config.json"
STATE_FILE="$XST_HOME/current-index"
SHELL_SNIPPET="$XST_HOME/shell.sh"

DEFAULT_LABEL="com.xst.xray"
DEFAULT_HTTP_PORT="10809"
DEFAULT_SOCKS_PORT="10808"
DEFAULT_UA="Happ/1.5.0"

if [[ -t 1 ]]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_R=""; C_B=""; C_G=""; C_Y=""; C_RED=""; C_DIM=""
fi

log()    { printf '%s==>%s %s\n' "$C_B" "$C_R" "$*"; }
ok()     { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$*"; }
warn()   { printf '  %s!%s %s\n' "$C_Y" "$C_R" "$*" >&2; }
fail()   { printf '  %s✗%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
die()    { fail "$*"; exit 1; }
hint()   { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_R"; }

xst_load_env() {
  [[ -f "$ENV_FILE" ]] || die "нет $ENV_FILE — сначала запусти install.sh"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  LABEL="${LABEL:-$DEFAULT_LABEL}"
  HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
  SOCKS_PORT="${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}"
  BYPASS_DOMAINS="${BYPASS_DOMAINS:-}"
  BYPASS_CIDRS="${BYPASS_CIDRS:-}"
  XRAY_BIN="${XRAY_BIN:-$(xst_find_xray)}"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  LOG_OUT="$HOME/Library/Logs/$LABEL.out.log"
  LOG_ERR="$HOME/Library/Logs/$LABEL.err.log"
  PROXY_URL="http://127.0.0.1:$HTTP_PORT"
}

xst_find_xray() {
  local p
  for p in /opt/homebrew/bin/xray /usr/local/bin/xray "$(command -v xray 2>/dev/null || true)"; do
    [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

xst_python() {
  python3 "$XST_ROOT/lib/xstlib.py" "$@"
}

# Скачать подписку: провайдеры вроде VPNUS требуют cookie-jar (первый ответ ставит
# куку, второй отдаёт JSON) и «клиентский» User-Agent. Прокси из окружения снимаем,
# иначе запрос уйдёт в ещё не поднятый xray.
xst_fetch_subscription() {
  local url="$1" dst="$2" jar
  jar="$(mktemp)"
  local rc=0
  env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    curl --max-time 45 -fsSL -A "${SUB_UA:-$DEFAULT_UA}" \
         -c "$jar" -b "$jar" --max-redirs 5 "$url" -o "$dst.raw" || rc=$?
  rm -f "$jar"
  return $rc
}

xst_launchctl_reload() {
  local label="$1" plist="$2"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

xst_is_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

xst_write_shell_snippet() {
  local no_proxy_list="localhost,127.0.0.1,::1"
  local d c
  for d in ${BYPASS_DOMAINS//,/ }; do
    no_proxy_list="$no_proxy_list,.${d#.}"
  done
  for c in ${BYPASS_CIDRS//,/ }; do
    no_proxy_list="$no_proxy_list,$c"
  done

  cat > "$SHELL_SNIPPET" <<EOF
# xray-split-tunnel — сгенерировано install.sh, правь через \`xst edit\` + \`xst apply\`.
export XST_PROXY_URL="http://127.0.0.1:$HTTP_PORT"
export XST_SOCKS_URL="socks5://127.0.0.1:$SOCKS_PORT"
export NO_PROXY="$no_proxy_list"
export no_proxy="\$NO_PROXY"
EOF
  if [[ "${EXPORT_HTTPS_PROXY:-0}" == "1" ]]; then
    cat >> "$SHELL_SNIPPET" <<EOF
export HTTPS_PROXY="\$XST_PROXY_URL"
export HTTP_PROXY="\$XST_PROXY_URL"
export https_proxy="\$XST_PROXY_URL"
export http_proxy="\$XST_PROXY_URL"
EOF
  fi
  chmod 600 "$SHELL_SNIPPET"
}

xst_zshrc_line() {
  echo "[ -f \"\$HOME/.config/xray-split-tunnel/shell.sh\" ] && source \"\$HOME/.config/xray-split-tunnel/shell.sh\"  # xray-split-tunnel"
}
