#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/deploy-host/bootstrap.sh
#
# Deploy-host bootstrap. Called once from UserData on first boot; can also be
# re-run manually on a running deploy host to refresh the toolchain after
# pulling changes from the repo.
#
# Usage (UserData):  bash /home/ubuntu/projects/cf-scalable-web/scripts/deploy-host/bootstrap.sh
# Usage (manual):    sudo bash ~/projects/cf-scalable-web/scripts/deploy-host/bootstrap.sh
#
# Design:
#   - set -e + ERR trap reports the failing line and last step name
#   - set -x is enabled so every command lands in the log
#   - step() prints a clear marker plus memory/disk snapshot before each section
#   - all operations are idempotent (re-runnable safely)
#

set -euo pipefail

# Ensure logs go to the bootstrap log even when run manually
LOG_FILE="/var/log/deploy-host-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ----- error reporting -----
LAST_STEP="(none)"
on_err() {
  local exit_code=$?
  echo ""
  echo "============================================"
  echo "=== BOOTSTRAP FAILED"
  echo "=== exit code: $exit_code"
  echo "=== last step: $LAST_STEP"
  echo "=== line:      $LINENO"
  echo "=== mem:       $(free -h 2>/dev/null | awk '/^Mem:/ {print $3"/"$2}')"
  echo "=== disk /:    $(df -h / 2>/dev/null | awk 'NR==2 {print $3" used / "$2" total ("$5" full)"}')"
  echo "============================================"
}
trap on_err ERR

step() {
  LAST_STEP="$*"
  echo ""
  echo "============================================"
  echo "STEP: $LAST_STEP"
  echo "  time:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "  mem:     $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
  echo "  disk /:  $(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')"
  echo "============================================"
}

# ----- defensive env -----
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
# AWS_DEFAULT_REGION is normally set by /etc/profile.d/deploy-host-env.sh, but
# during first-boot UserData that file may not be sourced yet. Defensive default.
if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
  AWS_DEFAULT_REGION=$(curl -sS http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
  export AWS_DEFAULT_REGION
fi

# Trace mode for full visibility in the log
set -x

# ============================================================
step "apt update + best-effort upgrade"
# ============================================================
apt-get update -y
apt-get upgrade -y || apt-get upgrade -y --fix-missing || echo "WARN: apt upgrade had issues, continuing"

# ============================================================
step "Core CLI tools"
# ============================================================
apt-get install -y \
  make \
  screen \
  tmux \
  tree \
  vim \
  python3-pip \
  python3-venv

# ============================================================
step "Editor defaults + profile.d env"
# ============================================================
update-alternatives --set editor /usr/bin/vim.basic
cat > /etc/profile.d/deploy-host-env.sh <<ENVEOF
export EDITOR=vim
export VISUAL=vim
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
ENVEOF
su - ubuntu -c 'git config --global core.editor vim' || true

# ============================================================
step "/home/ubuntu/.aws README"
# ============================================================
mkdir -p /home/ubuntu/.aws
cat > /home/ubuntu/.aws/README.md << 'AWSEOF'
# AWS Credentials on Deploy Host

This instance uses an IAM Instance Role for AWS access.
No access keys or credentials files are needed.

The instance role provides AdministratorAccess to this
AWS account via the EC2 instance metadata service (IMDS).

All AWS CLI commands work automatically:
  aws sts get-caller-identity    # verify your identity
  aws s3 ls                      # list buckets
  aws cloudformation list-stacks # list stacks

The default region is set via /etc/profile.d/deploy-host-env.sh.
Override per-command with: --region us-west-2
Override per-session with: export AWS_DEFAULT_REGION=us-west-2

DO NOT place access keys on this instance.
The instance role is more secure (automatic rotation, no key files).
AWSEOF
chown -R ubuntu:ubuntu /home/ubuntu/.aws

# ============================================================
step "Root password from Secrets Manager (optional, non-fatal)"
# ============================================================
ROOT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "worxco/deploy-host/root-password" \
  --region "$AWS_DEFAULT_REGION" \
  --query 'SecretString' \
  --output text 2>/dev/null) || ROOT_PASS=""
if [ -n "$ROOT_PASS" ]; then
  echo "root:$ROOT_PASS" | chpasswd
  echo "Root password set from Secrets Manager"
  unset ROOT_PASS
else
  echo "WARN: worxco/deploy-host/root-password not found in Secrets Manager - skipping"
fi

# ============================================================
step "cfn-lint (in /opt/cfn-lint venv)"
# ============================================================
python3 -m venv /opt/cfn-lint --system-site-packages
/opt/cfn-lint/bin/pip install --upgrade cfn-lint
ln -sf /opt/cfn-lint/bin/cfn-lint /usr/local/bin/cfn-lint

# ============================================================
step "Node.js 20 LTS"
# ============================================================
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# ============================================================
step "Claude Code CLI (npm global)"
# ============================================================
npm install -g @anthropic-ai/claude-code

# ============================================================
step "SSM agent (snap)"
# ============================================================
snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# ============================================================
step "Drupal management apt packages (NFS, psql, sqlite, redis-cli, PHP 8.3 + 12 extensions)"
# ============================================================
apt-get install -y \
  nfs-common \
  postgresql-client \
  sqlite3 \
  redis-tools \
  php8.3-cli \
  php8.3-common \
  php8.3-curl \
  php8.3-mbstring \
  php8.3-xml \
  php8.3-zip \
  php8.3-gd \
  php8.3-pgsql \
  php8.3-sqlite3 \
  php8.3-intl \
  php8.3-bcmath \
  php8.3-opcache

# ============================================================
step "Composer (latest stable)"
# ============================================================
curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm /tmp/composer-setup.php
ls -la /usr/local/bin/composer

