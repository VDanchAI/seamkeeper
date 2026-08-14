#!/bin/bash
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Главный сторож проекта. Следит ТОЛЬКО за tmux-сессией 'telegram' (канал
# Claude Code в Telegram) и лечит все классы её отказов — от смерти процесса
# до исчерпания лимита токенов. Другие tmux-сессии (интерактивная работа,
# прочие проекты) не трогает никогда. Запускается из cron каждые 3 минуты.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Канал живёт без присмотра человека — сообщения владельца должны получить
# ответ, даже если сессия упала, плагин завис, кончился лимит подписки или
# осиротевший процесс прошлой сессии ворует очередь Telegram себе. Без
# сторожа любой из этих отказов означает тишину на неопределённое время
# (реальный инцидент 14.08.2026 — 2 часа тишины из-за осиротевшего
# bun-процесса, ворующего getUpdates).
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# Лестница проверок сверху вниз, первая непройденная — точка выхода на лечение:
#   Check 1  tmux-сессия существует?                      нет → restart_session
#   Check 3  claude-процесс жив внутри сессии?             нет → restart_session
#            [детектор лимита токенов — сразу после Check 3: читает
#            jsonl-транскрипт сессии, парсит время сброса лимита, армирует
#            окно ожидания, оживляет канал по истечении]
#   Check 4  telegram-плагин (bun server.ts) вообще жив?   нет (>5 мин) → restart
#   Check 5b осиротевший bun прошлой сессии ворует
#            очередь getUpdates (409 Conflict)?            есть → reap --force
#   Check 5  плагин жив, но заморожен (нет живого
#            ESTABLISHED-соединения :443 к Telegram)?      да (>5 мин) → decide_restart
#   Check 6  тихий отказ: сообщение принято, ответа нет,
#            признаков активности нет (writing-гейт бережёт
#            сессию, занятую долгой легитимной задачей)    → decide_restart
#   Check 7  доступ к модели вообще есть? (прямой пинг
#            claude -p дешёвой моделью, раз в час)         нет → notify, рестарт не лечит
#
# Лестница рестартов (эскалация, а не всегда шаг 0):
#   0. restart_session   — обычный `--continue`, пока флапов в окне < FLAP_LIMIT
#   1. restart_fresh      — чистый старт без памяти (restart-channel-fresh.sh)
#   2. escalate_backoff   — экспоненциальный бэкофф (900→1800→3600с) и сдаться,
#                           дальше только уведомления — нужна рука владельца
# Гейт лимита/бэкоффа встаёт перед рестартами: пока активно окно ожидания
# лимита токенов ИЛИ окно бэкоффа, лечение подавлено — нет смысла чинить то,
# что само пройдёт, и это же не даёт флаппинг-счётчику копиться зря.
#
# Тестирование:
#   DRY_RUN=1              — ничего не чинит и не уведомляет, только печатает
#                             намерения; можно гонять на живой системе безопасно.
#   SKIP_PROCESS_CHECKS=1  — пропускает структурные Check 1–5b, чтобы юнит-тесты
#                             детектора лимита/тихого отказа не зависели от
#                             текущего состояния живой системы.
#   --selftest-parse "<текст>" [epoch] — юнит-тест парсера времени сброса лимита,
#                             без захвата flock и без сайд-эффектов.
#
# W1 2026-08-01 (консилиум Codex+Gemini+Opus):
#   - убрана проверка trust-промпта: она ложно срабатывала на тексте переписки
#     и через `exit 0` ослепляла проверки плагина и соединения;
#   - плагин ищется по bot.pid с привязкой к нашей сессии, а не глобальным pgrep -f;
#   - провал починки и «перезапуск по кругу» теперь уведомляют владельца;
#   - добавлен детектор тихого отказа: приняли сообщение и не ответили.
# ═══════════════════════════════════════════════════════════════════════════

SESSION_NAME="telegram"
LOG="${CHANNEL_LOG:-/home/ubuntu/claude-telegram.log}"
START_SCRIPT="/home/ubuntu/core/start-claude-telegram.sh"
NOTIFY="${CHANNEL_NOTIFY:-/home/ubuntu/core/notify-owner.sh}"
STALE_MARKER="/tmp/claude-telegram-no-bun"
FROZEN_MARKER="/tmp/claude-telegram-frozen"   # alive-but-frozen probe (AUDIT 2026-06-21 follow-up)
FROZEN_GRACE=300       # wrapper alive but no Telegram conn for >5 min → frozen → restart
# Имя флага сменено на -v2: СТАРЫЙ /tmp/watchdog-claude-telegram.lock намертво удерживает
# tmux, унаследовавший дескриптор 28.07 (см. комментарий в restart_session). Убить его
# нельзя — это живая сессия канала. Новое имя даёт чистый флаг, застрявший старый остаётся
# висеть безвредно и уйдёт при ближайшем перезапуске tmux.
LOCK="${CHANNEL_LOCK:-/tmp/watchdog-claude-telegram-v2.lock}"
RESTART_MARKER="/tmp/claude-telegram-last-restart"
RESTART_COOLDOWN=900   # max 1 рестарт / 15 мин — loop-guard (AUDIT 2026-06-21, BUG #6)
MAX_LOG_BYTES=1048576  # 1 MiB — rotate when exceeded

# Состояние, которое должно пережить ребут (/tmp чистится) — heartbeat сессии,
# история рестартов, метки антиспама уведомлений.
STATE_DIR="${CHANNEL_STATE_DIR:-/home/ubuntu/.local/state/claude-telegram}"
BOT_PID_FILE="${CHANNEL_BOT_PID:-/home/ubuntu/.claude/channels/telegram/bot.pid}"
RESTART_HISTORY="$STATE_DIR/restart_history"
SILENT_MARKER="$STATE_DIR/silent_since"

# Тихий отказ: сообщение принято, ответа нет. ACTIVITY_GRACE должен быть больше самой
# длинной легитимной задачи — консилиум 01.08 шёл ~10 мин, поэтому 15, а не 5.
SILENT_GRACE="${SILENT_GRACE:-1800}"      # 30 мин без ответа на принятое сообщение
ACTIVITY_GRACE="${ACTIVITY_GRACE:-900}"   # 15 мин без единого действия = не «думает», а завис
# ФИКС ревью W2 (находка 3): кап отсрочки writing-гейта. mtime транскрипта растёт и от
# ВХОДЯЩИХ сообщений — владелец, тычущий мёртвый канал «ты тут?», иначе откладывал бы
# починку вечно (инверсия). Дольше DEFER_MAX непрерывной отсрочки — рубим, несмотря на mtime.
DEFER_MAX="${DEFER_MAX:-1800}"            # 30 мин суммарной отсрочки — потолок
DEFER_SINCE="$STATE_DIR/silent_defer_since"
# Флаппинг = «чиним, и НЕ ПОМОГАЕТ», а не «часто чиним».
# Первая версия (3 за 3 ч) будила владельца зря: плагин падает ~раз в час, и рестарт
# КАЖДЫЙ раз срабатывает («Restart OK»). Формально 4 рестарта за 3 ч — флаппинг, по сути
# исправная регулярная починка. Окно: три рестарта подряд означают, что перезапуск
# проблему не решает — вот тогда нужен человек.
# W1-ФИКС Б1 (14.08, adversarial-ревью): окно поднято 1800→3600. При COOLDOWN=900 три
# рестарта растягиваются на ≥1800с, и в окне 1800 старейший ВЫПАДАЛ раньше, чем счётчик
# успевал набрать 3 → лестница fresh/backoff была НЕДОСТИЖИМА (доказано данными инцидента,
# шаг ровно 900с). 3600 даёт запас на джиттер cron и делает эскалацию достижимой.
FLAP_WINDOW="${FLAP_WINDOW:-3600}"        # окно 60 мин (было 30 — см. фикс Б1)
FLAP_LIMIT="${FLAP_LIMIT:-3}"             # ≥3 рестартов за окно = рестарт не помогает

# ── W1 2026-08-14: константы двух новых подсистем (детектор лимита + reap/эскалация) ──
# Все env-переопределяемы. Откат ФИЧИ ЛИМИТА целиком: LIMIT_MAX_WAIT=0 → окно не
# армируется, поведение как до Волны 1. Значения — прикидка в духе существующих 900/1800,
# калибруются по факту (см. WAVE1-DESIGN.md «ОТКРЫТЫЕ РИСКИ»).
LIMIT_MAX_WAIT="${LIMIT_MAX_WAIT:-21600}"   # 6ч кап на лимитное окно — потолок цены ошибки
LIMIT_MARGIN="${LIMIT_MARGIN:-120}"         # запас к моменту reset, чтобы не дёргаться раньше
LIMIT_RESUME_MAX="${LIMIT_RESUME_MAX:-5}"   # ≤5 попыток оживить после сброса, потом зову руку
# W1-ФИКС Б2 (14.08): верхняя граница свежести лимит-записи. parse_reset_epoch резолвит
# время дня в СЕГОДНЯ, поэтому вчерашняя «resets 2:50pm», прочитанная сегодня до 14:50,
# дала бы reset в будущем → ложный лимит глушил бы ЗДОРОВЫЙ канал. Армим только «свежий»
# лимит — запись не старше 2 циклов cron (2*180). Старше — не наш текущий лимит, игнор.
LIMIT_STALE_MAX="${LIMIT_STALE_MAX:-360}"   # запись старше 360с — не считаем свежим лимитом
ORPHAN_GRACE="${ORPHAN_GRACE:-180}"         # сирота должна продержаться столько до отстрела
REAP_COOLDOWN="${REAP_COOLDOWN:-600}"       # не чаще одного реального отстрела в 10 мин
FRESH_WINDOW="${FRESH_WINDOW:-3600}"        # окно учёта чистых стартов (restart-channel-fresh)
FRESH_LIMIT="${FRESH_LIMIT:-2}"             # ≥2 чистых старта за окно → backoff, рестарты стоп

# Пути актуаторов — env-override для тестов (по образцу START_SCRIPT/NOTIFY выше).
REAP_SCRIPT="${REAP_SCRIPT:-/home/ubuntu/core/reap-telegram-orphans.sh}"
FRESH_SCRIPT="${FRESH_SCRIPT:-/home/ubuntu/core/restart-channel-fresh.sh}"
CHANNEL_PROJECTS_DIR="${CHANNEL_PROJECTS_DIR:-/home/ubuntu/.claude/projects/-home-ubuntu}"

# Файловые метки (в STATE_DIR — переживают ребут). limit_until — ЕДИНСТВЕННАЯ точка стыка
# двух подсистем: пишет детектор лимита, читают remediation_allowed() и подавление Check 6/7.
LIMIT_UNTIL="$STATE_DIR/limit_until"              # epoch «не чинить до»
LIMIT_LAST_RECORD="$STATE_DIR/limit_last_record"  # epoch последней учтённой лимит-записи
LIMIT_DETECTED_AT="$STATE_DIR/limit_detected_at"  # когда засекли лимит (для капа)
LIMIT_RESUME_COUNT="$STATE_DIR/limit_resume_count" # счётчик попыток оживления после сброса
BACKOFF_UNTIL="$STATE_DIR/backoff_until"          # epoch экспоненциального бэкоффа эскалации
BACKOFF_STEP="$STATE_DIR/backoff_step"            # текущая ступень бэкоффа (0/1/2+)
FRESH_HISTORY="$STATE_DIR/fresh_history"          # история чистых стартов (лестница)
ORPHAN_MARKER="$STATE_DIR/orphan_since"           # grace-метка появления сироты
REAP_MARKER="$STATE_DIR/last_reap"                # cooldown-метка реального отстрела

# PATH: cron даёт /usr/bin:/bin, где лежит СТАРЫЙ claude 2.1.92 (симлинк npm), а не
# рабочий 2.1.220 из nvm. Без этого любая проверка через `claude` тихо пошла бы не в тот
# бинарник. Заодно нужны bun/ss/curl.
export PATH="/home/ubuntu/.nvm/versions/node/v22.22.2/bin:/home/ubuntu/.bun/bin:/home/ubuntu/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── W1 2026-08-14: парсер времени сброса лимита ───────────────────────────────
# Определён ДО flock, чтобы --selftest-parse (юнит-тест ниже) мог его вызвать без
# захвата блокировки и без сайд-эффектов. Функция чистая: читает только /etc/timezone.
# TZ берём из скобок сообщения «(Europe/Berlin)», фолбэк — /etc/timezone, затем UTC.
# Если распарсенное время < времени записи → это «завтра» (сброс уже за полночь).
# К результату прибавляем LIMIT_MARGIN — не дёргаться ровно в секунду сброса.
parse_reset_epoch() {
    local text="$1" rec_epoch="$2"
    local tz when cand
    tz=$(printf '%s' "$text" | grep -oE '\([A-Za-z]+/[A-Za-z_]+\)' | head -1 | tr -d '()')
    [ -z "$tz" ] && tz=$(cat /etc/timezone 2>/dev/null)
    [ -z "$tz" ] && tz="UTC"
    # Убираем (TZ), запятые → пробелы, филлер-слова; остаётся голое время/дата для date -d.
    when=$(printf '%s' "$text" \
        | sed -E 's/\([A-Za-z]+\/[A-Za-z_]+\)//g; s/,/ /g' \
        | sed -E 's/\b([Rr]esets?|will|be|available|again|at|on)\b//g' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$when" ] && return 1
    cand=$(TZ="$tz" date -d "$when" +%s 2>/dev/null) || return 1
    [ -z "$cand" ] && return 1
    if [ "$cand" -lt "$rec_epoch" ]; then
        cand=$(TZ="$tz" date -d "tomorrow $when" +%s 2>/dev/null) || return 1
        [ -z "$cand" ] && return 1
    fi
    echo $(( cand + LIMIT_MARGIN ))
}

# --selftest-parse "<текст>" [epoch_записи] — юнит-тест парсера, ДО flock и сайд-эффектов.
# Печатает epoch и rc0 при успехе, PARSE-FAIL и rc1 при мусоре. Нужен потому, что весь
# детектор лимита стоит на этом парсинге, а гонять его через живой tmux нельзя.
if [ "${1:-}" = "--selftest-parse" ]; then
    _st_epoch="${3:-$(date +%s)}"
    if _st_out=$(parse_reset_epoch "${2:-}" "$_st_epoch"); then
        echo "$_st_out"; exit 0
    else
        echo "PARSE-FAIL" >&2; exit 1
    fi
fi

mkdir -p "$STATE_DIR" 2>/dev/null

# ── Concurrency guard: only one watchdog at a time ──
exec 9>"$LOCK"
if ! flock -n 9; then
    exit 0  # another watchdog instance is running
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: $*" >> "$LOG"; }

# DRY_RUN=1 — ничего не чинит и никому не пишет, только печатает намерения. Нужен, чтобы
# прогнать watchdog на ЖИВОЙ системе и увидеть его решения, ничего при этом не сломав,
# и чтобы тесты гоняли настоящий скрипт, а не его копию.
DRY_RUN="${DRY_RUN:-0}"

notify() {
    if [ "$DRY_RUN" = "1" ]; then echo "DRY: notify $1"; return 0; fi
    [ -x "$NOTIFY" ] && "$NOTIFY" "$@" >/dev/null 2>&1
}
notify_recover() {
    if [ "$DRY_RUN" = "1" ]; then echo "DRY: notify-recover $1"; return 0; fi
    [ -x "$NOTIFY" ] && "$NOTIFY" --recover "$@" >/dev/null 2>&1
}

# Возраст файла в секундах. `|| echo 0` обязателен: если файл исчезнет между -f и stat,
# пустая подстановка даст синтаксическую ошибку арифметики, AGE станет 0 и проверка
# замолчит навсегда (замечание консилиума I6).
file_age() {
    [ -f "$1" ] || { echo 999999999; return; }
    echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
}

# Флаппинг: чиним, а оно не чинится. Ловит отказы ЛЮБОЙ природы, в том числе те,
# которых я не предусмотрел — рестарт просто не помогает, и владелец должен узнать.
record_restart() {
    local now; now=$(date +%s)
    echo "$now" >> "$RESTART_HISTORY"
    # держим только окно
    local cutoff=$(( now - FLAP_WINDOW ))
    awk -v c="$cutoff" '$1 >= c' "$RESTART_HISTORY" > "$RESTART_HISTORY.tmp" 2>/dev/null \
        && mv "$RESTART_HISTORY.tmp" "$RESTART_HISTORY"
    local count; count=$(wc -l < "$RESTART_HISTORY" 2>/dev/null || echo 0)
    if [ "$count" -ge "$FLAP_LIMIT" ]; then
        log "FLAPPING: $count рестартов за $((FLAP_WINDOW/3600))ч — чиним безуспешно"
        notify flapping "Канал перезапускался $count раз(а) за $((FLAP_WINDOW/3600)) часа и не чинится. Похоже, поломка не лечится перезапуском — нужен ты."
    fi
}

restart_session() {
    local reason="$*"
    if [ "$DRY_RUN" = "1" ]; then echo "DRY: restart ($reason)"; return 0; fi
    if [ -f "$RESTART_MARKER" ]; then
        age=$(file_age "$RESTART_MARKER")
        if [ "$age" -lt "$RESTART_COOLDOWN" ]; then
            log "Restart suppressed (rate-cap, last ${age}s ago < ${RESTART_COOLDOWN}s, reason: $reason)"
            # Подавление — не тишина: если причина держится, а мы не чиним, скажем об этом.
            notify restart-suppressed "Канал просит перезапуск ($reason), но я уже перезапускал его ${age} сек назад и жду паузу. Если это повторяется — перезапуск не помогает."
            return 1
        fi
    fi
    touch "$RESTART_MARKER"
    rm -f "$STALE_MARKER" "$FROZEN_MARKER"   # reset detector state across a restart
    log "Restarting session (reason: $reason)"
    record_restart

    # `9>&-` — КРИТИЧНО, иначе watchdog кончает с собой при первом же успешном ремонте.
    # Механизм (найден 01.08): `exec 9>$LOCK` + flock берёт блокировку на дескриптор 9;
    # start-скрипт запускает tmux, tmux НАСЛЕДУЕТ дескриптор вместе с блокировкой и живёт
    # вечно → флаг не отпускается никогда → все следующие запуски по cron выходят на flock.
    # Проверено: /proc/<tmux>/fd/9 → этот самый lock, открыт 28.07 21:33; последняя запись
    # watchdog в логе — 28.07 21:33. Три с половиной суток cron запускал труп ~1700 раз.
    # Владелец всё это время считал, что сторож на посту (и я вчера сказал ему то же самое).
    bash "$START_SCRIPT" >> "$LOG" 2>&1 9>&-
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log "Restart OK (reason: $reason)"
        notify_recover restart-failed "Отбой: канал поднялся."
        return 0
    fi
    # Раньше rc старт-скрипта не проверялся вообще: провалившаяся починка = тишина
    # навсегда. Это и был главный источник «телега молчит, а никто не сказал».
    log "Restart FAILED rc=$rc (reason: $reason)"
    notify restart-failed "Не смог поднять канал: перезапуск завершился ошибкой rc=$rc (причина: $reason). Нужна твоя рука."
    return 1
}

# ═══ W1 2026-08-14: ПОДСИСТЕМА A — ДЕТЕКТОР ЛИМИТА ТОКЕНОВ ════════════════════
# Причина: когда кончается лимит/подписка, процессы ЖИВЫ, а ответить сессия не может.
# Старый сторож видел «всё живо» и либо молчал, либо крутил бесполезные рестарты. Теперь
# лимит распознаётся по jsonl-записи API-ошибки, армируется окно «не чинить до reset», а
# по сбросу канал оживляется nudge'ом. Контракт с подсистемой B — файл limit_until.

# Транскрипт активной сессии канала. Подлинная канальная запись имеет ОДИНАРНОЕ
# экранирование \" (цитаты чужих сессий — двойное \\\", fixed-string их не ловит).
# Env-override CHANNEL_TRANSCRIPT — для тестов подставляем фейковый jsonl.
find_channel_transcript() {
    if [ -n "${CHANNEL_TRANSCRIPT:-}" ]; then
        [ -f "$CHANNEL_TRANSCRIPT" ] && echo "$CHANNEL_TRANSCRIPT"
        return
    fi
    find "$CHANNEL_PROJECTS_DIR" -maxdepth 1 -name '*.jsonl' -mmin -2880 2>/dev/null \
        | xargs -r grep -lF 'content":"<channel source=\"plugin:telegram' 2>/dev/null \
        | xargs -r ls -t 2>/dev/null | head -1
}

# Армирование лимитного окна. until = min(reset+margin, detected_at+LIMIT_MAX_WAIT).
# Пишет limit_until/limit_last_record/limit_detected_at и ОДНО уведомление token-limit.
# Уважает DRY_RUN: печатает намерение, файлы не трогает.
arm_limit_window() {
    local reset_epoch="$1" detected_at="$2" rec_epoch="$3"
    local cap=$(( detected_at + LIMIT_MAX_WAIT ))
    local until="$reset_epoch"
    [ "$until" -gt "$cap" ] && until="$cap"
    local hhmm; hhmm=$(date -d "@$until" '+%H:%M' 2>/dev/null)
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: arm limit_until=$until (reset=$reset_epoch cap=$cap ~$hhmm)"
    else
        echo "$until"      > "$LIMIT_UNTIL"
        echo "$rec_epoch"  > "$LIMIT_LAST_RECORD"
        echo "$detected_at" > "$LIMIT_DETECTED_AT"
    fi
    log "LIMIT armed: until=$until (~$hhmm), reset=$reset_epoch, detected=$detected_at"
    notify token-limit "Упёрся в лимит токенов. Вернусь примерно в ~$hhmm — сообщения приму, отвечу как отпустит."
    LIMIT_ACTIVE=1
}

# Стирание лимитного состояния (после запуска оживления). limit_last_record НЕ трогаем —
# иначе на следующем проходе заново «обнаружим» ту же старую запись и зациклимся.
# W1-ФИКС Б5 (14.08): LIMIT_RESUME_COUNT здесь НЕ чистим — иначе кап попыток мёртв (каждый
# проход обнулял бы счётчик). Он сбрасывается только по ПОДТВЕРЖДЁННОМУ успеху (last_stop
# сдвинулся, канал ответил) — в блоке стабилизации в конце главного цикла.
clear_limit_state() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: clear limit state (limit_until/limit_detected_at; resume_count СОХРАНЁН)"
        return
    fi
    rm -f "$LIMIT_UNTIL" "$LIMIT_DETECTED_AT"
}

# Детектор. Ставит LIMIT_ACTIVE (0/1) и, если найдена свежая подлинная запись лимита,
# армирует окно. Классификация: rate_limit/429 → ждать; 401/login → notify, НЕ ждать;
# 529/overloaded → только лог. Источник истины по активности окна — файл limit_until.
detect_limit() {
    LIMIT_ACTIVE=0
    local now; now=$(date +%s)
    if [ "$LIMIT_MAX_WAIT" -ne 0 ]; then
        local T; T=$(find_channel_transcript)
        if [ -n "$T" ] && [ -f "$T" ]; then
            local stem; stem=$(basename "$T" .jsonl)
            local rec; rec=$(tail -n 200 "$T" 2>/dev/null | grep -F '"isApiErrorMessage":true' | tail -1)
            # Подлинность: запись именно НАШЕЙ сессии (sessionId == stem файла).
            case "$rec" in *"\"sessionId\":\"$stem\""*) : ;; *) rec="" ;; esac
            if [ -n "$rec" ]; then
                local rec_iso rec_epoch last_rec
                rec_iso=$(printf '%s' "$rec" | grep -oE '"timestamp":"[^"]+"' | head -1 | sed -E 's/^"timestamp":"//; s/"$//')
                rec_epoch=$(date -d "$rec_iso" +%s 2>/dev/null || echo 0)
                last_rec=$(cat "$LIMIT_LAST_RECORD" 2>/dev/null | tr -cd 0-9); : "${last_rec:=0}"
                local rec_age=$(( now - ${rec_epoch:-0} ))
                # Свежесть двусторонняя: (1) новее уже учтённой И (2) не старше LIMIT_STALE_MAX
                # (фикс Б2 — иначе вчерашняя запись с «time-of-day» reset ложно армит лимит).
                if [ "${rec_epoch:-0}" -gt "$last_rec" ] && [ "$rec_age" -ge 0 ] && [ "$rec_age" -lt "$LIMIT_STALE_MAX" ]; then
                    case "$rec" in
                        *rate_limit*|*'"status":429'*)
                            local reset_text reset_epoch
                            reset_text=$(printf '%s' "$rec" | grep -oiE 'reset[^"\\]*' | head -1)
                            reset_epoch=$(parse_reset_epoch "$reset_text" "$rec_epoch" 2>/dev/null || echo "")
                            if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now" ]; then
                                arm_limit_window "$reset_epoch" "$now" "$rec_epoch"
                            else
                                log "LIMIT: rate_limit-запись, но reset в прошлом/непарсим ('$reset_text') — игнор"
                            fi
                            ;;
                        *'Please run /login'*|*'"status":401'*|*OAuth*|*authentication_error*)
                            log "LIMIT: потерян доступ (401/login) — не жду, зову владельца"
                            notify model-access "Потерян доступ к Claude (нужен вход в аккаунт). Канал в телеге живой, но отвечать не смогу, пока не залогинишься. Перезапуск не поможет."
                            ;;
                        *'"status":529'*|*overloaded*)
                            log "LIMIT: 529/overloaded — временная перегрузка, только фиксирую"
                            ;;
                    esac
                fi
            fi
        fi
    fi
    # Активность окна — по файлу (переживает и SKIP_PROCESS_CHECKS, и ребут).
    local lu; lu=$(cat "$LIMIT_UNTIL" 2>/dev/null | tr -cd 0-9); : "${lu:=0}"
    [ "$lu" -gt "$now" ] && LIMIT_ACTIVE=1
    return 0
}

