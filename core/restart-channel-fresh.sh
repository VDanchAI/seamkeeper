#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Перезапуск Telegram-канала С ЧИСТЫМ контекстом — без --resume/--continue.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Штатный start-claude-telegram.sh всегда пытается восстановить переписку
# (--resume/--continue), чтобы после сбоя разговор не обрывался — это верно
# по умолчанию. Но если контекст уже забит под завязку, обычный «рестарт»
# просто возвращает ровно тот же забитый контекст, и проблема не решается.
# Этот скрипт — сознательный побег из зацикленного контекста: тот же запуск,
# но без флага восстановления, агент стартует с чистого листа.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# 1. Ждёт 3с, чтобы текущий ход успел договорить в Telegram, затем убивает
#    tmux-сессию "telegram".
# 2. Зовёт reap-telegram-orphans.sh --force — на случай, если bun-плагин
#    переживёт SIGHUP от tmux и уедет под init (тот же баг 409 Conflict, что
#    и в штатном старте, см. reap-telegram-orphans.sh).
# 3. Поднимает новую tmux-сессию БЕЗ --resume/--continue, принимает
#    trust-prompt, уведомляет владельца, что память пуста.
# 4. Если новая сессия не поднялась — откатывается на штатный
#    start-claude-telegram.sh (лучше с памятью, чем никак).
#
# Запускать ОТСОЕДИНЁННО (setsid ... &) — иначе скрипт умрёт вместе с
# tmux-сессией, которую сам же убивает.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
SESSION_NAME="telegram"
export CHANNEL_SESSION=1  # W2: метка канальной сессии для heartbeat-фильтра
LOG="/home/ubuntu/claude-telegram.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FRESH: $*" >> "$LOG"; }

# Гарантируем маркер живого дайджеста (см. core/cli-digest.sh). Один выключатель — файл.
mkdir -p "$HOME/.local/state/claude-telegram" 2>/dev/null
touch "$HOME/.local/state/claude-telegram/digest_enabled" 2>/dev/null

sleep 3   # дать текущему ходу договорить в Telegram

log "Убиваю сессию для чистого старта"
TMUX= tmux kill-session -t "$SESSION_NAME" 2>/dev/null
sleep 2

# kill-session шлёт SIGHUP, но bun-сервер плагина умеет его пережить и уехать под
# init — дальше он ворует getUpdates у новой сессии (409 Conflict, 14.08.2026).
# Добиваем сирот; плагин живой сессии скрипт не трогает.
bash /home/ubuntu/core/reap-telegram-orphans.sh --force >/dev/null 2>&1

TOOLS="Bash Read Write Edit Glob Grep WebFetch WebSearch Agent NotebookEdit mcp__plugin_telegram_telegram__reply mcp__plugin_telegram_telegram__react mcp__plugin_telegram_telegram__edit_message mcp__plugin_telegram_telegram__download_attachment"

TMUX= tmux new-session -d -s "$SESSION_NAME" \
  "bash -lc 'export CLAUDE_STREAM_IDLE_TIMEOUT_MS=300000; cd /home/ubuntu && exec claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official --allowedTools \"$TOOLS\"'"

sleep 15
PANE=$(TMUX= tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$PANE" | grep -q "trust"; then
    # 17.09.2026, Claude Code 2.1.273: промпт доверия к папке перевёрнут — по умолчанию
    # подсвечен отказ. Слепой Enter выбирал выход, и «чистый рестарт» убивал сессию
    # вместо подъёма.
    #
    # Нажатие зависит от версии, поэтому определяем её (на старых версиях Down выбрал бы
    # как раз отказ — нельзя жать вслепую):
    #   2.1.273+   → Down, затем Enter
    #   старее     → только Enter
    # На корню это лечит штатный старт (start-claude-telegram.sh проставляет
    # hasTrustDialogAccepted в ~/.claude.json, что от версии не зависит); здесь страховка.
    _cc_v=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    _needs_down=1   # версию не определили — исходим из нового поведения
    if [ -n "$_cc_v" ]; then
        IFS=. read -r _maj _min _pat <<<"$_cc_v"
        if [ "$_maj" -eq 2 ] && [ "$_min" -eq 1 ] && [ "$_pat" -lt 273 ]; then
            _needs_down=0
        elif [ "$_maj" -lt 2 ] || { [ "$_maj" -eq 2 ] && [ "$_min" -lt 1 ]; }; then
            _needs_down=0
        fi
    fi
    if [ "$_needs_down" = "1" ]; then
        TMUX= tmux send-keys -t "$SESSION_NAME" Down
        sleep 1
    fi
    TMUX= tmux send-keys -t "$SESSION_NAME" Enter
    log "Trust prompt принят (версия ${_cc_v:-неизвестна}, Down=${_needs_down})"
fi

if TMUX= tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "Чистая сессия поднята"
    bash /home/ubuntu/core/notify-owner.sh fresh-restart "Перезапустился начисто — контекст пустой, прошлый разговор не помню. Пиши, я на связи." >/dev/null 2>&1
else
    log "ОШИБКА: чистая сессия не поднялась, откат на штатный старт"
    bash /home/ubuntu/core/start-claude-telegram.sh
fi
