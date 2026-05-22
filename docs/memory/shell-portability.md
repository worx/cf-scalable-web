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

## Word-splitting (the silent footgun)

The biggest difference between bash and zsh isn't a missing feature — it's
that **zsh does not word-split unquoted variable expansions by default**.
This bites hardest with AWS CLI snippets that capture multi-value `--output
text` results into a variable and then pass them as separate args.

**Failing pattern (works in bash, fails in zsh):**
```bash
IDS=$(aws ... --output text)   # IDS = "i-aaa    i-bbb" (tab-separated)
aws ssm send-command --instance-ids $IDS ...
# bash:  passes ["i-aaa", "i-bbb"] (auto-splits on $IFS)
# zsh:   passes ["i-aaa    i-bbb"] (one big string) → ValidationException
```

The zsh failure mode is **not** "bad substitution" — the snippet runs but
the downstream API call rejects it with a misleading validation error.
Symptom from 2026-05-22: `1 validation error detected: Value
'[i-aaa    i-bbb]' at 'instanceIds' failed to satisfy constraint`.

**Fixes (any of these is correct):**

1. **Array form (recommended for paste-in-terminal snippets):**
   ```bash
   IDS=( $(aws ... --output text) )
   aws ssm send-command --instance-ids "${IDS[@]}" ...
   ```
   Works in bash and zsh identically. `"${IDS[@]}"` always expands each
   element as a separate argument.

2. **zsh-specific force-split:** `${=IDS}` enables word-splitting on that
   expansion. zsh-only; doesn't break bash, but obscure for bash readers.

3. **Inline the substitution:** `aws ssm send-command --instance-ids
   $(aws ... --output text) ...` — relies on word-splitting at command
   substitution; this DOES word-split in both shells, but only the
   command-substitution result, not a previously-assigned variable.

**Default to (1)** — it's the readable, portable form. Bonus: makes the
script's intent obvious ("this is a list of things").

## Scripts vs paste-snippets — different rules

- **Scripts** with `#!/bin/bash` shebang run under bash regardless of
  Kurt's login shell. Bash-isms are fine in those. The two SSM-dispatch
  scripts (`reload-nginx.sh`, `restart-php-fpm.sh`) use `--instance-ids
  $IDS` unquoted and it works because their shebang pins bash.
- **Paste-in-terminal snippets** I send Kurt run under zsh. Apply the
  portable forms above — array-style is the safe default.

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
