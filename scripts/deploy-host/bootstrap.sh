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
  zsh \
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
step "tmux system-wide config (vi copy-mode, larger scrollback, env in status bar)"
# ============================================================
# Operators run long-lived sessions (e.g., `make serve-drupal-local`) inside
# tmux on this host. Default tmux is set up for emacs-keys in copy-mode and a
# 2000-line scrollback — both unhelpful when paging through make output on a
# Mac without dedicated PgUp/PgDn keys. This config:
#   - vi key bindings in copy-mode (Ctrl-u/d, /, ?, n, N, g, G all work)
#   - mouse on so trackpad scroll just works
#   - 50k-line scrollback to keep entire `make deploy-allX` runs in buffer
#   - current Worxco env shown on the right of the status bar (mirrors zsh RPROMPT)
cat > /etc/tmux.conf <<'TMUXEOF'
# /etc/tmux.conf — system-wide tmux config for deploy-host operators.
# Managed by deploy-host bootstrap.sh — edits here will be overwritten
# on the next AMI rebuild.

# Scroll & input ergonomics
set -g mouse on
set -g history-limit 50000

# Push tmux's copy buffer to the system clipboard via OSC 52 escape
# sequences. This makes click-drag selections (which are captured by
# tmux when `mouse on` is set) end up in the host's clipboard instead
# of disappearing the moment you release the trackpad. Requires a
# terminal emulator that supports OSC 52 — macOS Terminal supports it
# by default; iTerm2 needs "Applications in terminal may access
# clipboard" enabled in Preferences → General → Selection.
#
# Without this, the alternative is to HOLD OPTION while click-dragging,
# which makes the terminal emulator (not tmux) handle the selection.
# That works fine but operators have to remember it; OSC 52 makes
# the obvious behavior also be the correct one.
set -g set-clipboard on

# In copy-mode-vi, MouseDragEnd is the right time to copy: when the
# user releases the mouse after a drag selection. `copy-pipe-no-clear`
# copies the selection AND keeps it highlighted briefly so the operator
# can confirm they got what they wanted. With set-clipboard on (above),
# tmux pushes the result through OSC 52 to the system clipboard.
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear

# vi key bindings in copy-mode (Ctrl-b [ to enter):
#   Ctrl-u / Ctrl-d  half-page scroll
#   Ctrl-b / Ctrl-f  full-page scroll
#   /  ?             forward / reverse search
#   n  N             next / prev match
#   g  G             top / bottom
#   q                exit copy-mode
set -g mode-keys vi

# Don't swallow ESC — vim/nvim feel snappier
set -sg escape-time 10

# 1-indexed windows; window-0 on the far left is awkward to reach
set -g base-index 1
setw -g pane-base-index 1

# Show current Worxco env in the status bar, refreshed every 5s.
# Mirrors the zsh RPROMPT so the env is visible inside long-running panes
# (drush runserver, log tails, etc.) where the shell prompt isn't on screen.
set -g status-interval 5
set -g status-right-length 60
set -g status-right '#[fg=yellow][env:#(cat /etc/worxco/current-env 2>/dev/null || echo NONE)]#[default] %H:%M'

# Quick conf reload from inside a session
bind r source-file /etc/tmux.conf \; display-message "tmux.conf reloaded"
TMUXEOF
chmod 0644 /etc/tmux.conf

# ============================================================
step "zsh + right-prompt env indicator"
# ============================================================
# SSM Session Manager forces `exec bash -l`, bypassing ubuntu's login shell
# in /etc/passwd. So we keep bash as the entry shell but have bash auto-exec
# into zsh on interactive shells. To bypass once for debugging: NO_AUTO_ZSH=1 bash.
#
# RPROMPT shows the current Worxco environment on the right side of every
# prompt — read from /etc/worxco/current-env, which is managed by the
# `use-env <name>` script (TODO: that command in a follow-up commit).

chsh -s /bin/zsh ubuntu || true

# System-wide zsh interactive config — applies to every user that runs zsh.
mkdir -p /etc/zsh/zshrc.d
cat > /etc/zsh/zshrc.d/worxco-prompt.zsh <<'ZSHEOF'
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
#
# Worxco deploy-host zsh interactive setup. Installed by bootstrap.sh.

autoload -U colors && colors

