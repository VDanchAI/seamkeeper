# The memory system — why the agent remembers you across restarts

*Russian version: [README.md](README.md)*

Without memory, every restart = an amnesiac agent. Here's the three-layer schema our system
has lived on for half a year. Copy the templates, fill them with your own.

## Layer 1. Startup rules — `CLAUDE.md` (loaded EVERY start)

A file in the root of the home directory (or the project). It's the "firmware": the rules the
agent sees at the start of any session, before any memory. Only put here what must ALWAYS
work:

- security rules ("secrets never through chat");
- delivery rules ("the answer to the owner — only through the reply tool, text in the
  terminal doesn't reach them");
- the project map and entry points.

Template: [CLAUDE.md.template](CLAUDE.md.template)

## Layer 2. File-based memory — `memory/` + `MEMORY.md` (the index)

Each fact is a separate `.md` file with frontmatter. `MEMORY.md` is a table of contents, one
line per fact, and it's loaded into context; the files themselves the agent reads as needed.

Four types of entries:
| Type | What it stores | Example |
|---|---|---|
| `user` | who the owner is: role, style, preferences | "direct style, Russian, explain terms" |
| `feedback` | how the owner asked to work (with the REASON) | "ask about unclear things before starting — saves tokens" |
| `project` | state of affairs not derivable from the code | "vector search: hypothesis proven, awaiting a decision" |
| `reference` | links to external things | "metrics dashboard: URL" |

Rules hard-won in practice:
- **one entry = one fact** (not a dump);
- **feedback always has a "why" and a "how to apply"** — without it the rule dies;
- links between entries — `[[name-of-another-entry]]`;
- what's outdated — delete or mark with a date: memory is a snapshot, not an eternal truth;
- before writing — check whether a file about it already exists: update, don't breed
  duplicates.

Templates: [memory-examples/](memory-examples/)

## Layer 3. Long history — claude-mem (optional, third-party plugin)

The [claude-mem](https://github.com/thedotmack/claude-mem) plugin automatically compresses
every session into observations and gives search across months of work ("how did we fix X in
June?"). It's installed on top, it doesn't replace layers 1-2: those are curated facts, this
is a raw archive of everything.

## How the layers work together at a restart

1. Session start → CLAUDE.md (rules) + MEMORY.md (the index of facts) are loaded.
2. For the task, the agent reads the needed memory/*.md.
3. Continuing an interrupted conversation — `--resume <session_id>` in the start script
   (see core/start-claude-telegram.sh): the agent returns to the SAME conversation.
4. At the end of significant work → the agent appends to / updates memory. The circle is
   closed.