# W1-ФИКС Б8 (14.08): спокоен ли экран сессии для слепого send-keys? nudge шлётся literal'ом
# в pane; если сессия сейчас в TUI-меню/диалоге (trust, выбор опции, интерактивный вопрос),
# наш текст+Enter выберут случайный пункт. Шлём ТОЛЬКО когда виден спокойный prompt ввода и
# нет маркеров диалога. Неуверенность трактуем как «занят» (fail-safe: лучше отложить nudge).
# CHANNEL_PANE — env-override экрана для юнит-теста (без живого tmux).
screen_calm() {
    local pane
    if [ -n "${CHANNEL_PANE+x}" ]; then pane="$CHANNEL_PANE"
    else pane=$(TMUX= tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null); fi
    case "$pane" in
        *trust*|*"Do you want"*|*"❯"*|*"Select"*|*"(y/n)"*|*"esc to interrupt"*|*"Press Enter"*|*"1."*)
            return 1 ;;   # известный интерактивный экран — НЕ слать
    esac
    case "$pane" in
        *"for shortcuts"*|*"│ >"*) return 0 ;;   # спокойный prompt ввода
    esac
    return 1   # неуверенно → считаем занятым
}

# Оживление после сброса лимита (now >= limit_until). Процессы живы → nudge в сессию
# (literal -l + отдельный Enter, как trust-hack в start:92), но ТОЛЬКО на спокойном экране
# (фикс Б8); иначе restart_session. pending = last_prompt > last_stop. Состояние (limit_until)
# чистим ТОЛЬКО после РЕАЛЬНОГО действия; не более LIMIT_RESUME_MAX попыток. Всё уважает DRY_RUN.
resume_after_limit() {
    local rc; rc=$(cat "$LIMIT_RESUME_COUNT" 2>/dev/null | tr -cd 0-9); : "${rc:=0}"
    if [ "$rc" -ge "$LIMIT_RESUME_MAX" ]; then
        log "LIMIT resume: $rc попыток исчерпано — зову владельца"
        notify restart-failed "Лимит должен был сброситься, но канал не ожил за $rc попыток. Нужна твоя рука."
        return 1
    fi
    local lp ls; lp=$(cat "$STATE_DIR/last_prompt" 2>/dev/null | tr -cd 0-9); ls=$(cat "$STATE_DIR/last_stop" 2>/dev/null | tr -cd 0-9)
    : "${lp:=0}"; : "${ls:=0}"
    local pending=0; [ "$lp" -gt "$ls" ] && pending=1
    local alive=0
    if TMUX= tmux has-session -t "$SESSION_NAME" 2>/dev/null && [ -n "${CLAUDE_PID:-}" ]; then alive=1; fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: bump limit_resume_count → $((rc+1))"
    else
        echo $((rc+1)) > "$LIMIT_RESUME_COUNT"
    fi
    # acted=1 → было реальное действие, окно можно снимать. acted=0 → отложили (экран занят),
    # limit_until НЕ чистим, повторим на следующем проходе (до капа LIMIT_RESUME_MAX).
    local acted=0
    if [ "$alive" = "1" ]; then
        if [ "$pending" = "1" ]; then
            if screen_calm; then
                if [ "$DRY_RUN" = "1" ]; then
                    echo "DRY: send-keys nudge (лимит сброшен, ответь на повисшее сообщение)"
                else
                    TMUX= tmux send-keys -t "$SESSION_NAME" -l "лимит сброшен, ответь на повисшее сообщение"
                    TMUX= tmux send-keys -t "$SESSION_NAME" Enter
                fi
                log "LIMIT reset: nudged pending message (попытка $((rc+1)))"
                acted=1
            else
                log "LIMIT reset: экран сессии занят (меню/диалог) — nudge отложен, повтор на след. проходе"
            fi
        else
            log "LIMIT reset: процессы живы, повисших сообщений нет — просто снимаю окно"
            acted=1
        fi
    else
        # --continue безопасен ПОСЛЕ сброса (лимит уже отпустил).
        restart_session "limit-reset"
        acted=1
    fi
    if [ "$acted" = "1" ]; then
        clear_limit_state
        notify_recover token-limit "Отбой: лимит сброшен, снова на связи."
    fi
    return 0
}

