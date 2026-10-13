---
name: aws-tf-conventions
description: Project-specific Terraform rules for the AWS KAS/NVCF EKS foundation. Use when writing or reviewing AWS Terraform for VPC, EKS, node groups, IAM, ECR, state, tags, provider configuration, or before terraform apply.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "terraform", "eks", "conventions"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# AWS Terraform Conventions

## Purpose

Apply these rules to all AWS foundation Terraform generated for KAS/NVCF EKS.
This skill owns conventions only; use component skills for resource-specific
content.

## Terraform Ownership

Terraform owns these resources:

- VPC and subnets
- Internet gateway, NAT gateway, route tables, and subnet route associations
- EKS cluster and OIDC provider
- EKS managed node groups: `system`, `compute`, and `gpu`
- IAM roles and policies for the cluster and node groups
- ECR repositories under a stable cluster prefix, for example `${CLUSTER_NAME}/...`
- Security groups needed for EKS-managed infrastructure only
- Terraform outputs needed by later skills

Terraform must not own:

- Kubernetes in-cluster objects such as namespaces, services, service accounts,
  RBAC, ConfigMaps, or storage classes
- Helm releases or Helmfile environments
- NVCF control plane, NVCA, LLS, caches, UCC, OVDC, storage APIs, functions, or
  stream validation
- NGC to ECR image copy jobs
- Secret values or registry auth artifacts
- GPU Operator Helm release state

## Project Rules

1. Keep image mirroring separate from infra. Infra may create ECR repositories,
   but it must not copy NGC images as part of `terraform apply`.
2. Do not hardcode image versions in Terraform.
3. Do not create login material or machine access material with Terraform.
4. Do not use `null_resource` or `local-exec` for mirror jobs, waiters, or
   imperative Kubernetes work.
5. Use AWS-managed EKS behavior where possible. App ingress belongs to
   Kubernetes controllers/services after infra.
6. Use explicit per-environment CIDRs. Do not auto-select CIDRs unless the repo
   already has a reviewed helper for that.
7. Keep state safe. Prefer a remote backend for shared work; if local state is
   used, never run concurrent applies against the same env.
8. Add consistent tags to all taggable resources: `Name`, `cluster`, `owner`,
   `environment`, `managed-by=terraform`, and `workload=kas`.
9. Use the EKS GPU-optimized AMI for the GPU managed node group:
   `ami_type = "AL2023_x86_64_NVIDIA"`.
10. Label GPU nodes with `nvidia.com/gpu.deploy.driver=false`; GPU Operator
    must not install the driver or container toolkit.
11. Keep Helm releases outside Terraform state.
12. Do not store secrets in `*.tf`, `*.tfvars`, generated scripts, or Terraform
    state when avoidable.

## Expected Layout

Use a root stack per environment. A simple validation layout is acceptable:

```text
terraform/aws/envs/<cluster>/
├── main.tf
├── providers.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars
```

When generating review artifacts, prefix the same layout with `generated/`:

```text
generated/terraform/aws/envs/<cluster>/
```

For promoted code, split into modules only when it removes real complexity:

```text
terraform/aws/modules/network
terraform/aws/modules/eks
terraform/aws/modules/ecr
```

## Provider And Backend

Require explicit region input:

```hcl
variable "aws_region" {
  type = string
}

provider "aws" {
  region = var.aws_region
}
```

Prefer a remote backend for shared environments. If using local state for a
single-user validation environment, call that out in the generated README or
run instructions and do not run concurrent applies.

## Pre-Apply Checklist

- [ ] `terraform fmt -recursive` has run.
- [ ] `terraform validate` passes.
- [ ] `terraform plan` contains only expected AWS foundation resources.
- [ ] No plan action destroys or replaces a resource without explicit review.
- [ ] Tags are present on all taggable resources.
- [ ] No secrets or kubeconfig contents appear in Terraform files or outputs.
- [ ] GPU Operator, NVCF, and image mirroring are outside Terraform.
