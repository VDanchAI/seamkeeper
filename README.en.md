# Seamkeeper — your self-healing pocket Claude on a VPS

![Indigo denim repaired with a copper seam](assets/brand/seamkeeper-hero-denim-copper.png)

*Keeper of seams: a personal server-side Claude you drive from Telegram, stitched together
from the scars of real incidents — and able to stitch itself back up.*

Seamkeeper is a field-tested continuity protocol and reference implementation for a personal
technical agent. It keeps the agent reachable from Telegram, carries the thread of work across
restarts, and recovers after failures. It is not a bot and not a new agent: Claude Code remains
the agent. Seamkeeper is a survival layer built around it.

> ## 🪡 The fastest way in
> **Hand this repo to your Claude Code on the server and say:**
> **"Build me an eternal session following BOOTSTRAP.md"** — it takes it from there: asks what
> it's missing, adapts to your server, verifies it survives, and reports back.
>
> [→ BOOTSTRAP.md](BOOTSTRAP.md) — the build protocol (for the agent) · [→ docs/SETUP.en.md](docs/SETUP.en.md) — the manual path (for a human)

## Three values

- **Reachable** — the agent is a Telegram message away, from any device, at any time.
- **Continuous** — the thread of work and memory survive restarts, subscription limits, and
  server reboots.
- **Self-healing** — the watchdog tells failure classes apart and heals them, instead of
  restarting forever.

## What it is and what it does not do

**It is:** a survival protocol wrapped around your interactive Claude Code session — a
Telegram channel, a watchdog, memory, and recovery scaffolding, grown out of real production
use.

**It is not:** a standalone bot or a new agent; not a general-purpose framework for any LLM;
not ready-made support for Codex or other engines — that's a possible future direction, not a
current fact. The working implementation today is built around Claude Code, tmux, Telegram,
and a VPS.

## Why it exists

This is the product of roughly eight months of real production use and repair of a personal
server session: every safeguard here grew out of an observed failure, not a theory. The full
history of failures and fixes lives in [docs/GRABLI.md](docs/GRABLI.md), the Book of Rakes
(kept in Russian, with dated incident notes).

## Security

- **Secrets live on the server only.** Tokens, keys, and passwords are never entered or sent
  through Telegram or any other chat.
- **Restrict Telegram access with an allowlist.** An open channel into a personal agent with
  file and shell access is an attack surface; an allowlist of approved users is mandatory.
- **Broad-permission mode belongs on a personal, trusted VPS only.** If Claude Code is
  configured with wide-open permissions (files, bash, network), that's acceptable only on a
  server you personally control. Do not run it that way on shared or production machines
  without isolation.


## Architecture

Full diagram and details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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
| `core/restart-channel-fresh.sh` | Clean restart (no prior context) |
| `core/channel-heartbeat.sh` | "Received / answered / working" signals for silent-failure detection |
| `core/notify-owner.sh` | Direct Bot API path to the owner (works when everything else is down) |
| `core/cli-digest.sh` | Live digest of agent actions in Telegram (one self-updating message) |
| `core/cli-digest-parse.py` | Event parser for cli-digest.sh |
| `core/conv-mirror.sh` | Mirror of all replies to a log with delivered/failed marks + emergency push |
| `core/reply-guard.sh` | Stops the agent from "replying into the void" (terminal instead of Telegram) |
| `core/tell-agent.sh` | Fallback input: talk to the agent from a terminal when Telegram is down |
| `core/claude-telegram.service` | systemd unit to run the channel as a service |
| `hooks/` | settings.json fragment — how to wire the hooks |
| `memory-template/` | Memory schema: startup rules + note templates |
| `assets/brand/` | Project visual assets (hero, avatar) |
| `docs/SETUP.md` | Install from scratch (Russian; EN: SETUP.en.md) |
| `docs/ARCHITECTURE.md` | Detailed architecture and data-flow diagram |
| `docs/GRABLI.md` | The Book of Rakes: real failures and how each one is closed (Russian, dated incidents) |
| `docs/notes/` | Working notes and project discussions |

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
