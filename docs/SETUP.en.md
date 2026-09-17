# Setup from scratch — from a bare server to a live Telegram agent

*Russian version: [SETUP.md](SETUP.md)*

Tested on Ubuntu 24.04. You'll need: a VPS (4+ GB RAM), a Claude subscription
(Pro/Max), a Telegram account. Time: ~30 minutes.

> **A note on paths.** The scripts in this repository assume a user named
> `ubuntu` with home directory `/home/ubuntu` (the default on most Ubuntu VPS
> images) — paths are hardcoded, not computed dynamically. If your user or
> home directory is different, run this RIGHT AFTER step 4 (once `~/core`
> has already been copied):
> ```bash
> grep -rl '/home/ubuntu' ~/core | xargs sed -i "s|/home/ubuntu|$HOME|g"
> ```
> and in `claude-telegram.service` replace `User=ubuntu` with your own user,
> if you decide to install the systemd unit (this step is optional and not
> covered below — the unit lives at `core/claude-telegram.service`; run
> `sudo systemctl enable --now` after fixing the paths).

## 1. Base server

```bash
# tmux — home for the agent's session; jq/python3 — for the plumbing
sudo apt update && sudo apt install -y tmux jq python3 curl

# bun — runtime for Claude Code's telegram plugin (the plugin runs on bun;
# without it the channel won't come up)
curl -fsSL https://bun.sh/install | bash

# swap — insurance against OOM (our own incident: a process ballooned to
# 8.5GB and the kernel started shooting its neighbors)
# the grep guards make this step idempotent: a re-run won't duplicate lines
# in fstab/sysctl.conf
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=10
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
```

## 2. Claude Code CLI

```bash
curl -fsSL https://claude.ai/install.sh | bash   # or npm install -g @anthropic-ai/claude-code
claude login                                      # interactive, links your subscription
```

## 3. Telegram bot

1. In Telegram: @BotFather → `/newbot` → give it a name → you'll get a TOKEN.
2. The token goes ONLY on the server, never into chat:
```bash
echo 'TELEGRAM_BOT_TOKEN=your_token_here' > ~/.env
chmod 600 ~/.env        # mandatory: without this the token is readable by anyone on the server
```

## 3.5. The telegram plugin and the channels feature

The channel runs on Claude Code's official telegram plugin plus the
`channels` feature — at the time of writing this is a research preview, and
exactly how the plugin is installed may differ between versions. The general
idea:

```bash
claude   # start it interactively once
# inside Claude Code:
/plugin marketplace add claude-plugins-official   # if the marketplace isn't wired up yet
/plugin install telegram@claude-plugins-official
```

The exact commands may change — if this doesn't work as written, check
`claude /help` and the official Claude Code docs on plugins/channels. The
start script (`core/start-claude-telegram.sh`) already brings the session up
with the flag `--channels plugin:telegram@claude-plugins-official` — you
don't need to set that flag by hand, just install the plugin itself.

**Known gotcha:** if `DO_NOT_TRACK=1` (telemetry opt-out) is set anywhere in
`~/.claude/settings.json` or the environment, it also silently mutes loading
of Claude Code's feature flags — along with telemetry, the detection of
whether channel mode is even available goes dark too (symptom: "Channels are
not currently available" with no clear reason). Details and the full
incident writeup are in [GRABLI.en.md](GRABLI.en.md), item 4 ("DO_NOT_TRACK mutes
the channels feature flag"). Before starting the channel, make sure
`DO_NOT_TRACK` isn't set anywhere for the process that brings up the
session.

## 4. Project files

```bash
# copy this repository's core/ into ~/core
cp -r seamkeeper/core ~/core && chmod +x ~/core/*.sh
# startup rules and memory
cp seamkeeper/memory-template/CLAUDE.md.template ~/CLAUDE.md   # edit this to fit you!
```

## 5. Hooks

Insert the `hooks/settings-fragment.json` fragment into
`~/.claude/settings.json` (instructions and validation are in
`hooks/README.en.md`). Always: backup → edit →
`python3 -m json.tool < ~/.claude/settings.json` — broken JSON breaks EVERY
session.

## 6. First run

```bash
bash ~/core/start-claude-telegram.sh
```
The script will: verify the token (getMe), clean up orphaned pollers, check
the update queue for a 409, bring up the `telegram` tmux session, and clear
the trust prompt. You should see "started".

> **About the trust prompt (important as of Claude Code 2.1.273).** On first launch in a
> folder, Claude asks "Do you trust the files in this folder?". In 2.1.273 this dialog was
> **inverted**: the refusal option ("No, exit") is now selected by default. A blind Enter —
> which used to work — therefore picks *exit*, and the session dies right after startup
> while the log still says "started". The script handles this in two layers: it first marks
> the folder as trusted in `~/.claude.json` (`projects."<path>".hasTrustDialogAccepted: true`),
> so the prompt never appears; if it shows up anyway, the script sends **Down, then Enter**
> instead of Enter alone.
>
> If you see "started" but the bot stays silent, check the session screen first:
> `tmux capture-pane -t telegram -p | tail -20`. A stuck or declined trust dialog is
> immediately visible there. Anthropic has already changed the option order once, so don't
> rely on "press the Nth key" — rely on the `~/.claude.json` entry.

Message your bot on Telegram. The first message will ask for pairing — on
the server's terminal run `claude` and execute `/telegram:access`, then
approve yourself. (Only yourself! This is an allowlist.)

Pairing creates `~/.claude/channels/telegram/access.json` — a file holding
the allowlist of your chat_id. This is exactly where the digest
(`cli-digest.sh`) and the emergency push (`notify-owner.sh`) get the address
to send to. **Before pairing, they silently send nothing — that's expected**,
not a bug: no approved chat_id in access.json means nobody to send to.

## 7. Watchdog in cron

Run `crontab -e` as the REGULAR user (`ubuntu` or whoever you are), NOT via
`sudo` and not `sudo crontab -e` — root's cron sees root's environment, not
yours: it won't find your `~/.env` with the token and won't be pointing at
your `~/.claude`, so the channel won't come up right under it.

```bash
crontab -e
# add (REPLACE /home/ubuntu with your own home directory — cron won't expand
# $HOME reliably inside the line; the HOME=... line at the top of the crontab
# pins it explicitly):
HOME=/home/ubuntu
@reboot sleep 15 && /home/ubuntu/core/start-claude-telegram.sh
*/3 * * * * /home/ubuntu/core/watchdog-claude-telegram.sh
```
From this point on the system is self-sustaining: crashes, zombies,
subscription limits — the watchdog heals them itself, and messages you on
Telegram about anything it can't fix.

> **A note on node.** The watchdog looks for node under `~/.nvm`. If you
> installed Claude via `install.sh` (node landed in `~/.local/bin`, no nvm),
> that path won't exist — make sure the directory holding your `node` is in
> the PATH of the session that brings up the channel.

## 8. Survivability check (do it now, not "later")

```bash
bash ~/core/channel-resurrect.sh --dry   # health report: is everything green
```
Kill the session (`tmux kill-session -t telegram`) and wait 3 minutes — the
watchdog is supposed to bring it back up on its own. If it did, you have a
real seamkeeper. Congratulations.

If it didn't come back within 3 minutes, check `~/claude-telegram.log` —
both the start script and the watchdog write there (every check and every
action, timestamped). The reason for the failure is almost always visible
right in the last few lines of the log.

## If something's wrong

→ [GRABLI.en.md](GRABLI.en.md) — every known way this breaks, with the fix. Your
case is almost certainly in there: we've already stepped on this rake.
