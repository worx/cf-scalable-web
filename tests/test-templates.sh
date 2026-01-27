#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 The Worx Company
# Author: Kurt Vanderwater <kurt@worxco.net>

#
# Function: test-templates
# Purpose: Validate all CloudFormation templates and parameter files
# Returns: 0 on success, 1 on failure
# Dependencies: cfn-lint, jq
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Function: run_test
# Purpose: Run a test and track results
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

echo "================================"
echo "CloudFormation Template Tests"
echo "================================"
echo ""

# Check dependencies
echo "Checking dependencies..."
for cmd in cfn-lint jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo -e "${RED}Error: $cmd not found${NC}" >&2
    exit 1
  fi
done
echo -e "${GREEN}✓ Dependencies OK${NC}\n"

# Test 1: VPC template syntax
run_test "cf-vpc.yaml syntax" "cfn-lint cloudformation/cf-vpc.yaml"

# Test 2: IAM template syntax
run_test "cf-iam.yaml syntax" "cfn-lint cloudformation/cf-iam.yaml"

# Test 3: Storage template syntax
run_test "cf-storage.yaml syntax" "cfn-lint cloudformation/cf-storage.yaml"

# Test 4: Database template syntax
run_test "cf-database.yaml syntax" "cfn-lint cloudformation/cf-database.yaml"

# Test 5: Cache template syntax
run_test "cf-cache.yaml syntax" "cfn-lint cloudformation/cf-cache.yaml"

# Test 6: Production parameter file
run_test "production.json syntax" "jq empty cloudformation/parameters/production.json"

# Test 7: Staging parameter file
run_test "staging.json syntax" "jq empty cloudformation/parameters/staging.json"

# Test 8: Template parameter file
run_test "template.json syntax" "jq empty cloudformation/parameters/template.json"

# Test 9: VPC template has required outputs
run_test "VPC outputs present" \
  "grep -q 'VPCId:' cloudformation/cf-vpc.yaml && \
   grep -q 'PublicSubnets:' cloudformation/cf-vpc.yaml && \
   grep -q 'PrivateNginxSubnets:' cloudformation/cf-vpc.yaml"

# Test 10: IAM template has required outputs
run_test "IAM outputs present" \
  "grep -q 'NginxInstanceProfileArn:' cloudformation/cf-iam.yaml && \
   grep -q 'PHPInstanceProfileArn:' cloudformation/cf-iam.yaml"

# Test 11: Storage template has FSx configuration
run_test "FSx configuration present" \
  "grep -q 'FSxFileSystem:' cloudformation/cf-storage.yaml && \
   grep -q 'OpenZFSConfiguration:' cloudformation/cf-storage.yaml"

# Test 12: Database template has Multi-AZ enabled
run_test "RDS Multi-AZ configured" \
  "grep -q 'MultiAZ: true' cloudformation/cf-database.yaml"

# Test 13: Cache template has encryption
run_test "Redis encryption configured" \
  "grep -q 'TransitEncryptionEnabled: true' cloudformation/cf-cache.yaml && \
   grep -q 'AtRestEncryptionEnabled: true' cloudformation/cf-cache.yaml"

# Test 14: All templates have GPL headers
run_test "GPL headers present" \
  "grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-vpc.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-iam.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-storage.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-database.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-cache.yaml"

# Test 15: Parameter files have EnvironmentName
run_test "EnvironmentName parameter exists" \
  "jq -e '.Parameters.EnvironmentName' cloudformation/parameters/production.json > /dev/null && \
   jq -e '.Parameters.EnvironmentName' cloudformation/parameters/staging.json > /dev/null"

echo ""
echo "================================"
echo "Test Results"
echo "================================"
echo "Total: $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
  echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
  exit 1
else
  echo -e "Failed: $TESTS_FAILED"
  echo ""
  echo -e "${GREEN}✓ All tests passed${NC}"
  exit 0
fi
