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
        verify-all verify-vpc verify-iam verify-storage verify-database verify-cache \
        destroy-all destroy-vpc destroy-iam destroy-storage destroy-database destroy-cache \
        deploy-bastion verify-bastion destroy-bastion \
        stop-bastion start-bastion set-bastion-password \
        init-secrets list-secrets test clean consolidate-logs

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

# Bastion (standalone, not environment-specific)
BASTION_STACK := cf-bastion
BASTION_TEMPLATE := cloudformation/cf-bastion.yaml
BASTION_PARAMS := cloudformation/parameters/bastion.json
BASTION_SECRET_PATH := worxco/bastion/root-password

# Template files
VPC_TEMPLATE := cloudformation/cf-vpc.yaml
IAM_TEMPLATE := cloudformation/cf-iam.yaml
STORAGE_TEMPLATE := cloudformation/cf-storage.yaml
DATABASE_TEMPLATE := cloudformation/cf-database.yaml
CACHE_TEMPLATE := cloudformation/cf-cache.yaml

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
	@echo "  AWS_PROFILE:         $(CYAN)$${AWS_PROFILE:-<not set>}$(NC)"
	@echo "  AWS_REGION:          $(CYAN)$${AWS_REGION:-$(AWS_REGION)}$(NC)"
	@echo "  AWS_PAGER:           $(CYAN)$${AWS_PAGER:-<not set>}$(NC)"
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
	@echo "  make deploy-all               Deploy all stacks in order"
	@echo ""
	@echo "$(YELLOW)Verification:$(NC)"
	@echo "  make verify-all               Verify all stacks"
	@echo "  make verify-vpc               Verify VPC deployment"
	@echo "  make verify-iam               Verify IAM deployment"
	@echo "  make verify-storage           Verify storage deployment"
	@echo "  make verify-database          Verify database deployment"
	@echo "  make verify-cache             Verify cache deployment"
	@echo ""
	@echo "$(YELLOW)Destruction:$(NC)"
	@echo "  make destroy-vpc              Delete VPC stack"
	@echo "  make destroy-iam              Delete IAM stack"
	@echo "  make destroy-storage          Delete storage stack"
	@echo "  make destroy-database         Delete database stack"
	@echo "  make destroy-cache            Delete cache stack"
	@echo "  make destroy-all              Delete all stacks (reverse order)"
	@echo ""
	@echo "$(YELLOW)Bastion Host:$(NC)"
	@echo "  make deploy-bastion           Deploy bastion host (standalone)"
	@echo "  make verify-bastion           Show bastion connection info"
	@echo "  make stop-bastion             Stop bastion (EIP persists)"
	@echo "  make start-bastion            Start bastion instance"
	@echo "  make set-bastion-password     Set root password in Secrets Manager"
	@echo "  make destroy-bastion          Delete bastion host"
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

validate:  ## Validate all CloudFormation templates
	@echo "$(BLUE)Validating CloudFormation templates...$(NC)"
	@for template in $(VPC_TEMPLATE) $(IAM_TEMPLATE) $(STORAGE_TEMPLATE) $(DATABASE_TEMPLATE) $(CACHE_TEMPLATE) $(BASTION_TEMPLATE); do \
		if [ -f "$$template" ]; then \
			echo "  Validating $$template..."; \
			cfn-lint "$$template" || exit 1; \
		fi; \
	done
	@if [ -f $(PARAM_FILE) ]; then \
		echo "  Validating $(PARAM_FILE)..."; \
		jq empty $(PARAM_FILE) || exit 1; \
	else \
		echo "$(YELLOW)  Warning: Parameter file not found: $(PARAM_FILE)$(NC)"; \
	fi
	@if [ -f $(BASTION_PARAMS) ]; then \
		echo "  Validating $(BASTION_PARAMS)..."; \
		jq empty $(BASTION_PARAMS) || exit 1; \
	fi
	@echo "$(GREEN)✓ All templates valid$(NC)"

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
	@for stack in $(VPC_STACK) $(IAM_STACK) $(STORAGE_STACK) $(DATABASE_STACK) $(CACHE_STACK); do \
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

