#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# PostToolUse-хук «conv-mirror»: дублирует ОТПРАВЛЕННЫЕ ответы агента в
# durable человекочитаемый лог ~/telegram-conversation.log.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Владелец делает `tail -f` в терминале и видит разговор, даже если Telegram
# молчит. Правило владельца 14.08.2026 + мультимодельное ревью: дублировать
# исходящие, честно помечать дошло/не дошло.
#
# ПОЧЕМУ хук, а не «агент сам пишет»: дисциплина агента уже дважды подводила
# (см. reply-guard.sh — тот же класс отказа с другой стороны).
# ПОЧЕМУ только исходящие: входящие владелец в терминале видит сам; второй
# парсер = лишний код.
# СТАТУС OK/ERR обязателен: наивное зеркало логировало бы недоставленный
# текст как успех — ложная уверенность. При неизвестной форме ответа — [?],
# НЕ [OK].
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# Гейт — СВОЙ маркер (НЕ digest_enabled: на нём уже дайджест и guard; rm ради
# дайджеста не должен убивать зеркало). exit всегда 0 — хук не смеет ронять
# tool-call.
# ═══════════════════════════════════════════════════════════════════════════

# --- гейт ---
STATE_DIR="${CHANNEL_STATE_DIR:-$HOME/.local/state/claude-telegram}"
if [ "${CHANNEL_SESSION:-0}" != "1" ] && [ ! -f "$STATE_DIR/conv_mirror_enabled" ]; then
    exit 0
fi

LOG="${CONV_MIRROR_LOG:-$HOME/telegram-conversation.log}"
MAXBYTES="${CONV_MIRROR_MAXBYTES:-20971520}"   # 20 MiB → ротация в .1

INPUT=$(cat 2>/dev/null)

LINE=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    ev = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = ev.get("tool_name") or ev.get("tool") or ""
# только исходящие текстовые: reply и edit_message (react — эмодзи, не текст)
if not ("telegram_telegram__reply" in tool or "telegram_telegram__edit_message" in tool):
    sys.exit(0)
inp = ev.get("tool_input") or ev.get("input") or {}
if not isinstance(inp, dict):
    sys.exit(0)
# текст схемо-агностично: первый непустой из кандидатов, иначе самое длинное строковое значение
text = ""
for k in ("text", "message", "body", "content"):
    v = inp.get(k)
    if isinstance(v, str) and v.strip():
        text = v; break
if not text:
    strs = [v for v in inp.values() if isinstance(v, str)]
    text = max(strs, key=len) if strs else ""
if not text.strip():
    sys.exit(0)
# статус доставки из tool_response. ВАЖНО: у telegram-плагина tool_response — это СПИСОК
# блоков [{"type":"text","text":"sent (id: N)"}] (снято с живого события), НЕ dict.
# Ищем маркер успеха именно в РЕЗУЛЬТАТЕ (там "sent (id"), не в тексте ответа.
resp = ev.get("tool_response")
if resp is None:
    resp = ev.get("response")
status = "?"
rtext = ""
try:
    if isinstance(resp, list):
        rtext = " ".join(b.get("text", "") for b in resp if isinstance(b, dict))
    elif isinstance(resp, dict):
        ie = resp.get("is_error")
        if ie is True: status = "ERR"
        elif ie is False: status = "OK"
        rtext = json.dumps(resp, ensure_ascii=False)
    elif isinstance(resp, str):
        rtext = resp
    if status == "?":
        low = rtext.lower()
        if "sent (id" in low or "sent(id" in low:
            status = "OK"
        elif "error" in low or "fail" in low or "not sent" in low:
            status = "ERR"
except Exception:
    status = "?"
# однострочно, переводы строк схлопываем, чтобы лог оставался грепаемым
flat = " ".join(text.split())
print(f"[{status}] {flat}")
' 2>/dev/null)

[ -z "$LINE" ] && exit 0

# size-guard: не отдельный крон, три строки прямо здесь
if [ -f "$LOG" ]; then
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt "$MAXBYTES" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

# лог = plaintext всего разговора → 0600, только в $HOME
umask 077
printf '[%s] →TG %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LINE" >> "$LOG" 2>/dev/null
chmod 600 "$LOG" 2>/dev/null

# Аварийный пуш (владелец с телефона, выбрал этот вариант при ревью). Если reply
# НЕ дошёл через плагин ([ERR]), тот же текст уходит запасным путём — прямой
# Bot API (notify-owner.sh, свой токен). Спасает КЛАСС «MCP/плагин мёртв,
# а Telegram жив» (осиротевший процесс плагина, флаг не приехал — самый частый
# отказ на этой машине). НЕ переживёт бан/сеть — там тот же api.telegram.org
# (честно, по итогам ревью).
# NOTIFY_ANTISPAM_SEC=0: иначе антиспам 3600с молча съест все сообщения кроме первого.
# Текст через env (НЕ в bash -c кодом) — против инъекции. setsid+фон — не тормозить хук curl'ом.
case "$LINE" in
  "[ERR]"*)
    FB_BODY="${LINE#\[ERR\] }" setsid bash -c '
        NOTIFY_ANTISPAM_SEC=0 bash /home/ubuntu/core/notify-owner.sh reply_fallback "⚠️ (запасной канал) $FB_BODY"
    ' </dev/null >/dev/null 2>&1 &
    ;;
esac

exit 0
