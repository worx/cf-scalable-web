# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Makefile for cf-scalable-web infrastructure deployment
#
# Purpose: Simplified deployment and management of CloudFormation stacks
# Dependencies: aws-cli, cfn-lint, jq
#
# Usage:
#   make deploy-vpc ENV=sandbox     Deploy VPC to sandbox
#   make verify-vpc ENV=sandbox     Verify VPC deployment
#   make destroy-vpc ENV=sandbox    Delete VPC stack
#   make show-params ENV=sandbox    Show parameters for environment
#   make status ENV=sandbox         Show all stack statuses
#
-include .env
export

.PHONY: help env-check validate show-params status \
        deploy-all deploy-vpc deploy-iam deploy-storage deploy-database deploy-cache \
        deploy-compute deploy-compute-alb deploy-compute-nlb deploy-compute-nginx deploy-compute-php \
        verify-all verify-vpc verify-iam verify-storage verify-database verify-cache \
        verify-compute verify-compute-alb verify-compute-nlb verify-compute-nginx verify-compute-php \
        destroy-all destroy-vpc destroy-iam destroy-storage destroy-database destroy-cache \
        destroy-compute destroy-compute-alb destroy-compute-nlb destroy-compute-nginx destroy-compute-php \
        deploy-deploy-host verify-deploy-host destroy-deploy-host \
        stop-deploy-host start-deploy-host set-deploy-host-password \
        deploy-image-builder verify-image-builder destroy-image-builder \
        find-default-subnet upload-build-configs \
        build-ami-nginx build-ami-php74 build-ami-php83 build-amis \
        update-ami-param \
        init-secrets list-secrets test clean consolidate-logs \
        ssm-report ssm-remediate ssm-audit-params

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Default to sandbox for safety (not production!)
ENV ?= sandbox
AWS_REGION ?= us-east-1

# AWS CLI behavior (prevent hangs and pager issues)
export AWS_CLI_AUTO_PROMPT ?= off
export AWS_PAGER ?=

# Developer initials for prompt log filenames
DEVELOPER_INITIALS ?= KV

# Stack naming convention: cf-scalable-web-{environment}-{component}
STACK_PREFIX := cf-scalable-web-$(ENV)

# Parameter file location
PARAM_FILE := cloudformation/parameters/$(ENV).json

# Stack names
VPC_STACK := $(STACK_PREFIX)-vpc
IAM_STACK := $(STACK_PREFIX)-iam
STORAGE_STACK := $(STACK_PREFIX)-storage
DATABASE_STACK := $(STACK_PREFIX)-database
CACHE_STACK := $(STACK_PREFIX)-cache

# Deploy Host (standalone, not environment-specific)
DEPLOY_HOST_STACK := cf-deploy-host
DEPLOY_HOST_TEMPLATE := cloudformation/cf-deploy-host.yaml
DEPLOY_HOST_PARAMS := cloudformation/parameters/deploy-host.json
DEPLOY_HOST_SECRET_PATH := worxco/deploy-host/root-password

# Deploy Host VPC Peering (per environment, bridges deploy-host VPC to project VPC)
DEPLOY_PEERING_STACK := $(STACK_PREFIX)-deploy-peering
DEPLOY_PEERING_TEMPLATE := cloudformation/cf-deploy-peering.yaml
DEPLOY_PEERING_PARAMS := cloudformation/parameters/deploy-peering-$(ENV).json

# Drupal application lifecycle (per environment — Secrets Manager + SSM params)
APP_DRUPAL_STACK := $(STACK_PREFIX)-app-drupal
APP_DRUPAL_TEMPLATE := cloudformation/cf-app-drupal.yaml
APP_DRUPAL_PARAMS := cloudformation/parameters/app-drupal-$(ENV).json

# Template files
VPC_TEMPLATE := cloudformation/cf-vpc.yaml
IAM_TEMPLATE := cloudformation/cf-iam.yaml
STORAGE_TEMPLATE := cloudformation/cf-storage.yaml
DATABASE_TEMPLATE := cloudformation/cf-database.yaml
CACHE_TEMPLATE := cloudformation/cf-cache.yaml

# Image Builder
IMAGE_BUILDER_STACK := $(STACK_PREFIX)-image-builder
IMAGE_BUILDER_TEMPLATE := cloudformation/cf-image-builder.yaml
IMAGE_BUILDER_PARAMS := cloudformation/parameters/image-builder-$(ENV).json

# Compute Layer
COMPUTE_ALB_STACK := $(STACK_PREFIX)-compute-alb
COMPUTE_NLB_STACK := $(STACK_PREFIX)-compute-nlb
COMPUTE_NGINX_STACK := $(STACK_PREFIX)-compute-nginx
COMPUTE_PHP_STACK := $(STACK_PREFIX)-compute-php

COMPUTE_ALB_TEMPLATE := cloudformation/cf-compute-alb.yaml
COMPUTE_NLB_TEMPLATE := cloudformation/cf-compute-nlb.yaml
COMPUTE_NGINX_TEMPLATE := cloudformation/cf-compute-nginx.yaml
COMPUTE_PHP_TEMPLATE := cloudformation/cf-compute-php.yaml

COMPUTE_ALB_PARAMS := cloudformation/parameters/compute-alb-$(ENV).json
COMPUTE_NLB_PARAMS := cloudformation/parameters/compute-nlb-$(ENV).json
COMPUTE_NGINX_PARAMS := cloudformation/parameters/compute-nginx-$(ENV).json
COMPUTE_PHP_PARAMS := cloudformation/parameters/compute-php-$(ENV).json

# SSM Audit/Remediation
INSTANCE_PROFILE ?= $(ENV)-nginx-instance-profile
SSM_SSH_KEY ?=
SSM_SSH_USER ?= ec2-user

# AWS CLI environment
export AWS_PAGER :=
export AWS_CLI_AUTO_PROMPT := off

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
CYAN := \033[0;36m
NC := \033[0m

# -----------------------------------------------------------------------------
# Helper: Robust CloudFormation Wait
# -----------------------------------------------------------------------------
# aws cloudformation wait has a hard limit of 120 attempts × 30 seconds = 60 min.
# Long-running stacks (RDS Multi-AZ, FSx OpenZFS, Image Builder) can exceed this.
# This helper retries the wait in an outer loop, checking actual stack status
# between retries.
#
# Usage: $(call cf-wait,WAIT_TYPE,STACK_NAME)
#   WAIT_TYPE: stack-create-complete, stack-update-complete, stack-delete-complete
#   STACK_NAME: CloudFormation stack name
define cf-wait
	@WAIT_TYPE="$(1)"; \
	STACK="$(2)"; \
	MAX_RETRIES=5; \
	RETRY=0; \
	while [ $$RETRY -lt $$MAX_RETRIES ]; do \
		if aws cloudformation wait $$WAIT_TYPE \
			--stack-name "$$STACK" \
			--region $(AWS_REGION) 2>/dev/null; then \
			break; \
		fi; \
		RETRY=$$((RETRY + 1)); \
		STATUS=$$(aws cloudformation describe-stacks \
			--stack-name "$$STACK" \
			--query 'Stacks[0].StackStatus' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null || echo "DELETED"); \
		case $$STATUS in \
			*COMPLETE) \
				break ;; \
			*FAILED|*ROLLBACK_COMPLETE) \
				REASON=$$(aws cloudformation describe-stack-events \
					--stack-name "$$STACK" \
					--query 'StackEvents[?ResourceStatus==`CREATE_FAILED`||ResourceStatus==`UPDATE_FAILED`||ResourceStatus==`DELETE_FAILED`]|[0].ResourceStatusReason' \
					--output text \
					--region $(AWS_REGION) 2>/dev/null || echo "Unknown"); \
				echo "$(RED)Stack $$STACK failed ($$STATUS): $$REASON$(NC)"; \
				exit 1 ;; \
			DELETED|DELETE_COMPLETE) \
				break ;; \
			*IN_PROGRESS) \
				echo "  $(YELLOW)Wait timed out but stack still in progress ($$STATUS), retrying ($$RETRY/$$MAX_RETRIES)...$(NC)"; \
				;; \
			*) \
				echo "$(RED)Unexpected stack status: $$STATUS$(NC)"; \
				exit 1 ;; \
		esac; \
	done; \
	if [ $$RETRY -ge $$MAX_RETRIES ]; then \
		echo "$(RED)Error: Stack $$STACK did not complete after $$MAX_RETRIES wait cycles$(NC)"; \
		exit 1; \
	fi
endef

# -----------------------------------------------------------------------------
# Default Target
# -----------------------------------------------------------------------------

.DEFAULT_GOAL := help

env-check:  ## Display current AWS environment variables
	@echo "$(BLUE)AWS Environment Check$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@if [ ! -f .env ]; then \
		echo "  $(YELLOW).env file:       missing (run: cp .env.example .env)$(NC)"; \
	else \
		echo "  $(GREEN).env file:       loaded$(NC)"; \
	fi
	@if [ -n "$${AWS_PROFILE}" ]; then \
		echo "  AWS_PROFILE:         $(CYAN)$${AWS_PROFILE}$(NC)"; \
	else \
		echo "  AWS_PROFILE:         $(CYAN)<instance role>$(NC)"; \
	fi
	@echo "  AWS_REGION:          $(CYAN)$${AWS_REGION:-$(AWS_REGION)}$(NC)"
	@if [ "$${AWS_PAGER+set}" = "set" ]; then \
		echo "  AWS_PAGER:           $(CYAN)(disabled)$(NC)"; \
	else \
		echo "  AWS_PAGER:           $(YELLOW)<not set - may open pager>$(NC)"; \
	fi
	@echo "  AWS_CLI_AUTO_PROMPT: $(CYAN)$${AWS_CLI_AUTO_PROMPT:-<not set>}$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "  ENV (Makefile):      $(CYAN)$(ENV)$(NC)"
	@echo "  PARAM_FILE:          $(CYAN)$(PARAM_FILE)$(NC)"
	@echo "  STACK_PREFIX:        $(CYAN)$(STACK_PREFIX)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(BLUE)Verifying credentials...$(NC)"
	@aws sts get-caller-identity --output table --region $(AWS_REGION) 2>/dev/null \
		|| echo "$(RED)  Failed to get caller identity$(NC)"

