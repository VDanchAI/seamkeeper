#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Единая команда диагностики и самопочинки всего стека Telegram-канала:
# осиротевшие процессы → tmux → claude → bun-плагин → внешний сервис. Чинит
# ТОЛЬКО то, что реально сломано, и шлёт ОДИН сводный отчёт владельцу.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# До этого скрипта «поднять/починить всё» означало вручную вспомнить и
# прогнать 4-5 отдельных команд — reap, старт-скрипт, systemctl restart,
# просмотр логов, каждая со своими флагами. Теперь это одна команда,
# безопасная для регулярного/автоматического прогона (cron, watchdog).
#
# ═══ КАК РАБОТАЕТ (7 шагов) ════════════════════════════════════════════════
# 1. Сироты bun-плагина — reap-telegram-orphans.sh (см. тот скрипт: bun может
#    пережить SIGHUP и продолжить воровать очередь getUpdates).
# 2-3. tmux-сессия и claude-процесс в ней живы? Если нет — помечаем на рестарт
#      (сам рестарт выполняется ОДИН раз, после шага 4, чтобы не задвоить).
# 4. bun-плагин слушает? Если tmux+claude живы, а плагина нет — тоже рестарт.
# 5. Внешний сервис-компаньон (systemd-юнит, по умолчанию имя "jarvis") —
#    active? Если нет — sudo systemctl restart.
# 6. Health-чек: маркер дайджеста, heartbeat last_activity, окно rate-limit,
#    воркер claude-mem, диск/память. Это ТОЛЬКО отчёт, ничего не чинит.
# 7. Один сводный отчёт владельцу через notify-owner.sh (или в stdout под --dry).
#
# ═══ БЕЗОПАСНОСТЬ (главное требование) ═════════════════════════════════════
# Скрипт НЕ имеет права убить или перезапустить ЖИВОЙ канал. Каждый шаг —
# сначала проверка, и только при подтверждённом отказе — починка:
#   - reap-telegram-orphans.sh САМ щадит живое дерево (сверка с предком-claude);
#     под --dry мы зовём его БЕЗ --force — чистое обнаружение, ноль побочных
#     эффектов.
#   - рестарт tmux/claude-процесса — только если tmux-сессии реально нет ИЛИ
#     claude-процесс в ней реально не найден (проверка через pane_pid + pgrep).
#   - рестарт из-за мёртвого bun-плагина — только если tmux+claude уже живы
#     (иначе рестарт уже случился по прошлому пункту, второй не нужен).
#   - внешний сервис — только если systemctl is-active не вернул "active".
# Идемпотентность: повторный прогон на здоровой системе не находит отказов —
# ничего не чинит, только отчитывается.
#
# Флаги:
#   (без аргументов)  — полный прогон, чинит найденные отказы, шлёт отчёт
#   --dry             — DRY_RUN: печатает "DRY: …" вместо каждого действия,
#                        ничего не чинит и не шлёт; отчёт печатается в stdout
#
# Env-override (по образцу notify-owner.sh / watchdog-claude-telegram.sh):
#   CHANNEL_LOG, CHANNEL_STATE_DIR, CHANNEL_SESSION_NAME, CHANNEL_BOT_PID,
#   CHANNEL_ENV_FILE, CHANNEL_ACCESS_JSON, START_SCRIPT, REAP_SCRIPT, NOTIFY,
#   JARVIS_SERVICE
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

SESSION_NAME="${CHANNEL_SESSION_NAME:-telegram}"
LOG="${CHANNEL_LOG:-/home/ubuntu/claude-telegram.log}"
STATE_DIR="${CHANNEL_STATE_DIR:-$HOME/.local/state/claude-telegram}"
BOT_PID_FILE="${CHANNEL_BOT_PID:-$HOME/.claude/channels/telegram/bot.pid}"
ACCESS_JSON="${CHANNEL_ACCESS_JSON:-$HOME/.claude/channels/telegram/access.json}"

START_SCRIPT="${START_SCRIPT:-/home/ubuntu/core/start-claude-telegram.sh}"
REAP_SCRIPT="${REAP_SCRIPT:-/home/ubuntu/core/reap-telegram-orphans.sh}"
NOTIFY="${NOTIFY:-/home/ubuntu/core/notify-owner.sh}"
JARVIS_SERVICE="${JARVIS_SERVICE:-jarvis}"

mkdir -p "$STATE_DIR" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESURRECT: $*" >> "$LOG"; }

DRY_RUN=0
[ "${1:-}" = "--dry" ] && DRY_RUN=1