# ============================================================
step "Drush (composer global, as ubuntu)"
# ============================================================
su - ubuntu -c 'composer global require drush/drush' \
  || echo "WARN: drush install failed (non-fatal — install manually if needed)"

# Add composer global bin to ubuntu PATH (idempotent)
if ! grep -q "composer/vendor/bin" /home/ubuntu/.bashrc 2>/dev/null; then
  echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> /home/ubuntu/.bashrc
fi

# ============================================================
step "AWS Session Manager plugin"
# ============================================================
curl -sS \
  "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" \
  -o /tmp/session-manager-plugin.deb
dpkg -i /tmp/session-manager-plugin.deb || true
rm -f /tmp/session-manager-plugin.deb

# ============================================================
step "Worxco config directories + deploy-host marker"
# ============================================================
mkdir -p /etc/worxco/envs
chmod 755 /etc/worxco /etc/worxco/envs
echo "deploy-host" > /etc/worxco/deploy-host-marker
chmod 644 /etc/worxco/deploy-host-marker

# ============================================================
step "Install endpoint helper scripts from repo"
# ============================================================
REPO_DIR="/home/ubuntu/projects/cf-scalable-web"
if [ ! -d "$REPO_DIR/scripts/deploy-host" ]; then
  echo "ERROR: $REPO_DIR/scripts/deploy-host not found — repo not cloned?"
  exit 1
fi
install -m 0755 "$REPO_DIR/scripts/deploy-host/info-env"           /usr/local/bin/info-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/show-env"           /usr/local/bin/show-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/psql-env"           /usr/local/bin/psql-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/valkey-env"         /usr/local/bin/valkey-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/mount-env"          /usr/local/sbin/mount-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/refresh-env-config" /usr/local/sbin/refresh-env-config
install -m 0440 "$REPO_DIR/scripts/deploy-host/worxco-refresh-env-config.sudoers" /etc/sudoers.d/worxco-refresh-env-config

# ============================================================
step "First refresh-env-config (best-effort, populates /etc/worxco/envs/*)"
# ============================================================
/usr/local/sbin/refresh-env-config sandbox staging production || \
  echo "WARN: refresh-env-config had no envs to refresh (none deployed yet?)"

# ============================================================
step "Auto-mount FSx for any deployed environments"
# ============================================================
# After refresh-env-config populates /etc/worxco/envs/<env> for envs that
# have infrastructure deployed, ensure FSx is mounted for each. mount-env
# also writes /etc/fstab so the mount survives stop/start of this instance.
#
# This is best-effort: a failed mount logs a WARN and continues. The user
# can run `sudo mount-env <env>` manually to retry.
if [ -d /etc/worxco/envs ]; then
  for envfile in /etc/worxco/envs/*; do
    [ -f "$envfile" ] || continue
    env_name=$(basename "$envfile")
    fsx_dns=$(grep '^FSX_DNS=' "$envfile" | cut -d= -f2-)
    if [ -n "$fsx_dns" ] && [ "$fsx_dns" != "" ]; then
      echo "Mounting FSx for $env_name..."
      /usr/local/sbin/mount-env "$env_name" || \
        echo "  WARN: mount-env $env_name failed (non-fatal)"
    fi
  done
else
  echo "No /etc/worxco/envs/ — skipping auto-mount"
fi

# ============================================================
step "MOTD"
# ============================================================
cat > /etc/motd <<MOTDEOF

============================================
  cf-scalable-web Deploy Host
============================================

Quick Start:
  cd ~/projects/cf-scalable-web
  tmux new -s deploy
  make deploy-all ENV=sandbox
  # Ctrl-B D to detach

Reconnect:
  tmux attach -t deploy

Access: SSM Session Manager only (no SSH)
AWS:    Instance role provides AdministratorAccess
Region: $AWS_DEFAULT_REGION (override with export AWS_DEFAULT_REGION=...)
Tools:  aws, git, make, tmux, screen, vim, claude
        php, composer, drush, psql, redis-cli, mount-env

Project helpers (auto-resolve endpoints — no manual lookups):
  info-env sandbox                  # live endpoints from SSM
  show-env sandbox                  # cached endpoints (instant)
  source /etc/worxco/envs/sandbox   # exports DRUPAL_DB_HOST, FSX_DNS, etc.
  sudo refresh-env-config sandbox   # rebuild cache from SSM
  sudo mount-env sandbox            # mount FSx at /var/www/sandbox
  psql-env sandbox                  # psql shell against env's RDS
  psql-env sandbox -c "SELECT now();"
  valkey-env sandbox PING           # Valkey/Redis CLI

Drupal management (after sandbox is fully deployed):
  cd /var/www/sandbox/drupal        # navigate to Drupal install
  drush cr                          # clear caches
  drush updb -y                     # apply pending DB updates

MOTDEOF

# Show motd on interactive bash sessions (idempotent)
if ! grep -q "MOTD_SHOWN" /home/ubuntu/.bashrc 2>/dev/null; then
  cat >> /home/ubuntu/.bashrc << 'RCEOF'

# Show motd on interactive login
if [ -f /etc/motd ] && [ -z "$MOTD_SHOWN" ]; then
  cat /etc/motd
  export MOTD_SHOWN=1
fi
RCEOF
fi
chown ubuntu:ubuntu /home/ubuntu/.bashrc

# ============================================================
step "Bootstrap complete"
# ============================================================
LAST_STEP="(complete)"
echo ""
echo "============================================"
echo "  Deploy host bootstrap finished $(date)"
echo "============================================"
echo "SUCCESS" > /var/log/deploy-host-bootstrap-status
