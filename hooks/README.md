# Хуки канала

`settings-fragment.json` — только хуки обвязки связи (`core/*.sh`), вытащенные
из боевого `~/.claude/settings.json`. Пути в нём — `/home/ubuntu/core/...`:
скопируй туда содержимое `seamkeeper/core/` (см. `docs/SETUP.md`), либо
поправь пути под свой каталог перед вставкой.

Что делает каждый хук:

- **PreToolUse → `cli-digest.sh`** — живой дайджест «что агент делает сейчас»
  в одно самообновляющееся сообщение Telegram (не флудит).
- **PreToolUse / PostToolUse → `channel-heartbeat.sh activity`** — метка «идёт
  работа», гасит ложные тревоги на долгих задачах.
- **UserPromptSubmit → `channel-heartbeat.sh prompt`** — метка «сообщение
  принято».
- **Stop → `channel-heartbeat.sh stop`** — метка «ответ выдан»; вместе с
  `prompt`/`activity` даёт детектору тихих отказов.
- **Stop → `reply-guard.sh`** — не даёт ходу завершиться, если владельцу
  пришло сообщение, а ответа через `reply` не было.
- **PostToolUse (matcher: reply/edit_message) → `conv-mirror.sh`** — зеркалит
  отправленные ответы в лог с меткой доставлено/нет + аварийный пуш при сбое.

## Установка

1. Сделай бэкап: `cp ~/.claude/settings.json ~/.claude/settings.json.bak`.
2. Слей секцию `hooks` из `settings-fragment.json` в `~/.claude/settings.json`
   (объедини массивы по ключам событий, а не перезапиши файл целиком).
3. Проверь валидность: `python3 -m json.tool ~/.claude/settings.json`.
4. Хуки подхватываются автоматически при старте следующей сессии Claude Code —
   перезапускать ничего отдельно не нужно.
