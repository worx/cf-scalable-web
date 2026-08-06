#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/migrate-host/bootstrap.sh
#
# Migrate-host bootstrap. Called once from UserData on first boot;
# can also be re-run manually to refresh the toolchain after a git pull.
#
# Design doc: docs/plans/migrate-host-design-2026-08-05.md
#
# Compared to scripts/deploy-host/bootstrap.sh:
#   DROPS: cfn-lint venv, Node.js 20, Claude Code CLI, PHP 8.3 + all
#          extensions, Composer, Drush, install-drupal-local pieces,
#          nfs-common (no FSx mount needed — dumps stage local),
#          use-env / valkey-env (no FSx, no Valkey).
#   KEEPS: apt updates, core CLIs (htop tmux vim zsh tree jq pv plocate),
#          editor + AWS_PAGER env, tmux config, zsh + RPROMPT,
#          .aws README, root password from Secrets Manager, SSM agent,
#          session-manager-plugin, RDS CA bundle, git safe.directory,
#          worxco config dirs, endpoint helpers (refresh-env-config,
#          psql-env, info-env, show-env — needed by run-pgloader.sh),
#          admin SSH key sync, MOTD (retargeted).
#   ADDS:  mariadb-server + mariadb-client + pgloader + postgresql-client
#          + gettext-base, /etc/mysql/mariadb.conf.d/99-migrate-host.cnf
#          bulk-load tuning drop-in (design doc §6.1), /var/tmp/migration/
#          dir for dump staging, systemctl enable --now mariadb (opposite
#          of deploy-host's disable), /etc/worxco/migrate-host-marker.
#
# Usage (UserData):  bash /home/ubuntu/projects/cf-scalable-web/scripts/migrate-host/bootstrap.sh
# Usage (manual):    sudo bash ~/projects/cf-scalable-web/scripts/migrate-host/bootstrap.sh
#

set -euo pipefail