help:  ## Show this help message
	@echo "$(BLUE)cf-scalable-web Makefile$(NC)"
	@echo ""
	@echo "$(CYAN)Current Environment:$(NC) ENV=$(ENV)"
	@echo "$(CYAN)Parameter File:$(NC) $(PARAM_FILE)"
	@echo "$(CYAN)Stack Prefix:$(NC) $(STACK_PREFIX)"
	@echo ""
	@echo "$(YELLOW)Validation & Info:$(NC)"
	@echo "  make env-check                Show AWS environment variables"
	@echo "  make validate                 Validate all CloudFormation templates"
	@echo "  make show-params              Show parameters for current ENV"
	@echo "  make status                   Show status of all stacks"
	@echo ""
	@echo "$(YELLOW)Deployment (ENV=sandbox|staging|production):$(NC)"
	@echo "  make deploy-vpc               Deploy VPC stack"
	@echo "  make deploy-iam               Deploy IAM stack"
	@echo "  make deploy-storage           Deploy storage stack (FSx, S3)"
	@echo "  make deploy-database          Deploy database stack (RDS)"
	@echo "  make deploy-cache             Deploy cache stack (ElastiCache)"
	@echo "  make deploy-compute-alb       Deploy ALB stack"
	@echo "  make deploy-compute-nlb       Deploy NLB stack"
	@echo "  make deploy-compute-nginx     Deploy NGINX compute stack"
	@echo "  make deploy-compute-php       Deploy PHP compute stack"
	@echo "  make deploy-compute           Deploy all compute stacks in order"
	@echo "  make deploy-all               Full lifecycle (foundation → AMIs → compute)"
	@echo "  make deploy-allX              Same + data layer + Drupal install + smoke (~75 min)"
	@echo ""
	@echo "$(YELLOW)Drupal Install (local — SQLite, deploy-host only, for iteration):$(NC)"
	@echo "  make install-drupal-local     Install Drupal 11 locally (SQLite, ~3 min)"
	@echo "  make verify-drupal-local      Health check (drush status + queries)"
	@echo "  make serve-drupal-local       Start drush runserver in tmux (port 8080)"
	@echo "  make stop-drupal-local-server Stop the runserver tmux session"
	@echo "  make remove-drupal-local      Wipe local Drupal install"
	@echo "  make reinstall-drupal-local   Wipe and reinstall (full cycle for testing)"
	@echo ""
	@echo "$(YELLOW)Drupal App Stack (cf-app-drupal — Secrets Manager + SSM params, runs anywhere):$(NC)"
	@echo "  make deploy-app-drupal ENV=...    Create Drupal secrets + SSM params (deploy BEFORE install-drupal)"
	@echo "  make verify-app-drupal ENV=...    Show stack outputs + SSM params"
	@echo "  make destroy-app-drupal ENV=...   Delete the stack (CONFIRMED=yes to skip prompt)"
	@echo ""
	@echo "$(YELLOW)Drupal Install (cloud — RDS + FSx, requires ENV=sandbox|staging|production):$(NC)"
	@echo "  make install-drupal ENV=...        Install Drupal 11 against env's RDS+FSx (on deploy-host)"
	@echo "  make install-drupal-remote ENV=... SSM-dispatch install-drupal to deploy-host (from local)"
	@echo "  make smoke-test-drupal ENV=...     Curl the ALB and assert HTTP 200"
	@echo "  make verify-drupal ENV=...         Health check (live env-var-driven settings.php)"
	@echo "  make remove-drupal ENV=...         Drop Drupal tables and wipe FSx files"
	@echo "  make reinstall-drupal ENV=...      Wipe and reinstall against env"
	@echo ""
	@echo "$(YELLOW)Verification:$(NC)"
	@echo "  make verify-all               Verify all stacks"
	@echo "  make verify-vpc               Verify VPC deployment"
	@echo "  make verify-iam               Verify IAM deployment"
	@echo "  make verify-storage           Verify storage deployment"
	@echo "  make verify-database          Verify database deployment"
	@echo "  make verify-cache             Verify cache deployment"
	@echo "  make verify-compute-alb       Verify ALB deployment"
	@echo "  make verify-compute-nlb       Verify NLB deployment"
	@echo "  make verify-compute-nginx     Verify NGINX compute deployment"
	@echo "  make verify-compute-php       Verify PHP compute deployment"
	@echo "  make verify-compute           Verify all compute stacks"
	@echo ""
	@echo "$(YELLOW)Destruction:$(NC)"
	@echo "  make destroy-vpc              Delete VPC stack"
	@echo "  make destroy-iam              Delete IAM stack"
	@echo "  make destroy-storage          Delete storage stack"
	@echo "  make destroy-database         Delete database stack"
	@echo "  make destroy-cache            Delete cache stack"
	@echo "  make destroy-compute-php      Delete PHP compute stack"
	@echo "  make destroy-compute-nginx    Delete NGINX compute stack"
	@echo "  make destroy-compute-nlb      Delete NLB stack"
	@echo "  make destroy-compute-alb      Delete ALB stack"
	@echo "  make destroy-compute          Delete all compute stacks (reverse order)"
	@echo "  make pause-compute            Scale NGINX and PHP ASGs to 0 (saves ~\$$30-50/mo for short pauses)"
	@echo "  make resume-compute           Restore ASGs to pre-pause sizes"
	@echo "  make destroy-all              Delete all stacks (reverse order; CONFIRMED=yes to skip prompt)"
	@echo ""
	@echo "$(YELLOW)Deploy Host:$(NC)"
	@echo "  make deploy-deploy-host       Deploy deploy host (standalone)"
	@echo "  make verify-deploy-host       Show deploy host connection info"
	@echo "  make stop-deploy-host         Stop deploy host"
	@echo "  make start-deploy-host        Start deploy host instance"
	@echo "  make set-deploy-host-password Set root password in Secrets Manager"
	@echo "  make destroy-deploy-host      Delete deploy host (CONFIRMED=yes to skip prompt)"
	@echo "  make install-helpers          (on deploy-host) Sync /usr/local/{bin,sbin}/* from repo after git pull"
	@echo ""
	@echo "$(YELLOW)Deploy Host Peering (ENV=sandbox|staging|production):$(NC)"
	@echo "  make deploy-peering           Peer deploy-host VPC to project VPC"
	@echo "  make destroy-peering          Delete peering stack"
	@echo "  make test-peering             Verify deploy-host can reach FSx/RDS/Valkey"
	@echo ""
	@echo "$(YELLOW)Image Builder (ENV=sandbox|staging|production):$(NC)"
	@echo "  make find-default-subnet      Discover default VPC subnet IDs"
	@echo "  make upload-build-configs     Sync configs to S3 image-builder bucket"
	@echo "  make deploy-image-builder     Deploy Image Builder stack"
	@echo "  make verify-image-builder     Show pipeline statuses and latest builds"
	@echo "  make destroy-image-builder    Delete Image Builder stack + AMIs"
	@echo "  make build-ami-nginx          Trigger NGINX pipeline execution"
	@echo "  make build-ami-php74          Trigger PHP 7.4 pipeline execution"
	@echo "  make build-ami-php83          Trigger PHP 8.3 pipeline execution"
	@echo "  make build-amis               Trigger all 3 pipelines"
	@echo "  make update-ami-param         Write latest AMI to SSM (PIPELINE=nginx)"
	@echo ""
	@echo "$(CYAN)SSM Plugin (for 'aws ssm start-session'):$(NC)"
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		echo "  brew install --cask session-manager-plugin"; \
	else \
		echo "  See: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"; \
	fi
	@echo ""
	@echo "$(YELLOW)Secrets Management:$(NC)"
	@echo "  make init-secrets             Initialize required secrets"
	@echo "  make list-secrets             List all secrets for environment"
	@echo ""
	@echo "$(YELLOW)SSM Management:$(NC)"
	@echo "  make ssm-audit-params         Audit SSM Parameter Store completeness"
	@echo "  make ssm-report               Report instances missing from SSM"
	@echo "  make ssm-remediate            Remediate SSM Agent (SSM_SSH_KEY required)"
	@echo ""
	@echo "$(YELLOW)Testing & Maintenance:$(NC)"
	@echo "  make test                     Run test suite"
	@echo "  make clean                    Clean temporary files"
	@echo "  make consolidate-logs         Merge daily prompt logs (DATE=YYYY-MM-DD)"
	@echo ""
	@echo "$(YELLOW)Examples:$(NC)"
	@echo "  make ENV=sandbox deploy-vpc   Deploy VPC to sandbox"
	@echo "  make ENV=sandbox verify-vpc   Verify sandbox VPC"
	@echo "  make ENV=production status    Show production stack status"
	@echo ""

# -----------------------------------------------------------------------------
# Validation & Info Targets
# -----------------------------------------------------------------------------

validate:  ## Validate all CloudFormation templates + parameter files
	@# Compound deploy targets (deploy-all, deploy-allX) pass VALIDATED=1
	@# after validating once at the top, so sub-targets don't re-validate
	@# all 11 templates + 7 param files on every invocation (was eating
	@# 100+ lines of screen during a deploy-allX run).
	@#
	@# The entire body is one shell invocation (with continuations) so the
	@# early-exit `exit 0` actually terminates the recipe, not just the
	@# first @-line's sub-shell.
	@if [ "$$VALIDATED" = "1" ]; then \
		exit 0; \
	fi; \
	printf "$(BLUE)Validating CFN templates + param files... $(NC)"; \
	TMPFAIL=$$(mktemp); TPL_COUNT=0; PARAM_COUNT=0; \
	for template in $(VPC_TEMPLATE) $(IAM_TEMPLATE) $(STORAGE_TEMPLATE) $(DATABASE_TEMPLATE) $(CACHE_TEMPLATE) $(DEPLOY_HOST_TEMPLATE) $(IMAGE_BUILDER_TEMPLATE) $(COMPUTE_ALB_TEMPLATE) $(COMPUTE_NLB_TEMPLATE) $(COMPUTE_NGINX_TEMPLATE) $(COMPUTE_PHP_TEMPLATE); do \
		if [ -f "$$template" ]; then \
			TPL_COUNT=$$((TPL_COUNT + 1)); \
			OUTPUT=$$(cfn-lint -f parseable "$$template" 2>&1); \
			LINT_EXIT=$$?; \
			if [ $$LINT_EXIT -eq 2 ] || [ $$LINT_EXIT -eq 6 ]; then \
				echo "$(RED)✗ $$template$(NC)" >> $$TMPFAIL; \
				echo "$$OUTPUT" >> $$TMPFAIL; \
			fi; \
		fi; \
	done; \
	for params in $(PARAM_FILE) $(DEPLOY_HOST_PARAMS) $(IMAGE_BUILDER_PARAMS) $(COMPUTE_ALB_PARAMS) $(COMPUTE_NLB_PARAMS) $(COMPUTE_NGINX_PARAMS) $(COMPUTE_PHP_PARAMS); do \
		if [ -f "$$params" ]; then \
			PARAM_COUNT=$$((PARAM_COUNT + 1)); \
			JQ_OUT=$$(jq empty "$$params" 2>&1); \
			JQ_EXIT=$$?; \
			if [ $$JQ_EXIT -ne 0 ]; then \
				echo "$(RED)✗ $$params$(NC)" >> $$TMPFAIL; \
				echo "$$JQ_OUT" >> $$TMPFAIL; \
			fi; \
		fi; \
	done; \
	if [ -s "$$TMPFAIL" ]; then \
		echo ""; \
		cat "$$TMPFAIL"; \
		rm -f "$$TMPFAIL"; \
		exit 1; \
	fi; \
	rm -f "$$TMPFAIL"; \
	echo "$(GREEN)✓ $$TPL_COUNT templates + $$PARAM_COUNT param files$(NC)"

show-params:  ## Show parameters for current environment
	@echo "$(BLUE)Parameters for ENV=$(ENV)$(NC)"
	@echo "$(BLUE)File: $(PARAM_FILE)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@if [ -f $(PARAM_FILE) ]; then \
		jq -r '.Parameters | to_entries | .[] | "  \(.key): \(.value)"' $(PARAM_FILE); \
	else \
		echo "$(RED)Error: Parameter file not found: $(PARAM_FILE)$(NC)"; \
		exit 1; \
	fi

status:  ## Show status of all stacks for current environment
	@echo "$(BLUE)Stack Status for ENV=$(ENV)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@for stack in $(VPC_STACK) $(IAM_STACK) $(STORAGE_STACK) $(DATABASE_STACK) $(CACHE_STACK) $(IMAGE_BUILDER_STACK) $(COMPUTE_ALB_STACK) $(COMPUTE_NLB_STACK) $(COMPUTE_NGINX_STACK) $(COMPUTE_PHP_STACK); do \
		status=$$(aws cloudformation describe-stacks \
			--stack-name "$$stack" \
			--region $(AWS_REGION) \
			--query 'Stacks[0].StackStatus' \
			--output text 2>/dev/null || echo "NOT_EXISTS"); \
		case "$$status" in \
			*COMPLETE*) echo "  $$stack: $(GREEN)$$status$(NC)" ;; \
			*FAILED*|*ROLLBACK*) echo "  $$stack: $(RED)$$status$(NC)" ;; \
			NOT_EXISTS) echo "  $$stack: $(YELLOW)NOT_EXISTS$(NC)" ;; \
			*) echo "  $$stack: $(YELLOW)$$status$(NC)" ;; \
		esac; \
	done

# -----------------------------------------------------------------------------
# Check Parameter File Exists
# -----------------------------------------------------------------------------

check-params:
	@if [ ! -f $(PARAM_FILE) ]; then \
		echo "$(RED)Error: Parameter file not found: $(PARAM_FILE)$(NC)" >&2; \
		echo "Create it: cp cloudformation/parameters/template.json $(PARAM_FILE)" >&2; \
		exit 1; \
	fi

# -----------------------------------------------------------------------------
# Deploy Targets
# -----------------------------------------------------------------------------

deploy-vpc: validate check-params  ## Deploy VPC stack
	@echo "$(BLUE)Deploying VPC stack: $(VPC_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(VPC_TEMPLATE) \
		--stack-name $(VPC_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ VPC stack deployed: $(VPC_STACK)$(NC)"

deploy-iam: validate check-params  ## Deploy IAM stack
	@echo "$(BLUE)Deploying IAM stack: $(IAM_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(IAM_TEMPLATE) \
		--stack-name $(IAM_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ IAM stack deployed: $(IAM_STACK)$(NC)"

deploy-storage: validate check-params  ## Deploy storage stack (FSx ~15-20 min)
	@echo "$(BLUE)Deploying storage stack: $(STORAGE_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(STORAGE_TEMPLATE) \
		--stack-name $(STORAGE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset \
	|| { \
		echo "$(YELLOW)Deploy command returned non-zero, checking stack status...$(NC)"; \
		$(call cf-wait,stack-create-complete,$(STORAGE_STACK)); \
	}
	@echo "$(GREEN)✓ Storage stack deployed: $(STORAGE_STACK)$(NC)"

deploy-database: validate check-params  ## Deploy database stack (RDS ~15-20 min)
	@echo "$(BLUE)Deploying database stack: $(DATABASE_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(DATABASE_TEMPLATE) \
		--stack-name $(DATABASE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset \
	|| { \
		echo "$(YELLOW)Deploy command returned non-zero, checking stack status...$(NC)"; \
		$(call cf-wait,stack-create-complete,$(DATABASE_STACK)); \
	}
	@echo "$(GREEN)✓ Database stack deployed: $(DATABASE_STACK)$(NC)"

deploy-cache: validate check-params  ## Deploy cache stack
	@echo "$(BLUE)Deploying cache stack: $(CACHE_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(CACHE_TEMPLATE) \
		--stack-name $(CACHE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Cache stack deployed: $(CACHE_STACK)$(NC)"