# ═══ W1 2026-08-14: ПОДСИСТЕМА B — REAP + ЭСКАЛАЦИЯ ═══════════════════════════
# Причина: после рестарта иногда выживает bun-сервер прошлой сессии, ворует getUpdates
# (409 Conflict) — канал немой при живых процессах. И: бесконечные одинаковые рестарты
# не лечат «неубиваемую» поломку. Лечим лестницей continue→fresh→backoff под гейтом лимита.

# Гейт ремедиации: false, если активно лимитное окно ИЛИ бэкофф. Возвращает управление
# ДО любого record_restart → флаппинг в лимитном/бэкофф-окне НЕ накапливается.
# ПРИМЕНЯЕТСЯ к silent-failure и reap (следствия лимита Claude API). НЕ к plugin-frozen —
# см. фикс Б4 и backoff_allowed ниже.
remediation_allowed() {
    local now; now=$(date +%s)
    local lu bu
    lu=$(cat "$LIMIT_UNTIL" 2>/dev/null | tr -cd 0-9); : "${lu:=0}"
    bu=$(cat "$BACKOFF_UNTIL" 2>/dev/null | tr -cd 0-9); : "${bu:=0}"
    [ "$lu" -gt "$now" ] && return 1
    [ "$bu" -gt "$now" ] && return 1
    return 0
}

