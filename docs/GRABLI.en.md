# The Book of Rakes

*Russian version: [GRABLI.md](GRABLI.md)*

Real failures of the Claude Code Telegram channel and how each one is closed in this
project. The dates and incident write-ups are kept deliberately: this is the most valuable
part of the document, a compact digest of "what has already gone wrong and why". Ordered
from the nastiest (they cost hours of silence and were invisible) down to the less
dangerous ones.

---

## 1. A 409 orphan steals the Telegram queue

**Symptom:** the channel goes silent, yet the session is alive and even writes replies in
the terminal — they just never reach Telegram. New messages from the owner don't arrive at
all.

**Root cause:** Telegram hands the `getUpdates` queue to exactly ONE consumer per token.
`tmux kill-session` sends the plugin process (`bun server.ts`) a SIGHUP — but bun survives
it, migrates under `init`, and keeps polling the bot. A new session gets `409 Conflict` on
startup and stays mute: the queue is stolen by a dead process. Incident 14.08.2026 — 2 hours
of silence until the cause was found.

**How it's closed:** `core/reap-telegram-orphans.sh` — finds plugin bun processes that have
NO live `claude` in their ancestry (meaning they're not owners but orphans), sends SIGTERM →
3s pause → SIGKILL (they ignore SIGTERM). Wired into `start-claude-telegram.sh` and
`restart-channel-fresh.sh` before bringing a new session up; in
`watchdog-claude-telegram.sh` there's a separate Check 5b (`reap_orphans`), with a grace
period and cooldown so it doesn't kill blindly.

---

## 2. Subscription limit → pointless restarts in circles

**Symptom:** the channel goes silent, the watchdog reports "silent failure" and restarts the
session every ~15 minutes — to no effect. Over a few hours: dozens of restarts, zero result.

**Root cause:** the token/subscription limit ran out. Processes are alive, the plugin is
alive, the connection to Telegram is there — the session simply physically cannot answer.
The old detector looked in the output for words like `credit balance|quota|usage limit`, but
the real text of a Claude error is `You've hit your session limit · resets 2:50pm
(Europe/Berlin)` or the JSON `"error":"rate_limit"`, `"apiErrorStatus":429` — none of the
searched-for words matched. The detector never fired ONCE in the entire log history, and
`restart_session()` with `--continue` brought up the SAME context every time: the Stop hook
didn't fire, `last_prompt > last_stop` stayed true forever → restart again and again.

**How it's closed:** the limit detector reads the session's jsonl transcript directly
(`find_channel_transcript` + `detect_limit` in `watchdog-claude-telegram.sh`), parses the
reset time from the error text (`parse_reset_epoch`), arms a wait window (`limit_until`) and
during that window suppresses restarts (`remediation_allowed`). When the window expires,
`resume_after_limit` revives the channel itself with a nudge or a restart. Plus a safety net:
Check 7 — a periodic direct ping of the model (`claude -p 'ok'` with a cheap model once an
hour) catches the limit independently of the text in the transcript.

**Native backstop (Anthropic):** `core/start-claude-telegram.sh` sets
`export CLAUDE_CODE_RETRY_WATCHDOG=1` — the Claude CLI itself waits for the limit to
reset and retries the request. This complements our detector, it does not replace it:
orphans, the restart ladder, silent failures, and the reply mirror are still the
watchdog's job. Keep both.

---

## 3. The watchdog strangles itself through a flock descriptor inherited by tmux

**Symptom:** the watchdog nominally launches from cron every 3 minutes for 3.5 days straight,
but the log is silent since 28.07 21:33. The owner believes "the watchdog is on duty" while
it's actually dead.

**Root cause:** `exec 9>"$LOCK"` + `flock -n 9` holds a lock on file descriptor 9. When the
watchdog runs `start-claude-telegram.sh`, which brings up a tmux session, tmux INHERITS
descriptor 9 along with the lock and lives with it forever (`/proc/<tmux>/fd/9` points
exactly at the lock file). Every subsequent cron run sees the flock taken and quietly exits —
the watchdog exists but checks nothing.

**How it's closed:** `restart_session()` and `restart_fresh()` in
`watchdog-claude-telegram.sh` launch the start script with an explicit `9>&-` — they close
the inheritable descriptor BEFORE exec, so the spawned tmux cannot inherit the lock. Plus:
the lock file name was changed to `watchdog-claude-telegram-v2.lock`, so a stuck old flag
doesn't get in the new code's way (it just hangs harmlessly until the next tmux restart).

---

## 4. DO_NOT_TRACK mutes the channels feature flag → "Channels not available"

**Symptom:** the channel doesn't come up at all, `--channels` acts as if it doesn't exist, no
explicit error.

**Root cause:** the `DO_NOT_TRACK` environment variable (telemetry opt-out) also silences
Claude Code's internal feature-flag gate — along with telemetry, the detection that channel
mode is available goes dark too. The symptom reads like "a channel config bug" while in fact
it's a side effect of privacy.

**How it's closed:** the start script explicitly does NOT inherit / resets `DO_NOT_TRACK` in
the environment of the process that brings up the channel session — feature flags are
evaluated by a clean environment. The prophylaxis is described in the "Known bugs" section of
the project's runtime documentation; in a new environment the first thing checked is
`env | grep DO_NOT_TRACK` before working through any other hypotheses.

---

## 5. `--continue` picks up someone else's / stale session

**Symptom:** after a restart the channel answers, but out of place — the context is wrong, or
the session behaves as if it remembers a conversation that isn't yours.

**Root cause:** `--continue` resolves "the last session" in the Claude Code project directory
without any tie to the fact that this is specifically the telegram channel session and not
some other session started in the same working directory (for example, a manual run with the
same cwd for diagnostics).

**How it's closed:** the channel session runs in its own tmux window `telegram` (the watchdog
watches STRICTLY that one, `SESSION_NAME="telegram"`), the plugin is found via `bot.pid` tied
to the process tree of exactly this session, not a global `pgrep`. Diagnosis of a foreign
transcript is cut off by matching the file's `sessionId` against the jsonl name
(`detect_limit`: `case "$rec" in *"\"sessionId\":\"$stem\""*`).

