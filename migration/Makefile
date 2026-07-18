# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

# =============================================================================
# migration/Makefile - Prod → Sandbox one-time migration workflow
# =============================================================================
#
# Purpose:  Self-contained Makefile for the one-time migration of a client's
#           Drupal site (DB + codebase + files) from a legacy Aurora MySQL
#           production account into the sandbox PostgreSQL environment.
#
# Usage:    Run from THIS directory (not project root):
#             cd migration
#             make help
#             make deploy-bucket
#             etc.
#
#           When the migration for a client is complete, this entire
#           folder can be safely deleted:
#             rm -rf migration/
#           No changes to the parent project's Makefile or infrastructure.
#
# Design notes:
#   - Filenames retain `cf-migration-*` / `migration-*` prefixes so they
#     remain grep-able even in isolation (e.g., GitHub file search)
#   - Target names dropped the `migration-` prefix since being inside
#     migration/ already establishes the context
#   - Two AWS accounts, two profiles — every command uses --profile
#     explicitly so there's no chance of accidentally deploying the
#     prod jumpbox into sandbox or vice versa
#
# Docs:     README.md (in this folder) — narrative operator runbook
#           Per-script inline comments — how-it-works detail
#
# =============================================================================

# -----------------------------------------------------------------------------
# Shared configuration
# -----------------------------------------------------------------------------
# Bring in the project-root .env if it exists (for AWS_REGION overrides,
# CLI flags, etc.). The leading dash means "don't error if missing" —
# migration works with defaults if the root .env isn't set up.
-include ../.env
export

# Region default. Overridable via command line or ../.env.
AWS_REGION ?= us-east-1

