# Channel hooks

*Russian version: [README.md](README.md)*

`settings-fragment.json` — only the communication-scaffolding hooks (`core/*.sh`), pulled
out of the production `~/.claude/settings.json`. The paths in it are `/home/ubuntu/core/...`:
copy the contents of `seamkeeper/core/` there (see `docs/SETUP.en.md`), or fix the paths for
your own directory before pasting.

> **Different user / home directory?** The paths in this fragment (and in all `core/`
> scripts) are hardcoded to `/home/ubuntu`. If your user isn't `ubuntu`, fix the paths in
> `settings-fragment.json` BEFORE pasting — or paste it as is and then run this on the copied
> `~/core`:
> `grep -rl '/home/ubuntu' ~/core | xargs sed -i "s|/home/ubuntu|$HOME|g"`
> (see the warning in `docs/SETUP.en.md`), and don't forget to fix the commands in
> `settings-fragment.json` in sync — a sed over `~/core` won't touch them, since they live in
> `~/.claude/settings.json`, not in `~/core`.

At the top level of the fragment there's also `"skipDangerousModePermissionPrompt": true`.
Without it the first channel start hangs on the interactive confirmation "you are running
with --dangerously-skip-permissions, are you sure?" — and there's no one to press Enter in a
headless tmux session brought up from cron/systemd: the channel goes silent as if frozen,
while it's just waiting for a keypress.

What each hook does:

- **PreToolUse → `cli-digest.sh`** — a live digest of "what the agent is doing right now"
  into a single self-updating Telegram message (doesn't flood).
- **PreToolUse / PostToolUse → `channel-heartbeat.sh activity`** — a "work in progress"
  marker, suppresses false alarms on long tasks.
- **UserPromptSubmit → `channel-heartbeat.sh prompt`** — a "message received" marker.
- **Stop → `channel-heartbeat.sh stop`** — an "answer delivered" marker; together with
  `prompt`/`activity` it feeds the silent-failure detector.
- **Stop → `reply-guard.sh`** — prevents a turn from finishing if the owner got a message but
  no answer went out through `reply`.
- **PostToolUse (matcher: reply/edit_message) → `conv-mirror.sh`** — mirrors sent replies to
  a log with a delivered/not-delivered mark + an emergency push on failure.

## Installation

If your `~/.claude/settings.json` is still empty/default — you can just copy
`settings-fragment.json` over it (after making a backup). But if it already has your own hooks
or settings — a manual merge is easy to break (mismatched braces, accidentally overwriting
someone else's hooks array instead of merging). Below is a ready-made merge script that does
this safely and idempotently (a repeat run won't duplicate hooks).

1. Save the script as `merge_hooks.py` (can be next to `settings.json`):

   ```python
   #!/usr/bin/env python3
   # Merges hooks/settings-fragment.json into ~/.claude/settings.json without
   # touching existing hooks and keys. Always backs up; idempotent — rerun is safe.
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
               print(f"WARNING: '{key}' current={target[key]!r}, in fragment={value!r} — "
                     f"keeping your value, check manually")

       with open(target_path, "w") as f:
           json.dump(target, f, indent=2, ensure_ascii=False); f.write("\n")
       print(f"Merged. Verify: python3 -m json.tool {target_path}")

   if __name__ == "__main__":
       main()
   ```

2. Run it:
   ```bash
   python3 merge_hooks.py ~/.claude/settings.json seamkeeper/hooks/settings-fragment.json
   ```
   The script makes a backup `~/.claude/settings.json.bak.<timestamp>` itself before editing.
3. Check validity: `python3 -m json.tool ~/.claude/settings.json`.
4. The hooks are picked up automatically when the next Claude Code session starts — nothing
   needs to be restarted separately.

The script has been tested on a couple of test json files (existing hooks of another event +
a repeat run) — it creates no duplicates and doesn't touch other hooks or keys.
