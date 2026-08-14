# BOOTSTRAP — протокол для агента-сборщика

> **Это документ не для человека. Он адресован ИИ-агенту.**
> Человек, дай этот файл своему Claude Code на сервере и скажи: **«собери мне вечную сессию
> по этому протоколу»**. Дальше читает и делает агент.
>
> *(English version below — see part II.)*

---

# Часть I. Русский

## Агент, читай отсюда

Ты — Claude Code, запущенный на сервере владельца. Тебе поручено собрать **вечную
сессию**: себя же, но живущего постоянно и доступного владельцу из Telegram, с
самовосстановлением после падений, лимитов подписки и перезагрузок.

Этот репозиторий — не пакет для копипаста. Это **референс-реализация плюс объяснение
причин**. Твоя работа — понять ЗАЧЕМ каждая деталь и собрать эквивалент под КОНКРЕТНЫЙ
сервер владельца, а не слепо скопировать чужие пути.

### Правила поведения при сборке (обязательны)

1. **Спрашивай, не додумывай.** Развилки, которые меняют результат, задавай владельцу
   ДО работы, одним сжатым сообщением.
2. **Секреты — только на сервере.** Никогда не проси прислать токен в чат. Владелец
   вписывает его сам в файл, ты этот файл не читаешь вслух и не печатаешь.
3. **Ничего необратимого без подтверждения.** Убить сессию, переписать конфиг, ребутнуть
   сервис — сначала скажи что и зачем, дождись «да».
4. **Проверяй факты на этой машине**, а не по памяти: имя пользователя, домашний каталог,
   версии, что уже занято.
5. **Каждую строку, которую пишешь, комментируй «почему»** — с датой и причиной. Через
   месяц ни ты, ни владелец не вспомните, зачем она.

### Что ты должен собрать (целевое состояние)

Система из пяти способностей. Скрипты в `core/` — рабочий образец каждой; адаптируй.

| Способность | Зачем | Референс |
|---|---|---|
| **Жить постоянно** | Сессия не умирает с закрытием SSH; переживает перезагрузку | `core/start-claude-telegram.sh` + cron `@reboot` |
| **Слышать владельца** | Общение из Telegram, а не только с консоли | telegram-плагин Claude Code + allowlist |
| **Не терять нить** | Рестарт возвращает ТУ ЖЕ беседу, а не амнезию | `--resume <session_id>` + резолв id по транскрипту |
| **Чинить себя** | Падения, зомби-процессы, лимиты — без человека | `core/watchdog-claude-telegram.sh` (cron каждые 3 мин) |
| **Не пропадать молча** | Владелец узнаёт о поломке, и есть запасной канал | `core/notify-owner.sh`, `conv-mirror.sh`, `tell-agent.sh` |

### Порядок сборки

**Шаг 0. Разведка (перед любым действием).**
Установи фактами: `whoami`, `$HOME`, версия ОС, стоит ли `tmux`, установлен ли Claude Code
и авторизован ли, есть ли уже cron-задачи и tmux-сессии с похожим именем, сколько RAM,
есть ли swap. Ничего не меняй — только смотри. Результат покажи владельцу одним абзацем.

**Шаг 1. Вопросы владельцу (один блок, коротко).**
- Имя tmux-сессии для агента (дефолт `telegram`).
- Куда положить скрипты (дефолт `~/core`).
- Есть ли бот в Telegram или создавать (@BotFather → `/newbot`).
- Нужен ли сервис-компаньон в проверках живучести (у владельца может быть свой бот/сервис).
- Разрешает ли `sudo` для swap и OOM-защиты.

**Шаг 2. Фундамент.**
`tmux`, `jq`, `python3`. Если swap нет и владелец разрешил — сделай swap (см.
`docs/SETUP.md`, раздел 1) — это спасает от OOM-killer при всплесках памяти.

**Шаг 3. Токен.**
Владелец сам вписывает токен в `~/.env` как `TELEGRAM_BOT_TOKEN=…` и ставит `chmod 600`.
Ты проверяешь работоспособность через `getMe` — но НЕ печатаешь значение токена.

**Шаг 4. Скрипты.**
Скопируй `core/` в выбранный каталог и **адаптируй под этот сервер**: пути, имя сессии,
имя сервиса-компаньона (или отключи проверку), PATH к node. Хардкод `/home/ubuntu` в
референсе — не догма, это дом автора; подставь реальный.

**Шаг 5. Хуки.**
Влей `hooks/settings-fragment.json` в `~/.claude/settings.json` **слиянием массивов**, не
перезаписью (там могут быть чужие хуки). Всегда: бэкап → правка → валидация JSON.
Хуки дают: дайджест действий, сигналы живости, зеркало ответов, защиту «ответь владельцу».

**Шаг 6. Первый запуск и пейринг.**
Подними сессию старт-скриптом. Владелец пишет боту, одобряет себя в allowlist
(`/telegram:access` в терминале). Проверь, что ответ дошёл в Telegram.

**Шаг 7. Сторож.**
Пропиши в cron (от ОБЫЧНОГО пользователя, не root): `@reboot` — старт, `*/3` — сторож.

