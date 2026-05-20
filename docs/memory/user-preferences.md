---
name: User Preferences and Working Style
description: Kurt's preferences for how we work together on this project
type: feedback
created: 2026-04-25
---
# User Preferences

## Communication
- Prefers terse, direct responses — no trailing summaries of what was just done
- Wants to understand WHY things work, not just follow instructions (gave CF training on !GetAtt, !Ref, etc.)
- Asks thoughtful architecture questions — engage, don't just prescribe
- References old memory that may be fuzzy after weeks away — help reconstruct context

## Git Workflow (CRITICAL — overrides the global "never commit" default)

**Always commit + push without asking.** When changes are ready (code,
docs, config — anything tracked), the answer is always yes: stage,
commit, push.

**Why**: Kurt's view is that git's nature makes commits cheap and
recoverable. Wrong commits are an audit trail (acknowledge with a
follow-up "we decided that was bad, here's the fix" commit), not
something to delete or amend. The cost of asking-every-time exceeds the
cost of an occasional wrong commit, and the wrong commits are
recoverable anyway. Stated explicitly 2026-05-20.

**How to apply**:
- After any meaningful change, draft a commit message + commit + push in
  one motion. Do not pause for approval. Do not ask "should I commit?"
- Pipe the commit message via stdin instead of writing to
  `.git/COMMIT_MSG_DRAFT`. The draft-file pattern triggers a tool
  permission prompt for every commit (writing inside `.git/`); piping
  via `-F-` avoids it entirely. Pattern:
  ```bash
  git commit -F- <<'EOF'
  subject line

  body...

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  ```
  Then `git push origin main`.
- Still: stage specific files (`git add path/to/file`), never `git add -A`.
- Still: include prompt logs when batching housekeeping commits.
- Still: GPL-2.0-or-later headers on all source files.
- Still: never `--no-verify`, never force-push to main, never amend
  already-pushed commits.

**Open territory (not handled yet, do not initiate)**:
- Release tagging (`git tag v1.0.19`-style). Kurt has flagged this as
  potentially useful but explicitly doesn't want to design a release
  versioning scheme yet. Do not propose or apply tags unless he raises
  it first.

**One thing worth noting**: the project-level CLAUDE.md and the user's
global `~/.claude/CLAUDE.md` both have a "Never commit without explicit
permission" rule. This memory **overrides** that for this project per
the auto-memory protocol (project memory takes precedence when in
conflict with general defaults).

## AWS Workflow
- Always `source .env` or `export AWS_PROFILE=ZI-Sandbox` before AWS commands
- The `.env` file uses bare KEY=VALUE (no export) — Make reads it natively
- Run `set -a; source .env; set +a` for bash, NOT plain `source .env`
- Deploy host uses instance role — no AWS_PROFILE needed there

## Makefile Philosophy
- Errors should be human-readable — operator should never have to look up AWS error codes
- Destructive operations need confirmation prompts (unless CONFIRMED=yes from parent)
- Non-interactive chaining is important: `make deploy-all && make stop-deploy-host`
- deploy-all should work from absolute zero with no manual steps

## Testing Approach
- Wants full destroy-all + deploy-all cycles to prove everything works from scratch
- Times the runs for baseline reference (~50 min deploy-all, ~10 min database, ~12 min cache)
- Checks health via CLI target health queries, not just UI

## When Kurt makes a deliberate-looking choice, trust the deliberation

**Default to "he meant it" rather than "let me explain why that's wrong."**

**Why**: 2026-05-20 — Kurt ran `drush pmu update` to uninstall the
Update Manager module. Claude responded with a "well actually, `pmu` is
pm:uninstall and what you probably wanted is drush cron" lecture. Kurt
had to push back: he KNEW pmu was uninstall, he WANTED it uninstalled,
and the reasoning ("the architecture forbids self-update from compute,
so the module's warnings are noise about something Drupal can't act
on") was sound and consistent with the project's design. The lecture
was preachy and slowed the work down.

**How to apply**:
- When Kurt does something that looks unusual (deliberate uninstall,
  defies a "standard" pattern, chooses a less-common option), assume
  there's an architectural reason. ASK what he was solving for before
  proposing an alternative.
- If you're about to write "did you mean X?" or "you might want Y
  instead" — first ask yourself: "could there be a reason Kurt picked
  this specific path that I haven't considered?" Often yes, given the
  architecture's quirks (no NAT, immutable AMIs, separate access models
  for compute vs deploy-host, etc.).
- It's fine to propose alternatives — DO that — but frame as "here's
  another option, with these tradeoffs" rather than "you probably
  intended something else."
- After Kurt confirms his choice was deliberate, MEMORIALIZE the
  decision (project memory file) so future-you doesn't relitigate it.

## Naming
- "Bastion" renamed to "deploy-host" — the old name caused confusion about purpose
- Redis → Valkey/cache — infrastructure references should be engine-neutral where possible
- PHP extension still called "redis" — that's the package name, not the engine
