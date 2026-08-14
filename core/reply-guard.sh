#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Stop-hook «reply-guard»: не даёт ходу завершиться, если пришло сообщение
# от владельца в Telegram, а ответа через reply не было.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Правило владельца 14.08.2026 («чтоб не приходилось следить»): дважды за
# сессию агент отвечал в терминал вместо reply — владелец не видел ответ.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# Claude Code передаёт Stop-хуку на stdin JSON с transcript_path. Скрипт
# читает транскрипт, находит позицию ПОСЛЕДНЕГО входящего telegram-сообщения
# от владельца и ПОСЛЕДНЕГО вызова reply. Если входящее новее ответа —
# exit 2 + stderr (Claude Code вернёт текст агенту и НЕ завершит ход, заставив
# ответить). Анти-петля: маркер по индексу входящего, один и тот же промах
# не блокирует дважды (иначе агент завис бы, если ответ реально не нужен).
#
# Не для subagent'ов и не для не-канальных сессий — там reply не нужен, тихо
# выходим.
# ═══════════════════════════════════════════════════════════════════════════

INPUT=$(cat 2>/dev/null)
TP=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('transcript_path',''))
except: print('')" 2>/dev/null)
[ -z "$TP" ] && exit 0
[ ! -f "$TP" ] && exit 0

# Гейт: сторож работает только в канальной сессии (как heartbeat/дайджест).
if [ "${CHANNEL_SESSION:-0}" != "1" ] && [ ! -f "$HOME/.local/state/claude-telegram/digest_enabled" ]; then
    exit 0
fi

# Метка анти-петли — в durable $HOME (НЕ /tmp: тот чистится ребутом → после
# перезагрузки guard один раз ложно заблокировал бы уже отвеченное сообщение).
# Плюс session_id в имени: иначе индексы двух транскриптов пересекаются и
# гасят друг друга.
GUARD_DIR="${REPLY_GUARD_DIR:-$HOME/.local/state/claude-telegram}"
mkdir -p "$GUARD_DIR" 2>/dev/null
SID=$(printf '%s' "$INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('session_id','') or 'nosid')
except: print('nosid')" 2>/dev/null)
SID=$(printf '%s' "${SID:-nosid}" | tr -cd 'A-Za-z0-9._-')
MARK="${REPLY_GUARD_MARK:-$GUARD_DIR/reply-guard-${SID:-nosid}}"

python3 - "$TP" "$MARK" <<'PY'
import json, sys
tp, mark = sys.argv[1], sys.argv[2]
try:
    lines = open(tp, encoding='utf-8', errors='ignore').read().splitlines()
except Exception:
    sys.exit(0)

last_in = -1      # индекс последнего входящего telegram от владельца
last_reply = -1   # индекс последнего вызова reply/edit/react в телеграм
for i, l in enumerate(lines):
    try:
        o = json.loads(l)
    except Exception:
        continue
    t = o.get("type")
    if t == "user":
        # содержимое user-сообщения может быть строкой или списком блоков
        content = o.get("message", {}).get("content", "")
        blob = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
        # реальное входящее от владельца несёт тег канала именно telegram-плагина
        if 'source="plugin:telegram' in blob:
            last_in = i
    elif t == "assistant":
        for b in o.get("message", {}).get("content", []):
            if isinstance(b, dict) and b.get("type") == "tool_use":
                name = b.get("name", "")
                if "telegram_telegram__reply" in name or "telegram_telegram__edit_message" in name:
                    last_reply = i

# анти-петля: не блокировать повторно за один и тот же непрошедший ответ
try:
    seen = int(open(mark).read().strip())
except Exception:
    seen = -1

if last_in > last_reply and last_in != seen:
    try:
        open(mark, "w").write(str(last_in))
    except Exception:
        pass
    sys.stderr.write(
        "REPLY-GUARD: пришло сообщение от владельца в Telegram, но ты НЕ ответил через reply. "
        "Твой текст в терминале до него НЕ дошёл. Отправь ответ через "
        "mcp__plugin_telegram_telegram__reply (chat_id владельца), затем завершай ход."
    )
    sys.exit(2)

sys.exit(0)
PY
rc=$?
exit $rc