deploy-all:  ## Deploy all stacks from scratch (full lifecycle)
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(BLUE)  Full Deployment: ENV=$(ENV)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@$(MAKE) validate ENV=$(ENV)
	@echo ""
	@echo "$(CYAN)Phase 1: Foundation$(NC)"
	@$(MAKE) deploy-vpc ENV=$(ENV) VALIDATED=1
	@$(MAKE) deploy-peering ENV=$(ENV) VALIDATED=1 || \
		echo "$(YELLOW)  Note: deploy-peering skipped (deploy-host stack may not exist yet)$(NC)"
	@$(MAKE) deploy-iam ENV=$(ENV) VALIDATED=1
	@$(MAKE) deploy-storage ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(CYAN)Phase 2: Image Builder + AMI Builds$(NC)"
	@$(MAKE) deploy-image-builder ENV=$(ENV) VALIDATED=1
	@$(MAKE) upload-build-configs ENV=$(ENV) VALIDATED=1
	@$(MAKE) build-amis ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(BLUE)Waiting for all AMI builds to complete (this takes 20-30 minutes)...$(NC)"
	@echo "$(BLUE)All 3 builds run in parallel — polling all simultaneously.$(NC)"
	@NGINX_DONE=0; PHP74_DONE=0; PHP83_DONE=0; \
	NGINX_ARN=""; PHP74_ARN=""; PHP83_ARN=""; \
	for pipeline in nginx php74 php83; do \
		case $$pipeline in \
			nginx) OUTPUT_KEY="NginxPipelineArn" ;; \
			php74) OUTPUT_KEY="PhpFpm74PipelineArn" ;; \
			php83) OUTPUT_KEY="PhpFpm83PipelineArn" ;; \
		esac; \
		PIPELINE_ARN=$$(aws cloudformation describe-stacks \
			--stack-name $(IMAGE_BUILDER_STACK) \
			--query "Stacks[0].Outputs[?OutputKey==\`$$OUTPUT_KEY\`].OutputValue" \
			--output text \
			--region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$PIPELINE_ARN" ] || [ "$$PIPELINE_ARN" = "None" ]; then \
			echo "$(RED)Error: $$pipeline pipeline ARN not found$(NC)"; \
			exit 1; \
		fi; \
		BUILD_ARN=$$(aws imagebuilder list-image-pipeline-images \
			--image-pipeline-arn "$$PIPELINE_ARN" \
			--query 'imageSummaryList | sort_by(@, &dateCreated) | [-1].arn' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$BUILD_ARN" ] || [ "$$BUILD_ARN" = "None" ]; then \
			echo "$(RED)Error: No build found for $$pipeline$(NC)"; \
			exit 1; \
		fi; \
		case $$pipeline in \
			nginx) NGINX_ARN="$$BUILD_ARN" ;; \
			php74) PHP74_ARN="$$BUILD_ARN" ;; \
			php83) PHP83_ARN="$$BUILD_ARN" ;; \
		esac; \
	done; \
	echo "  Tracking: nginx, php74, php83"; \
	while [ $$NGINX_DONE -eq 0 ] || [ $$PHP74_DONE -eq 0 ] || [ $$PHP83_DONE -eq 0 ]; do \
		for pipeline in nginx php74 php83; do \
			case $$pipeline in \
				nginx) DONE=$$NGINX_DONE; ARN="$$NGINX_ARN" ;; \
				php74) DONE=$$PHP74_DONE; ARN="$$PHP74_ARN" ;; \
				php83) DONE=$$PHP83_DONE; ARN="$$PHP83_ARN" ;; \
			esac; \
			if [ $$DONE -eq 1 ]; then continue; fi; \
			STATUS=$$(aws imagebuilder get-image \
				--image-build-version-arn "$$ARN" \
				--query 'image.state.status' \
				--output text \
				--region $(AWS_REGION) 2>/dev/null); \
			case $$STATUS in \
				AVAILABLE) \
					echo "  $(GREEN)✓ $$pipeline AMI ready$(NC)"; \
					case $$pipeline in \
						nginx) NGINX_DONE=1 ;; \
						php74) PHP74_DONE=1 ;; \
						php83) PHP83_DONE=1 ;; \
					esac ;; \
				FAILED|CANCELLED) \
					REASON=$$(aws imagebuilder get-image \
						--image-build-version-arn "$$ARN" \
						--query 'image.state.reason' \
						--output text \
						--region $(AWS_REGION) 2>/dev/null); \
					echo "  $(RED)✗ $$pipeline AMI build $$STATUS: $$REASON$(NC)"; \
					exit 1 ;; \
				*) ;; \
			esac; \
		done; \
		if [ $$NGINX_DONE -eq 0 ] || [ $$PHP74_DONE -eq 0 ] || [ $$PHP83_DONE -eq 0 ]; then \
			REMAINING=""; \
			[ $$NGINX_DONE -eq 0 ] && REMAINING="$$REMAINING nginx"; \
			[ $$PHP74_DONE -eq 0 ] && REMAINING="$$REMAINING php74"; \
			[ $$PHP83_DONE -eq 0 ] && REMAINING="$$REMAINING php83"; \
			echo "  Waiting on:$$REMAINING (polling every 60s)"; \
			sleep 60; \
		fi; \
	done
	@echo ""
	@echo "$(CYAN)Phase 3: Update AMI Parameters$(NC)"
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=nginx VALIDATED=1
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=php74 VALIDATED=1
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=php83 VALIDATED=1
	@echo ""
	@echo "$(CYAN)Phase 4: Compute Layer$(NC)"
	@$(MAKE) deploy-compute ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(GREEN)========================================$(NC)"
	@echo "$(GREEN)  ✓ Full deployment complete: ENV=$(ENV)$(NC)"
	@echo "$(GREEN)========================================$(NC)"
	@echo ""
	@echo "$(YELLOW)Optional (deploy when needed):$(NC)"
	@echo "  make deploy-database ENV=$(ENV)    # RDS PostgreSQL (~15 min, ~\$$75/mo)"
	@echo "  make deploy-cache ENV=$(ENV)       # ElastiCache Valkey (~2 min, ~\$$12/mo)"
	@echo ""
	@echo "  make deploy-allX ENV=$(ENV)        # everything above + database + cache"

deploy-allX:  ## Deploy ALL incl data layer + Drupal app + install + smoke (~75 min) — set it and forget it
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(BLUE)  Full Deployment + Drupal: ENV=$(ENV)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@$(MAKE) validate ENV=$(ENV)
	@echo ""
	@echo "$(CYAN)Phase 1: Standard deploy-all (VPC through compute)$(NC)"
	@$(MAKE) deploy-all ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(CYAN)Phase 5: Data layer (RDS + ElastiCache, in parallel)$(NC)"
	@# Both stacks are independent — kick off in parallel for speed.
	@# Capture stdout/err to files; show output and propagate failures
	@# after both finish, so user sees both results regardless of which
	@# one had problems.
	@TMPDB=$$(mktemp); TMPCACHE=$$(mktemp); \
	$(MAKE) deploy-database ENV=$(ENV) VALIDATED=1 > "$$TMPDB" 2>&1 & \
	DB_PID=$$!; \
	$(MAKE) deploy-cache ENV=$(ENV) VALIDATED=1 > "$$TMPCACHE" 2>&1 & \
	CACHE_PID=$$!; \
	echo "$(CYAN)  database deploy started (pid $$DB_PID, log $$TMPDB)$(NC)"; \
	echo "$(CYAN)  cache deploy started    (pid $$CACHE_PID, log $$TMPCACHE)$(NC)"; \
	echo "$(CYAN)  waiting for both to complete (typically ~15 min)...$(NC)"; \
	wait $$DB_PID; DB_RC=$$?; \
	wait $$CACHE_PID; CACHE_RC=$$?; \
	echo ""; \
	echo "$(BLUE)=== database output ===$(NC)"; cat "$$TMPDB"; rm -f "$$TMPDB"; \
	echo "$(BLUE)=== cache output ===$(NC)"; cat "$$TMPCACHE"; rm -f "$$TMPCACHE"; \
	if [ $$DB_RC -ne 0 ] || [ $$CACHE_RC -ne 0 ]; then \
		echo "$(RED)One or both data-layer deploys failed (db=$$DB_RC cache=$$CACHE_RC)$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(CYAN)Phase 6: Drupal app stack (Secrets Manager + SSM params)$(NC)"
	@$(MAKE) deploy-app-drupal ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(CYAN)Phase 7: Install Drupal on deploy-host (via SSM, ~5 min)$(NC)"
	@$(MAKE) install-drupal-remote ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(CYAN)Phase 8: End-to-end smoke test (curl ALB)$(NC)"
	@$(MAKE) smoke-test-drupal ENV=$(ENV) VALIDATED=1
	@echo ""
	@echo "$(GREEN)========================================$(NC)"
	@echo "$(GREEN)  ✓ Full deployment + Drupal complete: ENV=$(ENV)$(NC)"
	@echo "$(GREEN)========================================$(NC)"
	@echo ""
	@if command -v refresh-env-config >/dev/null 2>&1; then \
		echo "$(CYAN)Refreshing /etc/worxco/envs/$(ENV) and /etc/hosts FSx entry...$(NC)"; \
		sudo refresh-env-config $(ENV) || true; \
	else \
		echo "$(YELLOW)Note: local refresh-env-config skipped (only available on deploy-host).$(NC)"; \
	fi

# -----------------------------------------------------------------------------
# Drupal Local Install (SQLite, deploy-host only — fast iteration playground)
# -----------------------------------------------------------------------------

install-drupal-local:  ## Install Drupal 11 locally on deploy-host (SQLite, no FSx/RDS)
	@if [ -f /etc/worxco/deploy-host-marker ]; then \
		bash scripts/deploy-host/install-drupal-local.sh; \
	else \
		echo "$(YELLOW)This target runs on the deploy-host (where /etc/worxco/deploy-host-marker exists).$(NC)"; \
		echo "$(YELLOW)Connect to the deploy-host first:$(NC)"; \
		echo "  $(CYAN)ssh deploy-host    # or: aws ssm start-session --target <instance-id>$(NC)"; \
		echo "  $(CYAN)cd ~/projects/cf-scalable-web && git pull$(NC)"; \
		echo "  $(CYAN)make install-drupal-local$(NC)"; \
		exit 1; \
	fi

remove-drupal-local:  ## Wipe local Drupal install (run on deploy-host)
	@if [ -f /etc/worxco/deploy-host-marker ]; then \
		bash scripts/deploy-host/remove-drupal-local.sh; \
	else \
		echo "$(YELLOW)Run this on the deploy-host. See: make install-drupal-local$(NC)"; \
		exit 1; \
	fi

reinstall-drupal-local: remove-drupal-local install-drupal-local  ## Wipe + install Drupal locally

verify-drupal-local:  ## Run health checks on local Drupal install (drush status + queries)
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host. See: make install-drupal-local$(NC)"; exit 1; \
	fi
	@if [ ! -f /var/www/local/drupal/.installed ]; then \
		echo "$(RED)Drupal not installed locally. Run: make install-drupal-local$(NC)"; exit 1; \
	fi
	@echo "$(BLUE)=== drush status ==="
	@cd /var/www/local/drupal && vendor/bin/drush status \
		--fields=drupal-version,db-driver,db-status,bootstrap,uri,php-version
	@echo ""
	@echo "$(BLUE)=== admin user ==="
	@cd /var/www/local/drupal && vendor/bin/drush user:information admin
	@echo ""
	@echo "$(BLUE)=== database row counts ==="
	@cd /var/www/local/drupal && vendor/bin/drush sqlq \
		"SELECT 'users' AS what, count(*) FROM users_field_data UNION ALL \
		 SELECT 'nodes',           count(*) FROM node_field_data UNION ALL \
		 SELECT 'config',          count(*) FROM config UNION ALL \
		 SELECT 'sessions',        count(*) FROM sessions;"
	@echo ""
	@echo "$(BLUE)=== recent watchdog entries ==="
	@cd /var/www/local/drupal && vendor/bin/drush watchdog:show --count=5 2>/dev/null \
		|| echo "  (no log entries yet)"
	@echo ""
	@echo "$(GREEN)✓ Local Drupal install looks healthy$(NC)"

serve-drupal-local:  ## Start drush runserver in tmux (port 8080) — survives detach
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host.$(NC)"; exit 1; \
	fi
	@if [ ! -f /var/www/local/drupal/.installed ]; then \
		echo "$(RED)Drupal not installed locally. Run: make install-drupal-local$(NC)"; exit 1; \
	fi
	@if tmux has-session -t drupal-local 2>/dev/null; then \
		echo "$(CYAN)drush runserver is already running in tmux session 'drupal-local'.$(NC)"; \
	else \
		echo "$(BLUE)Starting drush runserver in tmux session 'drupal-local'...$(NC)"; \
		tmux new-session -d -s drupal-local \
			"cd /var/www/local/drupal && vendor/bin/drush runserver 0.0.0.0:8080"; \
		sleep 2; \
		echo "$(GREEN)✓ Server started$(NC)"; \
	fi
	@echo ""
	@echo "$(YELLOW)To view server logs (Ctrl-B D to detach):$(NC)"
	@echo "  $(CYAN)tmux attach -t drupal-local$(NC)"
	@echo ""
	@echo "$(YELLOW)To browse from your Mac:$(NC)"
	@echo "  $(CYAN)# In a Mac terminal:$(NC)"
	@echo "  $(CYAN)ssh -L 8080:localhost:8080 deploy-host$(NC)"
	@echo "  $(CYAN)# Then open http://localhost:8080 in your browser$(NC)"
	@echo "  $(CYAN)# Login: admin / admin$(NC)"
	@echo ""
	@echo "$(YELLOW)To stop the server: make stop-drupal-local-server$(NC)"

# -----------------------------------------------------------------------------
# Drupal Application Lifecycle Stack (cf-app-drupal)
# -----------------------------------------------------------------------------
# Owns Secrets Manager entries and SSM parameters for a Drupal install in a
# given environment. Deploy this BEFORE install-drupal — install-drupal will
# read the existing secrets rather than auto-creating them. Optional but
# recommended for production: brings audit trail and rotation policy under
# CloudFormation lifecycle.

