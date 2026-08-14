# Хуки канала

`settings-fragment.json` — только хуки обвязки связи (`core/*.sh`), вытащенные
из боевого `~/.claude/settings.json`. Пути в нём — `/home/ubuntu/core/...`:
скопируй туда содержимое `seamkeeper/core/` (см. `docs/SETUP.md`), либо
поправь пути под свой каталог перед вставкой.

> **Другой пользователь/домашний каталог?** Пути в этом фрагменте (и во всех
> скриптах `core/`) захардкожены на `/home/ubuntu`. Если твой пользователь не
> `ubuntu`, поправь пути в `settings-fragment.json` ПЕРЕД вставкой — либо
> вставь как есть и потом прогони на скопированном `~/core`:
> `grep -rl '/home/ubuntu' ~/core | xargs sed -i "s|/home/ubuntu|$HOME|g"`
> (см. предупреждение в `docs/SETUP.md`), и не забудь синхронно поправить сами
> команды в `settings-fragment.json` — sed по `~/core` их не затронет, так как
> они живут в `~/.claude/settings.json`, а не в `~/core`.

На верхнем уровне фрагмента также стоит `"skipDangerousModePermissionPrompt":
true`. Без него первый старт канала зависает на интерактивном подтверждении
«you are running with --dangerously-skip-permissions, are you sure?» — а
нажать Enter в headless-tmux-сессии, поднятой из cron/systemd, некому: канал
молчит, будто завис, хотя просто ждёт клавишу.

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

Если `~/.claude/settings.json` у тебя ещё пустой/дефолтный — можно просто
скопировать `settings-fragment.json` поверх него (сделав бэкап). Но если там
уже есть свои хуки или настройки — слияние вручную легко сломать (перепутать
скобки, случайно перезаписать чужой массив хуков вместо объединения). Ниже —
готовый скрипт слияния, который делает это безопасно и идемпотентно (повторный
запуск не задвоит хуки).

1. Сохрани скрипт как `merge_hooks.py` (можно рядом с `settings.json`):

   ```python
   #!/usr/bin/env python3
   # Сливает hooks/settings-fragment.json в ~/.claude/settings.json, не трогая
   # существующие хуки и ключи. Бэкап — всегда, идемпотентно — повтор безопасен.
   import json, sys, shutil, datetime

   def main():
       target_path, fragment_path = sys.argv[1], sys.argv[2]
       with open(target_path) as f: target = json.load(f)
       with open(fragment_path) as f: fragment = json.load(f)

       backup = f"{target_path}.bak.{datetime.datetime.now():%Y%m%d%H%M%S}"
       shutil.copy2(target_path, backup)
       print(f"Backup: {backup}")

       target.setdefault("hooks", {})
       for event, blocks in fragment.get("hooks", {}).items():
           bucket = target["hooks"].setdefault(event, [])
           for block in blocks:
               if block not in bucket:
                   bucket.append(block)

       for key, value in fragment.items():
           if key == "hooks":
               continue
           if key not in target:
               target[key] = value
           elif target[key] != value:
               print(f"WARNING: '{key}' уже={target[key]!r}, во фрагменте={value!r} — "
                     f"оставляю твоё значение, проверь руками")

       with open(target_path, "w") as f:
           json.dump(target, f, indent=2, ensure_ascii=False); f.write("\n")
       print(f"Слито. Проверь: python3 -m json.tool {target_path}")

   if __name__ == "__main__":
       main()
   ```

2. Прогони:
   ```bash
   python3 merge_hooks.py ~/.claude/settings.json seamkeeper/hooks/settings-fragment.json
   ```
   Скрипт сам делает бэкап `~/.claude/settings.json.bak.<timestamp>` перед правкой.
3. Проверь валидность: `python3 -m json.tool ~/.claude/settings.json`.
4. Хуки подхватываются автоматически при старте следующей сессии Claude Code —
   перезапускать ничего отдельно не нужно.

Скрипт проверен на паре тестовых json (существующие хуки другого события +
повторный запуск) — дубликатов не создаёт, чужие хуки и ключи не трогает.