# W1-ФИКС Б4 (14.08): гейт ТОЛЬКО по бэкоффу (лимит игнорируется). Для plugin-frozen:
# потеря TCP к Telegram — структурный отказ бот-канала, приём сообщений мёртв. Это НЕ
# лимит Claude API (разные каналы), лечить его надо и под лимитом — иначе уведомление
# «сообщения приму» становится ложью. Бэкофф (give-up после fresh) уважаем всегда.
backoff_allowed() {
    local now; now=$(date +%s)
    local bu; bu=$(cat "$BACKOFF_UNTIL" 2>/dev/null | tr -cd 0-9); : "${bu:=0}"
    [ "$bu" -gt "$now" ] && return 1
    return 0
}

# Число строк-эпох в файле, попавших в окно (сек). Пустой/нет файла → 0.
count_recent() {
    local file="$1" window="$2" now; now=$(date +%s)
    [ -f "$file" ] || { echo 0; return; }
    local cutoff=$(( now - window ))
    awk -v c="$cutoff" '$1 >= c' "$file" 2>/dev/null | wc -l | tr -d ' '
}

# Запись факта чистого старта (fresh) + подрезка окна FRESH_WINDOW. Уважает DRY_RUN.
record_fresh() {
    local now; now=$(date +%s)
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: record_fresh @$now"
        return
    fi
    echo "$now" >> "$FRESH_HISTORY"
    local cutoff=$(( now - FRESH_WINDOW ))
    awk -v c="$cutoff" '$1 >= c' "$FRESH_HISTORY" > "$FRESH_HISTORY.tmp" 2>/dev/null \
        && mv "$FRESH_HISTORY.tmp" "$FRESH_HISTORY"
}

