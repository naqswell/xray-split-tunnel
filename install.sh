#!/usr/bin/env bash
# install.sh — интерактивная установка xray-split-tunnel.
# Спрашивает всё нужное, ставит xray, собирает конфиг, поднимает LaunchAgent, проверяет.
# Идемпотентен: повторный запуск безопасен, ранее заданные ответы предлагаются как дефолт.
#
# Неинтерактивный режим (для AI-агента и CI) — см. AGENTS.md:
#   XST_SUB_URL=... XST_BYPASS_DOMAINS=corp.example.com ./install.sh --non-interactive

set -euo pipefail

XST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$XST_ROOT/lib/common.sh"

INTERACTIVE=1
ASSUME_YES="${XST_ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive|-n) INTERACTIVE=0; ASSUME_YES=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    --help|-h)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done

[[ -t 0 ]] || INTERACTIVE=0

# ── ввод ────────────────────────────────────────────────────────────────────
# ask <переменная-результат> <вопрос> <дефолт> [значение-из-env] [secret]
# secret=1 — не печатать значение целиком (URL с токеном).
ask() {
  local __var="$1" prompt="$2" default="${3:-}" preset="${4:-}" secret="${5:-0}"
  local shown
  if [[ -n "$preset" ]]; then
    printf -v "$__var" '%s' "$preset"
    shown="$preset"; [[ "$secret" == 1 ]] && shown="${preset:0:18}…(скрыто)"
    ok "$prompt → $shown ${C_DIM}(из окружения)${C_R}"
    return
  fi
  if [[ "$INTERACTIVE" == 0 ]]; then
    printf -v "$__var" '%s' "$default"
    shown="${default:-(пусто)}"; [[ "$secret" == 1 && -n "$default" ]] && shown="${default:0:18}…(скрыто)"
    ok "$prompt → $shown ${C_DIM}(дефолт)${C_R}"
    return
  fi
  local reply
  if [[ -n "$default" ]]; then
    read -r -p "$(printf '%s?%s %s [%s]: ' "$C_B" "$C_R" "$prompt" "$default")" reply
    reply="${reply:-$default}"
  else
    read -r -p "$(printf '%s?%s %s: ' "$C_B" "$C_R" "$prompt")" reply
  fi
  printf -v "$__var" '%s' "$reply"
}

confirm() {
  local prompt="$1" default="${2:-y}"
  [[ "$ASSUME_YES" == 1 ]] && return 0
  [[ "$INTERACTIVE" == 0 ]] && { [[ "$default" == "y" ]]; return; }
  local reply
  read -r -p "$(printf '%s?%s %s [%s/%s]: ' "$C_B" "$C_R" "$prompt" \
    "$([[ $default == y ]] && echo Y || echo y)" "$([[ $default == y ]] && echo n || echo N)")" reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[YyДд] ]]
}

# ── 1. окружение ────────────────────────────────────────────────────────────
log "Шаг 1/8 — проверка окружения"

[[ "$(uname -s)" == "Darwin" ]] || die "скрипт для macOS (на Linux см. README §«Не macOS»)"
command -v python3 >/dev/null || die "нет python3 — поставь Xcode Command Line Tools: xcode-select --install"
command -v curl    >/dev/null || die "нет curl"
ok "macOS $(sw_vers -productVersion), python3 $(python3 -V 2>&1 | awk '{print $2}')"

XRAY_BIN="$(xst_find_xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  if command -v brew >/dev/null; then
    if confirm "xray не найден. Поставить через brew install xray?" y; then
      env -u HTTPS_PROXY -u HTTP_PROXY brew install xray
      XRAY_BIN="$(xst_find_xray || true)"
    fi
  else
    warn "нет Homebrew. Поставь: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  fi
fi
[[ -n "$XRAY_BIN" ]] || die "xray не установлен — без него дальше нельзя"
ok "xray: $XRAY_BIN ($("$XRAY_BIN" version 2>/dev/null | head -1))"

mkdir -p "$XST_HOME" && chmod 700 "$XST_HOME"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ── 2. подписка ─────────────────────────────────────────────────────────────
log "Шаг 2/8 — подписка провайдера"
hint "Ссылка вида https://<провайдер>/connect/<токен> — та же, что вставляется в Happ/v2rayN."
hint "Формат ответа должен быть XRay JSON (массив конфигов) — см. docs/subscription-format.md"

