# Seamkeeper — your self-healing pocket Claude on a VPS

*Keeper of seams: a personal server-side Claude you drive from Telegram, stitched together
from the scars of real incidents — and able to stitch itself back up.*

Not "a bot". A **personal AI engineer living on your server**: you text it in Telegram,
and it reads and edits files, fixes services, runs tests, manages your projects — and
**resurrects itself** when things fall apart.

Built not from a tutorial but from six months of production use: every script here closes
a specific failure that actually happened on a live server. Comments in the code explain
*why* — with incident dates.

## Architecture

```
Telegram ⇄ [bot plugin] ⇄ Claude Code (interactive session in tmux) ⇄ your server
                                  ▲
                    watchdog (cron, every 3 min) — guardian and resuscitator
```

- **The channel** is a regular interactive `claude` in a tmux session with the official
  Telegram plugin attached. Everything Claude Code can do (files, bash, agents) is
  available from your chat.
- **The watchdog** is a cron script that checks 7 vital signs every 3 minutes and heals
  failures: from "process died" to "alive but mute" and "hit the subscription limit —
  wait for reset instead of thrashing".
- **The survival kit** — reaping zombie processes that steal the bot's update queue;
  mirroring every reply to a log; a terminal fallback input; an emergency push when the
  primary path is dead.
- **Memory** — a file-based note system plus startup rules, so the agent remembers who
  you are and what you're working on across restarts and limits.

## File map

| File | What it does |
|---|---|
| `core/start-claude-telegram.sh` | Brings the channel up: pre-flight checks, context resume, tmux |
| `core/watchdog-claude-telegram.sh` | The guardian: 7 checks, restart ladder, subscription-limit detector |
| `core/reap-telegram-orphans.sh` | Kills orphaned bot pollers stealing the queue (409 Conflict) |
| `core/channel-resurrect.sh` | One command: "check and fix everything" + health report to Telegram |
| `core/restart-channel-fresh.sh` | Clean restart (no прошлый context) |
| `core/channel-heartbeat.sh` | "Received / answered / working" signals for silent-failure detection |
| `core/notify-owner.sh` | Direct Bot API path to the owner (works when everything else is down) |
| `core/cli-digest.sh` | Live digest of agent actions in Telegram (one self-updating message) |
| `core/conv-mirror.sh` | Mirror of all replies to a log with delivered/failed marks + emergency push |
| `core/reply-guard.sh` | Stops the agent from "replying into the void" (terminal instead of Telegram) |
| `core/tell-agent.sh` | Fallback input: talk to the agent from a terminal when Telegram is down |
| `hooks/` | settings.json fragment — how to wire the hooks |
| `memory-template/` | Memory schema: startup rules + note templates |
| `docs/SETUP.md` | Install from scratch (Russian; EN: SETUP.en.md) |
| `docs/GRABLI.md` | The Book of Rakes: real failures and how each one is closed |

## Quick start

See [docs/SETUP.en.md](docs/SETUP.en.md). In short: Ubuntu server → Claude Code CLI
(subscription) → create a bot with @BotFather → token into `~/.env` (chmod 600) →
`bash core/start-claude-telegram.sh` → add the watchdog to cron. Done.

## Principles this stands on

1. **Secrets never travel through chat.** Tokens are entered on the server only.
2. **The watchdog doesn't trust "process alive = all good".** Half of the failures are
   "alive but mute" — hence heartbeat signals and silent-failure detection.
3. **Restart is not a cure-all.** If you've hit the subscription limit, restarts only
   burn attempts. The watchdog tells the difference and knows how to wait.
4. **Every fix is explained.** A comment with a date and a reason — or a month later
   nobody remembers why that line exists.