**Шаг 8. Приёмка (не пропускай!).**
Докажи, что оно живое, а не «вроде запустилось»:
- убей сессию и подожди 3 минуты — сторож обязан её поднять;
- напиши боту — ответ должен прийти;
- прогони health-команду (`channel-resurrect.sh --dry`) — всё зелёное;
- покажи владельцу результаты трёх проверок.

**Шаг 9. Память.**
Заведи владельцу схему из `memory-template/`: стартовые правила (`CLAUDE.md`), индекс
(`MEMORY.md`), первые записи (кто владелец, как он просит работать). Без этого «вечная
сессия» помнит только текущий контекст — а после лимита начнёт с чистого листа.

**Шаг 10. Отчёт.**
Одним сообщением: что установлено, где лежит, три аварийные команды (починить всё,
читать разговор при лежащей телеге, написать из терминала), что осталось на потом.

### Что прочитать перед сборкой

- `docs/GRABLI.md` — **обязательно**. Это карта того, как система ломается в реальности:
  зомби-поллер крадёт очередь сообщений; сторож бессмысленно рестартует при лимите
  подписки; телеметрия выключена → канал не включается. Половина твоей работы — не
  повторить эти грабли.
- `README.md` — обзор и карта файлов.
- `docs/SETUP.md` — ручной путь, если владелец хочет делать сам.

### Проверь себя перед тем, как сказать «готово»

- [ ] Сессия переживает `tmux kill-session` (сторож поднимает)?
- [ ] Переживёт перезагрузку (`@reboot` в cron есть)?
- [ ] Рестарт возвращает ту же беседу, а не чистый лист?
- [ ] Токен: права `600`, в чат не попадал, в логах не светится?
- [ ] Владелец получит сообщение, если система сляжет?
- [ ] Есть запасной способ поговорить, когда Telegram лежит?
- [ ] В памяти записано, кто владелец и как с ним работать?

Если хоть один пункт «нет» — ты ещё не закончил.

---

# Part II. English

## Agent, start here

You are Claude Code running on the owner's server. Your task: build an **eternal session** —
yourself, but permanently alive, reachable from Telegram, and self-healing across crashes,
subscription limits and reboots.

This repository is not a copy-paste package. It is a **reference implementation plus the
reasoning behind it**. Understand WHY each part exists, then build the equivalent for THIS
server instead of blindly copying someone else's paths.

### Ground rules

1. **Ask, don't assume.** Put forks that change the outcome to the owner BEFORE working.
2. **Secrets stay on the server.** Never ask for a token in chat. The owner writes it into
   a file; you never echo it.
3. **Nothing irreversible without confirmation.**
4. **Verify facts on this machine** — user, home, versions, what's already taken.
5. **Comment every line you write with WHY** — date and reason included.

### Target capabilities

| Capability | Why | Reference |
|---|---|---|
| **Always alive** | Survives SSH disconnect and reboot | `core/start-claude-telegram.sh` + `@reboot` cron |
| **Hears the owner** | Telegram, not just console | Claude Code telegram plugin + allowlist |
| **Keeps the thread** | Restart resumes the SAME conversation | `--resume <session_id>` |
| **Heals itself** | Crashes, zombie pollers, limits — unattended | `core/watchdog-claude-telegram.sh` |
| **Never goes silent** | Owner learns about breakage; a fallback channel exists | `notify-owner.sh`, `conv-mirror.sh`, `tell-agent.sh` |

### Build order

0. **Recon** — `whoami`, `$HOME`, OS, tmux/Claude presence, existing cron and sessions,
   RAM and swap. Change nothing; report findings.
1. **Ask the owner** — session name, install dir, bot exists or create, companion service
   to monitor, sudo allowed for swap/OOM tuning.
2. **Foundation** — tmux, jq, python3; swap if missing and allowed.
3. **Token** — owner writes `TELEGRAM_BOT_TOKEN=…` into `~/.env`, `chmod 600`. You verify
   via `getMe`, never print the value.
4. **Scripts** — copy `core/`, adapt paths, session name, companion service, node PATH.
5. **Hooks** — merge `hooks/settings-fragment.json` into `~/.claude/settings.json`
   (merge arrays, never overwrite); backup and validate JSON.
6. **First run and pairing** — start the session; owner messages the bot and approves
   themselves into the allowlist; confirm a reply actually arrives.
7. **Watchdog** — cron as the normal user: `@reboot` start, `*/3` watchdog.
8. **Acceptance** — kill the session and watch it come back; message the bot; run the
   health command; show the owner all three results.
9. **Memory** — set up `memory-template/`: startup rules, index, first facts about the owner.
10. **Report** — what was installed, where, the three emergency commands, what's left.

### Read before building

`docs/GRABLI.md` (**mandatory** — a map of how this breaks in the real world),
`README.md`, `docs/SETUP.md`.

### Self-check before declaring done

- [ ] Session survives `tmux kill-session` (watchdog restores it)?
- [ ] Survives reboot?
- [ ] Restart resumes the same conversation?
- [ ] Token: `600`, never in chat, never in logs?
- [ ] Owner gets notified if the system dies?
- [ ] A fallback way to talk exists when Telegram is down?
- [ ] Memory holds who the owner is and how they want to work?

Any "no" means you are not done.
