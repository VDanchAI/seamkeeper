#!/usr/bin/env python3
#
# ═══ ЧТО ЭТО ═══════════════════════════════════════════════════════════════
# Парсер события хука для cli-digest.sh.
#
# ═══ ЗАЧЕМ ═════════════════════════════════════════════════════════════════
# Вынесен в отдельный файл, а не встроен heredoc'ом в cli-digest.sh: наивный
# `python3 - <<HEREDOC` внутри bash-хука съедает stdin как текст самой
# программы, и json.load(sys.stdin) не видит событие — вход всегда пуст.
# Отдельный файл читает stdin по-настоящему.
#
# ═══ КАК РАБОТАЕТ ══════════════════════════════════════════════════════════
# Читает JSON события хука на stdin, печатает одну короткую строку дайджеста
# (или ничего — тогда событие пропускается вызывающим скриптом).
# ═══════════════════════════════════════════════════════════════════════════
import sys, json, os

try:
    ev = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool = ev.get("tool_name") or ev.get("tool") or ""
inp = ev.get("tool_input") or ev.get("input") or {}
if not isinstance(inp, dict):
    inp = {}

# анти-эхо: телеграм-инструменты не показываем (иначе отправка дайджеста читается как действие)
skip = {
    "mcp__plugin_telegram_telegram__reply",
    "mcp__plugin_telegram_telegram__react",
    "mcp__plugin_telegram_telegram__edit_message",
    "mcp__plugin_telegram_telegram__download_attachment",
}
if tool in skip:
    sys.exit(0)


def short(s, n=70):
    s = " ".join(str(s).split())
    return s[:n] + ("…" if len(s) > n else "")


def base(p):
    return os.path.basename(str(p)) if p else ""


if tool == "Bash":
    line = f"⚙️ {short(inp.get('description') or inp.get('command') or '')}"
elif tool in ("Edit", "Write", "NotebookEdit"):
    line = f"✏️ {base(inp.get('file_path'))}"
elif tool == "Read":
    line = f"📖 {base(inp.get('file_path'))}"
elif tool in ("Grep", "Glob"):
    line = f"🔎 {short(inp.get('pattern') or '')}"
elif tool == "Agent":
    line = f"🤖 агент: {short(inp.get('description') or inp.get('prompt') or '')}"
elif tool in ("WebFetch", "WebSearch"):
    line = f"🌐 {short(inp.get('url') or inp.get('query') or '')}"
elif tool.startswith("mcp__"):
    line = f"🔌 {tool.split('__')[-1]}"
else:
    line = f"• {tool}"

print(line)
