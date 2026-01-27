# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Makefile for cf-scalable-web infrastructure deployment
#
# Purpose: Simplified deployment and management of CloudFormation stacks
# Dependencies: aws-cli, cfn-lint, jq
#

.PHONY: help validate deploy-all deploy-vpc deploy-iam deploy-storage deploy-database deploy-cache \
        delete-all delete-vpc delete-iam delete-storage delete-database delete-cache \
        init-secrets list-secrets test clean

# Default environment
ENV ?= production
AWS_REGION ?= us-east-1
PARAM_FILE := cloudformation/parameters/$(ENV).json

# Stack names
VPC_STACK := $(ENV)-vpc
IAM_STACK := $(ENV)-iam
STORAGE_STACK := $(ENV)-storage
DATABASE_STACK := $(ENV)-database
CACHE_STACK := $(ENV)-cache

# Template files
VPC_TEMPLATE := cloudformation/cf-vpc.yaml
IAM_TEMPLATE := cloudformation/cf-iam.yaml
STORAGE_TEMPLATE := cloudformation/cf-storage.yaml
DATABASE_TEMPLATE := cloudformation/cf-database.yaml
CACHE_TEMPLATE := cloudformation/cf-cache.yaml

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

## help: Display this help message
help:
	@echo "$(BLUE)cf-scalable-web Makefile$(NC)"
	@echo ""
	@echo "$(YELLOW)Environment:$(NC) ENV=$(ENV) AWS_REGION=$(AWS_REGION)"
	@echo ""
	@echo "$(YELLOW)Validation:$(NC)"
	@echo "  make validate                 - Validate all CloudFormation templates"
	@echo ""
	@echo "$(YELLOW)Deployment:$(NC)"
	@echo "  make deploy-all              - Deploy all stacks (ENV=production|staging|dev)"
	@echo "  make deploy-vpc              - Deploy VPC stack only"
	@echo "  make deploy-iam              - Deploy IAM stack only"
	@echo "  make deploy-storage          - Deploy storage stack (FSx, S3)"
	@echo "  make deploy-database         - Deploy database stack (RDS PostgreSQL)"
	@echo "  make deploy-cache            - Deploy cache stack (ElastiCache Redis)"
	@echo ""
	@echo "$(YELLOW)Deletion:$(NC)"
	@echo "  make delete-cache            - Delete cache stack"
	@echo "  make delete-database         - Delete database stack (WARNING: Data loss!)"
	@echo "  make delete-storage          - Delete storage stack (WARNING: Data loss!)"
	@echo "  make delete-iam              - Delete IAM stack"
	@echo "  make delete-vpc              - Delete VPC stack"
	@echo "  make delete-all              - Delete all stacks (WARNING: Complete teardown!)"
	@echo ""
	@echo "$(YELLOW)Secrets Management:$(NC)"
	@echo "  make init-secrets            - Initialize required secrets"
	@echo "  make list-secrets            - List all secrets for environment"
	@echo ""
	@echo "$(YELLOW)Testing & Maintenance:$(NC)"
	@echo "  make test                    - Run test suite"
	@echo "  make clean                   - Clean temporary files"
	@echo ""
	@echo "$(YELLOW)Examples:$(NC)"
	@echo "  make ENV=staging deploy-all  - Deploy staging environment"
	@echo "  make ENV=dev deploy-vpc      - Deploy development VPC only"
	@echo ""

## validate: Validate all CloudFormation templates
validate:
	@echo "$(BLUE)Validating CloudFormation templates...$(NC)"
	@cfn-lint $(VPC_TEMPLATE)
	@cfn-lint $(IAM_TEMPLATE)
	@cfn-lint $(STORAGE_TEMPLATE)
	@cfn-lint $(DATABASE_TEMPLATE)
	@cfn-lint $(CACHE_TEMPLATE)
	@if [ -f $(PARAM_FILE) ]; then \
		echo "$(BLUE)Validating parameter file...$(NC)"; \
		jq empty $(PARAM_FILE); \
	else \
		echo "$(YELLOW)Warning: Parameter file not found: $(PARAM_FILE)$(NC)"; \
	fi
	@echo "$(GREEN)✓ All templates valid$(NC)"

## check-params: Check if parameter file exists
check-params:
	@if [ ! -f $(PARAM_FILE) ]; then \
		echo "$(RED)Error: Parameter file not found: $(PARAM_FILE)$(NC)" >&2; \
		echo "Create it from the template: cp cloudformation/parameters/template.json $(PARAM_FILE)" >&2; \
		exit 1; \
	fi

