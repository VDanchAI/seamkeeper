#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Прямое уведомление владельца в Telegram через Bot API — в обход плагина
# и сессии Claude Code.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Путь «бот → владелец» работает от СВОЕГО токена и не зависит ни от подписки
# Claude, ни от фича-флагов, ни от живости сессии. Это единственный канал,
# который остаётся живым, когда лежит всё остальное — поэтому он не должен
# быть зашит внутрь watchdog'а и продублирован в третий раз где-то ещё.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# Использование:
#   notify-owner.sh <reason-code> <текст>            — тревога (с антиспамом)
#   notify-owner.sh --recover <reason-code> <текст>  — «отбой», только если тревога была
#
# reason-code — ключ антиспама. По одной причине не чаще ANTISPAM_SEC; НОВАЯ
# причина уходит сразу, иначе критичное «подписка кончилась» утонуло бы под
# уже отзвеневшим «плагин умер».
#
# Exit code всегда 0: это вспомогательный путь, он не должен ронять
# вызывающий watchdog.
# ═══════════════════════════════════════════════════════════════════════════

STATE_DIR="${CHANNEL_STATE_DIR:-$HOME/.local/state/claude-telegram}"
ENV_FILE="${CHANNEL_ENV_FILE:-$HOME/.env}"
ACCESS_JSON="${CHANNEL_ACCESS_JSON:-$HOME/.claude/channels/telegram/access.json}"
TG_API="${TG_API_BASE:-https://api.telegram.org}"
ANTISPAM_SEC="${NOTIFY_ANTISPAM_SEC:-3600}"
LOG="${CHANNEL_NOTIFY_LOG:-/home/ubuntu/claude-telegram.log}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] NOTIFY: $*" >> "$LOG"; }

RECOVER=0
if [ "$1" = "--recover" ]; then RECOVER=1; shift; fi

REASON="$1"; shift
TEXT="$*"
[ -z "$REASON" ] && exit 0
[ -z "$TEXT" ] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
MARKER="$STATE_DIR/notified_$REASON"

if [ "$RECOVER" = "1" ]; then
    # «Отбой» шлём только если по этой причине действительно звенела тревога —
    # иначе владелец получал бы «всё восстановлено» на ровном месте.
    [ -f "$MARKER" ] || exit 0
    rm -f "$MARKER"
else
    if [ -f "$MARKER" ]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
        # `|| echo 0` — если маркер исчез между -f и stat, пустая подстановка дала бы
        # синтаксическую ошибку арифметики.
        if [ "$AGE" -lt "$ANTISPAM_SEC" ]; then
            log "подавлено антиспамом (reason=$REASON, ${AGE}s < ${ANTISPAM_SEC}s)"
            exit 0
        fi
    fi
fi

set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a

CHAT=$(python3 -c "
import json
try:
    d = json.load(open('$ACCESS_JSON'))
    ids = d.get('allowFrom') or d.get('allowed') or []
    print(ids[0] if ids else '')
except Exception:
    print('')
" 2>/dev/null)

if [ -z "$CHAT" ] || [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    log "НЕ отправлено (chat=$([ -n "$CHAT" ] && echo есть || echo нет), токен $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo есть || echo нет))"
    exit 0
fi

# Тело ответа НЕ пишем в лог: оно содержит эхо отправленного текста и раздувает
# файл. Логируем только факт и HTTP-код. Токен в URL — поэтому и сам URL
# в лог не попадает.
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    "$TG_API/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d "chat_id=$CHAT" \
    --data-urlencode "text=$TEXT" 2>/dev/null)

if [ "$CODE" = "200" ]; then
    [ "$RECOVER" = "1" ] || touch "$MARKER"
    log "отправлено (reason=$REASON, recover=$RECOVER)"
else
    # Метку НЕ ставим — иначе неудачная отправка «съела» бы час антиспама и владелец
    # не узнал бы о проблеме вообще.
    log "ошибка отправки (reason=$REASON, http=$CODE)"
fi

exit 0
