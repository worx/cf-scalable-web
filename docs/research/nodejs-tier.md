# Worx CloudFormation Architecture Extension: Internal Node.js Service Tier for Drupal

## Purpose

This document defines the addition of a dedicated Node.js service tier to the existing Worx AWS hosting platform.

The intent is to support Drupal applications that optionally utilize Node.js for enhanced user interfaces, data-entry workflows, report generation, rendering services, and similar application features while preserving the existing Drupal/PHP implementation as the authoritative fallback.

The platform must continue to function normally if the Node.js service becomes unavailable.

---

# Existing Architecture

Current request flow:

```text
Internet
  ↓
Application Load Balancer (ALB)
  ↓
NGINX Auto Scaling Group
  ↓
PHP Network Load Balancer (NLB)
  ↓
PHP-FPM Auto Scaling Groups
     ├── PHP 7.4
     ├── PHP 8.1
     ├── PHP 8.2
     └── PHP 8.3
  ↓
Aurora PostgreSQL
```

Shared storage:

```text
FSx OpenZFS
  ├── NGINX ASG
  └── PHP ASGs
```

Shared services:

```text
Aurora PostgreSQL
Valkey
S3
SSM Parameter Store
Secrets Manager
```

PHP version routing is currently handled by NGINX selecting the appropriate port on the internal PHP NLB.

Examples:

```text
9074 → PHP 7.4
9081 → PHP 8.1
9082 → PHP 8.2
9083 → PHP 8.3
```

This architecture remains unchanged.

---

# Node.js Design Goals

## Node.js is an Internal Service

Node.js is not internet-facing.

Node.js is not directly accessed by browsers.

Node.js is not directly accessed by the ALB.

Node.js is not directly accessed by NGINX.

Node.js is accessed only from the Drupal/PHP layer.

---

## Drupal Remains Authoritative

Drupal remains the primary implementation.

Node.js provides enhanced functionality only.

Examples:

- Advanced data-entry interfaces
- Enhanced reporting
- Dynamic rendering
- Specialized transformations
- Optional application services

If Node.js is unavailable:

```text
Drupal must continue operating normally.
```

Node.js failures must never take down Drupal page rendering.

---

# New Architecture

## Request Flow

```text
Internet
  ↓
ALB
  ↓
NGINX ASG
  ↓
PHP NLB
  ↓
PHP-FPM ASGs
  ↓
Drupal
  ↓
Node NLB
  ↓
Node.js ASG
```

Detailed flow:

```text
Client
  ↓
ALB
  ↓
NGINX
  ↓
PHP NLB
  ↓
PHP-FPM
  ↓
Drupal
  ↓
Node NLB
  ↓
Node Service
  ↓
Response
  ↓
Drupal
  ↓
NGINX
  ↓
Client
```

---

# Dedicated Node Network Load Balancer

A dedicated internal NLB will be created.

The existing PHP NLB will not be reused.

Reasons:

- Separate trust boundary
- Independent scaling
- Independent health monitoring
- Independent deployment lifecycle
- Reduced blast radius
- Clear architectural separation

Node.js traffic is service-to-service traffic rather than request-routing traffic.

---

# New Infrastructure Components

## Node Launch Template

Create:

```text
NodeLaunchTemplate
```

Responsibilities:

- Install Node.js runtime
- Configure system services
- Mount FSx OpenZFS
- Configure CloudWatch
- Configure SSM
- Configure application deployment

---

## Node Auto Scaling Group

Create:

```text
NodeAutoScalingGroup
```

Initial recommendation:

```text
MinSize: 2
DesiredCapacity: 2
MaxSize: 10
```

Deploy across multiple Availability Zones.

---

## Node Target Group

Create:

```text
NodeTargetGroup
```

Protocol:

```text
TCP
or
HTTP
```

Port:

```text
3000
```

(or configurable parameter)

Health endpoint:

```text
GET /health
```

Expected response:

```text
HTTP 200
```

---

## Node Internal Network Load Balancer

Create:

```text
NodeInternalNLB
```

Internal-only.

Not internet-facing.

Example listener:

```text
3000 → NodeTargetGroup
```

Alternative:

```text
9100 → NodeTargetGroup
```

Port number to be determined during implementation.

---

# Shared Storage

## FSx OpenZFS

Initial implementation:

```text
NGINX
PHP
Node
```

all mount FSx OpenZFS.

Rationale:

Unknown whether Drupal Node integrations require direct access to:

- Templates
- Shared assets
- Uploaded files
- Generated reports
- Configuration files

Until proven otherwise:

```text
Mount FSx OpenZFS on Node tier.
```

Preferred future state:

If Node services operate entirely through API/JSON payloads:

```text
Remove FSx dependency.
```

This should be considered an optimization opportunity rather than an initial requirement.

---

# S3 Access

The existing platform heavily utilizes S3.

Node services may require:

- Reading uploaded assets
- Writing generated reports
- Temporary object creation
- Export generation
- Shared document processing

Because S3 is already a shared service:

```text
PHP → S3
Node → S3
```

No additional storage architecture is required.

Implementation recommendation:

Use IAM Roles attached to Node instances.

Avoid static credentials.

Permissions should follow least-privilege principles.

---

# Database Access

## Initial Recommendation

Assume:

```text
Node does NOT require direct Aurora access.
```

Preferred flow:

```text
Drupal
  ↓
Node Service
```

with Drupal supplying necessary data through API requests.

Benefits:

- Reduced security exposure
- Simplified service boundaries
- Easier auditing
- Easier scaling

---

## Future Option

If Drupal team requirements demand it:

```text
Node
  ↓
Aurora PostgreSQL
```

may be enabled.

This should be treated as a separate design decision.

Direct database access should not be assumed in the first implementation.

---

# Security Groups

## Existing

```text
ALB SG
  → NGINX SG

NGINX SG
  → PHP NLB / PHP SG

PHP SG
  → Aurora
  → Valkey
  → S3
  → FSx
```

---

## New

```text
PHP SG
  → Node SG : 3000

Node SG
  ← PHP SG only
```

Node should not receive traffic directly from:

```text
Internet
ALB
NGINX
```

unless future requirements explicitly require it.

---

## Optional Access

Allow only if needed:

```text
Node SG
  → Aurora SG

Node SG
  → Valkey SG

Node SG
  → FSx SG

Node SG
  → S3 endpoints
```

---

# Service Discovery

Recommended:

```text
node-service.internal
```

or equivalent Route53 private DNS name.

Drupal configuration example:

```text
NODE_SERVICE_URL=http://node-service.internal:3000
```

Store configuration in:

```text
SSM Parameter Store
```

or

```text
Secrets Manager
```

consistent with existing platform standards.

---

# Failure Handling

Node.js is optional enhancement infrastructure.

Drupal must gracefully degrade.

Required behavior:

```text
Node available
  → enhanced experience

Node unavailable
  → standard Drupal implementation
```

Recommended:

```text
Timeout: 1-3 seconds
Retries: none during user requests
Fallback: immediate
Logging: required
Metrics: required
```

Node failures must never generate site-wide outages.

---

# Monitoring

Create CloudWatch alarms for:

```text
Node Target Health
Node NLB Health
Node ASG Capacity
Node Memory
Node CPU
Node Response Time
Node Error Rate
```

Log aggregation should follow existing platform standards.

---

# CloudFormation Deliverables

Add:

```text
NodeLaunchTemplate
NodeAutoScalingGroup
NodeTargetGroup
NodeInternalNLB
NodeSecurityGroup
NodeIAMRole
NodeInstanceProfile
NodeCloudWatchConfiguration
NodeSSMConfiguration
```

Add optional:

```text
NodeFSxMount
NodeS3Permissions
NodeValkeyAccess
NodeAuroraAccess
```

controlled through parameters where practical.

---

# Final Architectural Diagram

```text
Internet
  ↓
ALB
  ↓
NGINX ASG
  ↓
PHP NLB
  ├── PHP 7.4 ASG
  ├── PHP 8.1 ASG
  ├── PHP 8.2 ASG
  └── PHP 8.3 ASG
          ↓
        Drupal
          ↓
      Node NLB
          ↓
      Node ASG

Shared Services
  ├── FSx OpenZFS
  ├── Aurora PostgreSQL
  ├── Valkey
  ├── S3
  ├── SSM Parameter Store
  └── Secrets Manager
```

The Node.js tier is an internal, scalable, optional application-service layer that enhances Drupal functionality while preserving complete Drupal-only operation in the event of Node service failure.