# Отстрел осиротевших plugin-серверов. Детектор И лекарство — один код (reap-скрипт):
# сухой прогон = детектор, --force = лекарство, рассинхрон невозможен. 3 предохранителя:
#  (1) cross-check: кандидат ∩ НАШЕ дерево (TREE_PIDS) → ABORT+notify;
#  (2) refuse-if-blind: TREE_PIDS пуст → не знаем своё → отмена;
#  (3) grace ORPHAN_GRACE + cooldown REAP_COOLDOWN.
# Тихо выходит, когда сирот нет (иначе засорял бы лог каждые 3 мин). Уважает DRY_RUN.
# W1-ФИКС Б6 (14.08): в DRY боевой лог не трогаем. reap-детектор прокидываем CHANNEL_LOG/LOG
# (CHANNEL_LOG-aware reap это уважит и напишет в наш лог). Дефолтный БОЕВОЙ reap-скрипт
# захардкодил свой путь лога и в DRY загрязнял бы боевой файл (доказано adversarial-ревью) —
# его в DRY не запускаем вовсе, только помечаем. Для теста reap подставляй REAP_SCRIPT-стаб.
reap_orphans() {
    if [ "$DRY_RUN" = "1" ] && [ "$REAP_SCRIPT" = "/home/ubuntu/core/reap-telegram-orphans.sh" ]; then
        echo "DRY: reap detection skipped (дефолтный reap пишет в боевой лог; в DRY не трогаю — для теста задай REAP_SCRIPT-стаб)"
        return 0
    fi
    local dry; dry=$(CHANNEL_LOG="$LOG" LOG="$LOG" bash "$REAP_SCRIPT" 2>/dev/null)
    local orphan_pids
    orphan_pids=$(printf '%s\n' "$dry" | grep -oE 'сирота pid=[0-9]+' | grep -oE '[0-9]+' | sort -u)
    if [ -z "$orphan_pids" ]; then
        rm -f "$ORPHAN_MARKER" 2>/dev/null   # сирот нет — сбрасываем grace-метку
        return 0
    fi
    # (2) refuse-if-blind
    if [ -z "${TREE_PIDS:-}" ]; then
        log "REAP: TREE_PIDS пуст — слепы, отмена (не отстреливаем вслепую)"
        notify reap-blind "Вижу осиротевшие процессы канала, но не вижу собственного дерева процессов — не рискую отстреливать вслепую. Загляни."
        return 1
    fi
    # (1) cross-check с нашим деревом
    local ours="|${TREE_PIDS}|" op
    for op in $orphan_pids; do
        case "$ours" in
            *"|$op|"*)
                log "REAP: кандидат $op принадлежит НАШЕМУ дереву — ABORT"
                notify reap-conflict "Отстрел сирот отменён: кандидат $op — процесс живой сессии. Не трогаю, зову тебя."
                return 1 ;;
        esac
    done
    # (3) grace + cooldown
    if [ ! -f "$ORPHAN_MARKER" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "DRY: touch orphan marker (grace start, сироты: $orphan_pids)"
        else
            date +%s > "$ORPHAN_MARKER"
        fi
        log "REAP: засёк сирот [$orphan_pids] — жду grace ${ORPHAN_GRACE}s"
        return 0
    fi
    local grace_age; grace_age=$(file_age "$ORPHAN_MARKER")
    if [ "$grace_age" -lt "$ORPHAN_GRACE" ]; then
        log "REAP: сироты держатся ${grace_age}s < grace ${ORPHAN_GRACE}s — жду"
        return 0
    fi
    local reap_age; reap_age=$(file_age "$REAP_MARKER")
    if [ "$reap_age" -lt "$REAP_COOLDOWN" ]; then
        log "REAP: cooldown (${reap_age}s < ${REAP_COOLDOWN}s) — не отстреливаю"
        return 0
    fi
    # Предохранители пройдены → отстрел.
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: reap --force (сироты: $orphan_pids)"
    else
        CHANNEL_LOG="$LOG" LOG="$LOG" bash "$REAP_SCRIPT" --force >/dev/null 2>&1
        date +%s > "$REAP_MARKER"
        rm -f "$ORPHAN_MARKER" 2>/dev/null
    fi
    log "REAP: отстрелял сирот [$orphan_pids] (grace ${grace_age}s пройден)"
    notify reap "Убрал осиротевший процесс канала — он держал очередь Telegram (409). Канал должен ожить сам."
    return 0
}

# Чистый старт как ступень 1 лестницы (restart-channel-fresh). Фоновый, отсоединённый
# (setsid), с 9>&- — закрыть flock-fd, иначе tmux наследует блокировку (fd-leak, баг 28.07).
# W1-ФИКС Б3 (14.08): та же rate-cap по RESTART_MARKER, что и в restart_session — ДО любого
# действия и ДО record_fresh. Иначе после фикса Б1 лестница дала бы два fresh-убийства
# свежей сессии за 6 мин (fresh не читал кулдаун — только touch'ил маркер). Уважает DRY_RUN.
restart_fresh() {
    local reason="$1"
    if [ -f "$RESTART_MARKER" ]; then
        local age; age=$(file_age "$RESTART_MARKER")
        if [ "$age" -lt "$RESTART_COOLDOWN" ]; then
            log "FRESH suppressed (rate-cap, last ${age}s ago < ${RESTART_COOLDOWN}s, reason: $reason)"
            return 1
        fi
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: restart-channel-fresh ($reason)"
        record_fresh
        return 0
    fi
    log "FRESH restart (reason: $reason) — обычный рестарт не помог, чистый старт"
    record_fresh
    touch "$RESTART_MARKER"
    rm -f "$STALE_MARKER" "$FROZEN_MARKER"
    setsid bash "$FRESH_SCRIPT" >> "$LOG" 2>&1 9>&- &
    notify fresh-restart "Обычный перезапуск не помог — стартую канал начисто (контекст обнулится). Если и это не поможет, отпишу."
    return 0
}

# Ступень 2: экспоненциальный бэкофф (900→1800→3600 cap) + notify give-up, рестарты стоп.
escalate_backoff() {
    local reason="$1" fresh="$2"
    local now; now=$(date +%s)
    local prev; prev=$(cat "$BACKOFF_STEP" 2>/dev/null | tr -cd 0-9); : "${prev:=0}"
    local dur
    case "$prev" in
        0) dur=900 ;;
        1) dur=1800 ;;
        *) dur=3600 ;;
    esac
    local until=$(( now + dur ))
    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY: backoff until=$until (dur=${dur}s, step=$prev→$((prev+1))), give-up notify"
    else
        echo "$until"       > "$BACKOFF_UNTIL"
        echo $(( prev + 1 )) > "$BACKOFF_STEP"
    fi
    log "GIVE-UP ($reason): $fresh чистых стартов за окно не помогли — backoff ${dur}s, рестарты стоп"
    notify give-up "Канал не чинится ни обычным перезапуском, ни чистым стартом ($fresh раз). Останавливаю попытки на $((dur/60)) мин — нужна твоя рука."
    return 0
}

# Лестница ремедиации. Заворачивает ТОЛЬКО plugin-frozen и silent-failure (структурная
# реанимация session-missing/claude-dead идёт мимо). Ступени: 0 обычный --continue до
# FLAP_LIMIT флапов; 1 — один чистый старт (fresh); 2 — backoff. Гейт лимита/бэкоффа —
# первым делом, ДО учёта рестартов.
decide_restart() {
    local reason="$1"
    # Б4: выбор гейта по причине. plugin-frozen (структурный отказ бот-канала) — только
    # бэкофф, МИМО лимита. Остальное (silent-failure) — полный гейт лимит+бэкофф.
    case "$reason" in
        plugin-frozen)
            if ! backoff_allowed; then
                log "REMEDIATION suppressed ($reason): активен бэкофф — не чиню"
                return 0
            fi
            ;;
        *)
            if ! remediation_allowed; then
                log "REMEDIATION suppressed ($reason): активен лимит/бэкофф — не чиню"
                return 0
            fi
            ;;
    esac
    # W1-ФИКС Б1(а) (14.08): считаем С УЧЁТОМ текущего рестарта (flaps+1/fresh+1). Иначе
    # порог 3 достигался только на 4-м рестарте, а из-за выпадения старейшего из окна — вообще
    # никогда. Теперь ТЕКУЩИЙ рестарт, который делает счётчик == лимиту, и есть ступень эскалации.
    local flaps fresh
    flaps=$(count_recent "$RESTART_HISTORY" "$FLAP_WINDOW")
    fresh=$(count_recent "$FRESH_HISTORY" "$FRESH_WINDOW")
    if [ $(( flaps + 1 )) -lt "$FLAP_LIMIT" ]; then
        restart_session "$reason"          # ступень 0: обычный --continue
        return $?
    fi
    if [ $(( fresh + 1 )) -lt "$FRESH_LIMIT" ]; then
        restart_fresh "$reason"            # ступень 1: один чистый старт
        return $?
    fi
    escalate_backoff "$reason" "$fresh"    # ступень 2: backoff + give-up
    return 0
}

