# Changelog

*Русская версия: [CHANGELOG.ru.md](CHANGELOG.ru.md)*

All notable changes to Seamkeeper are documented here.

---

## v1.0.0 — 2026-09-17

First tagged release. The protocol itself has been running in production since August 2026;
this release adds the compatibility work described below.

### ⚠️ Read this first if the bot starts and then goes silent

**Claude Code 2.1.273 inverted the folder-trust dialog.** If you are running that version (or
newer) with startup scripts written for earlier releases, this is what you see:

- the log says `started`
- `tmux has-session` reports the session exists
- the bot never answers anything

Cause: Claude asks *"Do you trust the files in this folder?"* and, since 2.1.273, the
**refusal** option is selected by default. Older scripts sent a blind `Enter`, which used to
mean consent — now it picks **exit**. Claude quits a second after launch. The failure is
silent and looks like success, which is why it is worth spelling out here.

### Which behaviour applies to your setup

Nothing is required from you: `core/start-claude-telegram.sh` reads `claude --version` and
adapts. For reference, and for anyone porting these scripts:

| Your Claude Code | Default in the dialog | What the script sends |
|---|---|---|
| **2.1.273 and newer** | refusal (`No, exit`) | `Down`, then `Enter` |
| **older than 2.1.273** | consent (`Yes, I trust`) | `Enter` only |
| version not detectable | assumed new | `Down`, then `Enter` |

So an older installation keeps working exactly as before, and upgrading Claude Code switches
the behaviour automatically. If you fork these scripts, do not hardcode "press the Nth key" —
Anthropic has already changed the option order once.

### Fixed

- **Inverted trust dialog handled** in `core/start-claude-telegram.sh` and
  `core/restart-channel-fresh.sh`. The keypress is now chosen by detected Claude Code version
  instead of being hardcoded.
- **Trust acceptance was not persisted**, so the dialog reappeared on every restart.

### Added

- **Prevention layer, version-independent.** Before launching, the working directory is marked
  as trusted in `~/.claude.json` (`projects."<path>".hasTrustDialogAccepted`), so the dialog
  does not appear at all. Written via a temporary file in the same directory plus an atomic
  replace — an interrupted write cannot leave you with a truncated `~/.claude.json`. A corrupt
  or unreadable config is left untouched and the script falls back to the keypress layer
  instead of making things worse. Existing keys and file mode are preserved; an
  already-trusted entry is not rewritten.
- **Diagnosis guidance** in `docs/SETUP.md` and `docs/SETUP.en.md`: if the log says `started`
  but the bot is mute, inspect the session screen with
  `tmux capture-pane -t telegram -p | tail -20` — a stuck or declined trust dialog is
  immediately visible there.
- **Compatibility section** in both READMEs.

### Verified

Option-order behaviour confirmed against Claude Code 2.1.273. The version comparison was
tested across 2.0.9, 2.1.0, 2.1.272, 2.1.273, 2.1.300, 2.2.0, 1.9.9 and 3.0.0. The config
writer was tested on copies: adds trust while preserving other keys, does not rewrite an
already-trusted entry, survives corrupt JSON without damaging it, and creates the file when
missing.
