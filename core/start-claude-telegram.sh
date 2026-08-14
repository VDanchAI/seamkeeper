#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Стартовый скрипт Telegram-канала: поднимает Claude Code в выделенной tmux-
# сессии "telegram" (имя намеренно не "claude" — чтобы не конфликтовать с
# другими запущенными инстансами на той же машине).
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# «Просто запустить claude» недостаточно — на практике ловили три разных тихих
# отказа: (1) бот без токена генерит ответы, но они никуда не долетают —
# ~/.env не подхватывался через .profile, и это выглядело как «всё работает,
# просто тишина»; (2) без --dangerously-skip-permissions сессия встаёт в manual
# mode и ждёт Enter с клавиатуры, которую в Telegram нажать некому — бот молчит
# после первого же действия; (3) наивный `--continue` в общем каталоге
# headless-сессий подхватывает ЧУЖОЙ транскрипт, если после падения канала кто-
# то ещё писал в тот же проект — бот отвечает в контексте не своей переписки.
# Этот скрипт закрывает все три дыры разом, вместо того чтобы натыкаться на
# каждую заново при следующем рестарте.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# 1. Готовит PATH (bun/nvm/local-бинарники), включает live-дайджест действий
#    в Telegram (маркер-файл digest_enabled).
# 2. Подгружает секреты из ~/.env; если TELEGRAM_BOT_TOKEN пуст или Telegram
#    getMe его не подтверждает — падает с внятной ошибкой (fail loud вместо
#    тихого молчания бота).
# 3. Убивает старую tmux-сессию "telegram" (если была), затем зовёт
#    reap-telegram-orphans.sh --force — добить осиротевший bun-процесс плагина,
#    который может пережить SIGHUP от tmux и продолжить воровать очередь
#    getUpdates у новой сессии (409 Conflict).
# 4. Резолвит session_id последнего КАНАЛЬНОГО транскрипта (по маркеру входящего
#    сообщения плагина telegram в .jsonl) и стартует `claude --resume <id>`;
#    если резолв не удался — откатывается на `--continue`.
# 5. Поднимает Claude Code в tmux с --dangerously-skip-permissions и нужным
#    --allowedTools, автоматически принимает trust-prompt (до двух попыток),
#    ставит oom_score_adj=-400, чтобы канал не попал под OOM-killer первым.
#
# Вызывается вручную, systemd-юнитом claude-telegram.service, а также из
# restart-channel-fresh.sh (как fallback) и channel-resurrect.sh.
# ═══════════════════════════════════════════════════════════════════════════

SESSION_NAME="telegram"
LOG="/home/ubuntu/claude-telegram.log"

# Ensure bun and local tools are in PATH
export BUN_INSTALL="$HOME/.bun"
export NVM_DIR="$HOME/.nvm"
export PATH="$BUN_INSTALL/bin:$HOME/.local/bin:$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node/ 2>/dev/null | tail -1)/bin:$PATH"

export CLAUDE_STREAM_IDLE_TIMEOUT_MS=300000
export CHANNEL_SESSION=1  # W2: метка канальной сессии для heartbeat-фильтра

# Живой дайджест действий CLI → Telegram (см. core/cli-digest.sh + хук PreToolUse в
# ~/.claude/settings.json). Единый выключатель — файл-маркер: есть = дайджест шлётся.
# Чтобы отключить: rm этого файла. Стартовый пакет гарантирует его наличие.
mkdir -p "$HOME/.local/state/claude-telegram" 2>/dev/null
touch "$HOME/.local/state/claude-telegram/digest_enabled" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] START: $*" >> "$LOG"; }

# Load secrets (TELEGRAM_BOT_TOKEN etc). tmux new-session inherits this env, so the
# bun plugin server gets the token even if ~/.profile sourcing ever breaks.
# Belt-and-suspenders to the line added in ~/.profile.
set -a; [ -f "$HOME/.env" ] && . "$HOME/.env"; set +a