# PROMPT_SUBST is REQUIRED for $(...) substitution to work inside prompts.
# Without it, the $(_worxco_env) expression below is treated as a literal string.
setopt PROMPT_SUBST

_worxco_env() {
  if [[ -r /etc/worxco/current-env ]]; then
    echo "[env:$(< /etc/worxco/current-env)]"
  else
    echo "[env:NONE]"
  fi
}

PROMPT='%n@%m:%~%# '
RPROMPT='%F{yellow}$(_worxco_env)%f'

# Auto-source the active env's variables on shell startup. Without this,
# every new SSH/SSM-session login lands in an empty shell — operators
# would have to run `use-env <env>` (which re-sources for the CURRENT
# shell) before drush, psql, etc. would see DRUPAL_DB_HOST and friends.
# Reading /etc/worxco/current-env lets us know which env file to source
# without prompting. File reads are cheap; no network calls happen here
# (the env file is a flat list of `export` lines populated by
# refresh-env-config when use-env switches envs).
if [[ -r /etc/worxco/current-env ]]; then
  _cur_env=$(< /etc/worxco/current-env)
  if [[ -n "$_cur_env" && "$_cur_env" != "NONE" && -r "/etc/worxco/envs/$_cur_env" ]]; then
    # shellcheck disable=SC1090
    source "/etc/worxco/envs/$_cur_env"
  fi
  unset _cur_env
fi

HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt INC_APPEND_HISTORY SHARE_HISTORY

# Wrap /usr/local/sbin/use-env so the env's DB/cache exports flow into
# the current shell. The binary itself can't propagate variables up to
# its caller (process boundaries), so the shell sources the env file
# after a successful switch.
use-env() {
  if [ "$#" -eq 0 ]; then
    /usr/local/sbin/use-env
    return $?
  fi
  if sudo /usr/local/sbin/use-env "$@"; then
    local _cur
    if [[ -r /etc/worxco/current-env ]]; then
      _cur=$(< /etc/worxco/current-env)
      if [[ -n "$_cur" && "$_cur" != "NONE" && -r "/etc/worxco/envs/$_cur" ]]; then
        # shellcheck disable=SC1090
        source "/etc/worxco/envs/$_cur"
        echo "Sourced /etc/worxco/envs/$_cur into current shell."
      fi
    fi
  fi
}
ZSHEOF

# Ensure system-wide /etc/zsh/zshrc sources the drop-in dir. Ubuntu's
# default /etc/zsh/zshrc doesn't include zshrc.d, so we append idempotently.
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

# Drop a per-user ~/.zshrc stub for ubuntu. zsh-newuser-install fires its
# q/0/1/2 wizard whenever zsh starts AND none of ~/.zshrc, ~/.zlogin,
# ~/.zprofile, or ~/.zshenv exist. Picking "q" only dismisses the current
# run — the wizard fires again next login because the file is never
# created. Existence of any one of those dotfiles silences the wizard
# permanently. We put project-required zsh setup in the SYSTEM-wide
# /etc/zsh/zshrc.d/ above, so the per-user file can just be a stub.
if [ ! -f /home/ubuntu/.zshrc ]; then
  cat > /home/ubuntu/.zshrc <<'ZSHRCEOF'
# Per-user .zshrc — managed by deploy-host bootstrap.sh.
#
# This file exists primarily to silence zsh-newuser-install (which fires
# whenever zsh starts and no ~/.zshrc / ~/.zlogin / ~/.zprofile / ~/.zshenv
# exists). All project-required zsh configuration lives in the system-wide
# drop-in directory /etc/zsh/zshrc.d/, sourced from /etc/zsh/zshrc.
#
# Feel free to add personal preferences here. Examples:
#   alias ll='ls -la'
#   bindkey -e          # emacs-style bindings (default)
#   bindkey -v          # vi-style bindings
ZSHRCEOF
  chown ubuntu:ubuntu /home/ubuntu/.zshrc
  chmod 644 /home/ubuntu/.zshrc
fi

# Auto-exec zsh from bash on interactive logins (Option A: keep bash as the
# SSM entry shell, swap to zsh for the user). Append idempotently to the
# system-wide bashrc so it applies even on a freshly-created user account.
if ! grep -q 'NO_AUTO_ZSH' /etc/bash.bashrc 2>/dev/null; then
  cat >> /etc/bash.bashrc <<'BASHEOF'