# ── Log rotation: keep log under MAX_LOG_BYTES ──
if [ -f "$LOG" ]; then
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
        mv "$LOG" "${LOG}.1"
        log "Log rotated (was ${size} bytes)"
    fi
fi

# TMUX= needed to avoid socket conflicts when called from within a tmux session

# W1 2026-08-14: инициализация ДО SKIP-блока — Check 6/7 (ниже, вне блока) читают
# LIMIT_ACTIVE даже когда структурные проверки пропущены. Реальное значение выставит
# detect_limit (в блоке) либо file-refresh перед Check 6.
LIMIT_ACTIVE=0

# SKIP_PROCESS_CHECKS=1 — только для тестов детектора (Check 6). Без него тест зависит от
# состояния ЖИВОЙ системы: если плагин в этот момент мёртв, скрипт честно выходит на
# Check 4 и до детектора не доходит — тест «падает», хотя код верен. Поймано 01.08 ровно так.
if [ "${SKIP_PROCESS_CHECKS:-0}" != "1" ]; then

# ── Check 1: tmux session exists? ──
if ! TMUX= tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "Session '$SESSION_NAME' not found — starting"
    restart_session "session-missing"
    exit 0
fi

# ── Check 2 УДАЛЕНА (2026-08-01) ─────────────────────────────────────────────
# Была: capture-pane | grep "I trust this folder|trust?" → send-keys Enter.
# Почему удалена, а не починена:
#   1. Ложно срабатывала на ТЕКСТЕ ПЕРЕПИСКИ — сессия идёт с --continue, диалог на экране.
#      Проверено 01.08: grep -c на здоровой сессии = 1, совпало с обсуждением этой же
#      ошибки. В логе есть срабатывание 28.07 18:33 — через 3 минуты после того, как
#      старт-скрипт уже принял промпт штатно в 18:30.
#   2. Actuator вслепую: слала Enter в живую сессию, то есть случайный ввод в чужой промпт.
#   3. Худшее: после матча шёл `exit 0` — проверки 3/4/5 не выполнялись ВООБЩЕ. Пока слово
#      «trust» на экране, смерть плагина не детектировалась.
# Промпт закрыт без неё: start-claude-telegram.sh:74-87 жмёт его при старте (дважды,
# с проверкой), плюс "skipDangerousModePermissionPrompt": true в settings.json. А если
# сессия всё же зависнет на промпте — плагин не поднимется, и это поймает Check 4.

# ── Check 3: claude process alive in our session? ──
# Use tmux #{pane_pid} (shell PID) and walk descendants — avoids pts ambiguity
SHELL_PID=$(TMUX= tmux list-panes -t "$SESSION_NAME" -F '#{pane_pid}' 2>/dev/null | head -1)
CLAUDE_PID=""
if [ -n "$SHELL_PID" ]; then
    # Find claude process that is a descendant of the pane's shell
    CLAUDE_PID=$(pgrep -P "$SHELL_PID" -x claude 2>/dev/null | head -1)
    # Fallback: search any descendant named 'claude'
    if [ -z "$CLAUDE_PID" ]; then
        CLAUDE_PID=$(pstree -p "$SHELL_PID" 2>/dev/null | grep -oP 'claude\(\K[0-9]+' | head -1)
    fi
fi

if [ -z "$CLAUDE_PID" ]; then
    log "Claude process not found in '$SESSION_NAME' — restarting"
    restart_session "claude-dead"
    exit 0
fi

# ── W1 2026-08-14: детектор лимита токенов (СРАЗУ после Check 3) ───────────────
# Ставится РАНЬШЕ reap и Check 6/7: армирование limit_until обязано случиться до его
# читателей в ТОМ ЖЕ проходе, иначе они увидят метку с задержкой в один 3-мин цикл.
# Мёртвый процесс (Check 1/3) лечится выше и МИМО лимитного гейта — реанимация независима.
detect_limit
_now_l=$(date +%s)
_lu=$(cat "$LIMIT_UNTIL" 2>/dev/null | tr -cd 0-9); : "${_lu:=0}"
if [ "$_lu" -gt 0 ] && [ "$_now_l" -ge "$_lu" ]; then
    log "LIMIT: окно истекло (until=$_lu) — оживляю канал"
    resume_after_limit
    exit 0
fi

# ── Check 4: telegram PLUGIN worker alive? (grace period 5 min) ──
# 2026-08-01: раньше был `pgrep -f 'claude-plugins-official/telegram'` — он матчит ЛЮБОЙ
# процесс, у которого путь попал в argv. Проверено: даёт 2 совпадения, второе — посторонняя
# bash-команда, упомянувшая путь. Класс отказа: плагин мёртв, случайная команда держит матч
# → «жив» → смерть не детектируется.
# Теперь: bot.pid (точный worker, `bun server.ts`) → сверка cmdline → принадлежность дереву
# НАШЕЙ сессии. Последнее закрывает вторую дыру: pgrep был глобальным, и плагин ЧУЖОГО
# инстанса Claude маскировал смерть нашего.
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
# Fallback на прежний способ, если bot.pid отсутствует (старая версия плагина),
# но с отсевом собственных команд watchdog'а по имени процесса.
if [ -z "$BUN_PID" ]; then
    for p in $(pgrep -f 'claude-plugins-official/telegram' 2>/dev/null); do
        pname=$(cat "/proc/$p/comm" 2>/dev/null)
        case "$pname" in
            bun|node) BUN_PID="$p"; break ;;
        esac
    done
fi

if [ -z "$BUN_PID" ]; then
    if [ -f "$STALE_MARKER" ]; then
        MARKER_AGE=$(file_age "$STALE_MARKER")
        if [ "$MARKER_AGE" -gt 300 ]; then
            log "Telegram plugin runtime missing for ${MARKER_AGE}s — restarting"
            rm -f "$STALE_MARKER"
            restart_session "plugin-dead"
        else
            log "Telegram plugin runtime not found (${MARKER_AGE}s) — waiting"
        fi
    else
        touch "$STALE_MARKER"
        log "Telegram plugin runtime not found — marking, will restart if persists >5min"
    fi
    exit 0   # plugin process gone — frozen-probe below is moot, skip it
else
    rm -f "$STALE_MARKER"
fi

# ── Check 5: plugin process alive but FROZEN? (functional probe) ──
# AUDIT 2026-06-21 follow-up: Check 4 only proves the wrapper PROCESS exists. The real
# Telegram I/O is done by a child worker (bun server.ts) holding a long-poll TLS
# connection to api.telegram.org:443. A wrapper that's alive while the worker has lost
# its connection (and isn't reconnecting) = "alive-but-frozen": messages silently stop.
# Healthy poller ALWAYS holds ≥1 ESTABLISHED :443 conn (connection-pooled long-poll);
# the plugin talks to nothing but Telegram, so any ESTABLISHED :443 from its process
# tree proves liveness. Grace period (>5min across 3-min cron runs) avoids a false
# positive on the sub-second reconnect gap between long-polls.
collect_descendants() {
    local p=$1; echo "$p"
    local c
    for c in $(pgrep -P "$p" 2>/dev/null); do collect_descendants "$c"; done
}
TREE_PIDS=$(collect_descendants "$BUN_PID" 2>/dev/null | sort -u | paste -sd'|')
TG_CONNS=0
if [ -n "$TREE_PIDS" ]; then
    TG_CONNS=$(ss -tnpH state established '( dport = :443 )' 2>/dev/null \
               | grep -cE "pid=(${TREE_PIDS})," )
fi

if [ "$TG_CONNS" -eq 0 ]; then
    if [ -f "$FROZEN_MARKER" ]; then
        FROZEN_AGE=$(file_age "$FROZEN_MARKER")
        if [ "$FROZEN_AGE" -gt "$FROZEN_GRACE" ]; then
            log "Plugin alive (pid $BUN_PID) but NO Telegram connection for ${FROZEN_AGE}s — frozen, restarting"
            decide_restart "plugin-frozen"   # W1: через лестницу continue→fresh→backoff + гейт лимита
        else
            log "Plugin has no Telegram connection (${FROZEN_AGE}s) — waiting (grace ${FROZEN_GRACE}s)"
        fi
    else
        touch "$FROZEN_MARKER"
        log "Plugin alive but no Telegram connection — marking, will restart if persists >$((FROZEN_GRACE/60))min"
    fi
    exit 0