SUB_SOURCE_FILE="${XST_SUB_FILE:-}"
SUB_URL=""

if [[ -n "$SUB_SOURCE_FILE" ]]; then
  ok "источник: локальный файл $SUB_SOURCE_FILE"
else
  existing_url=""
  [[ -f "$SUB_URL_FILE" ]] && existing_url="$(cat "$SUB_URL_FILE")"
  ask SUB_URL "Subscription URL" "$existing_url" "${XST_SUB_URL:-}" 1
  [[ -n "$SUB_URL" ]] || die "subscription URL обязателен (или задай XST_SUB_FILE=<путь к json>)"
  printf '%s\n' "$SUB_URL" > "$SUB_URL_FILE"
  chmod 600 "$SUB_URL_FILE"
fi

if [[ -n "$SUB_SOURCE_FILE" ]]; then
  cp "$SUB_SOURCE_FILE" "$SUB_JSON.raw"
else
  log "  скачиваю подписку…"
  xst_fetch_subscription "$SUB_URL" "$SUB_JSON" || die "не удалось скачать подписку (curl). Проверь ссылку и интернет"
fi

COUNT="$(xst_python normalize "$SUB_JSON.raw" "$SUB_JSON")"
rm -f "$SUB_JSON.raw"
chmod 600 "$SUB_JSON"
ok "получено конфигов: $COUNT"

# ── 3. выбор сервера ────────────────────────────────────────────────────────
log "Шаг 3/8 — выбор сервера"
[[ "$INTERACTIVE" == 1 ]] && xst_python list "$SUB_JSON"

prev_idx="0"
[[ -f "$STATE_FILE" ]] && prev_idx="$(cat "$STATE_FILE")"
ask SERVER_SEL "Сервер (индекс или часть названия)" "$prev_idx" "${XST_SERVER:-}"
INDEX="$(xst_python resolve "$SUB_JSON" "$SERVER_SEL")"

# ── 4. split-tunnel: что НЕ гнать через xray ────────────────────────────────
log "Шаг 4/8 — что оставить в обход туннеля (split tunnel)"
hint "Домены корпоративной сети/VPN и всё, что должно ходить напрямую."
hint "Через запятую, суффиксами: example.com,corp.local,intranet"
hint "Приватные подсети (10/8, 172.16/12, 192.168/16, link-local, loopback) добавляются всегда."

ask BYPASS_DOMAINS "Домены в обход" "${BYPASS_DOMAINS:-}" "${XST_BYPASS_DOMAINS:-}"
ask BYPASS_CIDRS   "Доп. подсети в обход (необязательно)" "${BYPASS_CIDRS:-}" "${XST_BYPASS_CIDRS:-}"

# ── 5. порты и метка сервиса ────────────────────────────────────────────────
log "Шаг 5/8 — порты и имя сервиса"
ask HTTP_PORT  "HTTP-прокси порт"  "${HTTP_PORT:-$DEFAULT_HTTP_PORT}"   "${XST_HTTP_PORT:-}"
ask SOCKS_PORT "SOCKS5 порт"       "${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}" "${XST_SOCKS_PORT:-}"
ask LABEL      "launchd label"     "${LABEL:-$DEFAULT_LABEL}"           "${XST_LABEL:-}"

for p in "$HTTP_PORT" "$SOCKS_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] || die "порт должен быть числом: $p"
done

EXPORT_HTTPS_PROXY="${XST_EXPORT_HTTPS_PROXY:-0}"
if [[ "$EXPORT_HTTPS_PROXY" != "1" ]] && [[ "$INTERACTIVE" == 1 ]]; then
  hint "Глобальный HTTPS_PROXY заворачивает в туннель ВСЕ CLI-приложения. Безопаснее"
  hint "включать точечно: xst run <команда>. Ответь «n», если не уверен."
  confirm "Экспортировать HTTPS_PROXY глобально в shell?" n && EXPORT_HTTPS_PROXY=1
fi

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_OUT="$HOME/Library/Logs/$LABEL.out.log"
LOG_ERR="$HOME/Library/Logs/$LABEL.err.log"

