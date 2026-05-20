# Project Memory

This folder contains version-controlled memory files that persist operational
knowledge across Claude Code sessions. When a new conversation starts, Claude
reads all files in this folder automatically.

## How It Works

- **This folder** (`docs/memory/`) is the source of truth — version controlled in git
- **One stub** in `~/.claude/projects/{path}/memory/MEMORY.md` tells Claude to read this folder
- Edit, add, rename, or delete files here freely — no sync needed

## File Format

Each file uses YAML frontmatter:

```markdown
---
name: Short descriptive name
description: One-line summary
type: project | feedback | reference | user
created: YYYY-MM-DD
---

Content here...
```

Field notes:
- **type** matches the auto-memory taxonomy: `project` (ongoing state),
  `feedback` (user preferences), `reference` (external system pointers),
  `user` (user identity).
- **created** is the date the memory was first written. Optional, but
  useful — pair with the timestamps in `PROMPT_LOGS/` to find the
  originating conversation if you ever need to.
- (Older files may have a deprecated `originSessionId` field — that was
  Claude's session ID. Being phased out per 2026-05-20 conversation;
  if you see one, it's safe to remove.)

## Current Files

| File | Type | Purpose |
|------|------|---------|
| `architecture-reference.md` | project | Stack names, deploy sequence, SSM params, boot flow |
| `gotchas.md` | project | Hard-won debugging lessons — things that broke and why |
| `admin-access-policy.md` | project | SSM-only ingress rule + scp-via-SSM-proxy pattern |
| `destroy-all-residue.md` | project | What survives `make destroy-all`; cleanup design options |
| `ssm-new-experience-decision.md` | project | Why we disabled AWS SSM Quick Setup / DHMC; rollback playbook |
| `user-preferences.md` | feedback | Kurt's working style, git workflow, naming conventions |

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
