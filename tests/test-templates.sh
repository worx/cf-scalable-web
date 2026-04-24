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
run_test "Cache encryption configured" \
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

# ---- Compute Layer Tests ----
echo ""
echo "--- Compute Layer ---"

# Test: ALB template syntax
run_test "cf-compute-alb.yaml syntax" "cfn-lint cloudformation/cf-compute-alb.yaml"

# Test: NLB template syntax
run_test "cf-compute-nlb.yaml syntax" "cfn-lint cloudformation/cf-compute-nlb.yaml"

# Test: NGINX compute template syntax
run_test "cf-compute-nginx.yaml syntax" "cfn-lint cloudformation/cf-compute-nginx.yaml"

# Test: PHP compute template syntax
run_test "cf-compute-php.yaml syntax" "cfn-lint cloudformation/cf-compute-php.yaml"

# Test: Compute parameter files (sandbox)
run_test "compute-alb-sandbox.json syntax" "jq empty cloudformation/parameters/compute-alb-sandbox.json"
run_test "compute-nlb-sandbox.json syntax" "jq empty cloudformation/parameters/compute-nlb-sandbox.json"
run_test "compute-nginx-sandbox.json syntax" "jq empty cloudformation/parameters/compute-nginx-sandbox.json"
run_test "compute-php-sandbox.json syntax" "jq empty cloudformation/parameters/compute-php-sandbox.json"

# Test: ALB has required resources
run_test "ALB resources present" \
  "grep -q 'ApplicationLoadBalancer:' cloudformation/cf-compute-alb.yaml && \
   grep -q 'NginxTargetGroup:' cloudformation/cf-compute-alb.yaml && \
   grep -q 'HTTPListener:' cloudformation/cf-compute-alb.yaml && \
   grep -q 'EnvironmentNameParameter:' cloudformation/cf-compute-alb.yaml"

# Test: NLB has required resources
run_test "NLB resources present" \
  "grep -q 'NetworkLoadBalancer:' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'PHP74TargetGroup:' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'PHP83TargetGroup:' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'PHP74Listener:' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'PHP83Listener:' cloudformation/cf-compute-nlb.yaml"

# Test: NLB listener ports are 9074 and 9083
run_test "NLB listener ports (9074, 9083)" \
  "grep -q 'Port: 9074' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'Port: 9083' cloudformation/cf-compute-nlb.yaml"

# Test: NGINX has ASG and launch template
run_test "NGINX ASG and launch template present" \
  "grep -q 'NginxLaunchTemplate:' cloudformation/cf-compute-nginx.yaml && \
   grep -q 'NginxAutoScalingGroup:' cloudformation/cf-compute-nginx.yaml && \
   grep -q 'NginxScaleOutPolicy:' cloudformation/cf-compute-nginx.yaml && \
   grep -q 'NginxScaleInPolicy:' cloudformation/cf-compute-nginx.yaml"

# Test: PHP has ASGs and launch templates for both versions
run_test "PHP ASGs and launch templates present" \
  "grep -q 'PHP74LaunchTemplate:' cloudformation/cf-compute-php.yaml && \
   grep -q 'PHP83LaunchTemplate:' cloudformation/cf-compute-php.yaml && \
   grep -q 'PHP74AutoScalingGroup:' cloudformation/cf-compute-php.yaml && \
   grep -q 'PHP83AutoScalingGroup:' cloudformation/cf-compute-php.yaml"

# Test: MaxInstanceLifetime is 604800 (7 days)
run_test "MaxInstanceLifetime 604800 in NGINX" \
  "grep -q 'MaxInstanceLifetime: 604800' cloudformation/cf-compute-nginx.yaml"

run_test "MaxInstanceLifetime 604800 in PHP" \
  "grep -q 'MaxInstanceLifetime: 604800' cloudformation/cf-compute-php.yaml"

# Test: SSM parameters configured
run_test "SSM parameter /environment/name in ALB" \
  "grep -q '/environment/name' cloudformation/cf-compute-alb.yaml"

run_test "SSM parameter NLB endpoint in NLB" \
  "grep -q '/nlb/endpoint' cloudformation/cf-compute-nlb.yaml"

# Test: IMDSv2 metadata options present (currently optional, pending AMI rebuild for required)
run_test "IMDSv2 metadata in NGINX" \
  "grep -q 'HttpTokens: optional' cloudformation/cf-compute-nginx.yaml"

run_test "IMDSv2 metadata in PHP" \
  "grep -q 'HttpTokens: optional' cloudformation/cf-compute-php.yaml"

# Test: EBS encryption enabled
run_test "EBS encryption in NGINX" \
  "grep -q 'Encrypted: true' cloudformation/cf-compute-nginx.yaml"

run_test "EBS encryption in PHP" \
  "grep -q 'Encrypted: true' cloudformation/cf-compute-php.yaml"

# Test: GPL headers on compute templates
run_test "GPL headers on compute templates" \
  "grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-compute-alb.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-compute-nlb.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-compute-nginx.yaml && \
   grep -q 'SPDX-License-Identifier: GPL-2.0-or-later' cloudformation/cf-compute-php.yaml"

# Test: Health check in NGINX UserData
run_test "Health check in NGINX UserData" \
  "grep -q '/health' cloudformation/cf-compute-nginx.yaml && \
   grep -q 'health-check.conf' cloudformation/cf-compute-nginx.yaml"

# Test: PHP version conditionals present
run_test "PHP version conditionals present" \
  "grep -q 'PHP74Enabled:' cloudformation/cf-compute-php.yaml && \
   grep -q 'PHP83Enabled:' cloudformation/cf-compute-php.yaml && \
   grep -q 'EnablePHP74' cloudformation/cf-compute-php.yaml && \
   grep -q 'EnablePHP83' cloudformation/cf-compute-php.yaml"

# Test: VPC SG ports updated to 9070-9099
run_test "VPC NLB SG ports 9070-9099" \
  "grep -q 'FromPort: 9070' cloudformation/cf-vpc.yaml && \
   grep -q 'ToPort: 9099' cloudformation/cf-vpc.yaml"

# Test: IAM has /environment/name SSM path
run_test "IAM SSM path includes /environment/name" \
  "grep -q 'parameter/environment/name' cloudformation/cf-iam.yaml"

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