LOG_FILE="/var/log/migrate-host-bootstrap.log"
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
if [ -z "${AWS_DEFAULT_REGION:-}" ]; then
  AWS_DEFAULT_REGION=$(curl -sS http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
  export AWS_DEFAULT_REGION
fi

set -x

# ============================================================
step "apt update + best-effort upgrade"
# ============================================================
apt-get update -y
apt-get upgrade -y || apt-get upgrade -y --fix-missing || echo "WARN: apt upgrade had issues, continuing"

# ============================================================
step "Core CLI tools (operator ergonomics)"
# ============================================================
apt-get install -y \
  htop \
  make \
  plocate \
  pv \
  screen \
  tmux \
  tree \
  vim \
  zsh \
  python3-pip \
  python3-venv

updatedb || echo "WARN: updatedb failed (non-fatal — plocate.timer will catch up)"

# ============================================================
step "Editor defaults + profile.d env"
# ============================================================
update-alternatives --set editor /usr/bin/vim.basic
cat > /etc/profile.d/migrate-host-env.sh <<ENVEOF
export EDITOR=vim
export VISUAL=vim
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
ENVEOF
su - ubuntu -c 'git config --global core.editor vim' || true

# ============================================================
step "tmux system-wide config (vi copy-mode, larger scrollback, env in status)"
# ============================================================
cat > /etc/tmux.conf <<'TMUXEOF'
# /etc/tmux.conf — system-wide tmux config for migrate-host operators.
# Managed by scripts/migrate-host/bootstrap.sh.

set -g mouse on
set -g history-limit 50000
set -g set-clipboard on
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear
set -g mode-keys vi
set -sg escape-time 10
set -g base-index 1
setw -g pane-base-index 1

# Status bar shows migrate-host marker so operator always knows which
# host they're on (deploy-host vs migrate-host — same tmux layout,
# different bar text).
set -g status-interval 5
set -g status-right-length 60
set -g status-right '#[fg=cyan][migrate-host]#[default] %H:%M'

bind r source-file /etc/tmux.conf \; display-message "tmux.conf reloaded"
TMUXEOF
chmod 0644 /etc/tmux.conf

# ============================================================
step "zsh + right-prompt migrate-host indicator"
# ============================================================
chsh -s /bin/zsh ubuntu || true

mkdir -p /etc/zsh/zshrc.d
cat > /etc/zsh/zshrc.d/worxco-prompt.zsh <<'ZSHEOF'
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
#
# Worxco migrate-host zsh interactive setup. Installed by bootstrap.sh.

autoload -U colors && colors
setopt PROMPT_SUBST

# Migrate-host doesn't have use-env (no FSx mount, no per-env active
# state). RPROMPT just shows the marker so operators can tell at a
# glance which host they're on.
PROMPT='%n@%m:%~%# '
RPROMPT='%F{cyan}[migrate-host]%f'

HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt INC_APPEND_HISTORY SHARE_HISTORY

# Treat # as comment in interactive shells (matches bash behavior;
# copy-pasted `# ...` blocks stop erroring). Same reasoning as
# deploy-host's config.
setopt INTERACTIVE_COMMENTS
ZSHEOF

# Ensure /etc/zsh/zshrc sources the drop-in dir
if ! grep -q '/etc/zsh/zshrc.d/' /etc/zsh/zshrc 2>/dev/null; then
  cat >> /etc/zsh/zshrc <<'SHRCEOF'

# Worxco drop-in dir for system-wide zsh interactive config
if [ -d /etc/zsh/zshrc.d ]; then
  for f in /etc/zsh/zshrc.d/*.zsh; do
    [ -r "$f" ] && source "$f"
  done
  unset f
fi
SHRCEOF
fi

# Per-user ~/.zshrc stub for ubuntu (silences zsh-newuser-install)
if [ ! -f /home/ubuntu/.zshrc ]; then
  cat > /home/ubuntu/.zshrc <<'ZSHRCEOF'
# Per-user .zshrc — managed by migrate-host bootstrap.sh.
# Silences zsh-newuser-install. Project config lives in
# system-wide /etc/zsh/zshrc.d/.
ZSHRCEOF
  chown ubuntu:ubuntu /home/ubuntu/.zshrc
  chmod 644 /home/ubuntu/.zshrc
fi

# Auto-exec zsh from bash on interactive logins
if ! grep -q 'NO_AUTO_ZSH' /etc/bash.bashrc 2>/dev/null; then
  cat >> /etc/bash.bashrc <<'BASHEOF'

# Worxco: auto-exec into zsh for interactive logins (escape with NO_AUTO_ZSH=1 bash)
if [[ $- == *i* ]] && [ -x /usr/bin/zsh ] && [ "${NO_AUTO_ZSH:-0}" != 1 ] && [ -z "${ZSH_VERSION:-}" ]; then
  exec zsh -l
fi
BASHEOF
fi

# ============================================================
step "/home/ubuntu/.aws README"
# ============================================================
mkdir -p /home/ubuntu/.aws
cat > /home/ubuntu/.aws/README.md << 'AWSEOF'
# AWS Credentials on Migrate Host

This instance uses an IAM Instance Role for AWS access.
No access keys or credentials files are needed.

The instance role provides AdministratorAccess to this
AWS account via the EC2 instance metadata service (IMDS).

All AWS CLI commands work automatically:
  aws sts get-caller-identity    # verify your identity
  aws s3 ls                      # list buckets
  aws rds describe-db-instances  # list RDS

The default region is set via /etc/profile.d/migrate-host-env.sh.

DO NOT place access keys on this instance.
The instance role is more secure (automatic rotation, no key files).
AWSEOF
chown -R ubuntu:ubuntu /home/ubuntu/.aws

# ============================================================
step "Root password from Secrets Manager (optional, non-fatal)"
# ============================================================
# Reuses deploy-host's root-password secret. Simpler than a separate
# secret for the ephemeral migrate-host, and the security profile is
# equivalent (both are operator boxes with SSM-only access).
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
step "SSM agent (snap)"
# ============================================================
snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# ============================================================
step "MariaDB + pgloader + postgresql-client + gettext-base"
# ============================================================
apt-get install -y \
  mariadb-client \
  mariadb-server \
  pgloader \
  postgresql-client \
  gettext-base

# ============================================================
step "MariaDB bulk-load tuning drop-in (design doc §6.1)"
# ============================================================
# Sized for r7g.xlarge (32 GiB). Turns off durability features safe on
# a throwaway box — dramatic speedup for the mysql < dump.sql import.
# See design doc §6.1 for the full rationale per knob.
cat > /etc/mysql/mariadb.conf.d/99-migrate-host.cnf <<'MYCNFEOF'
# /etc/mysql/mariadb.conf.d/99-migrate-host.cnf
# Managed by scripts/migrate-host/bootstrap.sh.
# See docs/plans/migrate-host-design-2026-08-05.md §6.1 for rationale.

[mysqld]
# Sized for r7g.xlarge (32 GiB).
# Leaves ~10 GiB for pgloader SBCL + ~8 GiB slack.
innodb_buffer_pool_size          = 8G
innodb_buffer_pool_instances     = 4
innodb_log_file_size             = 1G
innodb_log_buffer_size           = 64M
innodb_flush_log_at_trx_commit   = 0    # bulk-load; flush once/sec
innodb_doublewrite               = 0    # throwaway DB, skip DW
innodb_flush_method              = O_DIRECT
innodb_io_capacity               = 2000
innodb_io_capacity_max           = 4000
innodb_buffer_pool_dump_at_shutdown = 0
innodb_buffer_pool_load_at_startup  = 0
sync_binlog                      = 0
skip_log_bin                          # no binlog at all
max_allowed_packet               = 512M
performance_schema               = OFF  # save ~500 MB for buffer pool
MYCNFEOF
chmod 0644 /etc/mysql/mariadb.conf.d/99-migrate-host.cnf

# ============================================================
step "MariaDB service: enable + start (opposite of deploy-host)"
# ============================================================
# Deploy-host installs mariadb and immediately disables/stops it (uses
# on-demand). Migrate-host's WHOLE purpose is to run MariaDB, so we
# leave it enabled and running. First-boot log tuning changes apply at
# service start (systemd starts it fresh AFTER the drop-in is written
# above).
systemctl enable --now mariadb \
  || echo "WARN: could not enable/start mariadb — check journalctl -u mariadb"

# Give MariaDB a moment to finish its initial log-file allocation
# (with innodb_log_file_size=1G it takes a few seconds).
sleep 5
systemctl status mariadb --no-pager | head -20 || true

# ============================================================
step "AWS session-manager-plugin (SSM tunneling from migrate-host)"
# ============================================================
# ARM64 build (Graviton). Kept for symmetry with deploy-host — an
# operator interactively debugging might want to open a nested SSM
# session (unusual but possible).
cd /tmp
curl -sS \
  "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" \
  -o session-manager-plugin.deb
dpkg -i session-manager-plugin.deb || apt-get -f install -y
rm session-manager-plugin.deb
cd /
session-manager-plugin --version \
  || echo "WARN: session-manager-plugin install may have failed"

# ============================================================
step "AWS RDS CA bundle (for pgloader → RDS TLS)"
# ============================================================
curl -sS https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
     -o /usr/local/share/ca-certificates/rds-ca.crt \
  && update-ca-certificates >/dev/null 2>&1 \
  || echo "WARN: RDS CA bundle install failed (non-fatal — pgloader may still hit TLS verify errors)"

# ============================================================
step "Git safe.directory for cross-user repo access"
# ============================================================
# Same reasoning as deploy-host: SSM runs as root but repo is owned
# by ubuntu. Whitelisting the path lets root run git operations
# without per-command config.
git config --global --add safe.directory /home/ubuntu/projects/cf-scalable-web \
  || echo "WARN: could not set git safe.directory (non-fatal)"

# ============================================================
step "Worxco config directories + migrate-host marker"
# ============================================================
mkdir -p /etc/worxco/envs
chmod 755 /etc/worxco /etc/worxco/envs
# Marker file guards for restore-mysql.sh session-flag wrap (Phase 2)
# and any other host-detection code in migration scripts.
echo "migrate-host" > /etc/worxco/migrate-host-marker
chmod 644 /etc/worxco/migrate-host-marker

# ============================================================
step "Dump staging directory (local disk, not FSx)"
# ============================================================
# restore-mysql.sh's DUMP_LOCAL_PATH defaults to /var/www/mysql/zinew.sql
# on deploy-host (FSx). On migrate-host, migrate-db-all's dispatch
# wrapper overrides it to /var/tmp/migration/zinew.sql (local 40 GiB
# gp3). Design doc §6.2. Create the dir here so restore-mysql doesn't
# have to.
mkdir -p /var/tmp/migration
chown root:root /var/tmp/migration
chmod 0755 /var/tmp/migration

# ============================================================
step "Install endpoint helper scripts from repo"
# ============================================================
# Migrate-host needs psql-env (pgloader target verification) and
# refresh-env-config (populates /etc/worxco/envs/sandbox with
# DRUPAL_DB_HOST etc. — run-pgloader.sh sources this file).
#
# NOT installed on migrate-host: use-env (manages FSx mounts — we
# have no FSx), valkey-env (Drupal caching — not part of migration).
REPO_DIR="/home/ubuntu/projects/cf-scalable-web"
if [ ! -d "$REPO_DIR/scripts/deploy-host" ]; then
  echo "ERROR: $REPO_DIR/scripts/deploy-host not found — repo not cloned?"
  exit 1
fi
install -m 0755 "$REPO_DIR/scripts/deploy-host/info-env"           /usr/local/bin/info-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/show-env"           /usr/local/bin/show-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/psql-env"           /usr/local/bin/psql-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/refresh-env-config" /usr/local/sbin/refresh-env-config
install -m 0440 "$REPO_DIR/scripts/deploy-host/worxco-refresh-env-config.sudoers" /etc/sudoers.d/worxco-refresh-env-config

# ============================================================
step "First refresh-env-config (best-effort, populates /etc/worxco/envs/*)"
# ============================================================
/usr/local/sbin/refresh-env-config sandbox staging production || \
  echo "WARN: refresh-env-config had no envs to refresh (none deployed yet?)"

# ============================================================
step "MOTD"
# ============================================================
cat > /etc/motd <<MOTDEOF

============================================
  cf-scalable-web MIGRATE Host
============================================

This is the EPHEMERAL migrate host. Purpose:
  1. Run MariaDB (staging DB for prod dumps)
  2. Run pgloader (MySQL → PostgreSQL migration)
  3. Get destroyed at end of migrate-db-all

Access: SSM Session Manager only (no SSH)
Shell:  zsh (RPROMPT shows [migrate-host])
AWS:    Instance role provides AdministratorAccess
Region: $AWS_DEFAULT_REGION

Tools:  aws, git, make, tmux, screen, vim, zsh,
        mariadb, pgloader, psql, session-manager-plugin

Migration-specific commands:
  sudo systemctl status mariadb           # MariaDB status
  mysql -h 127.0.0.1 -u root              # local MariaDB shell
  pgloader --version                       # verify pgloader
  psql-env sandbox                         # psql shell to sandbox RDS

Dump staging: /var/tmp/migration/          (local disk, not FSx)
Backup dir:   /var/log/worxco-migration/   (backup-state.sh output)

MOTDEOF

# Print /etc/motd on interactive login (bash + zsh).
cat > /etc/profile.d/00-worxco-motd.sh <<'PROFEOF'
if [ -z "${SSH_CONNECTION:-}" ] && [ -f /etc/motd ] && [ -z "${MOTD_SHOWN:-}" ] && [ -t 1 ]; then
  cat /etc/motd
  export MOTD_SHOWN=1
fi
PROFEOF
chmod 644 /etc/profile.d/00-worxco-motd.sh

cat > /etc/zsh/zshrc.d/00-motd.zsh <<'ZMOTDEOF'
if [[ -z "${SSH_CONNECTION:-}" ]] && [[ -f /etc/motd ]] && [[ -z "${MOTD_SHOWN:-}" ]] && [[ -t 1 ]]; then
  cat /etc/motd
  export MOTD_SHOWN=1
fi
ZMOTDEOF
chmod 644 /etc/zsh/zshrc.d/00-motd.zsh

# ============================================================
step "Admin SSH keys — sync from SSM registry (best-effort)"
# ============================================================
# Same registry as deploy-host: /worxco/admin/ssh-public-keys/*. If
# keys are registered, they land in ubuntu's authorized_keys, enabling
# scp/sftp/rsync over the SSM Session Manager proxy without opening
# port 22. Idempotent — no keys registered = no-op.
REPO_DIR="/home/ubuntu/projects/cf-scalable-web"
if [ -x "$REPO_DIR/scripts/deploy-host/sync-admin-ssh-keys.sh" ]; then
  bash "$REPO_DIR/scripts/deploy-host/sync-admin-ssh-keys.sh" \
    || echo "WARN: admin SSH key sync failed (non-fatal — operator can run 'make admin-ssh-key-sync' later)"
else
  echo "WARN: sync-admin-ssh-keys.sh not found in repo — skipping"
fi

# ============================================================
step "Bootstrap complete"
# ============================================================
LAST_STEP="(complete)"
echo ""
echo "============================================"
echo "  Migrate host bootstrap finished $(date)"
echo "============================================"
echo "SUCCESS" > /var/log/migrate-host-bootstrap-status