## deploy-vpc: Deploy VPC stack
deploy-vpc: validate check-params
	@echo "$(BLUE)Deploying VPC stack: $(VPC_STACK)$(NC)"
	@aws cloudformation deploy \
		--template-file $(VPC_TEMPLATE) \
		--stack-name $(VPC_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ VPC stack deployed$(NC)"

## deploy-iam: Deploy IAM stack
deploy-iam: validate check-params
	@echo "$(BLUE)Deploying IAM stack: $(IAM_STACK)$(NC)"
	@aws cloudformation deploy \
		--template-file $(IAM_TEMPLATE) \
		--stack-name $(IAM_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ IAM stack deployed$(NC)"

## deploy-storage: Deploy storage stack
deploy-storage: validate check-params
	@echo "$(BLUE)Deploying storage stack: $(STORAGE_STACK)$(NC)"
	@aws cloudformation deploy \
		--template-file $(STORAGE_TEMPLATE) \
		--stack-name $(STORAGE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Storage stack deployed$(NC)"

## deploy-database: Deploy database stack
deploy-database: validate check-params
	@echo "$(BLUE)Deploying database stack: $(DATABASE_STACK)$(NC)"
	@aws cloudformation deploy \
		--template-file $(DATABASE_TEMPLATE) \
		--stack-name $(DATABASE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Database stack deployed$(NC)"

## deploy-cache: Deploy cache stack
deploy-cache: validate check-params
	@echo "$(BLUE)Deploying cache stack: $(CACHE_STACK)$(NC)"
	@aws cloudformation deploy \
		--template-file $(CACHE_TEMPLATE) \
		--stack-name $(CACHE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Cache stack deployed$(NC)"

## deploy-all: Deploy all foundation stacks
deploy-all: deploy-vpc deploy-iam deploy-storage deploy-database deploy-cache
	@echo "$(GREEN)✓ All stacks deployed successfully$(NC)"

## delete-cache: Delete cache stack
delete-cache:
	@echo "$(YELLOW)Deleting cache stack: $(CACHE_STACK)$(NC)"
	@aws cloudformation delete-stack --stack-name $(CACHE_STACK) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(CACHE_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Cache stack deleted$(NC)"

## delete-database: Delete database stack
delete-database:
	@echo "$(RED)WARNING: This will delete the database and all data!$(NC)"
	@read -p "Are you sure? (yes/no): " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo "Cancelled"; \
		exit 0; \
	fi
	@echo "$(YELLOW)Deleting database stack: $(DATABASE_STACK)$(NC)"
	@aws cloudformation delete-stack --stack-name $(DATABASE_STACK) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(DATABASE_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Database stack deleted$(NC)"

## delete-storage: Delete storage stack
delete-storage:
	@echo "$(RED)WARNING: This will delete FSx and S3 buckets with all data!$(NC)"
	@read -p "Are you sure? (yes/no): " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo "Cancelled"; \
		exit 0; \
	fi
	@echo "$(YELLOW)Deleting storage stack: $(STORAGE_STACK)$(NC)"
	@aws cloudformation delete-stack --stack-name $(STORAGE_STACK) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(STORAGE_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Storage stack deleted$(NC)"

## delete-iam: Delete IAM stack
delete-iam:
	@echo "$(YELLOW)Deleting IAM stack: $(IAM_STACK)$(NC)"
	@aws cloudformation delete-stack --stack-name $(IAM_STACK) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(IAM_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ IAM stack deleted$(NC)"

## delete-vpc: Delete VPC stack
delete-vpc:
	@echo "$(YELLOW)Deleting VPC stack: $(VPC_STACK)$(NC)"
	@aws cloudformation delete-stack --stack-name $(VPC_STACK) --region $(AWS_REGION)
	@aws cloudformation wait stack-delete-complete --stack-name $(VPC_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ VPC stack deleted$(NC)"

## delete-all: Delete all stacks (reverse order)
delete-all: delete-cache delete-database delete-storage delete-iam delete-vpc
	@echo "$(GREEN)✓ All stacks deleted$(NC)"

## init-secrets: Initialize secrets for deployment
init-secrets:
	@echo "$(BLUE)Initializing secrets for $(ENV)...$(NC)"
	@./scripts/manage-secrets.sh init worxco/$(ENV)

## list-secrets: List all secrets
list-secrets:
	@echo "$(BLUE)Listing secrets for $(ENV)...$(NC)"
	@./scripts/manage-secrets.sh list worxco/$(ENV)

## test: Run test suite
test:
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

## clean: Clean temporary files
clean:
	@echo "$(BLUE)Cleaning temporary files...$(NC)"
	@rm -f cloudformation/**/*.swp
	@rm -f cloudformation/**/*~
	@rm -rf tmp/
	@echo "$(GREEN)✓ Clean complete$(NC)"

# License: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>
