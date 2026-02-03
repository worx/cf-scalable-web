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

  TESTS_RUN=$((TESTS_RUN + 1))
  echo -ne "Testing: ${test_name}... "

  if eval "$test_command" &> /dev/null; then
    echo -e "${GREEN}PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAIL${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  return 0
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
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-cache.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-image-builder.yaml"

# Test 15: Parameter files have EnvironmentName
run_test "EnvironmentName parameter exists" \
  "jq -e '.Parameters.EnvironmentName' cloudformation/parameters/production.json > /dev/null && \
   jq -e '.Parameters.EnvironmentName' cloudformation/parameters/staging.json > /dev/null"

# ---- Image Builder Tests ----
echo ""
echo "--- Image Builder ---"

# Test 16: Image Builder template syntax
run_test "cf-image-builder.yaml syntax" "cfn-lint cloudformation/cf-image-builder.yaml"

# Test 17: Image Builder parameter files
run_test "image-builder-sandbox.json syntax" "jq empty cloudformation/parameters/image-builder-sandbox.json"
run_test "image-builder-staging.json syntax" "jq empty cloudformation/parameters/image-builder-staging.json"
run_test "image-builder-production.json syntax" "jq empty cloudformation/parameters/image-builder-production.json"

# Test 18: Image Builder template has required outputs
run_test "Image Builder outputs present" \
  "grep -q 'NginxPipelineArn:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm74PipelineArn:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm83PipelineArn:' cloudformation/cf-image-builder.yaml && \
   grep -q 'BuildSecurityGroupId:' cloudformation/cf-image-builder.yaml"

# Test 19: Image Builder has all 3 pipelines
run_test "3 pipelines defined" \
  "grep -q 'NginxPipeline:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm74Pipeline:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm83Pipeline:' cloudformation/cf-image-builder.yaml"

# Test 20: Image Builder has all 3 recipes
run_test "3 recipes defined" \
  "grep -q 'NginxImageRecipe:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm74ImageRecipe:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm83ImageRecipe:' cloudformation/cf-image-builder.yaml"

# Test 21: Image Builder has base + install components
run_test "Components defined" \
  "grep -q 'BaseHardeningComponent:' cloudformation/cf-image-builder.yaml && \
   grep -q 'NginxInstallComponent:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm74InstallComponent:' cloudformation/cf-image-builder.yaml && \
   grep -q 'PhpFpm83InstallComponent:' cloudformation/cf-image-builder.yaml"

# Test 22: Config files exist
run_test "PHP 7.4 configs exist" \
  "test -f image-builder/configs/php/7.4/extensions.txt && \
   test -f image-builder/configs/php/7.4/www.conf && \
   test -f image-builder/configs/php/7.4/php.ini"

run_test "PHP 8.3 configs exist" \
  "test -f image-builder/configs/php/8.3/extensions.txt && \
   test -f image-builder/configs/php/8.3/www.conf && \
   test -f image-builder/configs/php/8.3/php.ini"

run_test "NGINX configs exist" \
  "test -f image-builder/configs/nginx/nginx.conf && \
   test -f image-builder/configs/nginx/upstream-php.conf.template"

run_test "authorized_keys exists" \
  "test -f image-builder/configs/authorized_keys"

# Test 23: IAM S3 policy has PutObject (build logs)
run_test "IAM S3 PutObject for build logs" \
  "grep -q 's3:PutObject' cloudformation/cf-iam.yaml"

# Test 24: IAM S3 ARN uses wildcard for BucketSuffix
run_test "IAM S3 ARN wildcard" \
  "grep -q 'image-builder\*' cloudformation/cf-iam.yaml"

# Test 25: Extension files have both mysql and pgsql
run_test "Dual DB drivers in extensions" \
  "grep -q 'mysql' image-builder/configs/php/7.4/extensions.txt && \
   grep -q 'pgsql' image-builder/configs/php/7.4/extensions.txt && \
   grep -q 'mysql' image-builder/configs/php/8.3/extensions.txt && \
   grep -q 'pgsql' image-builder/configs/php/8.3/extensions.txt"

# Test 26: FPM pools listen on port 9000
run_test "FPM listen on port 9000" \
  "grep -q 'listen = 0.0.0.0:9000' image-builder/configs/php/7.4/www.conf && \
   grep -q 'listen = 0.0.0.0:9000' image-builder/configs/php/8.3/www.conf"

# Test 27: Component reference files exist
run_test "Component reference files exist" \
  "test -f image-builder/components/base-hardening.yaml && \
   test -f image-builder/components/install-nginx.yaml && \
   test -f image-builder/components/install-php-fpm-74.yaml && \
   test -f image-builder/components/install-php-fpm-83.yaml && \
   test -f image-builder/components/test-base.yaml && \
   test -f image-builder/components/test-nginx.yaml && \
   test -f image-builder/components/test-php-fpm.yaml"

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
