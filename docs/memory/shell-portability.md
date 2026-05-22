---
name: Shell portability — Kurt runs zsh on macOS
description: Avoid Bash-4+-only expansions in snippets meant for Kurt's terminal; he is on zsh
type: feedback
created: 2026-05-21
---

# Shell portability for command-line snippets

Kurt operates from zsh on macOS. Snippets I hand him to paste must be
**zsh-compatible**, not just bash-compatible.

## The rule

When writing one-off shell snippets for Kurt to paste into his terminal,
**avoid Bash-4+-only parameter expansions**. zsh either errors with "bad
substitution" or silently expands to empty, which produces misleading
downstream errors (e.g. "Invalid length for parameter, value: 0").

## Why this matters

The failure mode is subtle: zsh's "bad substitution" message is printed to
stderr but the substitution itself returns an empty string, which then
flows into the next command and produces a different, misleading error.
Operators (Kurt included) spend time chasing the symptom instead of the
empty-string root cause. Past incident: 2026-05-21, ASG instance-refresh
snippet in DNS publishing runbook used `${V^^}` and Kurt got
`ParamValidation: value: 0` from autoscaling.

## Common Bash-4+ extensions that fail in zsh

| Bash-only | zsh-compatible equivalents |
|-----------|---------------------------|
| `${var^^}` (uppercase all) | `${(U)var}` (zsh-native) OR `$(echo "$var" \| tr a-z A-Z)` (portable) |
| `${var,,}` (lowercase all) | `${(L)var}` OR `$(echo "$var" \| tr A-Z a-z)` |
| `${var^}` (uppercase first char) | `${(C)var}` (titlecase) OR sed |
| `mapfile`, `readarray` | Use `while read` loop |
| Associative arrays w/ `declare -A` | Both shells support, but syntax for iteration differs |

## How to apply

1. **Default to "portable" forms** when the snippet is for paste-into-terminal.
   Often simpler to just enumerate the values explicitly instead of
   computing them — `for X in FOO BAR` beats `for v in foo bar; do X=${v^^}`.
2. **Reserve Bash-isms** for scripts that start with `#!/bin/bash`. Those
   pin the interpreter and can use whatever Bash supports.
3. **Heredoc'd scripts** sent via SSM `AWS-RunShellScript` run under sh
   (Amazon Linux) or bash (Ubuntu) — those can use Bash extensions, but
   keep an eye on which shell the target distro uses.

## Detection

If a snippet I propose includes `${...^...}`, `${...,...}`, `mapfile`, or
`readarray`, double-check it before sending. Either translate to portable
form, or annotate it as "run this in bash" and provide a `bash -c '...'`
wrapper.
