---
name: eks-cluster
description: Generate Terraform for the EKS control plane, OIDC provider, cluster IAM role, system node group, and kubeconfig handoff. Use after aws-iam-vpc and before eks-nodes in the aws-infra workflow.
version: "1.0.0"
author: NVIDIA Omniverse Streaming
tags: ["aws", "eks", "terraform", "kubernetes"]
tools: ["Shell", "Read", "Write"]
---

<!-- SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. -->
<!-- SPDX-License-Identifier: CC-BY-4.0 AND Apache-2.0 -->

# EKS Cluster

## What This Skill Produces

Generate Terraform for:

- EKS control plane
- cluster IAM role and required policies
- OIDC provider for workload identity integrations
- system managed node group
- outputs needed by downstream node, ECR, GPU Operator, and validation skills

Do not create compute or GPU workload node groups here; use `eks-nodes`.
Do not install Kubernetes add-ons with Helm here; use later skills.

## Inputs

Required:

| Input | Notes |
|---|---|
| `AWS_REGION` | Target AWS region. |
| `CLUSTER_NAME` | EKS cluster name. |
| `private_subnet_ids` | From `aws-iam-vpc`. |
| `OWNER` | Owner/team tag. |

Optional:

| Input | Default |
|---|---|
| EKS Kubernetes version | AWS default unless the user pins one |
| system node instance type | `m6i.xlarge` |
| system min/max/desired | `1` / `3` / `1` |

## Generation Rules

- Read `aws-tf-conventions` before generating Terraform.
- Use private subnets for the system node group.
- Keep node group labels stable:

```text
system: node-type=system
```

- Ensure cluster outputs support later scripts:

```hcl
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
```

## Apply Handoff

After Terraform apply succeeds, update kubeconfig:

```bash
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME"
kubectl --context "$CLUSTER_NAME" get nodes
```

## Name Collision Check

Before creating a fresh cluster, check for existing resources:

```bash
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"
```

If the cluster exists, stop and ask whether to adopt, clean up, or choose a new
cluster name.

## Validation Checklist

- [ ] EKS cluster is created in private subnets from `aws-iam-vpc`.
- [ ] OIDC provider is enabled.
- [ ] System node group uses stable `node-type=system` label.
- [ ] Kubeconfig handoff command uses `--alias "$CLUSTER_NAME"`.
- [ ] No compute/GPU node groups, Helm releases, image mirrors, or runtime
      components are created here.