---

## 6. Manual mode without skip-permissions — the channel waits for an Enter keypress

**Symptom:** "it worked perfectly for months", then suddenly the bot accepts messages but
NEVER answers — as if frozen solid, even though the process is alive.

**Root cause:** two start scripts with different flags turned up — an old one (with
`--dangerously-skip-permissions`) and a new one without it. As long as the session wasn't
restarted, the old process kept running, brought up in autonomous mode months ago — hence the
illusion of stability. As soon as the session was restarted with the new script, it came up
in `⏸ manual mode on`: every action waits for an Enter confirmation from the keyboard, and
there's no one to press it from Telegram.

**How it's closed:** a single canonical start script with `--dangerously-skip-permissions` +
`skipDangerousModePermissionPrompt: true` in `settings.json`; the old duplicate script is
archived with a `.DEPRECATED` suffix so it can't be accidentally invoked by cron or by hand.

---

## 7. Bot token file without permission restrictions

**Symptom:** doesn't manifest as a channel failure — it's a hidden vulnerability that only
surfaces during an audit.

**Root cause:** the bot token file was stored with `0664` permissions (world-readable), and
the token had already leaked into the logs of adjacent tools with the same permissions. Any
process on the machine could read it.

**How it's closed:** a rule fixed in the project's operating guidelines — the token file must
be `0600`, the token is passed to child processes only through environment variables, never
as a command-line argument (otherwise it's visible in `ps aux`). The breakdown of the
incident's specific cost and the rotation plan live in the survivability-audit restart pack;
closing this item is scheduled as a separate wave alongside swap and OOM protection (see
item 11).

---

## 8. Bun without the token in its environment silently chews messages

**Symptom:** in tmux you can see that Claude received the message and wrote a reply ("On
it…"), but in Telegram — silence. The bot looks operational, but nothing arrives.

**Root cause:** the plugin's bun server started WITHOUT `TELEGRAM_BOT_TOKEN` in its
environment: long-poll and sending go blind, every message is silently lost. The token was in
`~/.env`, but the start script brought Claude up through a login shell (`bash -lc`), and
neither `.bashrc` (which has an early `return` for non-interactive shells) nor `.profile`
loaded the token. The old session worked only because the token had been exported into its
shell by hand — and it died along with the session.

**How it's closed:** the line `set -a; [ -f "$HOME/.env" ] && . "$HOME/.env"; set +a` was
added to `.profile`; the start script loads `.env` itself and does a preflight `getMe` —
without a valid token it fails with an explicit error rather than bringing up a bot that looks
alive but is deaf.

---

## 9. bun ignores SIGTERM

**Symptom:** an attempt to gracefully stop an orphaned plugin process (SIGTERM) doesn't work
— the process keeps hanging and holding the connection.

**Root cause:** the plugin's bun runtime doesn't respond to SIGTERM with a normal shutdown
(verified empirically, not assumed).

**How it's closed:** `reap-telegram-orphans.sh` sends SIGTERM, waits a fixed pause (3s), and
if the process is still alive — finishes it off with SIGKILL. A two-stage scheme, not a
single "soft" signal.

---

## 10. heartbeat is written by ALL Claude sessions, not just the channel one

**Symptom:** the watchdog either strangles a healthy channel mid-work or fails to see a real
silent failure — behavior is unpredictable and at first glance random.

**Root cause:** the global heartbeat/activity write hook didn't filter by which session
actually called it. Any Claude session on the machine (diagnostic, manual, from another
project) updated the same state files (`last_prompt`, `last_activity`) that the watchdog
reads for the channel session. Two symmetric failures: (a) a foreign session sent a prompt
and died before the Stop hook — the watchdog sees "received, not answered" and cuts down a
healthy channel; (b) a foreign BUSY session keeps `last_activity` fresh — a real silent
channel failure is masked as "the session is still working".

**How it's closed:** recorded in the survivability audit as an open defect — heartbeat
filtering must be tied to `--channels` / a specific session, not written by a global hook that
doesn't distinguish the source. This is wave 2 of the restart pack (the authors' internal
audit), the implementation is waiting its turn — until then, silent-failure diagnosis is
checked by hand by matching the session PID.

---

## 11. PostToolUse blindness on long tasks

**Symptom:** a live channel session, in the middle of a long legitimate task (a build, tests,
a 10+ minute council), suddenly restarts — the work is lost.

**Root cause:** the activity marker (`last_activity`) is updated by the `PostToolUse` hook —
that is, AFTER a tool finishes. One long tool call (20+ minutes) produces no events at all
between start and finish — from the outside it's indistinguishable from a hung session:
`IDLE` grows, the `ACTIVITY_GRACE` threshold is exceeded, the watchdog decides "failure" and
restarts a working session.

**How it's closed:** a writing gate in Check 6 (`watchdog-claude-telegram.sh`) — instead of a
child-process counter it checks the mtime of the session's jsonl transcript: it's updated in
real time on any activity (response stream, tool calls, intermediate results), even if
`PostToolUse` hasn't fired yet. As long as the transcript is "fresh" (younger than
`ACTIVITY_GRACE`), the kill is deferred. A separate safeguard against inversion: incoming
messages from the owner also move the transcript's mtime, so the deferral is capped by a
ceiling `DEFER_MAX` — beyond that we kill despite the "freshness".