# Возраст файла в секундах. `|| echo 0` — если файл исчезнет между -f и stat,
# пустая подстановка даёт синтаксическую ошибку арифметики (тот же приём,
# что в watchdog-claude-telegram.sh:file_age — консилиум I6).
file_age() {
    [ -f "$1" ] || { echo 999999999; return; }
    echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
}

REPORT_LINES=()
report() { REPORT_LINES+=("$1"); log "$1"; }

# ── Шаг 1: сироты 409 ──────────────────────────────────────────────────────
# Под --dry зовём reap БЕЗ --force — это чистое обнаружение (сухой прогон
# скрипта сам по себе не трогает процессы), поэтому безопасно даже для
# боевого лога, но мы всё равно передаём свой LOG/STATE через окружение
# вызывающего процесса не требуется: reap пишет в свой CHANNEL_LOG-путь.
if [ "$DRY_RUN" = "1" ]; then
    OUT=$(bash "$REAP_SCRIPT" 2>&1)
    if echo "$OUT" | grep -q "сирот нет"; then
        report "1/7 сироты: нет (dry-обнаружение)"
    else
        N=$(echo "$OUT" | grep -oE 'сирота pid=[0-9]+' | wc -l)
        report "1/7 сироты: DRY нашёл кандидатов=$N (не трогаю, запусти без --dry)"
    fi
else
    OUT=$(bash "$REAP_SCRIPT" --force 2>&1)
    if echo "$OUT" | grep -q "сирот нет"; then
        report "1/7 сироты: нет"
    elif echo "$OUT" | grep -qE 'отстрелено сирот: [0-9]+'; then
        N=$(echo "$OUT" | grep -oE 'отстрелено сирот: [0-9]+' | grep -oE '[0-9]+')
        report "1/7 сироты: убито $N"
    else
        report "1/7 сироты: reap вернул неожиданный вывод — см. $LOG (детали ниже)"
        log "REAP RAW: $OUT"
    fi
fi

# ── Шаг 2+3: tmux-сессия и claude-процесс в ней ────────────────────────────
# Решение о рестарте принимаем ЗДЕСЬ, но выполняем ОДИН раз, после шага 4 —
# чтобы плагин-чек (шаг 4) не запускал второй, избыточный рестарт, если
# рестарт уже случился по причине мёртвого tmux/claude.
NEED_RESTART=0
RESTART_REASON=""

TMUX_ALIVE=0
if TMUX= tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    TMUX_ALIVE=1
    report "2/7 tmux-сессия '$SESSION_NAME': жива"
else
    report "2/7 tmux-сессия '$SESSION_NAME': НЕТ"
    NEED_RESTART=1
    RESTART_REASON="tmux-missing"
fi

CLAUDE_PID=""
if [ "$TMUX_ALIVE" = "1" ]; then
    SHELL_PID=$(TMUX= tmux list-panes -t "$SESSION_NAME" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$SHELL_PID" ]; then
        CLAUDE_PID=$(pgrep -P "$SHELL_PID" -x claude 2>/dev/null | head -1)
        if [ -z "$CLAUDE_PID" ]; then
            CLAUDE_PID=$(pstree -p "$SHELL_PID" 2>/dev/null | grep -oP 'claude\(\K[0-9]+' | head -1)
        fi
    fi
    if [ -n "$CLAUDE_PID" ]; then
        report "3/7 claude-процесс: жив (pid=$CLAUDE_PID)"
    else
        report "3/7 claude-процесс: НЕ найден в сессии"
        NEED_RESTART=1
        [ -z "$RESTART_REASON" ] && RESTART_REASON="claude-dead"
    fi
else
    report "3/7 claude-процесс: пропущено (tmux уже мёртв)"
fi

# ── Шаг 4: bun-плагин ───────────────────────────────────────────────────────
# Тот же способ, что watchdog Check 4: bot.pid → сверка cmdline, fallback —
# pgrep по пути плагина. Если tmux/claude уже помечены на рестарт, отдельного
# рестарта здесь НЕ триггерим — «уже покрыто reap+рестарт» (спека, шаг 4).
BUN_PID=""
if [ -f "$BOT_PID_FILE" ]; then
    CAND=$(cat "$BOT_PID_FILE" 2>/dev/null | tr -cd '0-9')
    if [ -n "$CAND" ] && [ -d "/proc/$CAND" ]; then
        CMDLINE=$(tr '\0' ' ' < "/proc/$CAND/cmdline" 2>/dev/null)
        case "$CMDLINE" in
            *bun*server.ts*|*telegram*) BUN_PID="$CAND" ;;
        esac
    fi
