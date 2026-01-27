#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: test-vpc
# Purpose: Test VPC CloudFormation template structure
# Returns: 0 on success, 1 on failure
# Dependencies: grep, yq (optional)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
  local test_name="$1"
  local test_command="$2"

  ((TESTS_RUN++))
  echo -ne "Testing: ${test_name}... "

  if eval "$test_command" &> /dev/null; then
    echo -e "${GREEN}PASS${NC}"
    ((TESTS_PASSED++))
    return 0
  else
    echo -e "${RED}FAIL${NC}"
    ((TESTS_FAILED++))
    return 1
  fi
}

echo "========================"
echo "VPC Template Tests"
echo "========================"
echo ""

VPC_TEMPLATE="cloudformation/cf-vpc.yaml"

# Test 1: Template file exists
run_test "VPC template exists" "test -f $VPC_TEMPLATE"

# Test 2: Has VPC resource
run_test "VPC resource defined" "grep -q 'Type: AWS::EC2::VPC' $VPC_TEMPLATE"

# Test 3: Has Internet Gateway
run_test "Internet Gateway defined" "grep -q 'Type: AWS::EC2::InternetGateway' $VPC_TEMPLATE"

# Test 4: Has NAT Gateways
run_test "NAT Gateways defined" "grep -q 'Type: AWS::EC2::NatGateway' $VPC_TEMPLATE"

# Test 5: Has public subnets
run_test "Public subnets defined" "grep -q 'PublicSubnet1:' $VPC_TEMPLATE"

# Test 6: Has private NGINX subnets
run_test "NGINX subnets defined" "grep -q 'PrivateTier1Subnet1:' $VPC_TEMPLATE"

# Test 7: Has private NLB subnets
run_test "NLB subnets defined" "grep -q 'PrivateTier2Subnet1:' $VPC_TEMPLATE"

# Test 8: Has private PHP subnets
run_test "PHP subnets defined" "grep -q 'PrivateTier3Subnet1:' $VPC_TEMPLATE"

# Test 9: Has security groups
run_test "Security groups defined" \
  "grep -q 'ALBSecurityGroup:' $VPC_TEMPLATE && \
   grep -q 'NginxSecurityGroup:' $VPC_TEMPLATE && \
   grep -q 'PHPSecurityGroup:' $VPC_TEMPLATE"

# Test 10: ALB security group allows 80/443
run_test "ALB allows HTTP/HTTPS" \
  "grep -A 20 'ALBSecurityGroup:' $VPC_TEMPLATE | grep -q 'FromPort: 80' && \
   grep -A 20 'ALBSecurityGroup:' $VPC_TEMPLATE | grep -q 'FromPort: 443'"

# Test 11: NGINX security group references ALB
run_test "NGINX accepts from ALB" \
  "grep -A 30 'NginxSecurityGroup:' $VPC_TEMPLATE | grep -q 'SourceSecurityGroupId.*ALBSecurityGroup'"

# Test 12: PHP security group isolated
run_test "PHP isolated from ALB" \
  "grep -A 30 'PHPSecurityGroup:' $VPC_TEMPLATE | grep -q 'SourceSecurityGroupId.*NLBSecurityGroup'"

# Test 13: RDS security group defined
run_test "RDS security group defined" "grep -q 'RDSSecurityGroup:' $VPC_TEMPLATE"

# Test 14: FSx security group defined
run_test "FSx security group defined" "grep -q 'FSxSecurityGroup:' $VPC_TEMPLATE"

# Test 15: ElastiCache security group defined
run_test "ElastiCache security group defined" "grep -q 'ElastiCacheSecurityGroup:' $VPC_TEMPLATE"

# Test 16: Has required parameters
run_test "Required parameters defined" \
  "grep -q 'EnvironmentName:' $VPC_TEMPLATE && \
   grep -q 'VPCCidr:' $VPC_TEMPLATE && \
   grep -q 'AvailabilityZoneCount:' $VPC_TEMPLATE"

# Test 17: Has required outputs
run_test "Required outputs defined" \
  "grep -q 'VPCId:' $VPC_TEMPLATE && \
   grep -q 'PublicSubnets:' $VPC_TEMPLATE && \
   grep -q 'PrivateNginxSubnets:' $VPC_TEMPLATE"

# Test 18: Exports stack values
run_test "Exports defined" \
  "grep -q 'Export:' $VPC_TEMPLATE"

echo ""
echo "========================"
echo "Test Results"
echo "========================"
echo "Total: $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
  echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
  exit 1
else
  echo -e "Failed: $TESTS_FAILED"
  echo ""
  echo -e "${GREEN}✓ All VPC tests passed${NC}"
  exit 0
fi
