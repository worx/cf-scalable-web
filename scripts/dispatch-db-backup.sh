#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/dispatch-db-backup.sh
#
# Mac-side wrapper: fire db-backup on the deploy-host via SSM.
# Dispatches walk-away safe (survives Mac session timeout / sleep).
#
# Mirrors the inline-SSM pattern of scripts/clear-drupal-cache.sh.
# The migration-scoped dispatcher (migration/scripts/_ssm-run-deploy-host.sh)
# handles migration-family scripts that need _common.sh; db-backup.sh
# is standalone, so a small inline dispatch is simpler than extending
# the general dispatcher.
#
# Usage: scripts/dispatch-db-backup.sh <env> [db_name]
# Example:
#   scripts/dispatch-db-backup.sh sandbox           # DB defaults to drupal
#   scripts/dispatch-db-backup.sh sandbox drupal
#
# Output:
#   - Status/progress to stderr
#   - New backup DB name to stdout (one line) — parseable by chain callers
#
# Env passed through to remote:
#   CONFIRMED=yes  (always injected — dispatcher is non-interactive)
#   DB=<db_name>   (from arg $2, defaults to drupal)

set -euo pipefail

ENV="${1:-}"
DB_NAME="${2:-drupal}"

if [ -z "$ENV" ]; then
  echo "Usage: $0 <env> [db_name]" >&2
  exit 1
fi

DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  echo "ERROR: deploy-host not running. Start it (make resume-deploy-host) and retry." >&2
  exit 1
fi
echo "Deploy-host: $DEPLOY_ID" >&2
echo "Dispatching db-backup for env=$ENV DB=$DB_NAME..." >&2

# Inner script. Pulls latest git first so any local edits to db-backup.sh
# take effect without a separate deploy step. CONFIRMED=yes because SSM
# is non-interactive.
INNER_SCRIPT=$(cat <<EOF_INNER
#!/bin/bash
set -e
cd /home/ubuntu/projects/cf-scalable-web
git pull --quiet
CONFIRMED=yes DB="$DB_NAME" sudo -E scripts/deploy-host/db-backup.sh "$ENV" "$DB_NAME"
EOF_INNER
)

B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d > /tmp/dispatch-db-backup.sh && bash /tmp/dispatch-db-backup.sh\"]}" \
  --query 'Command.CommandId' --output text)
echo "CommandId: $CMD_ID" >&2

# Poll for completion — db-backup is fast (sub-second SQL work) but
# allow up to 5 min for SSM overhead / delayed instances.
echo -n "Waiting for completion" >&2
for _ in $(seq 1 100); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) echo -n "." >&2; sleep 3 ;;
    *) echo " $STATUS." >&2; break ;;
  esac
done

# Fetch stdout and stderr separately. db-backup.sh writes the backup
# name to stdout (single line) and status to stderr.
STDOUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
STDERR=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardErrorContent' --output text 2>/dev/null || echo "")

# Show status output to operator
if [ -n "$STDERR" ]; then
  echo "" >&2
  echo "--- deploy-host stderr ---" >&2
  echo "$STDERR" >&2
fi

# Surface non-Success
if [ "$STATUS" != "Success" ]; then
  echo "" >&2
  echo "ERROR: dispatch-db-backup failed with status: $STATUS" >&2
  exit 1
fi

# Extract backup name — db-backup.sh's stdout is a single line
BACKUP_NAME=$(printf '%s' "$STDOUT" | tail -n1 | tr -d '[:space:]')
if [ -z "$BACKUP_NAME" ]; then
  echo "ERROR: could not parse backup DB name from remote output" >&2
  echo "Raw stdout was: <<<$STDOUT>>>" >&2
  exit 1
fi

echo "" >&2
echo "OK: backup DB created on deploy-host: $BACKUP_NAME" >&2

# Machine-parseable — captured by chain callers
echo "$BACKUP_NAME"