deploy-app-drupal:  ## Deploy Drupal app stack (Secrets Manager + SSM params)
	@echo "$(BLUE)Deploying app-drupal stack: $(APP_DRUPAL_STACK)$(NC)"
	@if [ ! -f $(APP_DRUPAL_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(APP_DRUPAL_PARAMS)$(NC)"; \
		exit 1; \
	fi
	@time aws cloudformation deploy \
		--template-file $(APP_DRUPAL_TEMPLATE) \
		--stack-name $(APP_DRUPAL_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(APP_DRUPAL_PARAMS)) \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ app-drupal stack deployed: $(APP_DRUPAL_STACK)$(NC)"
	@echo ""
	@echo "$(CYAN)Secrets created (or pre-existing) and managed by this stack:$(NC)"
	@echo "  worxco/$(ENV)/drupal/admin-password"
	@echo "  worxco/$(ENV)/drupal/db-password"
	@echo ""
	@echo "$(CYAN)SSM parameters under /$(ENV)/drupal/ (db-name, db-user, site-name,$(NC)"
	@echo "$(CYAN)install-path, admin-username, admin-email)$(NC)"
	@echo ""
	@echo "$(YELLOW)Next: run 'make install-drupal ENV=$(ENV)' on the deploy-host$(NC)"

destroy-app-drupal:  ## Delete Drupal app stack (Secrets Manager + SSM params; CONFIRMED=yes to skip prompt)
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This deletes all Secrets Manager entries and SSM parameters$(NC)"; \
		echo "$(RED)for Drupal in $(ENV). The Drupal install on FSx + RDS is NOT touched$(NC)"; \
		echo "$(RED)by this — but it will fail to load until secrets are restored.$(NC)"; \
		echo "$(CYAN)(Pass CONFIRMED=yes to skip this prompt for unattended runs.)$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then echo "Cancelled"; exit 0; fi; \
	fi
	@if [ "$(ENV)" = "production" ] && [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)Production destroy: type 'WIPE PRODUCTION SECRETS' to proceed$(NC)"; \
		read -r prod_confirm; \
		[ "$$prod_confirm" = "WIPE PRODUCTION SECRETS" ] || { echo "Cancelled"; exit 1; }; \
	fi
	@echo "$(YELLOW)Deleting app-drupal stack: $(APP_DRUPAL_STACK)$(NC)"
	@time aws cloudformation delete-stack \
		--stack-name $(APP_DRUPAL_STACK) \
		--region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(APP_DRUPAL_STACK))
	@echo "$(GREEN)✓ app-drupal stack deleted: $(APP_DRUPAL_STACK)$(NC)"
	@echo "$(CYAN)Note: Secrets are scheduled for deletion with a 30-day recovery window.$(NC)"
	@echo "$(CYAN)To force-delete immediately:$(NC)"
	@echo "  aws secretsmanager delete-secret --secret-id worxco/$(ENV)/drupal/admin-password --force-delete-without-recovery"
	@echo "  aws secretsmanager delete-secret --secret-id worxco/$(ENV)/drupal/db-password    --force-delete-without-recovery"

verify-app-drupal:  ## Show app-drupal stack outputs and the secrets/params it owns
	@echo "$(BLUE)app-drupal stack: $(APP_DRUPAL_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(APP_DRUPAL_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null \
		|| { echo "$(RED)Stack not found — run: make deploy-app-drupal ENV=$(ENV)$(NC)"; exit 1; }
	@echo ""
	@echo "$(CYAN)SSM parameters:$(NC)"
	@aws ssm get-parameters-by-path \
		--path "/$(ENV)/drupal/" \
		--query 'Parameters[].{Name:Name,Value:Value}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null

# -----------------------------------------------------------------------------
# Drupal Install (cloud — RDS + FSx, deploy-host only)
# -----------------------------------------------------------------------------

install-drupal:  ## Install Drupal 11 against ENV's RDS+FSx (~3-5 min)
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host (or via SSM dispatch).$(NC)"; \
		echo "$(CYAN)ssh deploy-host && cd ~/projects/cf-scalable-web && make install-drupal ENV=$(ENV)$(NC)"; \
		exit 1; \
	fi
	@if [ "$(ENV)" = "production" ]; then \
		echo "$(YELLOW)WARNING: ENV=production. Confirm by typing 'production':$(NC)"; \
		read -r confirm; \
		[ "$$confirm" = "production" ] || { echo "Cancelled"; exit 1; }; \
	fi
	@bash scripts/deploy-host/install-drupal.sh $(ENV)

remove-drupal:  ## Drop Drupal tables and wipe FSx files for ENV (preserves Secrets Manager)
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host.$(NC)"; exit 1; \
	fi
	@if [ "$(ENV)" = "production" ]; then \
		echo "$(RED)DANGER: ENV=production. Type 'WIPE PRODUCTION' to proceed:$(NC)"; \
		read -r confirm; \
		[ "$$confirm" = "WIPE PRODUCTION" ] || { echo "Cancelled"; exit 1; }; \
	fi
	@bash scripts/deploy-host/remove-drupal.sh $(ENV)

reinstall-drupal: remove-drupal install-drupal  ## Wipe + reinstall Drupal for ENV

verify-drupal:  ## Health check on the cloud Drupal install for ENV (drush status + queries)
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host.$(NC)"; exit 1; \
	fi
	@if [ ! -f /var/www/$(ENV)/drupal/.installed ]; then \
		echo "$(RED)Drupal not installed for $(ENV). Run: make install-drupal ENV=$(ENV)$(NC)"; \
		exit 1; \
	fi
	@RDS_ENDPOINT=$$(aws ssm get-parameter --name "/$(ENV)/rds/endpoint" \
		--query 'Parameter.Value' --output text); \
	DRUPAL_DB_RAW=$$(aws secretsmanager get-secret-value \
		--secret-id "worxco/$(ENV)/drupal/db-password" \
		--query SecretString --output text); \
	DRUPAL_DB_PW=$$(echo "$$DRUPAL_DB_RAW" | jq -r '.password // empty' 2>/dev/null || true); \
	[ -z "$$DRUPAL_DB_PW" ] && DRUPAL_DB_PW="$$DRUPAL_DB_RAW"; \
	export ENVIRONMENT_NAME="$(ENV)" \
		DRUPAL_DB_HOST="$$RDS_ENDPOINT" DRUPAL_DB_PORT="5432" \
		DRUPAL_DB_NAME="drupal" DRUPAL_DB_USER="drupal_user" \
		DRUPAL_DB_PASS="$$DRUPAL_DB_PW"; \
	echo "$(BLUE)=== drush status ==="; \
	cd /var/www/$(ENV)/drupal && vendor/bin/drush status \
		--fields=drupal-version,db-driver,db-status,bootstrap,uri,php-version; \
	echo ""; \
	echo "$(BLUE)=== admin user ==="; \
	cd /var/www/$(ENV)/drupal && vendor/bin/drush user:information admin; \
	echo ""; \
	echo "$(BLUE)=== database row counts ==="; \
	cd /var/www/$(ENV)/drupal && vendor/bin/drush sqlq \
		"SELECT 'users' AS what, count(*) FROM users_field_data UNION ALL \
		 SELECT 'nodes',           count(*) FROM node_field_data UNION ALL \
		 SELECT 'config',          count(*) FROM config UNION ALL \
		 SELECT 'sessions',        count(*) FROM sessions;"
	@echo ""
	@echo "$(GREEN)✓ Drupal install for $(ENV) looks healthy$(NC)"

stop-drupal-local-server:  ## Stop the drush runserver tmux session
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host.$(NC)"; exit 1; \
	fi
	@if tmux has-session -t drupal-local 2>/dev/null; then \
		tmux kill-session -t drupal-local; \
		echo "$(GREEN)✓ Server stopped (tmux session 'drupal-local' killed)$(NC)"; \
	else \
		echo "$(CYAN)No drush runserver session running.$(NC)"; \
	fi

# -----------------------------------------------------------------------------
# Deploy-Host Helper Sync (after a git pull, refresh installed helpers)
# -----------------------------------------------------------------------------
# Avoids the friction of running 'sudo install' for each helper after every
# 'git pull'. Equivalent to the helper-installation portion of bootstrap.sh
# but doesn't run apt installs or replace already-running services.

install-helpers:  ## Re-install /usr/local/bin/* helpers from scripts/deploy-host/
	@if [ ! -f /etc/worxco/deploy-host-marker ]; then \
		echo "$(YELLOW)Run this on the deploy-host.$(NC)"; exit 1; \
	fi
	@echo "$(BLUE)Installing helpers from $(CURDIR)/scripts/deploy-host/$(NC)"
	@sudo install -m 0755 scripts/deploy-host/info-env           /usr/local/bin/info-env
	@sudo install -m 0755 scripts/deploy-host/show-env           /usr/local/bin/show-env
	@sudo install -m 0755 scripts/deploy-host/psql-env           /usr/local/bin/psql-env
	@sudo install -m 0755 scripts/deploy-host/valkey-env         /usr/local/bin/valkey-env
	@sudo install -m 0755 scripts/deploy-host/mount-env          /usr/local/sbin/mount-env
	@sudo install -m 0755 scripts/deploy-host/refresh-env-config /usr/local/sbin/refresh-env-config
	@sudo install -m 0440 scripts/deploy-host/worxco-refresh-env-config.sudoers /etc/sudoers.d/worxco-refresh-env-config
	@echo "$(GREEN)✓ Helpers installed.$(NC) Tip: re-run 'sudo refresh-env-config <env>' after this if the file format changed."

# -----------------------------------------------------------------------------
# Verify Targets
# -----------------------------------------------------------------------------

verify-vpc:  ## Verify VPC deployment
	@echo "$(BLUE)Verifying VPC stack: $(VPC_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. VPC:$(NC)"
	@aws ec2 describe-vpcs \
		--filters "Name=tag:Name,Values=$(ENV)-vpc" \
		--query 'Vpcs[0].{VpcId:VpcId,CidrBlock:CidrBlock,State:State}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Subnets:$(NC)"
	@aws ec2 describe-subnets \
		--filters "Name=tag:aws:cloudformation:stack-name,Values=$(VPC_STACK)" \
		--query 'Subnets[].{Name:Tags[?Key==`Name`].Value|[0],CidrBlock:CidrBlock,AZ:AvailabilityZone}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. Security Groups:$(NC)"
	@aws ec2 describe-security-groups \
		--filters "Name=tag:aws:cloudformation:stack-name,Values=$(VPC_STACK)" \
		--query 'SecurityGroups[].{Name:Tags[?Key==`Name`].Value|[0],GroupId:GroupId}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)4. CloudFormation Exports:$(NC)"
	@aws cloudformation list-exports \
		--query 'Exports[?starts_with(Name, `$(ENV)`)].{Name:Name,Value:Value}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)5. VPC Endpoints:$(NC)"
	@vpc_id=$$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$(ENV)-vpc" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION) 2>/dev/null); \
	if [ "$$vpc_id" != "None" ] && [ -n "$$vpc_id" ]; then \
		aws ec2 describe-vpc-endpoints \
			--filters "Name=vpc-id,Values=$$vpc_id" \
			--query 'VpcEndpoints[].{ServiceName:ServiceName,State:State,EndpointId:VpcEndpointId}' \
			--output table \
			--region $(AWS_REGION) 2>/dev/null || echo "  None"; \
	else \
		echo "  $(RED)VPC not found$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)6. NAT Gateways:$(NC)"
	@vpc_id=$$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$(ENV)-vpc" --query 'Vpcs[0].VpcId' --output text --region $(AWS_REGION) 2>/dev/null); \
	if [ "$$vpc_id" != "None" ] && [ -n "$$vpc_id" ]; then \
		result=$$(aws ec2 describe-nat-gateways \
			--filter "Name=vpc-id,Values=$$vpc_id" "Name=state,Values=available,pending" \
			--query 'NatGateways[].{NatGatewayId:NatGatewayId,State:State}' \
			--output table \
			--region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$result" ]; then \
			echo "  $(GREEN)None (using VPC Endpoints instead)$(NC)"; \
		else \
			echo "$$result"; \
		fi; \
	else \
		echo "  $(RED)VPC not found$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)7. All Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(VPC_STACK) \
		--query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ VPC verification complete$(NC)"

verify-iam:  ## Verify IAM deployment
	@echo "$(BLUE)Verifying IAM stack: $(IAM_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. IAM Roles:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(IAM_STACK) \
		--query 'StackResources[?ResourceType==`AWS::IAM::Role`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Instance Profiles:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(IAM_STACK) \
		--query 'StackResources[?ResourceType==`AWS::IAM::InstanceProfile`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. All Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(IAM_STACK) \
		--query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ IAM verification complete$(NC)"

