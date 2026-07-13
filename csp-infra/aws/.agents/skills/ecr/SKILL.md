---
name: ecr
description: Generate Terraform for AWS ECR repositories and EKS pull access needed by KAS/NVCF. Use after eks-cluster or eks-nodes and before ecr-mirror; this skill creates repositories only and does not mirror images.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "ecr", "terraform", "registry"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# ECR Repositories

## What This Skill Produces

Generate Terraform for ECR repositories under a stable cluster prefix, plus
repository outputs and pull permissions needed by EKS nodes or pod identity.

This skill does not copy images or charts. Use `ecr-mirror` for NGC to ECR
mirroring after repositories and permissions are ready.

## Inputs

Required:

| Input | Notes |
|---|---|
| `AWS_ACCOUNT_ID` | AWS account that owns the target registry. |
| `AWS_REGION` | Target ECR region. |
| `CLUSTER_NAME` | Default ECR repository prefix. |

Optional:

| Input | Default |
|---|---|
| `TARGET_REPOSITORY` | `${CLUSTER_NAME}` |
| repository names | Derived from the manifest or declared by the caller |
| scan on push | `true` |
| encryption | `AES256` unless a KMS key is provided |

## Repository Contract

Create repositories with this naming convention:

```text
${TARGET_REPOSITORY}/${image-or-chart-name}
```

Do not mirror to the registry root. Stop if `TARGET_REPOSITORY` is empty.

## Pull Permissions

For EKS pulls, confirm the node role or pod identity has ECR read access:

```text
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

## Preflight

Check for collisions before creating repositories:

```bash
aws ecr describe-repositories --region "$AWS_REGION" \
  --query "repositories[?starts_with(repositoryName, '${CLUSTER_NAME}/')].repositoryName"
```

If repositories already exist with the cluster prefix, stop and ask whether to
adopt, clean up, or choose a new prefix.

## Outputs

Expose values later skills can consume:

```hcl
output "ecr_registry" {
  value = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_prefix" {
  value = var.target_repository
}
```

## Validation Checklist

- [ ] Repository prefix is non-empty.
- [ ] Repository names use `${TARGET_REPOSITORY}/...`.
- [ ] EKS pull permissions are present.
- [ ] No NGC credentials, ECR passwords, or mirror jobs are in Terraform.
- [ ] `ecr-mirror` remains the only skill that copies images/charts.
