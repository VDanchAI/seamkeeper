#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Отстрел «зомби»-процессов telegram-плагина, ворующих очередь сообщений бота.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Telegram отдаёт очередь getUpdates ровно ОДНОМУ потребителю на токен. Когда
# сессия Claude умирает некрасиво (kill, обрыв), её bun-процесс плагина может
# выжить, переехать под init и продолжать опрашивать бота. Новая сессия тогда
# получает 409 Conflict и НЕМЕЕТ: сообщения владельца забирает мертвец.
# У нас это стоило двух часов тишины канала, прежде чем нашли причину
# (14.08.2026: tmux kill-session шлёт SIGHUP, но bun его пережил и переехал
# под init).
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# 1. Находит все bun-процессы, чей рабочий каталог = каталог telegram-плагина.
# 2. Оставляет в живых тех, у кого в цепочке предков есть ЖИВОЙ claude
#    (это плагин работающей сессии — его трогать нельзя).
# 3. Остальные — сироты: SIGTERM, пауза 3с, потом SIGKILL (SIGTERM они
#    игнорируют — проверено).
# Предохранители: без --force только показывает список (сухой прогон);
# собственное дерево процессов не трогает никогда.
#
# Использование:
#   reap-telegram-orphans.sh            # сухой прогон, показать кандидатов
#   reap-telegram-orphans.sh --force    # реально убить сирот
#
# Вызывается из start-скрипта и watchdog'а перед подъёмом новой сессии.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

PLUGIN_MARK="plugins/cache/claude-plugins-official/telegram"
LOG="${CHANNEL_LOG:-/home/ubuntu/claude-telegram.log}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] REAP: $*" >> "$LOG"; }
say() { echo "$*"; log "$*"; }

# PID'ы собственного дерева — их не трогаем ни при каких условиях.
declare -A SELF_TREE
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    SELF_TREE[$p]=1
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] && break
done

# Есть ли в цепочке предков живой claude? Возвращает 0 = хозяин найден.
has_live_claude_ancestor() {
    local pid=$1 hops=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 20 ]; do
        local cmd
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        # Обрамляем пробелами, чтобы поймать argv[0]="claude" без слэша: живая
        # сессия канала запущена как `exec claude`, и в /proc/PID/cmdline argv[0]
        # это просто "claude". Без обрамления *"/claude "* его не видит, и опознание
        # живого хозяина держалось только на случайном предке-tmux (баг найден 14.08).
        case " $cmd " in
            *" claude "*|*"/claude "*|*"/claude"|*"exec claude"*|*"tmux new-session"*) return 0 ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        hops=$((hops + 1))
    done
    return 1
}

orphans=()
for pid in $(pgrep -x bun 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    case "$cwd" in *"$PLUGIN_MARK"*) ;; *) continue ;; esac
    [ -n "${SELF_TREE[$pid]:-}" ] && continue
    if has_live_claude_ancestor "$pid"; then continue; fi
    orphans+=("$pid")
done

if [ ${#orphans[@]} -eq 0 ]; then
    say "сирот нет"
    exit 0
fi

for pid in "${orphans[@]}"; do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)
    say "сирота pid=$pid ppid=$(ps -o ppid= -p "$pid" | tr -d ' ') cmd=$cmd"
done

if [ "$FORCE" -ne 1 ]; then
    say "сухой прогон — никого не тронул (запусти с --force)"
    exit 0
fi

kill -TERM "${orphans[@]}" 2>/dev/null
sleep 3
still=()
for pid in "${orphans[@]}"; do
    kill -0 "$pid" 2>/dev/null && still+=("$pid")
done
if [ ${#still[@]} -gt 0 ]; then
    say "SIGTERM проигнорирован (${still[*]}) — добиваю SIGKILL"
    kill -KILL "${still[@]}" 2>/dev/null
    sleep 1
fi
left=()
for pid in "${orphans[@]}"; do
    kill -0 "$pid" 2>/dev/null && left+=("$pid")
done
if [ ${#left[@]} -gt 0 ]; then
    say "ОШИБКА: не умерли даже после SIGKILL: ${left[*]}"
    exit 1
fi
say "отстрелено сирот: ${#orphans[@]}"
