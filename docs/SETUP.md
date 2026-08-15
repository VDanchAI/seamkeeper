# Установка с нуля — от голого сервера до живого агента в Telegram

*English version: [SETUP.en.md](SETUP.en.md)*

Проверено на Ubuntu 24.04. Нужно: VPS (4+ ГБ RAM), подписка Claude (Pro/Max),
аккаунт Telegram. Время: ~30 минут.

> **Важно про пути.** Скрипты в этом репозитории рассчитаны на пользователя
> `ubuntu` с домашним каталогом `/home/ubuntu` (дефолт большинства VPS-образов
> Ubuntu) — пути захардкожены, а не вычисляются динамически. Если у тебя
> другой пользователь или домашний каталог, выполни СРАЗУ ПОСЛЕ шага 4
> (когда `~/core` уже скопирован):
> ```bash
> grep -rl '/home/ubuntu' ~/core | xargs sed -i "s|/home/ubuntu|$HOME|g"
> ```
> и в `claude-telegram.service` замени `User=ubuntu` на своего пользователя,
> если решишь ставить systemd-юнит (шаг опциональный, не описан ниже — юнит
> лежит в `core/claude-telegram.service`, `sudo systemctl enable --now`
> после правки путей).

## 1. Базовый сервер

```bash
# tmux — дом для сессии агента; jq/python3 — для обвязки
sudo apt update && sudo apt install -y tmux jq python3 curl

# bun — рантайм telegram-плагина Claude Code (плагин на bun, без него канал не поднимется)
curl -fsSL https://bun.sh/install | bash

# swap — страховка от OOM (наш инцидент: процесс раздулся до 8.5ГБ, ядро стреляло соседей)
# grep-гварды делают шаг идемпотентным: повторный прогон не задвоит строки в fstab/sysctl.conf
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=10
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
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

## 3.5. Плагин telegram и фича channels

Канал работает через официальный telegram-плагин Claude Code плюс фичу
`channels` — на момент написания это research preview, и то, как именно
плагин ставится, может отличаться от версии к версии. Общая идея:

```bash
claude   # запусти интерактивно один раз
# внутри Claude Code:
/plugin marketplace add claude-plugins-official   # если маркетплейс ещё не подключён
/plugin install telegram@claude-plugins-official
```

Точные команды могут поменяться — если не сработало как написано, проверь
`claude /help` и официальную документацию Claude Code по плагинам/channels.
Стартовый скрипт (`core/start-claude-telegram.sh`) уже поднимает сессию с
флагом `--channels plugin:telegram@claude-plugins-official` — отдельно
включать флаг вручную не нужно, только поставить сам плагин.

**Известная грабля:** если в `~/.claude/settings.json` или окружении стоит
`DO_NOT_TRACK=1` (отключение телеметрии), это заодно глушит загрузку
фичефлагов Claude Code — вместе с телеметрией гаснет и определение, что
канальный режим вообще доступен (симптом: «Channels are not currently
available» без внятной причины). Подробности и разбор инцидента — см.
[GRABLI.md](GRABLI.md), пункт 4 («DO_NOT_TRACK глушит фичефлаг каналов»).
Перед стартом канала убедись, что `DO_NOT_TRACK` нигде не выставлен для
процесса, поднимающего сессию.

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

Пейринг создаёт `~/.claude/channels/telegram/access.json` — файл с allowlist твоего
chat_id. Именно из него дайджест (`cli-digest.sh`) и аварийный пуш (`notify-owner.sh`)
берут, кому писать. **До пейринга они молча ничего не шлют — это нормально**, не баг:
нет approved chat_id в access.json → некому отправлять.

## 7. Сторож в cron

`crontab -e` выполняй от ОБЫЧНОГО пользователя (`ubuntu` или твоего), НЕ через `sudo` и
не `sudo crontab -e` — root-cron видит своё окружение, а не твоё: не найдёт `~/.env` с
токеном и не тот `~/.claude`, канал под ним не поднимется как надо.

```bash
crontab -e
# добавь (ЗАМЕНИ /home/ubuntu на свой домашний каталог — cron не раскроет $HOME
# внутри строки надёжно; строка HOME=... вверху crontab фиксирует его явно):
HOME=/home/ubuntu
@reboot sleep 15 && /home/ubuntu/core/start-claude-telegram.sh
*/3 * * * * /home/ubuntu/core/watchdog-claude-telegram.sh
```
С этого момента система самоподдерживающаяся: падения, зомби, лимиты подписки —
сторож лечит сам, о нерешаемом напишет тебе в Telegram.

> **Заметка про node.** Сторож ищет node в `~/.nvm`. Если ты ставил Claude через
> `install.sh` (node лёг в `~/.local/bin`, без nvm), этого пути не будет — убедись,
> что каталог с твоим `node` попадает в PATH сессии, поднимающей канал.

## 8. Проверка живучести (сразу, не «потом»)

```bash
bash ~/core/channel-resurrect.sh --dry   # health-отчёт: всё ли зелёное
```
Убей сессию (`tmux kill-session -t telegram`) и подожди 3 минуты — сторож обязан
поднять её сам. Если поднял — у тебя настоящий seamkeeper. Поздравляю.

Если не поднялось за 3 минуты — смотри `~/claude-telegram.log`: туда пишут и
старт-скрипт, и сторож (каждая проверка и каждое действие с меткой времени).
Почти всегда причина отказа видна прямо в последних строках лога.

## Если что-то не так

→ [GRABLI.md](GRABLI.md) — все известные способы, которыми оно ломается, с лечением.
Твой случай почти наверняка там: мы на эти грабли уже наступили.
