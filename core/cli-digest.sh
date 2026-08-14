#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Живой дайджест действий CLI → Telegram. Вызывается ХУКОМ (PreToolUse) на
# каждый вызов инструмента канальной сессии.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Показывает владельцу «что агент делает прямо сейчас», НЕ заваливая чат:
# редактирует ОДНО сообщение прогресса, а не шлёт новое на каждый чих.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# ПРИНЦИПЫ (почему так, а не «сырой флуд»):
# - Telegram режет ~20 сообщений/мин на чат. Сырой поток пробьёт лимит и бот
#   словит бан на отправку → владелец перестанет получать даже нормальные
#   ответы. Поэтому edit одного сообщения (editMessageText пуш НЕ шлёт) +
#   rate-limit на API.
# - Отправка в ФОН (setsid curl &): хук синхронный, без фона каждый инструмент
#   ждал бы curl и работа встала бы. Скрипт обязан возвращать мгновенно.
# - Фильтр CHANNEL_DIGEST=1: хук глобальный (срабатывает во ВСЕХ claude-сессиях
#   машины), дайджест шлём только из канальной — маркер ставит стартовый
#   скрипт канала.
# - Анти-эхо: телеграм-инструменты (reply/react/edit_message/download)
#   пропускаем, иначе отправка дайджеста воспринималась бы как новое действие
#   → визуальная петля.
#
# stdin: JSON события хука (tool_name, tool_input). Exit всегда 0 — дайджест
# не смеет ронять tool-call.
# ═══════════════════════════════════════════════════════════════════════════

# --- гейт: только канальная сессия ---
# Два пути включения: env CHANNEL_DIGEST=1 (ставит стартовый скрипт канала — чистый способ
# для будущих сессий) ИЛИ файл-маркер digest_enabled (включает дайджест в УЖЕ живой сессии
# без рестарта — env в запущенный процесс не пробросить). Файлом же удобно выключать: rm.
STATE_DIR="${CHANNEL_STATE_DIR:-$HOME/.local/state/claude-telegram}"
if [ "${CHANNEL_DIGEST:-0}" != "1" ] && [ ! -f "$STATE_DIR/digest_enabled" ]; then
    exit 0
fi
ENV_FILE="${CHANNEL_ENV_FILE:-$HOME/.env}"
ACCESS_JSON="${CHANNEL_ACCESS_JSON:-$HOME/.claude/channels/telegram/access.json}"
TG_API="${TG_API_BASE:-https://api.telegram.org}"
BUF="$STATE_DIR/digest_buffer"
MSGID_FILE="$STATE_DIR/digest_msgid"
LAST_SEND="$STATE_DIR/digest_last_send"
MSG_STARTED="$STATE_DIR/digest_msg_started"
LOCK="$STATE_DIR/digest.lock"

MIN_INTERVAL="${DIGEST_MIN_INTERVAL:-4}"   # не чаще раза в N сек дёргать API (edit-лимит TG)
ROLLOVER="${DIGEST_ROLLOVER:-150}"          # старше N сек — новое сообщение (с пушем), сброс
MAX_LINES="${DIGEST_MAX_LINES:-12}"         # сколько последних строк держать в сообщении

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Событие приходит на stdin ОДИН раз — читаем в переменную, затем отдаём парсеру.
# (Наивный вариант `python3 - <<HEREDOC` съедает stdin как текст программы, и
#  json.load не видит события — переменная всегда пуста. Парсер поэтому вынесен
#  в отдельный файл.)
EVENT=$(cat)
LINE=$(printf '%s' "$EVENT" | python3 /home/ubuntu/core/cli-digest-parse.py 2>/dev/null)
[ -z "$LINE" ] && exit 0

TS=$(date '+%H:%M:%S')

# --- обновить буфер и решить send/edit под локом (гонки фоновых отправок) ---
{
    flock -w 2 9 || exit 0

    echo "$TS  $LINE" >> "$BUF"
    # держим только последние MAX_LINES
    tail -n "$MAX_LINES" "$BUF" > "$BUF.tmp" 2>/dev/null && mv "$BUF.tmp" "$BUF"

    now=$(date +%s)
    last=$(cat "$LAST_SEND" 2>/dev/null | tr -cd 0-9); last=${last:-0}
    started=$(cat "$MSG_STARTED" 2>/dev/null | tr -cd 0-9); started=${started:-0}
    msgid=$(cat "$MSGID_FILE" 2>/dev/null | tr -cd 0-9)

    # rate-limit: если совсем недавно дёргали API — только копим буфер, выйдем
    if [ $((now - last)) -lt "$MIN_INTERVAL" ]; then
        exit 0
    fi

    mode="edit"
    if [ -z "$msgid" ] || [ $((now - started)) -ge "$ROLLOVER" ]; then
        mode="new"
    fi

    BODY="🟢 дайджест  ·  $(date '+%H:%M')"$'\n'"$(cat "$BUF" 2>/dev/null)"
    echo "$now" > "$LAST_SEND"

    # --- отправка В ФОНЕ, чтобы не тормозить tool-call ---
    (
        set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a
        CHAT=$(python3 -c "
import json
try:
    d=json.load(open('$ACCESS_JSON')); ids=d.get('allowFrom') or d.get('allowed') or []
    print(ids[0] if ids else '')
except Exception: print('')" 2>/dev/null)
        [ -z "$CHAT" ] && exit 0
        [ -z "$TELEGRAM_BOT_TOKEN" ] && exit 0

        if [ "$mode" = "new" ]; then
            RESP=$(curl -s --max-time 8 -X POST \
                "$TG_API/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d "chat_id=$CHAT" --data-urlencode "text=$BODY" 2>/dev/null)
            NEWID=$(printf '%s' "$RESP" | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['result']['message_id'])
except Exception: print('')" 2>/dev/null)
            if [ -n "$NEWID" ]; then
                echo "$NEWID" > "$MSGID_FILE"
                date +%s > "$MSG_STARTED"
            fi
        else
            curl -s -o /dev/null --max-time 8 -X POST \
                "$TG_API/bot$TELEGRAM_BOT_TOKEN/editMessageText" \
                -d "chat_id=$CHAT" -d "message_id=$msgid" \
                --data-urlencode "text=$BODY" 2>/dev/null
        fi
    ) </dev/null >/dev/null 2>&1 &

} 9>"$LOCK"

exit 0
