# Project Memory

This folder contains version-controlled memory files that persist operational
knowledge across Claude Code sessions. When a new conversation starts, Claude
reads all files in this folder automatically.

## How It Works

- **This folder** (`docs/memory/`) is the source of truth — version controlled in git
- **One stub** in `~/.claude/projects/{path}/memory/MEMORY.md` tells Claude to read this folder
- Edit, add, rename, or delete files here freely — no sync needed

## File Format

Each file uses optional YAML frontmatter:

```markdown
---
name: Short descriptive name
description: One-line summary
type: architecture | gotchas | preferences | project | reference
updated: YYYY-MM-DD
---

Content here...
```

## Current Files

| File | Type | Purpose |
|------|------|---------|
| `architecture-reference.md` | architecture | Stack names, deploy sequence, SSM params, boot flow |
| `gotchas.md` | gotchas | Hard-won debugging lessons — things that broke and why |
| `user-preferences.md` | preferences | Kurt's working style, git workflow, naming conventions |

## When to Add Memory

- Debugging lessons that cost significant time to discover
- Architecture decisions and the reasoning behind them
- Deployment procedures with specific gotchas
- Account/environment details (AWS accounts, profiles, regions)

## When NOT to Add Memory

- Things derivable from code or git history
- Ephemeral task state (use TODO.md)
- Anything already in CLAUDE.md or other documentation

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