# Worxco: auto-exec into zsh for interactive logins (escape with NO_AUTO_ZSH=1 bash)
if [[ $- == *i* ]] && [ -x /usr/bin/zsh ] && [ "${NO_AUTO_ZSH:-0}" != 1 ] && [ -z "${ZSH_VERSION:-}" ]; then
  exec zsh -l
fi
BASHEOF
fi

# Bootstrap /etc/worxco/current-env so a fresh deploy-host shows something
# meaningful in the prompt. `use-env <name>` will overwrite this later.
mkdir -p /etc/worxco
if [ ! -s /etc/worxco/current-env ]; then
  echo "NONE" > /etc/worxco/current-env
fi

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
install -m 0755 "$REPO_DIR/scripts/deploy-host/use-env"            /usr/local/sbin/use-env
install -m 0755 "$REPO_DIR/scripts/deploy-host/refresh-env-config" /usr/local/sbin/refresh-env-config
install -m 0440 "$REPO_DIR/scripts/deploy-host/worxco-refresh-env-config.sudoers" /etc/sudoers.d/worxco-refresh-env-config

# Remove the deprecated mount-env if it was installed by an older bootstrap.
# (Replaced by use-env, which mounts at /var/www regardless of env so paths
# match the runtime fleet. mount-env's per-env mount points are incompatible
# with the new model — keeping both side-by-side would be confusing.)
rm -f /usr/local/sbin/mount-env

# ============================================================
step "First refresh-env-config (best-effort, populates /etc/worxco/envs/*)"
# ============================================================
/usr/local/sbin/refresh-env-config sandbox staging production || \
  echo "WARN: refresh-env-config had no envs to refresh (none deployed yet?)"

# ============================================================
step "Restore last active env mount (if recorded in /etc/worxco/current-env)"
# ============================================================
# Deploy-host operates on ONE env at a time. /etc/worxco/current-env
# records which env the operator was last working on. On a fresh deploy-
# host that file is "NONE" — the operator runs `sudo use-env sandbox`
# explicitly. On a re-bootstrap of a host with an existing current-env,
# we restore the mount so the prompt and any tooling come back to a
# consistent state.
#
# If /etc/fstab already has a worxco-use-env entry, that mount has
# already happened automatically at boot via systemd-fstab-generator —
# this block is a no-op in that case.
if [ -r /etc/worxco/current-env ]; then
  prev_env=$(< /etc/worxco/current-env)
  if [ -n "$prev_env" ] && [ "$prev_env" != "NONE" ]; then
    if mountpoint -q /var/www 2>/dev/null; then
      echo "/var/www already mounted (env=$prev_env via fstab) — nothing to do"
    else
      echo "Restoring mount for env=$prev_env via use-env..."
      /usr/local/sbin/use-env "$prev_env" || \
        echo "  WARN: use-env $prev_env failed; run \`sudo use-env <env>\` manually"
    fi
  else
    echo "No active env recorded (/etc/worxco/current-env=NONE) — operator must run \`sudo use-env <env>\`"
  fi
else
  echo "/etc/worxco/current-env not yet created — operator must run \`sudo use-env <env>\`"
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
Shell:  zsh (RPROMPT shows [env:<name>] from /etc/worxco/current-env)
AWS:    Instance role provides AdministratorAccess
Region: $AWS_DEFAULT_REGION (override with export AWS_DEFAULT_REGION=...)
Tools:  aws, git, make, tmux, screen, vim, claude, zsh
        php, composer, drush, psql, redis-cli, use-env

Pick an environment to operate on (one at a time per deploy-host):
  use-env                           # show current env + mount state
  use-env sandbox                   # mount sandbox's FSx at /var/www
  use-env none                      # unmount, leave /var/www empty

Once an env is active, /var/www holds that env's FSx contents.
Drupal lives at /var/www/drupal regardless of which env is active.

Project helpers (auto-resolve endpoints — no manual lookups):
  info-env sandbox                  # live endpoints from SSM
  show-env sandbox                  # cached endpoints (instant)
  source /etc/worxco/envs/sandbox   # exports DRUPAL_DB_HOST, FSX_DNS, etc.
  sudo refresh-env-config sandbox   # rebuild cache from SSM
  psql-env sandbox                  # psql shell against env's RDS
  psql-env sandbox -c "SELECT now();"
  valkey-env sandbox PING           # Valkey/Redis CLI

