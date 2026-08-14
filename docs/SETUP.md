# Установка с нуля — от голого сервера до живого агента в Telegram

Проверено на Ubuntu 24.04. Нужно: VPS (4+ ГБ RAM), подписка Claude (Pro/Max),
аккаунт Telegram. Время: ~30 минут.

## 1. Базовый сервер

```bash
# tmux — дом для сессии агента; jq/python3 — для обвязки
sudo apt update && sudo apt install -y tmux jq python3 curl

# swap — страховка от OOM (наш инцидент: процесс раздулся до 8.5ГБ, ядро стреляло соседей)
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
```

## 2. Claude Code CLI

```bash
curl -fsSL https://claude.ai/install.sh | bash   # или npm install -g @anthropic-ai/claude-code
claude login                                      # интерактивно, привяжет подписку
```

## 3. Бот в Telegram

1. В Telegram: @BotFather → `/newbot` → имя → получишь ТОКЕН.
2. Токен — ТОЛЬКО на сервер, никогда в чаты:
```bash
echo 'TELEGRAM_BOT_TOKEN=сюда_токен' > ~/.env
chmod 600 ~/.env        # обязательно: без этого токен читаем всем на сервере
```

## 4. Файлы проекта

```bash
# скопируй core/ этого репозитория в ~/core
cp -r seamkeeper/core ~/core && chmod +x ~/core/*.sh
# стартовые правила и память
cp seamkeeper/memory-template/CLAUDE.md.template ~/CLAUDE.md   # отредактируй под себя!
```

## 5. Хуки

Вставь фрагмент `hooks/settings-fragment.json` в `~/.claude/settings.json`
(инструкция и валидация — в `hooks/README.md`). Всегда: бэкап → правка →
`python3 -m json.tool < ~/.claude/settings.json` — битый JSON ломает ВСЕ сессии.

## 6. Первый запуск

```bash
bash ~/core/start-claude-telegram.sh
```
Скрипт сам: проверит токен (getMe), зачистит зомби-поллеров, проверит очередь на 409,
поднимет tmux-сессию `telegram`, прожмёт trust-prompt. Увидишь «started».

Напиши своему боту в Telegram. Первое сообщение попросит пейринг — в терминале сервера
запусти `claude` и выполни `/telegram:access`, одобри себя. (Только себя! Это allowlist.)

## 7. Сторож в cron

```bash
crontab -e
# добавь:
@reboot sleep 15 && /home/ubuntu/core/start-claude-telegram.sh
*/3 * * * * /home/ubuntu/core/watchdog-claude-telegram.sh
```
С этого момента система самоподдерживающаяся: падения, зомби, лимиты подписки —
сторож лечит сам, о нерешаемом напишет тебе в Telegram.

## 8. Проверка живучести (сразу, не «потом»)

```bash
bash ~/core/channel-resurrect.sh --dry   # health-отчёт: всё ли зелёное
```
Убей сессию (`tmux kill-session -t telegram`) и подожди 3 минуты — сторож обязан
поднять её сам. Если поднял — у тебя настоящий seamkeeper. Поздравляю.

## Если что-то не так

→ [GRABLI.md](GRABLI.md) — все известные способы, которыми оно ломается, с лечением.
Твой случай почти наверняка там: мы на эти грабли уже наступили.
