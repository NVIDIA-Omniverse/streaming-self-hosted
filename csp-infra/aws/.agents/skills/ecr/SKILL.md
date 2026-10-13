---
name: ecr
description: Generate Terraform for AWS ECR repositories and EKS pull access needed by KAS/NVCF. Use after eks-cluster or eks-nodes and before ecr-mirror; this skill creates repositories only and does not mirror images.
version: "1.1.0"
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
| `TARGET_REPOSITORY` | `${CLUSTER_NAME}`, with trailing slashes removed |
| `TARGET_IMAGE_REPOSITORY` | Normalized `${TARGET_REPOSITORY}` |
| `TARGET_CHART_REPOSITORY` | Normalized `${TARGET_REPOSITORY}/charts` |
| repository names | Derived from the manifest or declared by the caller |
| scan on push | `true` |
| encryption | `AES256` unless a KMS key is provided |

## Repository Contract

Create repositories with this naming convention:

```text
${TARGET_IMAGE_REPOSITORY}/${image-name}
${TARGET_CHART_REPOSITORY}/${chart-name}
```

Keep the image and chart prefixes distinct so equal image/chart names and tags
cannot overwrite one another. Remove all trailing `/` characters from the base,
image, and chart prefixes before deriving or joining repository paths. Do not
mirror to the registry root. Stop if any normalized prefix is empty.

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

output "ecr_image_repository_prefix" {
  value = var.target_image_repository
}

output "ecr_chart_repository_prefix" {
  value = var.target_chart_repository
}
```

## Validation Checklist

- [ ] Base, image, and chart repository prefixes are non-empty and have no trailing slash.
- [ ] Image repositories use `${TARGET_IMAGE_REPOSITORY}/...`.
- [ ] Chart repositories use `${TARGET_CHART_REPOSITORY}/...`.
- [ ] Image and chart repository prefixes differ.
- [ ] EKS pull permissions are present.
- [ ] No NGC credentials, ECR passwords, or mirror jobs are in Terraform.
- [ ] `ecr-mirror` remains the only skill that copies images/charts.