---

## 12. Flapping without escalation — restarts in circles instead of a fix

**Symptom:** the watchdog honestly notifies "the channel has restarted N times and isn't
healing", but keeps doing EXACTLY THE SAME — an ordinary `--continue` restart — endlessly.
The notification is there, but the behavior doesn't change.

**Root cause:** a flapping detector (a restart counter over a window) existed, but was purely
informational — it didn't affect the choice of action. There was no next step: if an ordinary
restart doesn't help N times in a row, it makes sense to try something else (a clean start) or
to stop altogether and not waste attempts in vain.

**How it's closed:** the `decide_restart()` ladder — step 0 (ordinary `--continue`) up to
`FLAP_LIMIT` flaps in the window, step 1 (`restart_fresh`, a clean start with no memory) up to
`FRESH_LIMIT` attempts, step 2 (`escalate_backoff`, exponential backoff 900→1800→3600s) —
restarts stop entirely, the notification directly asks for the owner's intervention. The
flapping-window threshold was additionally calibrated against reality: with the original
30-minute window and a 15-minute restart cooldown, the oldest record fell out of the window
before the counter could reach the threshold — escalation was mathematically unreachable. The
window was widened so the ladder actually works, rather than existing only in the code.

---

## 13. OOM without swap — the watchdog and the channel can become random victims