verify-storage:  ## Verify storage deployment
	@echo "$(BLUE)Verifying storage stack: $(STORAGE_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. FSx File Systems:$(NC)"
	@aws fsx describe-file-systems \
		--query 'FileSystems[?Tags[?Key==`aws:cloudformation:stack-name` && Value==`$(STORAGE_STACK)`]].{FileSystemId:FileSystemId,Type:FileSystemType,Lifecycle:Lifecycle}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. S3 Buckets:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(STORAGE_STACK) \
		--query 'StackResources[?ResourceType==`AWS::S3::Bucket`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. All Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(STORAGE_STACK) \
		--query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Storage verification complete$(NC)"

verify-database:  ## Verify database deployment
	@echo "$(BLUE)Verifying database stack: $(DATABASE_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. RDS Instances:$(NC)"
	@aws rds describe-db-instances \
		--query 'DBInstances[?TagList[?Key==`aws:cloudformation:stack-name` && Value==`$(DATABASE_STACK)`]].{DBInstanceId:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Endpoint:Endpoint.Address}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. DB Subnet Groups:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(DATABASE_STACK) \
		--query 'StackResources[?ResourceType==`AWS::RDS::DBSubnetGroup`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. All Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(DATABASE_STACK) \
		--query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Database verification complete$(NC)"

verify-cache:  ## Verify cache deployment
	@echo "$(BLUE)Verifying cache stack: $(CACHE_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. ElastiCache Clusters:$(NC)"
	@aws elasticache describe-cache-clusters \
		--query 'CacheClusters[].{CacheClusterId:CacheClusterId,Engine:Engine,Status:CacheClusterStatus,NodeType:CacheNodeType}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Replication Groups:$(NC)"
	@aws elasticache describe-replication-groups \
		--query 'ReplicationGroups[].{ReplicationGroupId:ReplicationGroupId,Status:Status,NodeGroups:NodeGroups[0].PrimaryEndpoint.Address}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. All Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(CACHE_STACK) \
		--query 'StackResources[].{Type:ResourceType,LogicalId:LogicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Cache verification complete$(NC)"

verify-all: verify-vpc verify-iam verify-storage verify-database verify-cache  ## Verify all stacks
	@echo ""
	@echo "$(GREEN)========================================$(NC)"
	@echo "$(GREEN)✓ All stacks verified for ENV=$(ENV)$(NC)"
	@echo "$(GREEN)========================================$(NC)"

# -----------------------------------------------------------------------------
# Destroy Targets
# -----------------------------------------------------------------------------

destroy-vpc:  ## Delete VPC stack
	@echo "$(YELLOW)Deleting VPC stack: $(VPC_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(VPC_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(VPC_STACK))
	@echo "$(GREEN)✓ VPC stack deleted: $(VPC_STACK)$(NC)"

destroy-iam:  ## Delete IAM stack
	@echo "$(YELLOW)Deleting IAM stack: $(IAM_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(IAM_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(IAM_STACK))
	@echo "$(GREEN)✓ IAM stack deleted: $(IAM_STACK)$(NC)"

destroy-storage:  ## Delete storage stack (WARNING: Data loss!)
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete FSx and S3 with all data!$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled"; \
			exit 0; \
		fi; \
	fi
	@echo "$(BLUE)Emptying S3 buckets in stack $(STORAGE_STACK) before deletion...$(NC)"
	@BUCKETS=$$(aws cloudformation describe-stack-resources \
		--stack-name $(STORAGE_STACK) \
		--region $(AWS_REGION) \
		--query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
		--output text 2>/dev/null || echo ""); \
	for bucket in $$BUCKETS; do \
		if [ -n "$$bucket" ]; then \
			echo "  $(YELLOW)Emptying bucket: $$bucket$(NC)"; \
			aws s3 rm "s3://$$bucket" --recursive --region $(AWS_REGION) 2>/dev/null || true; \
			VERSIONS=$$(aws s3api list-object-versions --bucket "$$bucket" \
				--query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
				--output json --region $(AWS_REGION) 2>/dev/null); \
			if [ "$$VERSIONS" != '{"Objects": null}' ] && [ -n "$$VERSIONS" ]; then \
				aws s3api delete-objects --bucket "$$bucket" \
					--delete "$$VERSIONS" --region $(AWS_REGION) >/dev/null 2>&1 || true; \
			fi; \
			MARKERS=$$(aws s3api list-object-versions --bucket "$$bucket" \
				--query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
				--output json --region $(AWS_REGION) 2>/dev/null); \
			if [ "$$MARKERS" != '{"Objects": null}' ] && [ -n "$$MARKERS" ]; then \
				aws s3api delete-objects --bucket "$$bucket" \
					--delete "$$MARKERS" --region $(AWS_REGION) >/dev/null 2>&1 || true; \
			fi; \
			echo "  $(GREEN)✓ Bucket emptied: $$bucket$(NC)"; \
		fi; \
	done
	@echo "$(YELLOW)Deleting storage stack: $(STORAGE_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(STORAGE_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(STORAGE_STACK))
	@echo "$(GREEN)✓ Storage stack deleted: $(STORAGE_STACK)$(NC)"

destroy-database:  ## Delete database stack (WARNING: Data loss!)
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete the database and all data!$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled"; \
			exit 0; \
		fi; \
	fi
	@echo "$(BLUE)Disabling RDS deletion protection...$(NC)"
	@aws rds modify-db-instance \
		--db-instance-identifier $(ENV)-postgres \
		--no-deletion-protection \
		--apply-immediately \
		--region $(AWS_REGION) >/dev/null 2>&1 || true
	@echo "$(YELLOW)Deleting database stack: $(DATABASE_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(DATABASE_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(DATABASE_STACK))
	@echo "$(GREEN)✓ Database stack deleted: $(DATABASE_STACK)$(NC)"

destroy-cache:  ## Delete cache stack
	@echo "$(YELLOW)Deleting cache stack: $(CACHE_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(CACHE_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(CACHE_STACK))
	@echo "$(GREEN)✓ Cache stack deleted: $(CACHE_STACK)$(NC)"

destroy-all:  ## Delete all stacks (reverse order; pass CONFIRMED=yes to skip prompt)
	@echo "$(RED)========================================$(NC)"
	@echo "$(RED)WARNING: This will DELETE ALL STACKS$(NC)"
	@echo "$(RED)Environment: $(ENV)$(NC)"
	@echo "$(RED)========================================$(NC)"
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(CYAN)(Pass CONFIRMED=yes to skip this prompt for unattended runs.)$(NC)"; \
		read -p "Type 'yes' to confirm COMPLETE TEARDOWN: " confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled"; \
			exit 0; \
		fi; \
	fi
	@$(MAKE) destroy-compute ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-image-builder ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-cache ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-database ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-storage ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-iam ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-peering ENV=$(ENV) || true
	@$(MAKE) destroy-vpc ENV=$(ENV) CONFIRMED=yes
	@echo "$(GREEN)✓ All stacks deleted for ENV=$(ENV)$(NC)"

# -----------------------------------------------------------------------------
# Compute Layer Deploy Targets
# -----------------------------------------------------------------------------

deploy-compute-alb: validate  ## Deploy ALB stack
	@echo "$(BLUE)Deploying ALB stack: $(COMPUTE_ALB_STACK)$(NC)"
	@if [ ! -f $(COMPUTE_ALB_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(COMPUTE_ALB_PARAMS)$(NC)"; \
		exit 1; \
	fi
	@time aws cloudformation deploy \
		--template-file $(COMPUTE_ALB_TEMPLATE) \
		--stack-name $(COMPUTE_ALB_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(COMPUTE_ALB_PARAMS)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ ALB stack deployed: $(COMPUTE_ALB_STACK)$(NC)"

deploy-compute-nlb: validate  ## Deploy NLB stack
	@echo "$(BLUE)Deploying NLB stack: $(COMPUTE_NLB_STACK)$(NC)"
	@if [ ! -f $(COMPUTE_NLB_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(COMPUTE_NLB_PARAMS)$(NC)"; \
		exit 1; \
	fi
	@time aws cloudformation deploy \
		--template-file $(COMPUTE_NLB_TEMPLATE) \
		--stack-name $(COMPUTE_NLB_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(COMPUTE_NLB_PARAMS)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ NLB stack deployed: $(COMPUTE_NLB_STACK)$(NC)"

deploy-compute-nginx: validate  ## Deploy NGINX compute stack
	@echo "$(BLUE)Deploying NGINX compute stack: $(COMPUTE_NGINX_STACK)$(NC)"
	@if [ ! -f $(COMPUTE_NGINX_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(COMPUTE_NGINX_PARAMS)$(NC)"; \
		exit 1; \
	fi
	@time aws cloudformation deploy \
		--template-file $(COMPUTE_NGINX_TEMPLATE) \
		--stack-name $(COMPUTE_NGINX_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(COMPUTE_NGINX_PARAMS)) ForceUpdateToken=$$(date +%s) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ NGINX compute stack deployed: $(COMPUTE_NGINX_STACK)$(NC)"

deploy-compute-php: validate  ## Deploy PHP compute stack
	@echo "$(BLUE)Deploying PHP compute stack: $(COMPUTE_PHP_STACK)$(NC)"
	@if [ ! -f $(COMPUTE_PHP_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(COMPUTE_PHP_PARAMS)$(NC)"; \
		exit 1; \
	fi
	@time aws cloudformation deploy \
		--template-file $(COMPUTE_PHP_TEMPLATE) \
		--stack-name $(COMPUTE_PHP_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(COMPUTE_PHP_PARAMS)) ForceUpdateToken=$$(date +%s) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ PHP compute stack deployed: $(COMPUTE_PHP_STACK)$(NC)"

deploy-compute: deploy-compute-alb deploy-compute-nlb deploy-compute-nginx deploy-compute-php  ## Deploy all compute stacks in order
	@echo "$(GREEN)✓ All compute stacks deployed for ENV=$(ENV)$(NC)"

# -----------------------------------------------------------------------------
# Compute Layer Verify Targets
# -----------------------------------------------------------------------------

verify-compute-alb:  ## Verify ALB deployment
	@echo "$(BLUE)Verifying ALB stack: $(COMPUTE_ALB_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. Load Balancer:$(NC)"
	@aws elbv2 describe-load-balancers \
		--names "$(ENV)-alb" \
		--query 'LoadBalancers[0].{DNSName:DNSName,State:State.Code,Scheme:Scheme}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Target Groups:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(COMPUTE_ALB_STACK) \
		--query 'StackResources[?ResourceType==`AWS::ElasticLoadBalancingV2::TargetGroup`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. SSM Parameter (/environment/name):$(NC)"
	@aws ssm get-parameter \
		--name "/environment/name" \
		--query 'Parameter.{Name:Name,Value:Value}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ ALB verification complete$(NC)"

verify-compute-nlb:  ## Verify NLB deployment
	@echo "$(BLUE)Verifying NLB stack: $(COMPUTE_NLB_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. Load Balancer:$(NC)"
	@aws elbv2 describe-load-balancers \
		--names "$(ENV)-nlb" \
		--query 'LoadBalancers[0].{DNSName:DNSName,State:State.Code,Scheme:Scheme}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Target Groups:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(COMPUTE_NLB_STACK) \
		--query 'StackResources[?ResourceType==`AWS::ElasticLoadBalancingV2::TargetGroup`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. Listeners:$(NC)"
	@NLB_ARN=$$(aws elbv2 describe-load-balancers \
		--names "$(ENV)-nlb" \
		--query 'LoadBalancers[0].LoadBalancerArn' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -n "$$NLB_ARN" ] && [ "$$NLB_ARN" != "None" ]; then \
		aws elbv2 describe-listeners \
			--load-balancer-arn "$$NLB_ARN" \
			--query 'Listeners[].{Port:Port,Protocol:Protocol}' \
			--output table \
			--region $(AWS_REGION) 2>/dev/null; \
	else \
		echo "  $(RED)NLB not found$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)4. SSM Parameter (NLB endpoint):$(NC)"
	@aws ssm get-parameter \
		--name "/$(ENV)/nlb/endpoint" \
		--query 'Parameter.{Name:Name,Value:Value}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ NLB verification complete$(NC)"

verify-compute-nginx:  ## Verify NGINX compute deployment
	@echo "$(BLUE)Verifying NGINX compute stack: $(COMPUTE_NGINX_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. Auto Scaling Group:$(NC)"
	@aws autoscaling describe-auto-scaling-groups \
		--auto-scaling-group-names "$(ENV)-nginx-asg" \
		--query 'AutoScalingGroups[0].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity,HealthCheckType:HealthCheckType,Instances:length(Instances)}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Instance Status:$(NC)"
	@aws autoscaling describe-auto-scaling-groups \
		--auto-scaling-group-names "$(ENV)-nginx-asg" \
		--query 'AutoScalingGroups[0].Instances[].{InstanceId:InstanceId,LifecycleState:LifecycleState,HealthStatus:HealthStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ NGINX compute verification complete$(NC)"

verify-compute-php:  ## Verify PHP compute deployment
	@echo "$(BLUE)Verifying PHP compute stack: $(COMPUTE_PHP_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. PHP 7.4 Auto Scaling Group:$(NC)"
	@aws autoscaling describe-auto-scaling-groups \
		--auto-scaling-group-names "$(ENV)-php74-asg" \
		--query 'AutoScalingGroups[0].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity,Instances:length(Instances)}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(YELLOW)Not found (may be disabled)$(NC)"
	@echo ""
	@echo "$(CYAN)2. PHP 8.3 Auto Scaling Group:$(NC)"
	@aws autoscaling describe-auto-scaling-groups \
		--auto-scaling-group-names "$(ENV)-php83-asg" \
		--query 'AutoScalingGroups[0].{MinSize:MinSize,MaxSize:MaxSize,DesiredCapacity:DesiredCapacity,Instances:length(Instances)}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(YELLOW)Not found (may be disabled)$(NC)"
	@echo ""
	@echo "$(GREEN)✓ PHP compute verification complete$(NC)"

verify-compute: verify-compute-alb verify-compute-nlb verify-compute-nginx verify-compute-php  ## Verify all compute stacks
	@echo ""
	@echo "$(GREEN)========================================$(NC)"
	@echo "$(GREEN)✓ All compute stacks verified for ENV=$(ENV)$(NC)"
	@echo "$(GREEN)========================================$(NC)"

# -----------------------------------------------------------------------------
# Compute Layer Destroy Targets
# -----------------------------------------------------------------------------

destroy-compute-php:  ## Delete PHP compute stack
	@echo "$(YELLOW)Deleting PHP compute stack: $(COMPUTE_PHP_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(COMPUTE_PHP_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(COMPUTE_PHP_STACK))
	@echo "$(GREEN)✓ PHP compute stack deleted: $(COMPUTE_PHP_STACK)$(NC)"

destroy-compute-nginx:  ## Delete NGINX compute stack
	@echo "$(YELLOW)Deleting NGINX compute stack: $(COMPUTE_NGINX_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(COMPUTE_NGINX_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(COMPUTE_NGINX_STACK))
	@echo "$(GREEN)✓ NGINX compute stack deleted: $(COMPUTE_NGINX_STACK)$(NC)"

destroy-compute-nlb:  ## Delete NLB stack
	@echo "$(YELLOW)Deleting NLB stack: $(COMPUTE_NLB_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(COMPUTE_NLB_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(COMPUTE_NLB_STACK))
	@echo "$(GREEN)✓ NLB stack deleted: $(COMPUTE_NLB_STACK)$(NC)"

destroy-compute-alb:  ## Delete ALB stack
	@echo "$(YELLOW)Deleting ALB stack: $(COMPUTE_ALB_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(COMPUTE_ALB_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(COMPUTE_ALB_STACK))
	@echo "$(GREEN)✓ ALB stack deleted: $(COMPUTE_ALB_STACK)$(NC)"

destroy-compute: destroy-compute-php destroy-compute-nginx destroy-compute-nlb destroy-compute-alb  ## Delete all compute stacks (reverse order)
	@echo "$(GREEN)✓ All compute stacks deleted for ENV=$(ENV)$(NC)"

# -----------------------------------------------------------------------------
# Compute Pause / Resume (cost optimization for short pauses)
# -----------------------------------------------------------------------------
# Scales NGINX and PHP auto-scaling groups to 0 to stop EC2 hour charges
# during short pauses (overnight, between sessions). ALB/NLB still cost
# (~$32/mo combined) but EC2 hour charges go to zero.
#
# State is preserved per-ASG in SSM at /<env>/asg-pause-state/<asg-name>
# so resume restores the exact same min/max/desired sizes you had.
#
# Note: 'make deploy-compute' resets ASG sizes from CFN parameters and
# would unpause without going through resume. Orphaned SSM state is
# harmless — delete with 'aws ssm delete-parameters-by-path' if it bothers
# you.

pause-compute:  ## Scale NGINX and PHP ASGs to 0 (saves state for resume; ~$30-50/mo savings)
	@echo "$(BLUE)Pausing compute ASGs for $(ENV)...$(NC)"
	@for ASG in $(ENV)-nginx-asg $(ENV)-php74-asg $(ENV)-php83-asg; do \
		STATE=$$(aws autoscaling describe-auto-scaling-groups \
			--auto-scaling-group-names "$$ASG" \
			--query 'AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity]' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null); \
		if [ -z "$$STATE" ] || echo "$$STATE" | grep -q "None"; then \
			echo "  $(YELLOW)$$ASG: not found, skipping$(NC)"; \
			continue; \
		fi; \
		MIN=$$(echo "$$STATE" | cut -f1); \
		MAX=$$(echo "$$STATE" | cut -f2); \
		DESIRED=$$(echo "$$STATE" | cut -f3); \
		if [ "$$DESIRED" -eq 0 ] && [ "$$MIN" -eq 0 ] && [ "$$MAX" -eq 0 ]; then \
			echo "  $(CYAN)$$ASG: already paused$(NC)"; \
			continue; \
		fi; \
		aws ssm put-parameter \
			--name "/$(ENV)/asg-pause-state/$$ASG" \
			--type String \
			--value "$$MIN:$$MAX:$$DESIRED" \
			--overwrite \
			--region $(AWS_REGION) >/dev/null; \
		aws autoscaling update-auto-scaling-group \
			--auto-scaling-group-name "$$ASG" \
			--min-size 0 --max-size 0 --desired-capacity 0 \
			--region $(AWS_REGION); \
		echo "  $(GREEN)$$ASG: was MIN=$$MIN MAX=$$MAX DESIRED=$$DESIRED → 0/0/0$(NC)"; \
	done
	@echo "$(GREEN)✓ Compute paused.$(NC) Resume with: make resume-compute ENV=$(ENV)"
	@echo "$(CYAN)Note: ALB and NLB still running (~\$$32/mo combined) — their hourly charges continue.$(NC)"
	@echo "$(CYAN)To save ALB/NLB cost too, use: make destroy-compute ENV=$(ENV) CONFIRMED=yes$(NC)"

resume-compute:  ## Restore NGINX and PHP ASGs to pre-pause sizes
	@echo "$(BLUE)Resuming compute ASGs for $(ENV)...$(NC)"
	@for ASG in $(ENV)-nginx-asg $(ENV)-php74-asg $(ENV)-php83-asg; do \
		SAVED=$$(aws ssm get-parameter \
			--name "/$(ENV)/asg-pause-state/$$ASG" \
			--query 'Parameter.Value' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null) || SAVED=""; \
		if [ -z "$$SAVED" ]; then \
			echo "  $(YELLOW)$$ASG: no saved state in SSM, skipping (run pause-compute first or it was never paused)$(NC)"; \
			continue; \
		fi; \
		MIN=$$(echo "$$SAVED" | cut -d: -f1); \
		MAX=$$(echo "$$SAVED" | cut -d: -f2); \
		DESIRED=$$(echo "$$SAVED" | cut -d: -f3); \
		aws autoscaling update-auto-scaling-group \
			--auto-scaling-group-name "$$ASG" \
			--min-size $$MIN --max-size $$MAX --desired-capacity $$DESIRED \
			--region $(AWS_REGION); \
		aws ssm delete-parameter \
			--name "/$(ENV)/asg-pause-state/$$ASG" \
			--region $(AWS_REGION) >/dev/null 2>&1 || true; \
		echo "  $(GREEN)$$ASG: restored to MIN=$$MIN MAX=$$MAX DESIRED=$$DESIRED$(NC)"; \
	done
	@echo "$(GREEN)✓ Compute resumed.$(NC) Instances will spin up over the next ~2-3 minutes."
	@echo "$(CYAN)Watch progress: make verify-compute ENV=$(ENV)$(NC)"

# -----------------------------------------------------------------------------
# Deploy Host (Standalone)
# -----------------------------------------------------------------------------

deploy-deploy-host:  ## Deploy deploy host (standalone, uses default VPC)
	@echo "$(BLUE)Deploying deploy host stack: $(DEPLOY_HOST_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@# Pre-delete the SSM-SessionManagerRunShell document only when the
	@# stack does NOT exist. If the stack DOES exist, CloudFormation already
	@# owns the document (CREATE_COMPLETE state) — deleting it here would
	@# leave the stack thinking the doc is fine while it's actually gone,
	@# silently breaking SSM session preferences. The pre-delete is only
	@# meant to clean up orphans from a prior stack lifecycle, not to
	@# re-bootstrap on every deploy.
	@if aws cloudformation describe-stacks \
		--stack-name $(DEPLOY_HOST_STACK) \
		--region $(AWS_REGION) >/dev/null 2>&1; then \
		echo "$(CYAN)Stack exists — skipping orphan SSM document cleanup$(NC)"; \
	else \
		echo "$(CYAN)Stack does not exist — pre-cleaning any orphan SSM document$(NC)"; \
		aws ssm delete-document --name SSM-SessionManagerRunShell \
			--region $(AWS_REGION) 2>/dev/null || true; \
	fi
	@time aws cloudformation deploy \
		--template-file $(DEPLOY_HOST_TEMPLATE) \
		--stack-name $(DEPLOY_HOST_STACK) \
		--parameter-overrides file://$(DEPLOY_HOST_PARAMS) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)
	@echo "$(GREEN)✓ Deploy host deployed$(NC)"
	@$(MAKE) verify-deploy-host

verify-deploy-host:  ## Show deploy host connection info
	@echo "$(BLUE)Deploy Host Connection Info$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)Stack Outputs:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(DEPLOY_HOST_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Deploy host stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)Instance Status:$(NC)"
	@aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(DEPLOY_HOST_STACK)" \
		--query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType,IP:PublicIpAddress}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Instance not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Deploy host verification complete$(NC)"

destroy-deploy-host:  ## Delete deploy host (pass CONFIRMED=yes to skip prompt)
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete the deploy host!$(NC)"; \
		echo "$(CYAN)(Pass CONFIRMED=yes to skip this prompt for unattended runs.)$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled"; \
			exit 0; \
		fi; \
	fi
	@echo "$(YELLOW)Deleting deploy host stack: $(DEPLOY_HOST_STACK)$(NC)"
	@time aws cloudformation delete-stack \
		--stack-name $(DEPLOY_HOST_STACK) \
		--region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(DEPLOY_HOST_STACK))
	@echo "$(BLUE)Cleaning up SSM session preferences document...$(NC)"
	@aws ssm delete-document \
		--name SSM-SessionManagerRunShell \
		--region $(AWS_REGION) 2>/dev/null \
		&& echo "  $(GREEN)✓ SSM-SessionManagerRunShell deleted$(NC)" \
		|| echo "  $(CYAN)SSM-SessionManagerRunShell not found (already clean)$(NC)"
	@echo "$(GREEN)✓ Deploy host deleted$(NC)"

# -----------------------------------------------------------------------------
# Deploy Host VPC Peering (per environment)
# -----------------------------------------------------------------------------
# Connects the deploy-host's default VPC to the project VPC for the given ENV
# so the deploy host can reach FSx (NFS), RDS, and Valkey directly.
# Requires both cf-deploy-host and cf-vpc stacks to exist for ENV first.
#
# DefaultVpcId and DefaultVpcRouteTableId are looked up at deploy time
# (no need to hand-edit the parameter file).

deploy-peering:  ## Deploy VPC peering between deploy-host and project VPC
	@echo "$(BLUE)Deploying peering: $(DEPLOY_PEERING_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "$(CYAN)Looking up default VPC info...$(NC)"
	@DEFAULT_VPC_ID=$$(aws ec2 describe-vpcs \
		--filters "Name=isDefault,Values=true" \
		--query 'Vpcs[0].VpcId' \
		--output text \
		--region $(AWS_REGION)); \
	if [ -z "$$DEFAULT_VPC_ID" ] || [ "$$DEFAULT_VPC_ID" = "None" ]; then \
		echo "$(RED)Error: No default VPC found in $(AWS_REGION)$(NC)"; \
		exit 1; \
	fi; \
	DEFAULT_RT_ID=$$(aws ec2 describe-route-tables \
		--filters "Name=vpc-id,Values=$$DEFAULT_VPC_ID" "Name=association.main,Values=true" \
		--query 'RouteTables[0].RouteTableId' \
		--output text \
		--region $(AWS_REGION)); \
	if [ -z "$$DEFAULT_RT_ID" ] || [ "$$DEFAULT_RT_ID" = "None" ]; then \
		echo "$(RED)Error: Could not find main route table for default VPC $$DEFAULT_VPC_ID$(NC)"; \
		exit 1; \
	fi; \
	echo "  $(CYAN)Default VPC: $$DEFAULT_VPC_ID$(NC)"; \
	echo "  $(CYAN)Default VPC main route table: $$DEFAULT_RT_ID$(NC)"; \
	echo ""; \
	BASE_PARAMS=$$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(DEPLOY_PEERING_PARAMS)); \
	time aws cloudformation deploy \
		--template-file $(DEPLOY_PEERING_TEMPLATE) \
		--stack-name $(DEPLOY_PEERING_STACK) \
		--parameter-overrides $$BASE_PARAMS DefaultVpcId=$$DEFAULT_VPC_ID DefaultVpcRouteTableId=$$DEFAULT_RT_ID \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Peering stack deployed: $(DEPLOY_PEERING_STACK)$(NC)"
	@# Enable cross-VPC DNS resolution on the peering connection.
	@# CloudFormation's AWS::EC2::VPCPeeringConnection does not expose
	@# this flag, so we set it via the API after the stack is deployed.
	@# Without this, FSx hostnames (which resolve only from inside their
	@# home VPC) cannot be resolved from the peered deploy-host VPC.
	@# RDS and ElastiCache work without this flag because their DNS names
	@# are AWS-public with split-horizon resolution.
	@echo "$(BLUE)Enabling cross-VPC DNS resolution on peering connection...$(NC)"
	@PCX_ID=$$(aws cloudformation describe-stacks \
		--stack-name $(DEPLOY_PEERING_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`PeeringConnectionId`].OutputValue' \
		--output text \
		--region $(AWS_REGION)); \
	if [ -n "$$PCX_ID" ] && [ "$$PCX_ID" != "None" ]; then \
		aws ec2 modify-vpc-peering-connection-options \
			--vpc-peering-connection-id "$$PCX_ID" \
			--requester-peering-connection-options AllowDnsResolutionFromRemoteVpc=true \
			--accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true \
			--region $(AWS_REGION) >/dev/null && \
		echo "$(GREEN)✓ DNS resolution enabled on $$PCX_ID$(NC)" || \
		echo "$(YELLOW)Warning: failed to enable DNS resolution on peering$(NC)"; \
	else \
		echo "$(YELLOW)Warning: could not determine PeeringConnectionId$(NC)"; \
	fi
	@echo ""
	@echo "$(CYAN)Run 'make test-peering ENV=$(ENV)' to verify connectivity.$(NC)"

destroy-peering:  ## Delete VPC peering stack
	@echo "$(YELLOW)Deleting peering stack: $(DEPLOY_PEERING_STACK)$(NC)"
	@time aws cloudformation delete-stack \
		--stack-name $(DEPLOY_PEERING_STACK) \
		--region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(DEPLOY_PEERING_STACK))
	@echo "$(GREEN)✓ Peering stack deleted: $(DEPLOY_PEERING_STACK)$(NC)"

test-peering:  ## Verify deploy host can reach project VPC services (FSx, RDS, Valkey)
	@echo "$(BLUE)Testing peering connectivity from deploy host to $(ENV)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(DEPLOY_HOST_STACK)" \
			"Name=instance-state-name,Values=running" \
		--query 'Reservations[].Instances[0].InstanceId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Error: Deploy host not running. Run: make start-deploy-host$(NC)"; \
		exit 1; \
	fi; \
	echo "  $(CYAN)Deploy host: $$INSTANCE_ID$(NC)"; \
	FSX_DNS=$$(aws cloudformation describe-stacks \
		--stack-name $(STORAGE_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`FSxDNSName`].OutputValue' \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	RDS_ENDPOINT=$$(aws cloudformation describe-stacks \
		--stack-name $(DATABASE_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`DBEndpoint`].OutputValue' \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	VALKEY_ENDPOINT=$$(aws cloudformation describe-stacks \
		--stack-name $(CACHE_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`CachePrimaryEndpoint`].OutputValue' \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	echo "  $(CYAN)Targets:$(NC)"; \
	echo "    FSx:    $${FSX_DNS:-(not deployed)}:2049"; \
	echo "    RDS:    $${RDS_ENDPOINT:-(not deployed)}:5432"; \
	echo "    Valkey: $${VALKEY_ENDPOINT:-(not deployed)}:6379"; \
	echo ""; \
	CMD="echo '=== FSx (NFS 2049) ==='; nc -zv $${FSX_DNS:-skip-fsx} 2049 2>&1 || true; "; \
	CMD="$$CMD echo '=== RDS (PostgreSQL 5432) ==='; nc -zv $${RDS_ENDPOINT:-skip-rds} 5432 2>&1 || true; "; \
	CMD="$$CMD echo '=== Valkey (6379) ==='; nc -zv $${VALKEY_ENDPOINT:-skip-valkey} 6379 2>&1 || true"; \
	CMD_ID=$$(aws ssm send-command \
		--instance-ids "$$INSTANCE_ID" \
		--document-name "AWS-RunShellScript" \
		--parameters "commands=[\"$$CMD\"]" \
		--query 'Command.CommandId' \
		--output text \
		--region $(AWS_REGION)); \
	echo "$(CYAN)Running connectivity test (SSM command $$CMD_ID)...$(NC)"; \
	sleep 5; \
	for i in 1 2 3 4 5; do \
		STATUS=$$(aws ssm get-command-invocation \
			--command-id "$$CMD_ID" \
			--instance-id "$$INSTANCE_ID" \
			--query 'Status' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null); \
		if [ "$$STATUS" = "Success" ] || [ "$$STATUS" = "Failed" ]; then break; fi; \
		sleep 3; \
	done; \
	echo ""; \
	echo "$(CYAN)Output:$(NC)"; \
	aws ssm get-command-invocation \
		--command-id "$$CMD_ID" \
		--instance-id "$$INSTANCE_ID" \
		--query 'StandardOutputContent' \
		--output text \
		--region $(AWS_REGION); \
	aws ssm get-command-invocation \
		--command-id "$$CMD_ID" \
		--instance-id "$$INSTANCE_ID" \
		--query 'StandardErrorContent' \
		--output text \
		--region $(AWS_REGION)

stop-deploy-host:  ## Stop deploy host instance
	@echo "$(BLUE)Stopping deploy host instance...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(DEPLOY_HOST_STACK)" \
			"Name=instance-state-name,Values=pending,running,stopping,stopped" \
		--query 'Reservations[].Instances[0].InstanceId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Error: Deploy host instance not found$(NC)"; \
		exit 1; \
	fi; \
	CURRENT_STATE=$$(aws ec2 describe-instances \
		--instance-ids "$$INSTANCE_ID" \
		--query 'Reservations[].Instances[0].State.Name' \
		--output text \
		--region $(AWS_REGION)); \
	echo "  Instance: $(CYAN)$$INSTANCE_ID$(NC)"; \
	echo "  Current state: $(CYAN)$$CURRENT_STATE$(NC)"; \
	if [ "$$CURRENT_STATE" = "stopped" ]; then \
		echo "$(YELLOW)Instance is already stopped$(NC)"; \
		exit 0; \
	fi; \
	echo ""; \
	aws ec2 stop-instances \
		--instance-ids "$$INSTANCE_ID" \
		--region $(AWS_REGION) \
		--output json | jq -r '.StoppingInstances[0].CurrentState.Name'; \
	echo "$(BLUE)Waiting for instance to stop...$(NC)"; \
	aws ec2 wait instance-stopped \
		--instance-ids "$$INSTANCE_ID" \
		--region $(AWS_REGION); \
	echo "$(GREEN)✓ Deploy host stopped$(NC)"

start-deploy-host:  ## Start deploy host instance
	@echo "$(BLUE)Starting deploy host instance...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(DEPLOY_HOST_STACK)" \
			"Name=instance-state-name,Values=pending,running,stopping,stopped" \
		--query 'Reservations[].Instances[0].InstanceId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Error: Deploy host instance not found$(NC)"; \
		exit 1; \
	fi; \
	CURRENT_STATE=$$(aws ec2 describe-instances \
		--instance-ids "$$INSTANCE_ID" \
		--query 'Reservations[].Instances[0].State.Name' \
		--output text \
		--region $(AWS_REGION)); \
	echo "  Instance: $(CYAN)$$INSTANCE_ID$(NC)"; \
	echo "  Current state: $(CYAN)$$CURRENT_STATE$(NC)"; \
	if [ "$$CURRENT_STATE" = "running" ]; then \
		echo "$(YELLOW)Instance is already running$(NC)"; \
		exit 0; \
	fi; \
	echo ""; \
	aws ec2 start-instances \
		--instance-ids "$$INSTANCE_ID" \
		--region $(AWS_REGION) \
		--output json | jq -r '.StartingInstances[0].CurrentState.Name'; \
	echo "$(BLUE)Waiting for instance to start...$(NC)"; \
	aws ec2 wait instance-running \
		--instance-ids "$$INSTANCE_ID" \
		--region $(AWS_REGION); \
	echo "$(GREEN)✓ Deploy host started$(NC)"
	@echo ""
	@$(MAKE) verify-deploy-host

set-deploy-host-password:  ## Set root password for deploy host in Secrets Manager
	@echo "$(BLUE)Set Deploy Host Root Password$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "This password will be applied on next deploy-deploy-host."
	@echo ""
	@read -s -p "Enter root password: " PASS1; echo ""; \
	read -s -p "Confirm root password: " PASS2; echo ""; \
	if [ "$$PASS1" != "$$PASS2" ]; then \
		echo "$(RED)Error: Passwords do not match$(NC)"; \
		exit 1; \
	fi; \
	if [ -z "$$PASS1" ]; then \
		echo "$(RED)Error: Password cannot be empty$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Storing password in Secrets Manager...$(NC)"; \
	if aws secretsmanager describe-secret \
		--secret-id "$(DEPLOY_HOST_SECRET_PATH)" \
		--region $(AWS_REGION) >/dev/null 2>&1; then \
		aws secretsmanager put-secret-value \
			--secret-id "$(DEPLOY_HOST_SECRET_PATH)" \
			--secret-string "$$PASS1" \
			--region $(AWS_REGION) >/dev/null; \
		echo "$(GREEN)✓ Password updated in Secrets Manager$(NC)"; \
	else \
		aws secretsmanager create-secret \
			--name "$(DEPLOY_HOST_SECRET_PATH)" \
			--description "Root password for deploy host" \
			--secret-string "$$PASS1" \
			--region $(AWS_REGION) >/dev/null; \
		echo "$(GREEN)✓ Password created in Secrets Manager$(NC)"; \
	fi; \
	echo "  Secret: $(CYAN)$(DEPLOY_HOST_SECRET_PATH)$(NC)"; \
	echo "  $(YELLOW)Note: Password applies on next deploy-deploy-host (UserData runs on first boot only)$(NC)"

# -----------------------------------------------------------------------------
# Image Builder
# -----------------------------------------------------------------------------

find-default-subnet:  ## Discover default VPC subnet IDs for BuildSubnetId parameter
	@echo "$(BLUE)Default VPC Subnets$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@DEFAULT_VPC=$$(aws ec2 describe-vpcs \
		--filters "Name=isDefault,Values=true" \
		--query 'Vpcs[0].VpcId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$DEFAULT_VPC" ] || [ "$$DEFAULT_VPC" = "None" ]; then \
		echo "$(RED)Error: No default VPC found in $(AWS_REGION)$(NC)"; \
		exit 1; \
	fi; \
	echo "  VPC: $(CYAN)$$DEFAULT_VPC$(NC)"; \
	echo ""; \
	aws ec2 describe-subnets \
		--filters "Name=vpc-id,Values=$$DEFAULT_VPC" \
		--query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,MapPublicIp:MapPublicIpOnLaunch,CidrBlock:CidrBlock}' \
		--output table \
		--region $(AWS_REGION); \
	echo ""; \
	echo "$(YELLOW)Copy a SubnetId to image-builder-$(ENV).json BuildSubnetId parameter$(NC)"

upload-build-configs:  ## Sync image-builder/configs/ to S3 image-builder bucket
	@echo "$(BLUE)Uploading build configs to S3...$(NC)"
	@BUCKET=$$(aws ssm get-parameter \
		--name "/$(ENV)/s3/image-builder-bucket" \
		--query 'Parameter.Value' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$BUCKET" ] || [ "$$BUCKET" = "None" ]; then \
		echo "$(RED)Error: Image builder bucket not found in SSM (deploy storage stack first)$(NC)"; \
		exit 1; \
	fi; \
	echo "  Bucket: $(CYAN)$$BUCKET$(NC)"; \
	aws s3 sync image-builder/configs/ "s3://$$BUCKET/configs/" \
		--region $(AWS_REGION) \
		--delete; \
	echo "$(GREEN)✓ Configs synced to s3://$$BUCKET/configs/$(NC)"

deploy-image-builder:  ## Deploy Image Builder stack (depends on IAM + Storage)
	@echo "$(BLUE)Deploying Image Builder stack: $(IMAGE_BUILDER_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@if [ ! -f $(IMAGE_BUILDER_PARAMS) ]; then \
		echo "$(RED)Error: Parameter file not found: $(IMAGE_BUILDER_PARAMS)$(NC)"; \
		echo "Create it from the sandbox template and fill in BuildSubnetId"; \
		exit 1; \
	fi
	@BUCKET=$$(aws ssm get-parameter \
		--name "/$(ENV)/s3/image-builder-bucket" \
		--query "Parameter.Value" --output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$BUCKET" ] || [ "$$BUCKET" = "None" ]; then \
		echo "$(RED)Error: Image builder bucket not found in SSM (deploy storage stack first)$(NC)"; \
		exit 1; \
	fi; \
	echo "  Using S3 bucket for template: $(CYAN)$$BUCKET$(NC)"; \
	time aws cloudformation deploy \
		--template-file $(IMAGE_BUILDER_TEMPLATE) \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--s3-bucket "$$BUCKET" \
		--s3-prefix "cloudformation" \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(IMAGE_BUILDER_PARAMS)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Image Builder stack deployed: $(IMAGE_BUILDER_STACK)$(NC)"

verify-image-builder:  ## Show pipeline statuses and latest build info
	@echo "$(BLUE)Image Builder Status for ENV=$(ENV)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)1. Stack Resources:$(NC)"
	@aws cloudformation describe-stack-resources \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--query 'StackResources[?ResourceType==`AWS::ImageBuilder::ImagePipeline`].{LogicalId:LogicalResourceId,PhysicalId:PhysicalResourceId,Status:ResourceStatus}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)2. Pipeline Status:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--query 'Stacks[0].Outputs[?contains(OutputKey, `Pipeline`)].{Pipeline:OutputKey,ARN:OutputValue}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)3. Latest AMIs (owned by self):$(NC)"
	@aws ec2 describe-images \
		--owners self \
		--filters "Name=name,Values=$(ENV)-*" \
		--query 'Images | sort_by(@, &CreationDate) | [-3:].{Name:Name,ImageId:ImageId,Created:CreationDate,State:State}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(YELLOW)No AMIs found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Image Builder verification complete$(NC)"

destroy-image-builder:  ## Delete Image Builder stack and associated AMIs/snapshots
	@if [ "$(CONFIRMED)" != "yes" ]; then \
		echo "$(RED)WARNING: This will delete the Image Builder stack and all associated AMIs!$(NC)"; \
		read -p "Type 'yes' to confirm: " confirm; \
		if [ "$$confirm" != "yes" ]; then \
			echo "Cancelled"; \
			exit 0; \
		fi; \
	fi
	@echo "$(BLUE)Cleaning up AMIs built by Image Builder for ENV=$(ENV)...$(NC)"
	@AMI_IDS=$$(aws ec2 describe-images --owners self \
		--filters "Name=tag:CreatedBy,Values=EC2 Image Builder" \
			"Name=name,Values=$(ENV)-*" \
		--query 'Images[].ImageId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null || echo ""); \
	if [ -n "$$AMI_IDS" ] && [ "$$AMI_IDS" != "None" ]; then \
		for ami in $$AMI_IDS; do \
			echo "  $(YELLOW)Deregistering AMI: $$ami$(NC)"; \
			SNAP_IDS=$$(aws ec2 describe-images --image-ids "$$ami" \
				--query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
				--output text \
				--region $(AWS_REGION) 2>/dev/null || echo ""); \
			aws ec2 deregister-image --image-id "$$ami" \
				--region $(AWS_REGION) 2>/dev/null || true; \
			for snap in $$SNAP_IDS; do \
				if [ -n "$$snap" ] && [ "$$snap" != "None" ]; then \
					echo "    $(YELLOW)Deleting snapshot: $$snap$(NC)"; \
					aws ec2 delete-snapshot --snapshot-id "$$snap" \
						--region $(AWS_REGION) 2>/dev/null || true; \
				fi; \
			done; \
			echo "  $(GREEN)✓ AMI $$ami and snapshots removed$(NC)"; \
		done; \
	else \
		echo "  $(CYAN)No AMIs found for ENV=$(ENV)$(NC)"; \
	fi
	@echo "$(YELLOW)Deleting Image Builder stack: $(IMAGE_BUILDER_STACK)$(NC)"
	@time aws cloudformation delete-stack \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	$(call cf-wait,stack-delete-complete,$(IMAGE_BUILDER_STACK))
	@echo "$(GREEN)✓ Image Builder stack and AMIs deleted$(NC)"

build-ami-nginx:  ## Trigger NGINX pipeline execution
	@echo "$(BLUE)Triggering NGINX AMI build...$(NC)"
	@PIPELINE_ARN=$$(aws cloudformation describe-stacks \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`NginxPipelineArn`].OutputValue' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$PIPELINE_ARN" ] || [ "$$PIPELINE_ARN" = "None" ]; then \
		echo "$(RED)Error: NGINX pipeline not found (deploy image-builder stack first)$(NC)"; \
		exit 1; \
	fi; \
	echo "  Pipeline: $(CYAN)$$PIPELINE_ARN$(NC)"; \
	aws imagebuilder start-image-pipeline-execution \
		--image-pipeline-arn "$$PIPELINE_ARN" \
		--region $(AWS_REGION) \
		--output json | jq -r '.imageBuildVersionArn'; \
	echo "$(GREEN)✓ NGINX build started$(NC)"; \
	echo "$(YELLOW)Monitor in AWS Console > EC2 Image Builder > Image pipelines$(NC)"

build-ami-php74:  ## Trigger PHP 7.4 pipeline execution
	@echo "$(BLUE)Triggering PHP 7.4 AMI build...$(NC)"
	@PIPELINE_ARN=$$(aws cloudformation describe-stacks \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`PhpFpm74PipelineArn`].OutputValue' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$PIPELINE_ARN" ] || [ "$$PIPELINE_ARN" = "None" ]; then \
		echo "$(RED)Error: PHP 7.4 pipeline not found (deploy image-builder stack first)$(NC)"; \
		exit 1; \
	fi; \
	echo "  Pipeline: $(CYAN)$$PIPELINE_ARN$(NC)"; \
	aws imagebuilder start-image-pipeline-execution \
		--image-pipeline-arn "$$PIPELINE_ARN" \
		--region $(AWS_REGION) \
		--output json | jq -r '.imageBuildVersionArn'; \
	echo "$(GREEN)✓ PHP 7.4 build started$(NC)"; \
	echo "$(YELLOW)Monitor in AWS Console > EC2 Image Builder > Image pipelines$(NC)"

build-ami-php83:  ## Trigger PHP 8.3 pipeline execution
	@echo "$(BLUE)Triggering PHP 8.3 AMI build...$(NC)"
	@PIPELINE_ARN=$$(aws cloudformation describe-stacks \
		--stack-name $(IMAGE_BUILDER_STACK) \
		--query 'Stacks[0].Outputs[?OutputKey==`PhpFpm83PipelineArn`].OutputValue' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$PIPELINE_ARN" ] || [ "$$PIPELINE_ARN" = "None" ]; then \
		echo "$(RED)Error: PHP 8.3 pipeline not found (deploy image-builder stack first)$(NC)"; \
		exit 1; \
	fi; \
	echo "  Pipeline: $(CYAN)$$PIPELINE_ARN$(NC)"; \
	aws imagebuilder start-image-pipeline-execution \
		--image-pipeline-arn "$$PIPELINE_ARN" \
		--region $(AWS_REGION) \
		--output json | jq -r '.imageBuildVersionArn'; \
	echo "$(GREEN)✓ PHP 8.3 build started$(NC)"; \
	echo "$(YELLOW)Monitor in AWS Console > EC2 Image Builder > Image pipelines$(NC)"

build-amis: build-amis-async wait-amis  ## Trigger all 3 pipeline executions and WAIT for AVAILABLE

build-amis-async:  ## Trigger all 3 pipeline executions (fire-and-forget; no wait)
	@echo "$(BLUE)Triggering all AMI builds...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@$(MAKE) build-ami-nginx ENV=$(ENV)
	@$(MAKE) build-ami-php74 ENV=$(ENV)
	@$(MAKE) build-ami-php83 ENV=$(ENV)
	@echo ""
	@echo "$(GREEN)✓ All 3 builds triggered$(NC)"

wait-amis:  ## Poll Image Builder pipelines until all 3 reach AVAILABLE or any FAIL
	@echo "$(BLUE)Waiting for all 3 pipelines to reach AVAILABLE...$(NC)"
	@echo "$(YELLOW)(checks every 30s; ~10-15 min per pipeline in parallel, hard cap 40 min)$(NC)"
	@TIMEOUT_SECS=2400; \
	START=$$(date +%s); \
	while true; do \
		ELAPSED=$$(( $$(date +%s) - $$START )); \
		if [ "$$ELAPSED" -gt "$$TIMEOUT_SECS" ]; then \
			echo "$(RED)✗ Timeout after $$TIMEOUT_SECS s — pipelines did not finish$(NC)"; \
			exit 1; \
		fi; \
		ALL_DONE=1; ANY_FAILED=0; \
		printf "  [%2dm%02ds] " $$((ELAPSED/60)) $$((ELAPSED%60)); \
		for P in $$(aws imagebuilder list-image-pipelines \
				--query "imagePipelineList[?contains(name,'$(ENV)')].arn" \
				--output text --region $(AWS_REGION) 2>/dev/null); do \
			NAME=$$(echo "$$P" | awk -F/ '{print $$NF}' | sed -e 's/sandbox-//' -e 's/-pipeline//'); \
			STATUS=$$(aws imagebuilder list-image-pipeline-images --image-pipeline-arn "$$P" \
				--query "reverse(sort_by(imageSummaryList, &dateCreated))[0].state.status" \
				--output text --region $(AWS_REGION) 2>/dev/null); \
			printf "%s=%s  " "$$NAME" "$$STATUS"; \
			case "$$STATUS" in \
				AVAILABLE) ;; \
				FAILED|CANCELLED|DEPRECATED|DELETED) ANY_FAILED=1 ;; \
				*) ALL_DONE=0 ;; \
			esac; \
		done; \
		echo ""; \
		if [ "$$ALL_DONE" = "1" ]; then \
			if [ "$$ANY_FAILED" = "1" ]; then \
				echo "$(RED)✗ One or more pipelines failed — check the Image Builder console$(NC)"; \
				exit 1; \
			fi; \
			echo "$(GREEN)✓ All pipelines AVAILABLE$(NC)"; \
			exit 0; \
		fi; \
		sleep 30; \
	done

# PIPELINE variable for update-ami-param (nginx, php74, php83)
PIPELINE ?= nginx

update-ami-param:  ## Write latest AMI ID to SSM (PIPELINE=nginx|php74|php83)
	@echo "$(BLUE)Updating SSM with latest $(PIPELINE) AMI...$(NC)"
	@case "$(PIPELINE)" in \
		nginx) RECIPE_FILTER="*nginx-recipe*" ;; \
		php74) RECIPE_FILTER="*php-fpm-74-recipe*" ;; \
		php83) RECIPE_FILTER="*php-fpm-83-recipe*" ;; \
		*) echo "$(RED)Error: PIPELINE must be nginx, php74, or php83$(NC)"; exit 1 ;; \
	esac; \
	AMI_ID=$$(aws ec2 describe-images \
		--owners self \
		--filters "Name=tag:Ec2ImageBuilderArn,Values=$$RECIPE_FILTER" \
			"Name=tag:Environment,Values=$(ENV)" \
			"Name=state,Values=available" \
		--query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$AMI_ID" ] || [ "$$AMI_ID" = "None" ]; then \
		AMI_ID=$$(aws ec2 describe-images \
			--owners self \
			--filters "Name=tag:Ec2ImageBuilderArn,Values=$$RECIPE_FILTER" \
				"Name=state,Values=available" \
			--query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
			--output text \
			--region $(AWS_REGION) 2>/dev/null); \
	fi; \
	if [ -z "$$AMI_ID" ] || [ "$$AMI_ID" = "None" ]; then \
		echo "$(RED)Error: No AMI found for $(PIPELINE) (recipe filter: $$RECIPE_FILTER)$(NC)"; \
		exit 1; \
	fi; \
	echo "  AMI: $(CYAN)$$AMI_ID$(NC)"; \
	aws ssm put-parameter \
		--name "/$(ENV)/ami/$(PIPELINE)" \
		--value "$$AMI_ID" \
		--type String \
		--overwrite \
		--region $(AWS_REGION) >/dev/null; \
	echo "$(GREEN)✓ SSM parameter /$(ENV)/ami/$(PIPELINE) = $$AMI_ID$(NC)"

update-ami-params:  ## Write latest AMI IDs to SSM for all 3 pipelines (nginx + php74 + php83)
	@echo "$(BLUE)Updating SSM AMI parameters for all 3 pipelines...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=nginx
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=php74
	@$(MAKE) update-ami-param ENV=$(ENV) PIPELINE=php83
	@echo ""
	@echo "$(GREEN)✓ All 3 SSM AMI parameters updated$(NC)"

# Alias matching the muscle-memory `deploy-*` naming convention of the
# surrounding targets (deploy-image-builder, deploy-compute, etc.).
deploy-ami-params: update-ami-params  ## Alias for update-ami-params

check-drift:  ## Warn when local CFN templates are newer than deployed stacks
	@scripts/check-cfn-drift.sh $(ENV)

restart-php-fpm:  ## SSM-restart php*-fpm on every PHP box (busts OPcache + reloads www.conf env[])
	@scripts/restart-php-fpm.sh $(ENV)

clear-drupal-cache:  ## Wipe FSx compiled-container cache + TRUNCATE cache_* tables (via deploy-host)
	@scripts/clear-drupal-cache.sh $(ENV)

install-drupal-remote:  ## SSM-dispatch `make install-drupal ENV=<env>` to the deploy-host
	@scripts/install-drupal-remote.sh $(ENV)

smoke-test-drupal:  ## Curl the ALB with the Drupal Host header and assert HTTP 200
	@echo "$(BLUE)Smoke-testing Drupal at ENV=$(ENV)$(NC)"
	@ALB_DNS=$$(aws cloudformation describe-stacks \
		--stack-name $(COMPUTE_ALB_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
		--output text --region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$ALB_DNS" ] || [ "$$ALB_DNS" = "None" ]; then \
		echo "$(RED)ERROR: could not read ALBDnsName from $(COMPUTE_ALB_STACK)$(NC)"; \
		exit 1; \
	fi; \
	SITE_NAME=$$(aws ssm get-parameter --name "/$(ENV)/drupal/site-name" \
		--query 'Parameter.Value' --output text --region $(AWS_REGION) 2>/dev/null \
		|| echo "drupal-$(ENV).test"); \
	echo "  ALB:  $$ALB_DNS"; \
	echo "  Host: $$SITE_NAME"; \
	BODY=$$(mktemp); \
	HTTP=$$(curl -s -o "$$BODY" -w "%{http_code}" -H "Host: $$SITE_NAME" \
		"http://$$ALB_DNS/" --max-time 20); \
	if [ "$$HTTP" = "200" ]; then \
		echo "  $(GREEN)✓ Drupal returned HTTP 200$(NC)"; \
		head -3 "$$BODY"; \
		rm -f "$$BODY"; \
	else \
		echo "  $(RED)✗ Drupal returned HTTP $$HTTP$(NC)"; \
		head -10 "$$BODY"; \
		rm -f "$$BODY"; \
		exit 1; \
	fi

# -----------------------------------------------------------------------------
# Secrets Management
# -----------------------------------------------------------------------------

init-secrets:  ## Initialize secrets for deployment
	@echo "$(BLUE)Initializing secrets for $(ENV)...$(NC)"
	@./scripts/manage-secrets.sh init worxco/$(ENV)

list-secrets:  ## List all secrets
	@echo "$(BLUE)Listing secrets for $(ENV)...$(NC)"
	@./scripts/manage-secrets.sh list worxco/$(ENV)

# -----------------------------------------------------------------------------
# SSM Management
# -----------------------------------------------------------------------------

ssm-audit-params:  ## Audit SSM Parameter Store completeness for ENV
	@echo "$(BLUE)Auditing SSM parameters for $(ENV)...$(NC)"
	@./scripts/ssm-audit-params.sh --env $(ENV) --region $(AWS_REGION)

ssm-report:  ## Report EC2 instances missing from SSM
	@echo "$(BLUE)Running SSM Agent report for $(ENV)...$(NC)"
	@./scripts/ssm-bootstrap.sh \
		--profile $${AWS_PROFILE:-default} \
		--region $(AWS_REGION) \
		--instance-profile $(INSTANCE_PROFILE) \
		report

ssm-remediate:  ## Attach IAM profile + install SSM Agent via SSH (SSM_SSH_KEY required)
	@if [ -z "$(SSM_SSH_KEY)" ]; then \
		echo "$(RED)ERROR: SSM_SSH_KEY is required. Usage: make ssm-remediate SSM_SSH_KEY=~/.ssh/key.pem$(NC)"; \
		exit 2; \
	fi
	@echo "$(BLUE)Remediating SSM Agent for $(ENV)...$(NC)"
	@./scripts/ssm-bootstrap.sh \
		--profile $${AWS_PROFILE:-default} \
		--region $(AWS_REGION) \
		--instance-profile $(INSTANCE_PROFILE) \
		--ssh-user $(SSM_SSH_USER) \
		--ssh-key $(SSM_SSH_KEY) \
		remediate

# -----------------------------------------------------------------------------
# Testing & Maintenance
# -----------------------------------------------------------------------------

test:  ## Run test suite
	@echo "$(BLUE)Running tests...$(NC)"
	@if [ -d tests ]; then \
		for test in tests/test-*.sh; do \
			if [ -f "$$test" ]; then \
				echo "$(YELLOW)Running $$test...$(NC)"; \
				bash "$$test" || exit 1; \
			fi; \
		done; \
		echo "$(GREEN)✓ All tests passed$(NC)"; \
	else \
		echo "$(YELLOW)No tests found$(NC)"; \
	fi

clean:  ## Clean temporary files
	@echo "$(BLUE)Cleaning temporary files...$(NC)"
	@rm -f cloudformation/**/*.swp
	@rm -f cloudformation/**/*~
	@rm -rf tmp/
	@echo "$(GREEN)✓ Clean complete$(NC)"

# Default to today's date for log consolidation
DATE ?= $(shell date +%Y-%m-%d)

consolidate-logs:  ## Merge daily prompt logs into one file (DATE=YYYY-MM-DD)
	@echo "$(BLUE)Consolidating prompt logs for $(DATE)...$(NC)"
	@date_compact=$$(echo "$(DATE)" | tr -d '-'); \
	files=$$(ls PROMPT_LOGS/$${date_compact}-*-$(DEVELOPER_INITIALS).md 2>/dev/null); \
	if [ -z "$$files" ]; then \
		echo "$(YELLOW)No prompt logs found for $(DATE)$(NC)"; \
		exit 0; \
	fi; \
	count=$$(echo "$$files" | wc -w | tr -d ' '); \
	if [ "$$count" -le 1 ]; then \
		echo "$(YELLOW)Only one log file for $(DATE) - nothing to consolidate$(NC)"; \
		exit 0; \
	fi; \
	outfile="PROMPT_LOGS/$${date_compact}-consolidated-$(DEVELOPER_INITIALS).md"; \
	echo "# Consolidated AI Prompt Log" > "$$outfile"; \
	echo "" >> "$$outfile"; \
	echo "**Date**: $(DATE)" >> "$$outfile"; \
	echo "**Prompts**: $$count" >> "$$outfile"; \
	echo "**AI System**: Claude Opus 4.5" >> "$$outfile"; \
	echo "" >> "$$outfile"; \
	echo "---" >> "$$outfile"; \
	echo "" >> "$$outfile"; \
	for f in $$files; do \
		echo "## $$(basename $$f)" >> "$$outfile"; \
		echo "" >> "$$outfile"; \
		cat "$$f" >> "$$outfile"; \
		echo "" >> "$$outfile"; \
		echo "---" >> "$$outfile"; \
		echo "" >> "$$outfile"; \
	done; \
	echo "" >> "$$outfile"; \
	echo '<sub>**License:** GPL-2.0-or-later | **Copyright:** 2026 The Worx Company | **Author:** Kurt Vanderwater <<kurt@worxco.net>></sub>' >> "$$outfile"; \
	echo "$(GREEN)✓ Consolidated $$count logs into $$outfile$(NC)"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