fi
if [ -z "$BUN_PID" ]; then
    for p in $(pgrep -f 'claude-plugins-official/telegram' 2>/dev/null); do
        pname=$(cat "/proc/$p/comm" 2>/dev/null)
        case "$pname" in
            bun|node) BUN_PID="$p"; break ;;
        esac
    done
fi

if [ -n "$BUN_PID" ]; then
    report "4/7 bun-плагин: слушает (pid=$BUN_PID)"
elif [ "$NEED_RESTART" = "1" ]; then
    report "4/7 bun-плагин: не найден (уже покрыто рестартом из шага 2/3)"
else
    report "4/7 bun-плагин: НЕ найден, tmux+claude живы — плагин мёртв отдельно"
    NEED_RESTART=1
    RESTART_REASON="plugin-dead"
fi

# ── Выполняем рестарт ОДИН раз, если он реально нужен ──────────────────────
if [ "$NEED_RESTART" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        report "2-4/7 РЕШЕНИЕ: нужен рестарт (причина: $RESTART_REASON) — DRY, не выполняю"
    else
        report "2-4/7 запускаю $START_SCRIPT (причина: $RESTART_REASON)"
        # 9>&- не нужен: этот скрипт не держит flock (в отличие от watchdog), поэтому
        # fd-leak класса 28.07 здесь структурно невозможен — лочит только watchdog.
        if bash "$START_SCRIPT" >> "$LOG" 2>&1; then
            report "2-4/7 рестарт: OK"
        else
            RC=$?
            report "2-4/7 рестарт: ОШИБКА rc=$RC — смотри $LOG"
        fi
    fi
else
    report "2-4/7 починка не требуется — канал живой стек не трогаю"
fi

# ── Шаг 5: внешний сервис-компаньон (например Jarvis) ──────────────────────
JARVIS_STATUS=$(systemctl is-active "$JARVIS_SERVICE" 2>/dev/null)
if [ "$JARVIS_STATUS" = "active" ]; then
    report "5/7 сервис ($JARVIS_SERVICE): active"
else
    report "5/7 сервис ($JARVIS_SERVICE): $JARVIS_STATUS — чиню"
    if [ "$DRY_RUN" = "1" ]; then
        report "5/7 DRY: sudo systemctl restart $JARVIS_SERVICE"
    else
        if sudo systemctl restart "$JARVIS_SERVICE" >> "$LOG" 2>&1; then
            sleep 2
            NEW_STATUS=$(systemctl is-active "$JARVIS_SERVICE" 2>/dev/null)
            report "5/7 сервис рестарт: статус теперь $NEW_STATUS"
        else
            report "5/7 сервис рестарт: ОШИБКА — смотри $LOG"
        fi
    fi
fi

# ── Шаг 6: health-чек (ТОЛЬКО отчёт, ничего не чинит) ──────────────────────
if [ -f "$STATE_DIR/digest_enabled" ]; then
    report "6/7 дайджест: включён"
else
    report "6/7 дайджест: маркер digest_enabled отсутствует"
fi

LAST_ACT_AGE=$(file_age "$STATE_DIR/last_activity")
if [ "$LAST_ACT_AGE" -ge 999999999 ]; then
    report "6/7 heartbeat: last_activity ещё ни разу не писался"
else
    report "6/7 heartbeat: last_activity ${LAST_ACT_AGE}с назад"
fi

LIMIT_UNTIL_VAL=$(cat "$STATE_DIR/limit_until" 2>/dev/null | tr -cd '0-9')
NOW_EPOCH=$(date +%s)
if [ -n "$LIMIT_UNTIL_VAL" ] && [ "$LIMIT_UNTIL_VAL" -gt "$NOW_EPOCH" ] 2>/dev/null; then
    report "6/7 лимит: активно окно limit_until=$(date -d "@$LIMIT_UNTIL_VAL" '+%H:%M' 2>/dev/null)"
else
    report "6/7 лимит: окно не активно"
fi

if pgrep -f 'claude-mem.*worker-service' >/dev/null 2>&1; then
    report "6/7 claude-mem worker: жив"
else
    report "6/7 claude-mem worker: НЕ найден"
fi

DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $5" занято, "$4" свободно"}')
MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print "used "$3"/"$2}')
report "6/7 диск: ${DISK:-н/д} · память: ${MEM:-н/д}"

# ── Шаг 7: один сводный отчёт владельцу ────────────────────────────────────
SUMMARY=$(printf '%s\n' "Resurrect-прогон:" "${REPORT_LINES[@]}")
if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: notify resurrect"
    printf '%s\n' "$SUMMARY"
else
    "$NOTIFY" resurrect "$SUMMARY" >/dev/null 2>&1
    printf '%s\n' "$SUMMARY"
fi

exit 0
