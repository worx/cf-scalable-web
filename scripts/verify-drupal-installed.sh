#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/verify-drupal-installed.sh
#
# Mac-side preflight: verify Drupal is installed on the target env's
# deploy-host BEFORE running migration. Migration is a "swap contents"
# workflow — it assumes install-drupal.sh has already produced the
# structural foundation (codebase on FSx, settings.php, salt.txt,
# the `drupal` DB in RDS).
#
# Discovered 2026-07-19: without this check, a fresh sandbox +
# migrate-full-all reaches Phase 6 (restore-private) with a working
# DB and files, then the site WSODs because settings.php's
# $settings['hash_salt'] resolves to file_get_contents('/var/www/drupal-private/salt.txt')
# and the file is missing — the atomic swap replaced it with prod's
# private/ tarball (which didn't have salt.txt).
#
# Structural checks — no reliance on the .installed marker
# (see docs/memory/structural-checks-over-markers.md):
#   1. /var/www is mounted (env's FSx via use-env)
#   2. /var/www/drupal/vendor/bin/drush is executable
#   3. /var/www/drupal/web/sites/default/settings.php exists
#   4. /var/www/drupal-private/salt.txt exists (would move to SSM later)
#
# Fails fast with a clear "run make install-drupal ENV=<env>" hint if
# any check fails. Exits 0 quietly if all pass.
#
# Usage:  scripts/verify-drupal-installed.sh <env>
# Called by:
#   - migration/Makefile: migrate-db-all (as Phase -1 preflight)
#   - top-level Makefile: verify-drupal-installed target

set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

ENV="${1:-}"
if [ -z "$ENV" ]; then
  echo "Usage: $0 <env>" >&2
  exit 2
fi

# Local log — captures the SSM command details for post-mortem.
log_init "verify-drupal-installed"
trap 'log_upload_and_exit ""' EXIT

log_step "verify-drupal-installed — preflight for env=$ENV"

DEPLOY_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=cf-deploy-host" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$DEPLOY_ID" ] || [ "$DEPLOY_ID" = "None" ]; then
  log_error "deploy-host is not running. Start it (make resume-deploy-host) and retry."
  exit 1
fi
log_info "Deploy-host: $DEPLOY_ID"

# Inline SSM check — one command, four assertions.
# Prints WHY it failed so the operator's fix is obvious.
INNER_SCRIPT=$(cat <<INNER_EOF
#!/bin/bash
FAIL=0
if ! mountpoint -q /var/www 2>/dev/null; then
  echo "FAIL: /var/www is not mounted."
  echo "      Run: sudo use-env $ENV"
  FAIL=1
fi
if [ ! -x /var/www/drupal/vendor/bin/drush ]; then
  echo "FAIL: /var/www/drupal/vendor/bin/drush not found or not executable."
  echo "      Drupal codebase is missing. Run: make install-drupal ENV=$ENV"
  FAIL=1
fi
if [ ! -f /var/www/drupal/web/sites/default/settings.php ]; then
  echo "FAIL: /var/www/drupal/web/sites/default/settings.php not found."
  echo "      Drupal settings.php is missing. Run: make install-drupal ENV=$ENV"
  FAIL=1
fi
if [ ! -f /var/www/drupal-private/salt.txt ]; then
  echo "FAIL: /var/www/drupal-private/salt.txt not found."
  echo "      Drupal hash_salt file is missing — the site would WSOD."
  echo "      Run: make install-drupal ENV=$ENV"
  FAIL=1
fi
if [ \$FAIL -eq 0 ]; then
  echo "OK: Drupal is installed on $ENV. Migration can proceed."
fi
exit \$FAIL
INNER_EOF
)
B64=$(echo "$INNER_SCRIPT" | base64 | tr -d '\n')

CMD_ID=$(aws ssm send-command \
  --instance-ids "$DEPLOY_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $B64 | base64 -d | bash\"]}" \
  --query 'Command.CommandId' --output text)
log_info "CommandId: $CMD_ID"

# Poll — should complete in seconds.
log_info "Polling for completion..."
for _ in $(seq 1 30); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress) sleep 2 ;;
    *) break ;;
  esac
done

STDOUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
STDERR=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$DEPLOY_ID" \
  --query 'StandardErrorContent' --output text 2>/dev/null || echo "")

if [ "$STATUS" = "Success" ]; then
  log_ok "Preflight passed:"
  echo "$STDOUT"
  exit 0
else
  log_error "Preflight FAILED (SSM status: $STATUS)."
  echo "$STDOUT"
  [ -n "$STDERR" ] && echo "--- stderr ---" && echo "$STDERR"
  exit 1
fi