**Symptom:** didn't manifest directly as a channel failure (yet), but recorded in the live
system: the OOM killer fired twice in a single day, killing processes with large RSS.

**Root cause:** the machine has no swap with limited RAM. Neither the channel session nor
cron (under which the watchdog runs) is protected by `OOMScoreAdjust` — under memory pressure
the kernel can kill either of them as a random victim, and then the failure will look
mysterious: processes simply vanish with no diagnosable cause in the application log.

**How it's closed:** for now — only recorded as an open risk in the survivability audit (the
authors' internal audit, the "infra" section); the solution (swap + `MemoryMax`/`MemoryHigh`
+ `OOMScoreAdjust` for the channel and adjacent services) is scheduled as a separate wave, not
implemented in code at the time this document was written. Stated deliberately — so a future
reader knows: "the watchdog is bulletproof" does not mean "the machine is bulletproof".

---

## 14. The watchdog didn't tell "its own" plugin from foreign node processes

**Symptom:** the telegram plugin (the bun process) actually died, the bot isn't answering, but
`claude-telegram.log` is silent for days — the watchdog doesn't restart, as if all is well.

**Root cause:** an early version of Check 4 looked in the session's process tree for ANY child
process `bun` OR `node`. But other node-based MCP servers (memory, reviewer, analytics) were
running in the same session — they were always alive, so the check always found "at least
something" and considered the plugin operational, even when the telegram plugin itself had
been dead for a long time.

**How it's closed:** precise detection — searching for exactly the telegram plugin's process
via the plugin's install path (`claude-plugins-official/telegram`), and then via `bot.pid`
tied to the process tree of the specific channel session. The generic `pgrep -f (bun|node)`
was removed entirely.

---

## 15. "Alive-but-frozen": the process is alive, but the channel is dead

**Symptom:** the plugin's bun process exists (the "is the process alive" check passes), but
the bot silently stopped answering. No restart happens, because formally everything is
"green".

**Root cause:** the fact that a process exists proves only that a wrapper process exists. The
actual I/O with Telegram is done by a child worker holding a long-poll TLS connection to
`api.telegram.org:443`. If the worker lost the connection and isn't reconnecting, the wrapper
stays alive — the "the process is there" check is green, while the channel is effectively
dead.

**How it's closed:** a functional check (Check 5) instead of an existence check: a healthy
poller ALWAYS holds at least one `ESTABLISHED` TCP connection to port 443 (the plugin doesn't
go anywhere except Telegram). The whole tree of the plugin process's descendants is gathered,
and if none of them has an established connection older than the grace period (5 minutes, so
as not to catch the split second between long-polls) — the channel is considered frozen and
goes into the restart ladder.