# Colors — matches the parent Makefile's palette so visual output is
# consistent whether you're in the parent shell or in this folder.
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
CYAN   := \033[0;36m
NC     := \033[0m

# -----------------------------------------------------------------------------
# .PHONY declarations
# -----------------------------------------------------------------------------
.PHONY: help \
        deploy-bucket destroy-bucket \
        deploy-secret destroy-secret set-secret-password \
        deploy-jumpbox destroy-jumpbox \
        ssm-jumpbox ssm-tunnel jumpbox-pubkey \
        dump-mysql dump-codebase dump-files dump-private dump-all \
        restore-mysql run-pgloader \
        dispatch-restore-mysql dispatch-run-pgloader \
        backup-jumpbox restore-jumpbox list-jumpbox-backups \
        .preflight

# -----------------------------------------------------------------------------
# Stack/resource names and file paths (all paths are relative to migration/)
# -----------------------------------------------------------------------------

# Sandbox migration S3 bucket
BUCKET_STACK    := cf-scalable-web-sandbox-migration-bucket
BUCKET_TEMPLATE := cloudformation/cf-migration-bucket.yaml
BUCKET_PARAMS   := parameters/migration-bucket-sandbox.json

# Source endpoints for the SSM port-forwarding tunnel. Override on the
# command line if migrating from a different prod cluster or to a
# different local port (e.g., if 3306 is already in use):
#   make ssm-tunnel LOCAL_PORT=3307
SOURCE_HOST := d8demo-cluster.cluster-cmbywichztfj.us-east-1.rds.amazonaws.com
SOURCE_PORT := 3306
LOCAL_PORT  := 3306

# Prod jumpbox EC2
JUMPBOX_STACK    := cf-migration-jumpbox
JUMPBOX_TEMPLATE := cloudformation/cf-migration-jumpbox.yaml
JUMPBOX_PARAMS   := parameters/migration-jumpbox.json

# Prod Secrets Manager entry holding the MySQL password for worxco@zinew.
# Created with a placeholder value; operator sets the real value with
# `make set-secret-password`. The jumpbox IAM role gets
# `secretsmanager:GetSecretValue` scoped to this ARN.
SECRET_STACK    := cf-migration-secret
SECRET_TEMPLATE := cloudformation/cf-migration-secret.yaml
SECRET_PARAMS   := parameters/migration-secret.json
SECRET_NAME     := cf-migration/prod-mysql-zinew

# -----------------------------------------------------------------------------
# help — quick-reference for all targets in this Makefile
# -----------------------------------------------------------------------------

help:  ## Show this help
	@echo "$(YELLOW)Prod → Sandbox Migration — one-time client migration workflow$(NC)"
	@echo "$(YELLOW)Docs: migration/README.md (narrative runbook)$(NC)"
	@echo ""
	@echo "  $(CYAN)Legend:$(NC) [ FROM = host to invoke the command from ] [ PROFILE = ~/.aws/credentials profile ]"
	@echo "  $(CYAN)         Mac|DH means Mac OR deploy-host (needs the AWS profile)$(NC)"
	@echo ""
	@echo "$(YELLOW)Sandbox-side (S3 migration bucket):$(NC)"
	@echo "  make deploy-bucket           S3 bucket in SANDBOX"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZI-Sandbox$(NC)"
	@echo "  make destroy-bucket          Tear down sandbox bucket (CONFIRMED=yes)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZI-Sandbox$(NC)"
	@echo ""
	@echo "$(YELLOW)Prod-side (Secrets Manager + Jumpbox EC2):$(NC)"
	@echo "  make deploy-secret           Prod Secrets Manager entry for DB creds (placeholder pw)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make set-secret-password     Prompt & inject the real password into the secret"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make destroy-secret          Tear down prod secret (CONFIRMED=yes)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make deploy-jumpbox          EC2 in PROD (needs secret stack first)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make destroy-jumpbox         Tear down prod EC2 (CONFIRMED=yes)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo ""
	@echo "$(YELLOW)SSM sessions and utilities (needs jumpbox deployed):$(NC)"
	@echo "  make ssm-jumpbox             Open SSM interactive shell on the prod jumpbox"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make ssm-tunnel              SSM port-forward → prod RDS (blocks; endpoint on invoking host)"
	@echo "                                 $(CYAN)FROM: deploy-host   PROFILE: ZoningInfoAdmin$(NC)"
	@echo "  make jumpbox-pubkey          Show jumpbox SSH pubkey (paste into React2)"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZoningInfoAdmin$(NC)"
	@echo ""
	@echo "$(YELLOW)Jumpbox state protection (SSH keys + configs; nightly auto-backup via EventBridge):$(NC)"
	@echo "  make backup-jumpbox          Snapshot jumpbox state → sandbox S3 (timestamped + latest)"
	@echo "  make restore-jumpbox         Restore state from S3 (auto-snapshots current to /tmp first)"
	@echo "  make list-jumpbox-backups    List all state backups in S3"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZI-Sandbox + ZoningInfoAdmin$(NC)"
	@echo ""
	@echo "$(YELLOW)Data operations (execute the actual migration after infrastructure is up):$(NC)"
	@echo "  make dump-all                Run all 4 dumps sequentially. Fire-and-forget (~30-45 min)."
	@echo "  make dump-mysql              Push script to jumpbox → mysqldump prod → sandbox S3"
	@echo "  make dump-codebase           Push script to jumpbox → tar Drupal codebase → sandbox S3"
	@echo "  make dump-files              Push script to jumpbox → tar public files/ → sandbox S3"
	@echo "  make dump-private            Push script to jumpbox → tar private/ → sandbox S3"
	@echo "                                 $(CYAN)FROM: Mac|DH   PROFILE: ZI-Sandbox + ZoningInfoAdmin$(NC)"
	@echo "                                 $(CYAN)Common env: CONFIRMED=yes DRY_RUN=yes$(NC)"
	@echo "  make restore-mysql           Fetch prod dump from S3 → local MariaDB scratch"
	@echo "                                 $(CYAN)FROM: deploy-host   PROFILE: instance-role$(NC)"
	@echo "                                 $(CYAN)Env overrides: MIGRATION_BUCKET DUMP_S3_KEY LOCAL_DB_NAME LOCAL_DB_USER LOCAL_DB_PASS FORCE_DOWNLOAD$(NC)"
	@echo "  make run-pgloader            Local MariaDB scratch → sandbox RDS PostgreSQL (via pgloader)"
	@echo "                                 $(CYAN)FROM: deploy-host   PROFILE: instance-role$(NC)"
	@echo "                                 $(CYAN)Env overrides: MIGRATION_BUCKET ENV_FILE TEMPLATE_PATH PGLOADER_HEAP_MB MIGRATION_DB_NAME$(NC)"
	@echo ""
	@echo "$(YELLOW)Walk-away dispatch (Mac-side; kicks off on deploy-host via SSM, survives session timeout):$(NC)"
	@echo "  make dispatch-restore-mysql  Kick restore-mysql on deploy-host, poll from Mac"
	@echo "  make dispatch-run-pgloader   Kick run-pgloader on deploy-host, poll from Mac"
	@echo "                                 $(CYAN)FROM: Mac|deploy-host   PROFILE: ZI-Sandbox$(NC)"
	@echo "                                 $(CYAN)Env overrides: CONFIRMED DRY_RUN MIGRATION_DB_NAME PGLOADER_HEAP_MB POLL_TIMEOUT$(NC)"
	@echo ""

# -----------------------------------------------------------------------------
# Sandbox-side stack: migration S3 bucket
# -----------------------------------------------------------------------------

deploy-bucket:  ## Create migration S3 bucket in SANDBOX  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox]
	@echo "$(BLUE)Deploying migration bucket: $(BUCKET_STACK) (ZI-Sandbox)$(NC)"
	@aws --profile ZI-Sandbox cloudformation deploy \
		--template-file $(BUCKET_TEMPLATE) \
		--stack-name $(BUCKET_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(BUCKET_PARAMS)) \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Migration bucket deployed$(NC)"
	@aws --profile ZI-Sandbox cloudformation describe-stacks \
		--stack-name $(BUCKET_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table --region $(AWS_REGION)

destroy-bucket:  ## Delete migration bucket. CONFIRMED=yes to skip prompt.  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox]
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete the migration S3 bucket and all data in it.$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled"; exit 0; fi; \
	fi
	@echo "$(BLUE)Emptying migration bucket before deletion...$(NC)"
	@BUCKET=$$(aws --profile ZI-Sandbox cloudformation describe-stacks \
		--stack-name $(BUCKET_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	if [ -n "$$BUCKET" ] && [ "$$BUCKET" != "None" ]; then \
		echo "  Emptying: $$BUCKET"; \
		aws --profile ZI-Sandbox s3 rm "s3://$$BUCKET" --recursive --region $(AWS_REGION) 2>/dev/null || true; \
	fi
	@aws --profile ZI-Sandbox cloudformation delete-stack \
		--stack-name $(BUCKET_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion...$(NC)"
	@aws --profile ZI-Sandbox cloudformation wait stack-delete-complete \
		--stack-name $(BUCKET_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Migration bucket deleted$(NC)"

# -----------------------------------------------------------------------------
# Prod-side stacks: Secrets Manager entry + Jumpbox EC2
# -----------------------------------------------------------------------------

deploy-secret:  ## Create prod-DB Secrets Manager entry (placeholder pw)  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@echo "$(BLUE)Deploying migration secret: $(SECRET_STACK) (ZoningInfoAdmin / prod)$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation deploy \
		--template-file $(SECRET_TEMPLATE) \
		--stack-name $(SECRET_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(SECRET_PARAMS)) \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Migration secret deployed (placeholder password)$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(SECRET_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table --region $(AWS_REGION)
	@echo ""
	@echo "$(YELLOW)NEXT STEP: populate the real password:$(NC)"
	@echo "$(CYAN)    make set-secret-password$(NC)"

destroy-secret:  ## Delete prod-DB secret. CONFIRMED=yes to skip prompt.  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This deletes the Secrets Manager entry holding prod MySQL credentials.$(NC)"; \
		echo "$(RED)Any jumpbox script that relies on it will fail until it is recreated.$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled"; exit 0; fi; \
	fi
	@aws --profile ZoningInfoAdmin cloudformation delete-stack \
		--stack-name $(SECRET_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion...$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation wait stack-delete-complete \
		--stack-name $(SECRET_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Migration secret deleted$(NC)"
	@echo "$(YELLOW)Note: Secrets Manager entries have a 30-day recovery window by default.$(NC)"
	@echo "$(YELLOW)To force-delete immediately (skip recovery): use --force-delete-without-recovery via CLI.$(NC)"

set-secret-password:  ## Prompt & inject real password into secret  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@if ! aws --profile ZoningInfoAdmin secretsmanager describe-secret \
		--secret-id $(SECRET_NAME) --region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "$(RED)Secret '$(SECRET_NAME)' does not exist. Deploy it first:$(NC)"; \
		echo "$(CYAN)    make deploy-secret$(NC)"; \
		exit 1; \
	fi
	@echo "$(CYAN)Updating password field in $(SECRET_NAME)$(NC)"
	@echo "$(CYAN)(Other fields — host, port, database, username — are preserved from the CFN template.)$(NC)"
	@read -s -p "Prod MySQL password for user 'worxco': " NEW_PW; echo; \
	if [ -z "$$NEW_PW" ]; then echo "$(RED)Empty password; aborting.$(NC)"; exit 1; fi; \
	CURRENT=$$(aws --profile ZoningInfoAdmin secretsmanager get-secret-value \
		--secret-id $(SECRET_NAME) --region $(AWS_REGION) \
		--query SecretString --output text); \
	UPDATED=$$(printf '%s' "$$CURRENT" | jq --arg pw "$$NEW_PW" '.password = $$pw'); \
	aws --profile ZoningInfoAdmin secretsmanager put-secret-value \
		--secret-id $(SECRET_NAME) --region $(AWS_REGION) \
		--secret-string "$$UPDATED" \
		--query 'VersionId' --output text >/dev/null; \
	unset NEW_PW; unset UPDATED; \
	echo "$(GREEN)✓ Password updated (new version stored, previous version retained by Secrets Manager)$(NC)"

deploy-jumpbox:  ## Create jumpbox EC2 in PROD. Requires secret stack.  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@# Look up the actual secret ARN from the deployed secret stack.
	@# Fails loud if the secret stack isn't deployed — the jumpbox IAM
	@# role needs a real ARN, not the wildcard fallback in the param file.
	@SECRET_ARN=$$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(SECRET_STACK) --region $(AWS_REGION) \
		--query "Stacks[0].Outputs[?OutputKey=='MigrationSecretArn'].OutputValue" \
		--output text 2>/dev/null); \
	if [ -z "$$SECRET_ARN" ] || [ "$$SECRET_ARN" = "None" ]; then \
		echo "$(RED)Secret stack '$(SECRET_STACK)' not found in prod account.$(NC)"; \
		echo "$(CYAN)Deploy it first:  make deploy-secret$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Deploying migration jumpbox: $(JUMPBOX_STACK) (ZoningInfoAdmin / prod)$(NC)"; \
	echo "$(CYAN)  Using secret ARN: $$SECRET_ARN$(NC)"; \
	echo "$(CYAN)  AMI: latest Ubuntu 24.04 ARM64 (via SSM param — may trigger instance replacement)$(NC)"; \
	echo "$(CYAN)  State is preserved: UserData auto-restore pulls s3://.../config/jumpbox-latest.tar.gz$(NC)"; \
	PARAMS=$$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(JUMPBOX_PARAMS) | sed "s|MigrationSecretArn=[^ ]*|MigrationSecretArn=$$SECRET_ARN|"); \
	aws --profile ZoningInfoAdmin cloudformation deploy \
		--template-file $(JUMPBOX_TEMPLATE) \
		--stack-name $(JUMPBOX_STACK) \
		--parameter-overrides $$PARAMS \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Migration jumpbox deployed$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(JUMPBOX_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table --region $(AWS_REGION)
	@echo ""
	@echo "$(CYAN)Note: UserData may take ~2 min to finish installing tools.$(NC)"
	@echo "$(CYAN)Once ready: make ssm-jumpbox$(NC)"

destroy-jumpbox:  ## Delete jumpbox (with final backup). CONFIRMED=yes skips prompt; SKIP_FINAL_BACKUP=yes skips backup.  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete the prod jumpbox EC2 instance.$(NC)"; \
		echo "$(CYAN)A final backup will be taken automatically before delete$(NC)"; \
		echo "$(CYAN)(set SKIP_FINAL_BACKUP=yes to skip that too).$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled"; exit 0; fi; \
	fi
	@# Take a final state backup so the operator can restore into a
	@# rebuilt jumpbox later without losing SSH keys or configs.
	@# Escape hatch: SKIP_FINAL_BACKUP=yes bypasses this.
	@if [ "$(SKIP_FINAL_BACKUP)" != "yes" ]; then \
		echo "$(BLUE)Taking final backup before destroy...$(NC)"; \
		if ! $(MAKE) backup-jumpbox CONFIRMED=yes; then \
			echo "$(YELLOW)Final backup failed. You have three choices:$(NC)"; \
			echo "$(YELLOW)  1) Fix the backup issue and re-run 'make destroy-jumpbox'$(NC)"; \
			echo "$(YELLOW)  2) Skip the backup: 'make destroy-jumpbox SKIP_FINAL_BACKUP=yes'$(NC)"; \
			echo "$(YELLOW)  3) Manually back up SSH keys elsewhere before proceeding$(NC)"; \
			exit 1; \
		fi; \
	else \
		echo "$(YELLOW)SKIP_FINAL_BACKUP=yes — skipping final backup (existing S3 state, if any, is your only restore point).$(NC)"; \
	fi
	@echo "$(BLUE)Deleting CFN stack: $(JUMPBOX_STACK)$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation delete-stack \
		--stack-name $(JUMPBOX_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion...$(NC)"
	@aws --profile ZoningInfoAdmin cloudformation wait stack-delete-complete \
		--stack-name $(JUMPBOX_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Migration jumpbox deleted$(NC)"
	@echo "$(CYAN)State was backed up to S3. On next deploy, UserData will auto-restore.$(NC)"
	@echo "$(CYAN)List backups: make list-jumpbox-backups$(NC)"

# -----------------------------------------------------------------------------
# SSM and utility targets
# -----------------------------------------------------------------------------

# Internal: diagnostic pre-flight for any target that needs to start an
# SSM session against the prod jumpbox. Distinguishes between the three
# real failure modes (missing plugin, missing/invalid profile, missing
# stack) instead of swallowing all of them as "jumpbox not deployed."
.preflight:
	@command -v session-manager-plugin >/dev/null 2>&1 || { \
		echo "$(RED)session-manager-plugin not installed.$(NC)"; \
		echo "$(YELLOW)On the deploy-host (Ubuntu ARM64):$(NC)"; \
		echo "  sudo curl -sSL \"https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb\" -o /tmp/smp.deb"; \
		echo "  sudo dpkg -i /tmp/smp.deb && rm /tmp/smp.deb"; \
		echo "$(YELLOW)On macOS:$(NC)"; \
		echo "  brew install --cask session-manager-plugin"; \
		exit 1; \
	}
	@aws --profile ZoningInfoAdmin sts get-caller-identity --query Account --output text >/dev/null 2>&1 || { \
		echo "$(RED)ZoningInfoAdmin profile not configured (or credentials invalid/expired).$(NC)"; \
		echo "$(YELLOW)Set up per README.md — copy the [ZoningInfoAdmin] block from$(NC)"; \
		echo "$(YELLOW)your ~/.aws/config and ~/.aws/credentials onto the host running 'make'.$(NC)"; \
		exit 1; \
	}

ssm-jumpbox: .preflight  ## Open SSM interactive shell on prod jumpbox  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@INSTANCE_ID=$$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(JUMPBOX_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='JumpboxInstanceId'].OutputValue" \
		--output text --region $(AWS_REGION) 2>&1); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ] || echo "$$INSTANCE_ID" | grep -q "does not exist"; then \
		echo "$(RED)Migration jumpbox stack not found in prod.$(NC)"; \
		echo "$(YELLOW)Deploy first: make deploy-jumpbox$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Opening SSM session to jumpbox $$INSTANCE_ID (prod)...$(NC)"; \
	aws --profile ZoningInfoAdmin ssm start-session --target $$INSTANCE_ID --region $(AWS_REGION)

ssm-tunnel: .preflight  ## SSM port-forward: localhost:$(LOCAL_PORT) → prod RDS (blocks; endpoint on invoking host)  [FROM: deploy-host, PROFILE: ZoningInfoAdmin]
	@INSTANCE_ID=$$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(JUMPBOX_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='JumpboxInstanceId'].OutputValue" \
		--output text --region $(AWS_REGION) 2>&1); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ] || echo "$$INSTANCE_ID" | grep -q "does not exist"; then \
		echo "$(RED)Migration jumpbox stack not found in prod.$(NC)"; \
		echo "$(YELLOW)Deploy first: make deploy-jumpbox$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Opening SSM port-forwarding tunnel:$(NC)"; \
	echo "  $(CYAN)localhost:$(LOCAL_PORT)$(NC)  ──tunnel──▶  $(CYAN)$(SOURCE_HOST):$(SOURCE_PORT)$(NC)"; \
	echo "  via jumpbox $$INSTANCE_ID (prod)"; \
	echo "$(CYAN)This command BLOCKS. Use Ctrl-C to close the tunnel.$(NC)"; \
	echo "$(CYAN)Open a second shell on this host to run pgloader against localhost:$(LOCAL_PORT).$(NC)"; \
	aws --profile ZoningInfoAdmin ssm start-session \
		--target "$$INSTANCE_ID" \
		--document-name AWS-StartPortForwardingSessionToRemoteHost \
		--parameters host=$(SOURCE_HOST),portNumber=$(SOURCE_PORT),localPortNumber=$(LOCAL_PORT) \
		--region $(AWS_REGION)

jumpbox-pubkey:  ## Display jumpbox pubkey (paste into React2 authorized_keys)  [FROM: Mac|deploy-host, PROFILE: ZoningInfoAdmin]
	@INSTANCE_ID=$$(aws --profile ZoningInfoAdmin cloudformation describe-stacks \
		--stack-name $(JUMPBOX_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='JumpboxInstanceId'].OutputValue" \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Migration jumpbox not deployed.$(NC)"; exit 1; \
	fi; \
	echo "$(BLUE)Fetching ed25519 pubkey from jumpbox (creates one if absent)...$(NC)"; \
	CMD_ID=$$(aws --profile ZoningInfoAdmin ssm send-command \
		--instance-ids $$INSTANCE_ID \
		--document-name AWS-RunShellScript \
		--parameters 'commands=["[ -f /root/.ssh/id_ed25519 ] || sudo ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519 -q","sudo cat /root/.ssh/id_ed25519.pub"]' \
		--query 'Command.CommandId' --output text --region $(AWS_REGION)); \
	echo "  CommandId: $$CMD_ID"; \
	sleep 5; \
	aws --profile ZoningInfoAdmin ssm get-command-invocation \
		--command-id $$CMD_ID --instance-id $$INSTANCE_ID \
		--query 'StandardOutputContent' --output text --region $(AWS_REGION)

# -----------------------------------------------------------------------------
# Data operations — the actual migration work, after infrastructure is up
# -----------------------------------------------------------------------------
# Convention:  targets in this section delegate to shell scripts under
#              scripts/{deploy-host,jumpbox}/ that are executed on the
#              appropriate host.
#
#   Deploy-host targets  — run the deploy-host script directly via
#                          `sudo -E ./scripts/deploy-host/<script>.sh`
#
#   Jumpbox targets      — invoke scripts/_ssm-run-jumpbox.sh which:
#                            (1) uploads _common.sh + the target script
#                                to s3://<bucket>/scripts/
#                            (2) uses aws ssm send-command to have the
#                                jumpbox pull them and execute
#                            (3) polls for completion, shows output
#                          The pattern extracts the cross-account
#                          orchestration into one place so all four
#                          dump-* targets stay tiny.
# -----------------------------------------------------------------------------

dump-mysql:  ## Push script to jumpbox → mysqldump prod → sandbox S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh dump-mysql

dump-codebase:  ## Push script to jumpbox → tar React2 Drupal codebase → sandbox S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh dump-codebase

dump-files:  ## Push script to jumpbox → tar React2 public files → sandbox S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh dump-files

dump-private:  ## Push script to jumpbox → tar React2 private files → sandbox S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh dump-private

dump-all:  ## Run all 4 dumps sequentially: mysql → codebase → files → private. Fire-and-forget (~30-45 min).  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@# Outer confirmation prompt. If CONFIRMED=yes at invocation, skip
	@# straight through. Otherwise show what we're about to do and prompt.
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(YELLOW)About to run ALL FOUR migration dumps sequentially:$(NC)"; \
		echo "$(YELLOW)  1. dump-mysql     (~10-15 min, prod MySQL → S3)$(NC)"; \
		echo "$(YELLOW)  2. dump-codebase  (~10-15 min, React2 codebase → S3)$(NC)"; \
		echo "$(YELLOW)  3. dump-files     (~5-10 min, React2 files/ → S3)$(NC)"; \
		echo "$(YELLOW)  4. dump-private   (~1 min, React2 private/ → S3)$(NC)"; \
		echo "$(YELLOW)Total estimate: 30-45 minutes. Chain aborts on any failure.$(NC)"; \
		echo "$(YELLOW)Best run off-hours (mysqldump adds real prod read load).$(NC)"; \
		echo ""; \
		echo "$(CYAN)(Pass CONFIRMED=yes to skip this prompt for unattended runs.)$(NC)"; \
		read -p "Type 'yes' to run all four: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled"; exit 0; fi; \
	fi
	@echo ""
	@echo "$(BLUE)=== dump-all: starting sequential dump chain ===$(NC)"
	@echo "$(BLUE)    Order: mysql → codebase → files → private$(NC)"
	@echo "$(BLUE)    Started at: $$(date -u +%Y-%m-%dT%H:%M:%SZ) UTC$(NC)"
	@echo ""
	@$(MAKE) dump-mysql CONFIRMED=yes
	@echo ""
	@$(MAKE) dump-codebase CONFIRMED=yes
	@echo ""
	@$(MAKE) dump-files CONFIRMED=yes
	@echo ""
	@$(MAKE) dump-private CONFIRMED=yes
	@echo ""
	@echo "$(GREEN)=== dump-all: ALL FOUR DUMPS COMPLETE ===$(NC)"
	@echo "$(GREEN)    Finished at: $$(date -u +%Y-%m-%dT%H:%M:%SZ) UTC$(NC)"
	@echo ""
	@echo "$(CYAN)Verify with:$(NC)"
	@echo "$(CYAN)  aws --profile ZI-Sandbox s3 ls s3://sandbox-migration-kv-worxco/dumps/ --human-readable$(NC)"
	@echo "$(CYAN)Or peek at any run's log:$(NC)"
	@echo "$(CYAN)  aws --profile ZI-Sandbox s3 ls s3://sandbox-migration-kv-worxco/logs/$$(date -u +%Y-%m-%d)/$(NC)"

# -----------------------------------------------------------------------------
# Jumpbox state protection — backup, restore, list
# -----------------------------------------------------------------------------
# Protects operator-managed state on the jumpbox (SSH keys, .env files,
# custom bin/ dirs, /etc/worxco/) against instance-replacement events.
# Nightly automated backup is set up separately via EventBridge Scheduler
# in the jumpbox CFN template.
# -----------------------------------------------------------------------------

backup-jumpbox:  ## Push script to jumpbox → tar SSH keys + configs → sandbox S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh backup-state

restore-jumpbox:  ## Push script to jumpbox → snapshot current + restore from S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox + ZoningInfoAdmin]
	@AWS_REGION="$(AWS_REGION)" \
	 BUCKET_STACK="$(BUCKET_STACK)" \
	 JUMPBOX_STACK="$(JUMPBOX_STACK)" \
	 SECRET_NAME="$(SECRET_NAME)" \
	 ./scripts/_ssm-run-jumpbox.sh restore-state

list-jumpbox-backups:  ## List jumpbox state backups in S3  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox]
	@BUCKET_NAME=$$(aws --profile ZI-Sandbox cloudformation describe-stacks \
		--stack-name $(BUCKET_STACK) --region $(AWS_REGION) \
		--query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
		--output text 2>/dev/null); \
	if [ -z "$$BUCKET_NAME" ] || [ "$$BUCKET_NAME" = "None" ]; then \
		echo "$(RED)Bucket stack '$(BUCKET_STACK)' not deployed.$(NC)"; exit 1; \
	fi; \
	echo "$(BLUE)=== Latest pointer (never expires) ===$(NC)"; \
	aws --profile ZI-Sandbox s3 ls "s3://$$BUCKET_NAME/config/jumpbox-latest.tar.gz" \
		--region $(AWS_REGION) --human-readable 2>&1 || echo "  (no latest — no backup taken yet)"; \
	echo ""; \
	echo "$(BLUE)=== Timestamped archives (90-day retention) ===$(NC)"; \
	aws --profile ZI-Sandbox s3 ls "s3://$$BUCKET_NAME/config/jumpbox-archive/" \
		--region $(AWS_REGION) --human-readable 2>&1 || echo "  (no archives yet)"; \
	echo ""; \
	echo "$(CYAN)Restore latest: make restore-jumpbox$(NC)"; \
	echo "$(CYAN)Restore specific: make restore-jumpbox RESTORE_KEY=config/jumpbox-archive/jumpbox-<UTC>.tar.gz$(NC)"

restore-mysql:  ## Fetch prod dump from S3 → local MariaDB scratch  [FROM: deploy-host, PROFILE: instance-role]
	@# Look up the actual migration bucket name from CFN output if the
	@# operator didn't override MIGRATION_BUCKET. On deploy-host this uses
	@# the instance role automatically — no --profile flag needed.
	@# The `--` after MIGRATION_BUCKET protects against operators typing
	@# `MIGRATION_BUCKET=` (empty) instead of unsetting.
	@BUCKET_NAME="$${MIGRATION_BUCKET:-}"; \
	if [ -z "$$BUCKET_NAME" ]; then \
		echo "$(BLUE)Looking up bucket name from CFN stack '$(BUCKET_STACK)'...$(NC)"; \
		BUCKET_NAME=$$(aws cloudformation describe-stacks \
			--stack-name $(BUCKET_STACK) \
			--query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
			--output text --region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$BUCKET_NAME" ] || [ "$$BUCKET_NAME" = "None" ]; then \
			echo "$(RED)Could not resolve migration bucket from CFN stack '$(BUCKET_STACK)'.$(NC)"; \
			echo "$(YELLOW)Either:$(NC)"; \
			echo "$(YELLOW)  1) Deploy the bucket:  make deploy-bucket$(NC)"; \
			echo "$(YELLOW)  2) Override the name:  make restore-mysql MIGRATION_BUCKET=<name>$(NC)"; \
			exit 1; \
		fi; \
	fi; \
	echo "$(BLUE)Running restore-mysql.sh on this host...$(NC)"; \
	echo "$(CYAN)  MIGRATION_BUCKET = $$BUCKET_NAME$(NC)"; \
	echo "$(CYAN)  DUMP_S3_KEY      = $${DUMP_S3_KEY:-dumps/zinew.sql}$(NC)"; \
	echo "$(CYAN)  DUMP_LOCAL_PATH  = $${DUMP_LOCAL_PATH:-/var/www/mysql/zinew.sql}$(NC)"; \
	echo "$(CYAN)  LOCAL_DB_NAME    = $${LOCAL_DB_NAME:-zinew}$(NC)"; \
	echo "$(CYAN)  LOCAL_DB_USER    = $${LOCAL_DB_USER:-worxco}$(NC)"; \
	echo "$(CYAN)  FORCE_DOWNLOAD   = $${FORCE_DOWNLOAD:-no}$(NC)"; \
	echo "$(CYAN)  CONFIRMED        = $${CONFIRMED:-no}$(NC)"; \
	echo "$(CYAN)  DRY_RUN          = $${DRY_RUN:-no}$(NC)"; \
	echo ""; \
	MIGRATION_BUCKET=$$BUCKET_NAME sudo -E ./scripts/deploy-host/restore-mysql.sh

run-pgloader:  ## Local MariaDB scratch → sandbox RDS PostgreSQL (via pgloader)  [FROM: deploy-host, PROFILE: instance-role]
	@# Same bucket-lookup pattern as restore-mysql: use MIGRATION_BUCKET from
	@# the operator env if set, otherwise read it from CFN. On deploy-host
	@# this uses the instance role automatically — no --profile flag needed.
	@BUCKET_NAME="$${MIGRATION_BUCKET:-}"; \
	if [ -z "$$BUCKET_NAME" ]; then \
		echo "$(BLUE)Looking up bucket name from CFN stack '$(BUCKET_STACK)'...$(NC)"; \
		BUCKET_NAME=$$(aws cloudformation describe-stacks \
			--stack-name $(BUCKET_STACK) \
			--query "Stacks[0].Outputs[?OutputKey=='MigrationBucketName'].OutputValue" \
			--output text --region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$BUCKET_NAME" ] || [ "$$BUCKET_NAME" = "None" ]; then \
			echo "$(RED)Could not resolve migration bucket from CFN stack '$(BUCKET_STACK)'.$(NC)"; \
			echo "$(YELLOW)Either:$(NC)"; \
			echo "$(YELLOW)  1) Deploy the bucket:  make deploy-bucket$(NC)"; \
			echo "$(YELLOW)  2) Override the name:  make run-pgloader MIGRATION_BUCKET=<name>$(NC)"; \
			exit 1; \
		fi; \
	fi; \
	echo "$(BLUE)Running run-pgloader.sh on this host...$(NC)"; \
	echo "$(CYAN)  MIGRATION_BUCKET  = $$BUCKET_NAME$(NC)"; \
	echo "$(CYAN)  ENV_FILE          = $${ENV_FILE:-/etc/worxco/envs/sandbox}$(NC)"; \
	echo "$(CYAN)  TEMPLATE_PATH     = $${TEMPLATE_PATH:-<repo>/migration/pgloader/zinew.load.tmpl}$(NC)"; \
	echo "$(CYAN)  PGLOADER_HEAP_MB  = $${PGLOADER_HEAP_MB:-4096}$(NC)"; \
	echo "$(CYAN)  MIGRATION_DB_NAME = $${MIGRATION_DB_NAME:-zinew}$(NC)"; \
	echo "$(CYAN)  CONFIRMED         = $${CONFIRMED:-no}$(NC)"; \
	echo "$(CYAN)  DRY_RUN           = $${DRY_RUN:-no}$(NC)"; \
	echo ""; \
	MIGRATION_BUCKET=$$BUCKET_NAME sudo -E ./scripts/deploy-host/run-pgloader.sh

dispatch-restore-mysql:  ## Fire restore-mysql on deploy-host via SSM (walk-away safe)  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox]
	@# Uses `aws ssm send-command`, survives Mac-side interrupts (session
	@# timeout, sleep, lid close). Poll timeout defaults to 2h — override
	@# with POLL_TIMEOUT=<seconds> if you're on the moon.
	@./scripts/_ssm-run-deploy-host.sh restore-mysql

dispatch-run-pgloader:  ## Fire run-pgloader on deploy-host via SSM (walk-away safe)  [FROM: Mac|deploy-host, PROFILE: ZI-Sandbox]
	@# 2-hour default POLL_TIMEOUT matches the observed pgloader wall time
	@# for a full 12M-row load with index build. Override with
	@# POLL_TIMEOUT=<seconds> for smaller/larger datasets.
	@./scripts/_ssm-run-deploy-host.sh run-pgloader

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