Drupal management (after env is active and Drupal is deployed):
  cd /var/www/drupal                # navigate to Drupal install
  drush cr                          # clear caches
  drush updb -y                     # apply pending DB updates

MOTDEOF

# Print /etc/motd on interactive login. Earlier versions of this script
# appended the print logic to ~/.bashrc, but ~/.bashrc is NOT read by
# `bash -l` (which is what SSM Session Manager invokes) — login bash
# reads /etc/profile + ~/.bash_profile, then exec's into zsh via our
# auto-exec in /etc/bash.bashrc. So the .bashrc-based print never fired.
#
# Two system-wide files now handle the print (covers both code paths):
#   - /etc/profile.d/00-worxco-motd.sh:    bash login shells (the
#     NO_AUTO_ZSH=1 escape hatch case — operator manually opted out of zsh)
#   - /etc/zsh/zshrc.d/00-motd.zsh:        zsh interactive shells (the
#     normal SSM flow, since /etc/bash.bashrc auto-execs bash → zsh)
# Both gated by MOTD_SHOWN; the env var carries across the bash→zsh exec
# so we don't double-print in the rare both-fire case.
cat > /etc/profile.d/00-worxco-motd.sh <<'PROFEOF'
# Print /etc/motd on interactive bash login.
#
# Skip if SSH already printed it via pam_motd. Ubuntu's default
# /etc/pam.d/sshd includes pam_motd, which auto-prints /etc/motd on
# every SSH login BEFORE the user's shell starts. SSH_CONNECTION is
# set by sshd in that case. We don't want to double-print on SSH
# sessions, but we still want our MOTD to appear for SSM Session
# Manager sessions (which spawn the shell directly, no PAM, no
# SSH_CONNECTION). Same logic applied symmetrically in
# /etc/zsh/zshrc.d/00-motd.zsh.
if [ -z "${SSH_CONNECTION:-}" ] && [ -f /etc/motd ] && [ -z "${MOTD_SHOWN:-}" ] && [ -t 1 ]; then
  cat /etc/motd
  export MOTD_SHOWN=1
fi
PROFEOF
chmod 644 /etc/profile.d/00-worxco-motd.sh

cat > /etc/zsh/zshrc.d/00-motd.zsh <<'ZMOTDEOF'
# Print /etc/motd on interactive zsh start. Skip if SSH already
# triggered pam_motd (SSH_CONNECTION set by sshd). See the matching
# /etc/profile.d/00-worxco-motd.sh for the full reasoning.
if [[ -z "${SSH_CONNECTION:-}" ]] && [[ -f /etc/motd ]] && [[ -z "${MOTD_SHOWN:-}" ]] && [[ -t 1 ]]; then
  cat /etc/motd
  export MOTD_SHOWN=1
fi
ZMOTDEOF
chmod 644 /etc/zsh/zshrc.d/00-motd.zsh

# ============================================================
step "Admin SSH keys — sync from SSM registry"
# ============================================================
# Pulls any keys at /worxco/admin/ssh-public-keys/* from SSM and writes
# them to ubuntu's authorized_keys. Enables scp/sftp/rsync over the SSM
# Session Manager proxy without ever opening port 22. See
# docs/memory/admin-access-policy.md for the access model.
#
# Idempotent — if no keys are registered, writes a header-only authorized_keys
# that's safely empty of key material. Operators add keys later via
# `make admin-ssh-key-add NAME=<owner> FILE=<path>` on their local machine;
# that command auto-syncs to this host without needing a reboot.
REPO_DIR="/home/ubuntu/projects/cf-scalable-web"
if [ -x "$REPO_DIR/scripts/deploy-host/sync-admin-ssh-keys.sh" ]; then
  bash "$REPO_DIR/scripts/deploy-host/sync-admin-ssh-keys.sh" \
    || echo "WARN: admin SSH key sync failed (non-fatal — operator can run 'make admin-ssh-key-sync' later)"
else
  echo "WARN: sync-admin-ssh-keys.sh not found in repo at $REPO_DIR — skipping"
fi

# ============================================================
step "Bootstrap complete"
# ============================================================
LAST_STEP="(complete)"
echo ""
echo "============================================"
echo "  Deploy host bootstrap finished $(date)"
echo "============================================"
echo "SUCCESS" > /var/log/deploy-host-bootstrap-status