else
    rm -f "$FROZEN_MARKER"
fi

# ── Check 5b (W1 2026-08-14): осиротевший plugin-сервер (409 Conflict) ─────────
# Даже при живом соединении нашей сессии выживший bun прошлой сессии может воровать
# getUpdates → канал немой. Детектор = сухой прогон reap; лечение = reap --force (см.
# reap_orphans, 3 предохранителя). Гейтится: под лимитом/бэкоффом не трогаем.
if remediation_allowed; then
    reap_orphans
fi

fi   # ← конец блока SKIP_PROCESS_CHECKS

# ── Check 6: тихий отказ — сообщение приняли и не ответили ────────────────────
# Всё выше доказывает, что ПРОЦЕССЫ живы. 30.07 они были живы, TCP был, очередь пуста —
# и сообщение владельца пролежало 1.5 суток (кончилась подписка: поллер забирал, ответить
# сессия не могла). Отличить такое от здорового простоя снаружи нельзя, поэтому сигнал
# даёт сама сессия через хуки: prompt (принято), stop (отвечено), activity (жива и работает).
#
#   принято <= отвечено                        → тишина, владелец просто не пишет
#   принято >  отвечено, activity свежая       → идёт длинная задача, молчим
#   принято >  отвечено, activity протухла     → приняли и не отвечаем = тихий отказ
# W1 2026-08-14: подхватываем лимит из файла даже когда структурные проверки пропущены
# (SKIP_PROCESS_CHECKS=1, detect_limit не отработал). limit_until — источник истины.
if [ "${LIMIT_ACTIVE:-0}" != "1" ]; then
    _lu6=$(cat "$LIMIT_UNTIL" 2>/dev/null | tr -cd 0-9); : "${_lu6:=0}"
    [ "$_lu6" -gt "$(date +%s)" ] && LIMIT_ACTIVE=1
fi

LAST_PROMPT=$(cat "$STATE_DIR/last_prompt" 2>/dev/null | tr -cd '0-9')
LAST_STOP=$(cat "$STATE_DIR/last_stop" 2>/dev/null | tr -cd '0-9')
LAST_ACT=$(cat "$STATE_DIR/last_activity" 2>/dev/null | tr -cd '0-9')
NOW=$(date +%s)

# Пока хуки ни разу не отработали (свежая установка) — детектор молчит, а не паникует.
if [ -n "$LAST_PROMPT" ]; then
    : "${LAST_STOP:=0}"
    : "${LAST_ACT:=0}"
    UNANSWERED=$(( NOW - LAST_PROMPT ))
    IDLE=$(( NOW - LAST_ACT ))

    # W2 2026-08-14 (находка 6): «занята ли сессия» по mtime транскрипта. activity пишется
    # ТОЛЬКО PostToolUse (после инструмента) — один длинный tool-call 20+ мин протухает IDLE
    # и рубит РАБОЧУЮ сессию посреди задачи. Транскрипт же обновляется в реальном времени
    # (стрим ответа/tool_use/результаты, mtime≈1с при активной работе). Надёжнее детекта детей:
    # не зависит от MCP-демонов (у claude в простое куча постоянных детей — все MCP-серверы).
    # find_channel_transcript переиспользуем из Волны 1 (env CHANNEL_TRANSCRIPT override для тестов).
    writing=0
    _T=$(find_channel_transcript 2>/dev/null)
    if [ -n "$_T" ] && [ -f "$_T" ]; then
        _age=$(( NOW - $(stat -c %Y "$_T" 2>/dev/null || echo 0) ))
        [ "$_age" -lt "$ACTIVITY_GRACE" ] && writing=1
    fi

    # W1: при активном лимите тихий отказ ПОДАВЛЕН — это не поломка, а ожидаемое молчание,
    # рестартом не лечится. Окно снимет resume_after_limit по сбросу.
    if [ "${LIMIT_ACTIVE:-0}" != "1" ] && [ "$LAST_PROMPT" -gt "$LAST_STOP" ] && [ "$UNANSWERED" -gt "$SILENT_GRACE" ] && [ "$IDLE" -gt "$ACTIVITY_GRACE" ]; then
        # Кап отсрочки (находка 3 ревью): writing защищает работу, но входящие тоже двигают
        # mtime. Считаем НЕПРЕРЫВНУЮ длительность отсрочки; дольше DEFER_MAX — рубим всё равно.
        capped=0
        if [ "$writing" = 1 ]; then
            if [ ! -f "$DEFER_SINCE" ]; then
                if [ "${DRY_RUN:-0}" = 1 ]; then echo "DRY: touch defer_since"; else date +%s > "$DEFER_SINCE"; fi
            fi
            _ds=$(cat "$DEFER_SINCE" 2>/dev/null | tr -cd '0-9'); _ds=${_ds:-$NOW}
            [ $(( NOW - _ds )) -ge "$DEFER_MAX" ] && capped=1
        fi
        if [ "$writing" = 1 ] && [ "$capped" != 1 ]; then
            # W2: счётчики кричат «тихий отказ», НО транскрипт свеж — сессия пишет ход
            # (длинный tool-call/стрим ответа), это работа, а не висяк. Откладываем, БЕЗ notify.
            log "SILENT FAILURE отложен: сессия пишет ход (транскрипт свеж ${_age}s), рубку откладываю"
            exit 0   # ФИКС находка 4: симметрично kill-ветке — НЕ проваливаться в recover,
                     # иначе строка "Отбой: канал поднялся" уходит владельцу при живом отказе.
        else
            [ "$capped" = 1 ] && log "SILENT FAILURE: отсрочка исчерпана (пишет ход, но $((NOW-_ds))s>=${DEFER_MAX}s) — рублю"
            rm -f "$DEFER_SINCE"
            if [ ! -f "$SILENT_MARKER" ]; then touch "$SILENT_MARKER"; fi
            log "SILENT FAILURE: принято ${UNANSWERED}s назад, ответа нет, активности ${IDLE}s"
            notify silent-failure "Я принял твоё сообщение $((UNANSWERED/60)) мин назад и не ответил — и это не долгая задача, признаков работы нет $((IDLE/60)) мин. Похоже, канал жив, а я отвечать не могу. Пробую перезапуститься; если не поможет — напишу ещё раз."
            # Рестарт всё же пробуем: часть причин (зависание, manual mode) им лечится.
            # W1: теперь через лестницу continue→fresh→backoff (decide_restart), а не в лоб.
            # Если причина не лечится — лестница дойдёт до give-up и скажет об этом прямо.
            decide_restart "silent-failure"
            exit 0
        fi
    fi

    # Ответили — снимаем тревогу и сбрасываем отсрочку writing-гейта (W2 находка 3).
    if [ "$LAST_STOP" -ge "$LAST_PROMPT" ]; then
        rm -f "$DEFER_SINCE"
        if [ -f "$SILENT_MARKER" ]; then
            rm -f "$SILENT_MARKER"
            notify_recover silent-failure "Отбой: канал снова отвечает."
        fi
    fi
fi

# ── Check 7 (W2): доступ к модели ────────────────────────────────────────────
# Единственная проверка, видящая отказ B (кончилась подписка / отозван доступ) НАПРЯМУЮ.
# `claude auth status` для этого негоден: проверено 01.08 — с наглухо закрытым egress он
# за 0.9 с отдаёт закэшированное "subscriptionType":"max" из ~/.claude/.credentials.json,
# то есть во время отказа рапортовал бы «здоров».
#
# Наблюдаемое поведение (проверено, а не угадано):
#   доступ есть   → rc=0, ~15 с
#   разлогин      → rc=1, stdout "Not logged in · Please run /login"
# Формат при протухшей подписке НЕ наблюдался, поэтому классификация трёхзначная:
# известный негатив → точная причина; нераспознанный сбой → ОДНО уведомление (не молчим,
# иначе пропустим ровно тот отказ, ради которого всё затевалось, и не спамим — антиспам
# в notify-owner.sh держит паузу в час).
#
# Цена: раз в час, самая дешёвая модель. Сеть моргает часто, поэтому неудача подтверждается
# немедленным повтором — одиночный сбой сети не будит владельца (fail-open).
PING_INTERVAL="${PING_INTERVAL:-3600}"
PING_MARKER="$STATE_DIR/last_ping"