# Pre-flight: refuse to start a tokenless (dead) bot. A tokenless bun-server polls
# blind and silently drops every message — the exact "нихрена не долетает" failure.
# Fail loud here instead.
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    log "ABORT: TELEGRAM_BOT_TOKEN not set (check ~/.env)"
    echo "ERROR: TELEGRAM_BOT_TOKEN не найден — смотри ~/.env" >&2
    exit 1
fi
GETME=$(curl -s --max-time 10 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe")
if ! echo "$GETME" | grep -q '"ok":true'; then
    log "ABORT: token present but Telegram getMe failed (invalid token or no network)"
    echo "ERROR: токен есть, но Telegram getMe не прошёл — токен невалиден или нет сети" >&2
    exit 1
fi
log "Token OK ($(echo "$GETME" | grep -o '\"username\":\"[^\"]*\"'))"

# Kill ONLY our session, never touch others
# TMUX= needed to avoid socket conflicts when called from within a tmux session
if TMUX= tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "Killing existing '$SESSION_NAME' session"
    TMUX= tmux kill-session -t "$SESSION_NAME" 2>/dev/null
    sleep 2
fi

# tmux kill-session above already sends SIGHUP to all children (including bun).
# Do NOT pkill "bun.*telegram" here — it kills the calling Claude's own plugin.
sleep 1

# Но SIGHUP от kill-session — не гарантия: 14.08.2026 bun его пережил, переехал
# под init и продолжил опрашивать getUpdates. Новая сессия получала 409 Conflict
# и молчала два часа. Отстреливаем именно СИРОТ (без живого claude в предках);
# плагин работающей сессии скрипт не трогает, поэтому это безопасно и отсюда.
bash /home/ubuntu/core/reap-telegram-orphans.sh --force >/dev/null 2>&1

# Контрольный вопрос самому Telegram: очередь свободна? Если кто-то её всё ещё
# держит — эвристика по процессам не сработала, и новая сессия опять будет немой.
# Лучше узнать об этом здесь, в логе, чем через два часа тишины.
CONFLICT=$(curl -s --max-time 10 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?limit=1&timeout=0")
if echo "$CONFLICT" | grep -q '"error_code":409'; then
    log "WARN: getUpdates отдаёт 409 — очередь держит кто-то ещё, канал может остаться немым"
fi

# ── Волна 3, ЦЕЛЬ 2 (14.08.2026, R8 Волны 1): резолв session_id канала ──────
# ПРОБЛЕМА: `--continue` продолжает ПОСЛЕДНИЙ тронутый транскрипт в каталоге
# проекта -home-ubuntu, а каталог общий для ВСЕХ headless-сессий этой машины
# (ручные запуски, аудиты, claude-mem-обвязка). Если после падения канала
# кто-то ещё писал в проект позже, чем канал, `--continue` подцепит ЧУЖУЮ
# сессию — канал начнёт отвечать в контексте не своей переписки.
# ФИКС: тот же приём, что find_channel_transcript в watchdog-claude-telegram.sh
# (Волна 1) — ищем самый свежий .jsonl с маркером входящего сообщения плагина
# telegram; имя файла без расширения = его session_id. Стартуем через
# `--resume <id>`. FALLBACK на `--continue`, если id не резолвился (первый
# запуск, каталог пуст, маркер не встретился) — как было раньше.
# РИСК: `--resume` с протухшим/удалённым id падает с ошибкой запуска, поэтому
# резолв ОБЯЗАН деградировать в `--continue`, а не оставлять пустой аргумент.
CHANNEL_PROJECTS_DIR="${CHANNEL_PROJECTS_DIR:-/home/ubuntu/.claude/projects/-home-ubuntu}"

find_channel_transcript() {
    if [ -n "${CHANNEL_TRANSCRIPT:-}" ]; then
        [ -f "$CHANNEL_TRANSCRIPT" ] && echo "$CHANNEL_TRANSCRIPT"
        return
    fi
    find "$CHANNEL_PROJECTS_DIR" -maxdepth 1 -name '*.jsonl' -mmin -2880 2>/dev/null \
        | xargs -r grep -lF 'content":"<channel source=\"plugin:telegram' 2>/dev/null \
        | xargs -r ls -t 2>/dev/null | head -1
}

RESUME_SESSION_ID=""
CHANNEL_TRANSCRIPT_FOUND=$(find_channel_transcript)
if [ -n "$CHANNEL_TRANSCRIPT_FOUND" ] && [ -f "$CHANNEL_TRANSCRIPT_FOUND" ]; then
    RESUME_SESSION_ID=$(basename "$CHANNEL_TRANSCRIPT_FOUND" .jsonl)
fi

if [ -n "$RESUME_SESSION_ID" ]; then
    RESUME_FLAG="--resume $RESUME_SESSION_ID"
    log "Resume: канальный транскрипт найден, session_id=$RESUME_SESSION_ID"
else
    RESUME_FLAG="--continue"
    log "Resume: канальный транскрипт не найден — fallback на --continue"
fi

log "Starting Claude Code in tmux session '$SESSION_NAME'"

# --dangerously-skip-permissions обязателен: без него сессия поднимается в manual
# mode и КАЖДОЕ действие ждёт Enter с клавиатуры. Из Telegram нажать некому —
# сообщение приходит, обработка встаёт, бот молчит. Флаг потерялся при переезде
# со scripts/start-claude-telegram.sh (04.06), выстрелило при первом рестарте
# после апгрейда Claude Code 2.1.220 (27.07). settings.json уже содержит
# skipDangerousModePermissionPrompt: true — интерактивного вопроса не будет.
# $RESUME_FLAG вместо жёсткого --continue: см. блок выше (резолв session_id,
# Волна 3 ЦЕЛЬ 2) — либо `--resume <id>` канальной сессии, либо fallback
# `--continue`. Без восстановления диалога каждый рестарт = чистый лист, и
# Telegram-собеседник получает агента с амнезией.
#
# ВАЖНО про канал: он включается удалённым флагом tengu_harbor, который приезжает
# вместе с feature-флагами. DO_NOT_TRACK=1 глушит их загрузку целиком → флаг
# падает в дефолт false → "Channels are not currently available" (28.07).
# Поэтому DO_NOT_TRACK убран из ~/.claude/settings.json. Не возвращать его туда,
# не проверив канал.
TMUX= tmux new-session -d -s "$SESSION_NAME" \
  "bash -lc 'export CLAUDE_STREAM_IDLE_TIMEOUT_MS=300000; cd /home/ubuntu && exec claude \
    $RESUME_FLAG \
    --dangerously-skip-permissions \
    --channels plugin:telegram@claude-plugins-official \
    --allowedTools \"Bash Read Write Edit Glob Grep WebFetch WebSearch Agent NotebookEdit mcp__plugin_telegram_telegram__reply mcp__plugin_telegram_telegram__react mcp__plugin_telegram_telegram__edit_message mcp__plugin_telegram_telegram__download_attachment\"'"

# Wait for Claude to initialize, then pass trust prompt if it appears
sleep 15
PANE=$(TMUX= tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$PANE" | grep -q "trust"; then
    TMUX= tmux send-keys -t "$SESSION_NAME" Enter
    log "Trust prompt accepted"
fi
sleep 3
# Second check — sometimes prompt appears later
PANE=$(TMUX= tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$PANE" | grep -q "trust"; then
    TMUX= tmux send-keys -t "$SESSION_NAME" Enter
    log "Trust prompt accepted (second pass)"
fi

# W4 14.08.2026: оградить канал от OOM-killer. Сегодня днём python раздулся до 8.5ГБ и
# ядро убивало жертв по oom_score; канал (не systemd) был беззащитен. -400 сильно снижает
# шанс, что под раздачу попадёт именно он. Сервис-компаньон (пример: ваш отдельный бот),
# если он у вас есть и живёт под systemd, защищайте отдельно (systemd drop-in).
for _p in $(pgrep -f "claude --dangerously-skip-permissions --channels" 2>/dev/null); do
    echo -400 > "/proc/$_p/oom_score_adj" 2>/dev/null || sudo sh -c "echo -400 > /proc/$_p/oom_score_adj" 2>/dev/null
done

log "Session '$SESSION_NAME' started"
echo "Claude Code Telegram channel started in tmux session '$SESSION_NAME'"
echo "Attach: tmux attach -t $SESSION_NAME"
