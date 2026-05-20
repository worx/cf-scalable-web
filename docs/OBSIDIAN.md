# Browsing the project docs with Obsidian

This project ships with an Obsidian vault configuration so you can read,
search, and cross-navigate the documentation without using IntelliJ, VS
Code, or any other code editor. Obsidian renders Markdown beautifully,
indexes everything full-text, and shows backlinks between documents — so
you can follow an idea from one doc to the next without going back to a
file tree.

If you're contributing code, you'll likely still want a real editor.
Obsidian is intentionally framed here as a **reader's tool** for users
and guests — anyone who wants to understand what this project does,
how to operate it, and what's been learned along the way, without first
becoming a developer.

## What you'll see (and what's hidden)

The vault config in `.obsidian/app.json` hides folders that aren't
documentation:

| Hidden in Obsidian | Why |
|---|---|
| `cloudformation/` | Templates — read in a code editor, not here |
| `image-builder/` | Build configs — same |
| `scripts/` | Shell scripts — same |
| `tests/` | Test code — same |
| `deploy-host/` | Operator-side tooling — same |
| `PROMPT_LOGS/` | ISO 27001 audit trail — noisy, not useful for browsing |

What remains visible in the sidebar: `README.md`, `TODO.md`, the
contents of `docs/` (including `docs/memory/` and `docs/plans/`), and
the LICENSE. That's the doc set.

## One-time setup

1. **Install Obsidian** if you don't have it:
   - macOS: `brew install --cask obsidian` (or download from
     [obsidian.md](https://obsidian.md/))
   - Other platforms: see the Obsidian website.
2. **Open Obsidian.** First launch shows a vault picker.
3. **Click "Open folder as vault"** (in the lower-left of the picker, or
   from the vault-switcher dropdown in the top-left of any open vault).
4. **Navigate to and select the project directory** (the folder that
   contains this `README.md`, the `docs/` folder, and the hidden
   `.obsidian/` folder). Obsidian sees the `.obsidian/` config and opens
   the project as a configured vault — folders are filtered, settings
   are applied, no further config needed.

Obsidian remembers the vault location, so future runs reopen it
directly from the vault switcher.

## Recurring use — open from the command line

From the project root, on macOS:

```bash
open -a obsidian .
```

This launches Obsidian with the current directory as the active vault.
The `.` is the working directory; Obsidian sees the `.obsidian/`
config and uses the existing vault settings.

Tip: alias it if you'll do this often:

```bash
# In ~/.zshrc or ~/.bashrc
alias docs='open -a obsidian .'
```

Then from the project root, just `docs` and you're in.

## What you can do once it's open

- **Read any doc** — `README.md` opens by default. Clicking any
  inline link (`[text](docs/OTHER.md)`) navigates to that file in
  Obsidian, in the same window.
- **Navigate back and forward** — `Cmd+Alt+Left` (back), `Cmd+Alt+Right`
  (forward), browser-style. There are also arrows in the top-left of
  the reading pane, but the keyboard shortcuts are faster.
- **Search across all docs** — `Cmd+Shift+F` (macOS) / `Ctrl+Shift+F`
  (others) searches the full text of every visible doc.
- **Quick switcher** — `Cmd+O` / `Ctrl+O` opens a name-search to jump
  to any file in the vault.
- **Backlinks panel** — opens automatically with each file; shows
  every other doc that links to the file you're reading. Useful for
  "what else mentions this concept?"
- **Outline panel** — shows the heading hierarchy of the current
  file. Useful for long docs like `docs/ARCHITECTURE.md`.

## Not using Obsidian? You're not stuck.

Every doc in this project is plain Markdown with standard `[text](path)`
links — readable in GitHub, IntelliJ, VS Code, any Markdown viewer, or
even `less`. Obsidian is a comfortable reader; it's not a requirement.

## I'm a contributor, not just a reader. Should I use Obsidian?

If you're editing docs (not code): yes, it's pleasant. Obsidian's editor
is good for prose and renders Markdown live.

If you're editing CloudFormation templates, shell scripts, or anything
code-shaped: use your code editor. The Obsidian vault filters those
folders out for a reason — they're not Obsidian-shaped.

Many of us run both: code editor open for source, Obsidian open for the
docs we're cross-referencing.

---

<sub>**License:** GPL-2.0-or-later | **Copyright:** © 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>