deploy-storage: validate check-params  ## Deploy storage stack
	@echo "$(BLUE)Deploying storage stack: $(STORAGE_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(STORAGE_TEMPLATE) \
		--stack-name $(STORAGE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
	@echo "$(GREEN)✓ Storage stack deployed: $(STORAGE_STACK)$(NC)"

deploy-database: validate check-params  ## Deploy database stack
	@echo "$(BLUE)Deploying database stack: $(DATABASE_STACK)$(NC)"
	@time aws cloudformation deploy \
		--template-file $(DATABASE_TEMPLATE) \
		--stack-name $(DATABASE_STACK) \
		--parameter-overrides $$(jq -r '.Parameters | to_entries | map("\(.key)=\(.value)") | join(" ")' $(PARAM_FILE)) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--no-fail-on-empty-changeset
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

deploy-all: deploy-vpc deploy-iam deploy-storage deploy-database deploy-cache  ## Deploy all stacks
	@echo "$(GREEN)✓ All stacks deployed for ENV=$(ENV)$(NC)"

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
	@aws cloudformation wait stack-delete-complete --stack-name $(VPC_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ VPC stack deleted: $(VPC_STACK)$(NC)"

destroy-iam:  ## Delete IAM stack
	@echo "$(YELLOW)Deleting IAM stack: $(IAM_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(IAM_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	@aws cloudformation wait stack-delete-complete --stack-name $(IAM_STACK) --region $(AWS_REGION)
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
	@echo "$(YELLOW)Deleting storage stack: $(STORAGE_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(STORAGE_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	@aws cloudformation wait stack-delete-complete --stack-name $(STORAGE_STACK) --region $(AWS_REGION)
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
	@aws cloudformation wait stack-delete-complete --stack-name $(DATABASE_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Database stack deleted: $(DATABASE_STACK)$(NC)"

destroy-cache:  ## Delete cache stack
	@echo "$(YELLOW)Deleting cache stack: $(CACHE_STACK)$(NC)"
	@time aws cloudformation delete-stack --stack-name $(CACHE_STACK) --region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	@aws cloudformation wait stack-delete-complete --stack-name $(CACHE_STACK) --region $(AWS_REGION)
	@echo "$(GREEN)✓ Cache stack deleted: $(CACHE_STACK)$(NC)"

destroy-all:  ## Delete all stacks (reverse order, with confirmation)
	@echo "$(RED)========================================$(NC)"
	@echo "$(RED)WARNING: This will DELETE ALL STACKS$(NC)"
	@echo "$(RED)Environment: $(ENV)$(NC)"
	@echo "$(RED)========================================$(NC)"
	@read -p "Type 'yes' to confirm COMPLETE TEARDOWN: " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo "Cancelled"; \
		exit 0; \
	fi
	@$(MAKE) destroy-cache ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-database ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-storage ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-iam ENV=$(ENV) CONFIRMED=yes || true
	@$(MAKE) destroy-vpc ENV=$(ENV) CONFIRMED=yes
	@echo "$(GREEN)✓ All stacks deleted for ENV=$(ENV)$(NC)"

# -----------------------------------------------------------------------------
# Bastion Host (Standalone)
# -----------------------------------------------------------------------------

deploy-bastion:  ## Deploy bastion host (standalone, uses default VPC)
	@echo "$(BLUE)Deploying bastion stack: $(BASTION_STACK)$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@time aws cloudformation deploy \
		--template-file $(BASTION_TEMPLATE) \
		--stack-name $(BASTION_STACK) \
		--parameter-overrides file://$(BASTION_PARAMS) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION)
	@echo "$(GREEN)✓ Bastion deployed$(NC)"
	@$(MAKE) verify-bastion

verify-bastion:  ## Show bastion connection info
	@echo "$(BLUE)Bastion Connection Info$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo ""
	@echo "$(CYAN)Stack Outputs:$(NC)"
	@aws cloudformation describe-stacks \
		--stack-name $(BASTION_STACK) \
		--query 'Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Bastion stack not found$(NC)"
	@echo ""
	@echo "$(CYAN)Instance Status:$(NC)"
	@aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(BASTION_STACK)" \
		--query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Type:InstanceType,IP:PublicIpAddress}' \
		--output table \
		--region $(AWS_REGION) 2>/dev/null || echo "  $(RED)Instance not found$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Bastion verification complete$(NC)"

destroy-bastion:  ## Delete bastion host
	@echo "$(RED)WARNING: This will delete the bastion host!$(NC)"
	@read -p "Type 'yes' to confirm: " confirm; \
	if [ "$$confirm" != "yes" ]; then \
		echo "Cancelled"; \
		exit 0; \
	fi
	@echo "$(YELLOW)Deleting bastion stack: $(BASTION_STACK)$(NC)"
	@time aws cloudformation delete-stack \
		--stack-name $(BASTION_STACK) \
		--region $(AWS_REGION)
	@echo "$(BLUE)Waiting for deletion to complete...$(NC)"
	@aws cloudformation wait stack-delete-complete \
		--stack-name $(BASTION_STACK) \
		--region $(AWS_REGION)
	@echo "$(GREEN)✓ Bastion deleted$(NC)"

stop-bastion:  ## Stop bastion instance (EIP persists)
	@echo "$(BLUE)Stopping bastion instance...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(BASTION_STACK)" \
			"Name=instance-state-name,Values=pending,running,stopping,stopped" \
		--query 'Reservations[].Instances[0].InstanceId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Error: Bastion instance not found$(NC)"; \
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
	echo "$(GREEN)✓ Bastion stopped (EIP remains associated)$(NC)"

start-bastion:  ## Start bastion instance
	@echo "$(BLUE)Starting bastion instance...$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=$(BASTION_STACK)" \
			"Name=instance-state-name,Values=pending,running,stopping,stopped" \
		--query 'Reservations[].Instances[0].InstanceId' \
		--output text \
		--region $(AWS_REGION) 2>/dev/null); \
	if [ -z "$$INSTANCE_ID" ] || [ "$$INSTANCE_ID" = "None" ]; then \
		echo "$(RED)Error: Bastion instance not found$(NC)"; \
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
	echo "$(GREEN)✓ Bastion started$(NC)"
	@echo ""
	@$(MAKE) verify-bastion

set-bastion-password:  ## Set root password for bastion in Secrets Manager
	@echo "$(BLUE)Set Bastion Root Password$(NC)"
	@echo "$(BLUE)========================================$(NC)"
	@echo "This password will be applied on next bastion deploy."
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
		--secret-id "$(BASTION_SECRET_PATH)" \
		--region $(AWS_REGION) >/dev/null 2>&1; then \
		aws secretsmanager put-secret-value \
			--secret-id "$(BASTION_SECRET_PATH)" \
			--secret-string "$$PASS1" \
			--region $(AWS_REGION) >/dev/null; \
		echo "$(GREEN)✓ Password updated in Secrets Manager$(NC)"; \
	else \
		aws secretsmanager create-secret \
			--name "$(BASTION_SECRET_PATH)" \
			--description "Root password for bastion host" \
			--secret-string "$$PASS1" \
			--region $(AWS_REGION) >/dev/null; \
		echo "$(GREEN)✓ Password created in Secrets Manager$(NC)"; \
	fi; \
	echo "  Secret: $(CYAN)$(BASTION_SECRET_PATH)$(NC)"; \
	echo "  $(YELLOW)Note: Password applies on next deploy-bastion (UserData runs on first boot only)$(NC)"

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
