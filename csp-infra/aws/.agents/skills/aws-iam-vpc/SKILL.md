---
name: aws-iam-vpc
description: Generate the AWS network and IAM foundation for a KAS/NVCF EKS deployment: VPC, public/private subnets, route tables, Internet/NAT gateways, and base IAM/tagging inputs. Use as Stage 01 of aws-infra before eks-cluster.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "vpc", "iam", "terraform"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AWS IAM + VPC Foundation

## What This Skill Produces

Generate Terraform for the AWS network foundation used by EKS:

- VPC
- public and private subnets across available AZs
- Internet gateway
- NAT gateway and route tables
- subnet route associations
- common tags and naming locals
- IAM inputs consumed by later EKS resources

Do not create the EKS cluster, node groups, ECR repositories, Kubernetes
objects, Helm releases, or mirror jobs here.

## Inputs

Required:

| Input | Notes |
|---|---|
| `AWS_ACCOUNT_ID` | Must match the active AWS CLI identity before apply. |
| `AWS_REGION` | Target AWS region. |
| `CLUSTER_NAME` | Stable prefix for network names and Kubernetes discovery tags. |
| `OWNER` | Owner/team tag. |

Defaults when the user does not provide values:

| Input | Default |
|---|---|
| VPC CIDR | `10.10.0.0/16` |
| private subnet CIDRs | three `/20` ranges across available AZs |
| public subnet CIDRs | three `/24` ranges across available AZs |
| environment tag | `dev` |

## Generation Rules

- Read `aws-tf-conventions` before generating Terraform.
- Use explicit CIDRs in `terraform.tfvars`; do not pick hidden defaults inside
  modules.
- Tag subnets for Kubernetes load balancer discovery:
  - private: `kubernetes.io/role/internal-elb = "1"`
  - public: `kubernetes.io/role/elb = "1"`
  - both: `kubernetes.io/cluster/<cluster-name> = "shared"`
- Prefer private subnets for EKS node groups.
- Keep app ingress outside this skill; only provision AWS network foundation.

## Preflight

Before generating apply instructions, include these checks:

```bash
aws sts get-caller-identity --query Account --output text
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[?State==`available`].ZoneName' --output text
```

Block if the active account does not equal `AWS_ACCOUNT_ID`.

## Terraform Shape

The generated stack should expose network outputs for later skills:

```hcl
output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}
```

Use locals for common tags:

```hcl
locals {
  common_tags = {
    cluster    = var.cluster_name
    owner      = var.owner
    environment = var.environment
    managed-by = "terraform"
    workload   = "kas"
  }
}
```

## Validation Checklist

- [ ] VPC CIDR and subnet CIDRs are explicit inputs.
- [ ] At least two AZs are used; three is preferred when available.
- [ ] Private subnets have outbound access through NAT.
- [ ] Kubernetes subnet discovery tags are present.
- [ ] Network outputs are available for `eks-cluster` and `eks-nodes`.
- [ ] No EKS, ECR, Helm, or Kubernetes objects are created here.