if [ "$DRY_RUN" != "1" ] && [ "${LIMIT_ACTIVE:-0}" != "1" ] && [ "$(file_age "$PING_MARKER")" -gt "$PING_INTERVAL" ]; then
    date +%s > "$PING_MARKER"
    # ПИНГ ОБЯЗАН БЫТЬ ИЗОЛИРОВАН. До 05.08 он запускался как
    #   cd /home/ubuntu && claude -p --model … 'ok'
    # — то есть в том же каталоге, что и сессия канала, и с полной обвязкой. Второй
    # экземпляр Claude Code в том же проекте убивал первый: канал умирал РОВНО в минуту
    # пинга (03:00, 04:03, 05:06, 06:09, 07:12 — интервал 63 мин десять раз подряд), а
    # через 3 минуты этот же сторож находил труп и «чинил» его. Доказательство: в файле
    # умершей сессии лежит lastPrompt "ok" — сам пинг.
    #   --no-session-persistence — не писать сессию в проект, откуда канал берёт --continue;
    #   --strict-mcp-config      — не поднимать общие MCP-серверы второй раз (chroma держит
    #                              блокировку на data-dir, docker-контейнер — фиксированное имя);
    #   --setting-sources=       — не запускать хуки (в т.ч. heartbeat канала);
    #   cwd=$PING_DIR            — отдельный каталог, чужой проект.
    # Проверка доступа к модели не должна стоить дороже самого отказа, который она ищет.
    PING_DIR="$STATE_DIR/ping"
    mkdir -p "$PING_DIR" 2>/dev/null
    run_ping() {
        # W1-ФИКС Б7 (14.08): 9>&- — закрыть унаследованный flock-fd, иначе долгий дочерний
        # claude держит блокировку watchdog'а (fd-leak класс, баг 28.07). timeout может оставить
        # процесс, и он унёс бы флаг. Закрываем fd 9 у ребёнка, как в restart_session:125.
        cd "$PING_DIR" && timeout 90 claude -p \
            --model claude-haiku-4-5-20251001 \
            --no-session-persistence \
            --strict-mcp-config \
            --setting-sources= \
            'ok' 2>&1 9>&-
    }

    OUT=$(run_ping); RC=$?
    if [ "$RC" -ne 0 ]; then
        sleep 5
        OUT=$(run_ping); RC=$?     # подтверждаем: одиночный сбой сети не считается отказом
    fi

    if [ "$RC" -eq 0 ]; then
        notify_recover model-access "Отбой: доступ к модели восстановлен."
        notify_recover model-unknown "Отбой: доступ к модели восстановлен."
    elif echo "$OUT" | grep -qiE "not logged in|please run /login|invalid api key|authentication"; then
        log "MODEL ACCESS: не авторизован (rc=$RC)"
        notify model-access "Потерян доступ к Claude: «не авторизован». Перезапуск тут не поможет — нужен вход в аккаунт. Канал в телеге живой, я просто не смогу отвечать."
    elif echo "$OUT" | grep -qiE "credit balance|quota|usage limit|rate limit|too many requests|subscription"; then
        # W1 2026-08-14: пинг подтвердил лимит НЕЗАВИСИМО от jsonl — армируем окно, чтобы
        # reap/рестарты отступили (remediation_allowed увидит limit_until). Точного reset из
        # пинга нет: берём консервативный час, кап LIMIT_MAX_WAIT. При откате фичи (=0) —
        # прежнее поведение (только уведомление).
        if [ "$LIMIT_MAX_WAIT" -ne 0 ]; then
            log "MODEL ACCESS: лимит/подписка (rc=$RC) — армирую лимитное окно"
            _pnow=$(date +%s)
            arm_limit_window "$(( _pnow + 3600 ))" "$_pnow" "$_pnow"
        else
            log "MODEL ACCESS: лимит/подписка (rc=$RC)"
            notify model-access "Не могу обратиться к модели: похоже, упёрлись в лимит или закончилась подписка. Перезапуском не лечится. Сообщения буду принимать, но отвечать не смогу."
        fi
    else
        # Нераспознанный сбой. Не молчим (иначе пропустим неизвестный вариант отказа B)
        # и не спамим (антиспам — час). Текст обрезаем: в выводе может быть что угодно.
        log "MODEL ACCESS: нераспознанный сбой (rc=$RC)"
        notify model-unknown "Не могу обратиться к модели (код $RC). Ответ: $(echo "$OUT" | head -c 200). Перезапускать не стал — не похоже, что это лечится перезапуском."
    fi
fi

# Отбой по флаппингу — ТОЛЬКО когда окно реально очистилось, а не на первом же здоровом
# проходе. Иначе «отбой» снимает метку антиспама через 3 минуты после тревоги, и следующая
# тревога проходит без подавления — владелец получает качели «тревога/отбой» каждый час.
# Именно так и вышло 01.08: 6 сообщений подряд. Метка антиспама — это и есть подавление,
# снимать её надо, только когда проблема действительно ушла.
if [ -f "$RESTART_HISTORY" ]; then
    CUTOFF=$(( $(date +%s) - FLAP_WINDOW ))
    RECENT=$(awk -v c="$CUTOFF" '$1 >= c' "$RESTART_HISTORY" 2>/dev/null | wc -l)
    [ "$RECENT" -eq 0 ] && notify_recover flapping "Отбой: перезапусков не было $((FLAP_WINDOW/60)) мин, канал стабилен."
fi

# W1 2026-08-14: сброс ЭСКАЛАЦИИ (fresh/backoff), когда канал реально стабилизировался —
# окно рестартов И чистых стартов пусто И последнее сообщение отвечено (last_stop>=last_prompt).
# Иначе счётчики fresh/backoff копились бы вечно и лестница застряла бы на верхней ступени.
if [ -f "$FRESH_HISTORY" ] || [ -f "$BACKOFF_UNTIL" ] || [ -f "$BACKOFF_STEP" ]; then
    _rh_recent=$(count_recent "$RESTART_HISTORY" "$FLAP_WINDOW")
    _fh_recent=$(count_recent "$FRESH_HISTORY" "$FRESH_WINDOW")
    _lp_r=$(cat "$STATE_DIR/last_prompt" 2>/dev/null | tr -cd 0-9); : "${_lp_r:=0}"
    _ls_r=$(cat "$STATE_DIR/last_stop" 2>/dev/null | tr -cd 0-9); : "${_ls_r:=0}"
    if [ "$_rh_recent" -eq 0 ] && [ "$_fh_recent" -eq 0 ] && [ "$_ls_r" -ge "$_lp_r" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "DRY: clear escalation state (fresh_history/backoff)"
        else
            rm -f "$FRESH_HISTORY" "$BACKOFF_UNTIL" "$BACKOFF_STEP"
        fi
        notify_recover give-up "Отбой: канал стабилен, снимаю режим ожидания."
    fi
fi

# W1-ФИКС Б5 (14.08): счётчик попыток оживления после лимита сбрасываем ТОЛЬКО по
# ПОДТВЕРЖДЁННОМУ успеху — канал ответил (last_stop>=last_prompt). clear_limit_state его
# больше НЕ трогает (иначе кап LIMIT_RESUME_MAX обнулялся бы каждый проход и был бы мёртв).
if [ -f "$LIMIT_RESUME_COUNT" ]; then
    _lp_rc=$(cat "$STATE_DIR/last_prompt" 2>/dev/null | tr -cd 0-9); : "${_lp_rc:=0}"
    _ls_rc=$(cat "$STATE_DIR/last_stop" 2>/dev/null | tr -cd 0-9); : "${_ls_rc:=0}"
    if [ "$_ls_rc" -ge "$_lp_rc" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "DRY: clear limit_resume_count (подтверждён успех: канал ответил)"
        else
            rm -f "$LIMIT_RESUME_COUNT"
        fi
    fi
fi

# restart-failed снимаем на здоровом проходе: тут «отбой» честен — канал поднят и работает.
notify_recover restart-failed "Отбой: канал поднялся и работает."

# Отметка «дошёл до конца». На здоровом канале watchdog не пишет в лог ничего, поэтому
# по логу невозможно отличить «всё хорошо» от «watchdog мёртв» — и 01.08 я именно на этом
# и ошибся, сказав владельцу «сторож исправно тикает», когда тот был мёртв трое суток.
# Теперь живость проверяется одной командой:
#   [ $(( $(date +%s) - $(cat ~/.local/state/claude-telegram/watchdog_last_pass) )) -lt 600 ]
[ "$DRY_RUN" = "1" ] || date +%s > "$STATE_DIR/watchdog_last_pass" 2>/dev/null
