#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
#
# scripts/_common.sh
#
# Thin wrapper that re-exports the migration/scripts/_common.sh helpers
# so top-level scripts can source a nearby _common.sh without needing to
# know about the migration subsystem's directory layout.
#
# Provides: colors, log_init, log_upload_and_exit, log_info/ok/step/warn/error,
#           confirm_or_exit, is_dry_run, run_or_echo, require_env, mask_secret.
#
# Sourced by (from scripts/):
#   scripts/dispatch-db-backup.sh
#   scripts/clear-drupal-cache.sh
#   scripts/admin-login-url.sh
#   scripts/install-drupal-remote.sh
#   scripts/publish-drupal-vhost.sh
#
# Sourced by (from scripts/deploy-host/):
#   scripts/deploy-host/db-backup.sh
#   ... etc. (via ../_common.sh)
#
# Canonical file:  migration/scripts/_common.sh
# Rationale for indirection: migration/scripts/_common.sh gets uploaded
# to remote hosts (jumpbox, deploy-host) alongside the migration scripts
# via the SSM upload machinery. Making it the canonical file keeps the
# upload path simple. Top-level scripts don't share that upload flow,
# so this thin wrapper lets them reach the same helpers without the
# awkward relative path.

_this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_this_dir}/../migration/scripts/_common.sh"
unset _this_dir