cat > "$ENV_FILE" <<EOF
# xray-split-tunnel — параметры установки. Меняй и запускай: xst apply
LABEL="$LABEL"
HTTP_PORT="$HTTP_PORT"
SOCKS_PORT="$SOCKS_PORT"
BYPASS_DOMAINS="$BYPASS_DOMAINS"
BYPASS_CIDRS="$BYPASS_CIDRS"
XRAY_BIN="$XRAY_BIN"
EXPORT_HTTPS_PROXY="$EXPORT_HTTPS_PROXY"
SUB_UA="${SUB_UA:-$DEFAULT_UA}"
EOF
chmod 600 "$ENV_FILE"
ok "параметры записаны: $ENV_FILE"

# ── 6. сборка конфига ───────────────────────────────────────────────────────
log "Шаг 6/8 — сборка конфига"
REMARKS="$(xst_python apply "$SUB_JSON" "$INDEX" "$CONFIG_JSON" \
  --http-port "$HTTP_PORT" --socks-port "$SOCKS_PORT" \
  --bypass-domains "$BYPASS_DOMAINS" --bypass-cidrs "$BYPASS_CIDRS")"
chmod 600 "$CONFIG_JSON"
echo "$INDEX" > "$STATE_FILE"
ok "сервер [$INDEX] $REMARKS → $CONFIG_JSON"

"$XRAY_BIN" run -test -config "$CONFIG_JSON" >/dev/null 2>&1 \
  && ok "xray: Configuration OK" \
  || die "xray отверг конфиг: $("$XRAY_BIN" run -test -config "$CONFIG_JSON" 2>&1 | tail -3)"

# ── 7. LaunchAgent + shell ──────────────────────────────────────────────────
log "Шаг 7/8 — сервис и переменные окружения"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s#__LABEL__#$LABEL#g" \
    -e "s#__XRAY_BIN__#$XRAY_BIN#g" \
    -e "s#__CONFIG__#$CONFIG_JSON#g" \
    -e "s#__HOME__#$HOME#g" \
    -e "s#__LOG_OUT__#$LOG_OUT#g" \
    -e "s#__LOG_ERR__#$LOG_ERR#g" \
    "$XST_ROOT/templates/launchagent.plist.template" > "$PLIST"
xst_launchctl_reload "$LABEL" "$PLIST"
ok "LaunchAgent $LABEL загружен (RunAtLoad + KeepAlive)"

xst_write_shell_snippet
ok "shell-сниппет: $SHELL_SNIPPET (NO_PROXY для доменов в обход)"

ZSHRC="$HOME/.zshrc"
if [[ "${XST_ZSHRC:-}" == "0" ]]; then
  warn "правка ~/.zshrc отключена (XST_ZSHRC=0). Подключи сам: $(xst_zshrc_line)"
elif ! grep -qF "xray-split-tunnel" "$ZSHRC" 2>/dev/null; then
  if [[ "${XST_ZSHRC:-}" == "1" ]] || confirm "Дописать подключение сниппета в ~/.zshrc?" y; then
    printf '\n%s\n' "$(xst_zshrc_line)" >> "$ZSHRC"
    ok "строка добавлена в ~/.zshrc (применится в новых терминалах)"
  else
    warn "пропущено. Подключи сам: $(xst_zshrc_line)"
  fi
else
  ok "~/.zshrc уже подключает сниппет"
fi

if [[ "${XST_LINK_BIN:-1}" == "1" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$XST_ROOT/bin/xst" "$HOME/.local/bin/xst"
  ok "команда xst → ~/.local/bin/xst"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin не в PATH — добавь: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
fi

# ── 8. проверка ─────────────────────────────────────────────────────────────
log "Шаг 8/8 — проверка"
sleep 2
"$XST_ROOT/bin/xst" verify || {
  warn "проверка не прошла целиком — см. вывод выше и \`xst logs\`"
  exit 1
}

echo
log "Готово."
hint "xst status | xst list | xst switch <сервер> | xst check <домен> | xst run <команда>"
hint "Новый терминал (или: source ~/.zshrc), чтобы подхватить NO_PROXY."
