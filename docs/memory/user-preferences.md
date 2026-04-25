---
name: User Preferences and Working Style
description: Kurt's preferences for how we work together on this project
type: feedback
originSessionId: f483de33-7dee-4185-b1a3-72a0ada5c58e
---
# User Preferences

## Communication
- Prefers terse, direct responses — no trailing summaries of what was just done
- Wants to understand WHY things work, not just follow instructions (gave CF training on !GetAtt, !Ref, etc.)
- Asks thoughtful architecture questions — engage, don't just prescribe
- References old memory that may be fuzzy after weeks away — help reconstruct context

## Git Workflow (CRITICAL)
- Never commit without explicit permission — write to `.git/COMMIT_MSG_DRAFT` and notify
- **Exception granted**: Kurt has been telling me to commit and push directly throughout this session
- Always `git add` specific files, never `git add -A`
- Include prompt logs in commits
- GPL-2.0-or-later headers on all source files

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

## Naming
- "Bastion" renamed to "deploy-host" — the old name caused confusion about purpose
- Redis → Valkey/cache — infrastructure references should be engine-neutral where possible
- PHP extension still called "redis" — that's the package name, not the engine
